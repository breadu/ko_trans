import sys
import os
import datetime
import logging
from logger_util import log, DEBUG

import cv2
import numpy as np
import traceback
import math
import tempfile
import configparser
import asyncio
import mmap
import fugashi
import re

from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
from contextlib import asynccontextmanager
import uvicorn

from paddleocr import PaddleOCR
import paddle
import onnxruntime as ort
import path_util
import ai_engines
from PIL import Image, ImageDraw, ImageFont
import nvl_processor

@asynccontextmanager
async def lifespan(app: FastAPI):
    log("--- 🥊 KO Trans: One-Shot OCR & Translation Engine (FastAPI) Activated ---")
    init_ocr_engine()
    init_craft_engine()
    log("[System] KO Trans FastAPI Server is ready.")

    yield
    log("[System] KO Trans FastAPI Server is shutting down.")

# Initialize FastAPI application
app = FastAPI(title="KO Trans Engine", lifespan=lifespan)

# --- Shared Memory Configuration ---
SHM_NAME = "KO_TRANS_SHM"
SHM_SIZE = 4000 * 2500 * 4 + 1 # Add 1 byte for status flag
shm_obj = mmap.mmap(-1, SHM_SIZE, tagname=SHM_NAME)

# --- Define the Initialization Function ---
g_ocr = None
g_session = None
g_read_mode = "ADV"
g_is_jap_read_vertical = False
g_engine_name = "Gemini"
g_jap_tagger = None
g_active_profile = "Settings"
g_current_device = "Unknown"
g_typical_h = -1.0
g_h_history = []
g_last_crop_pos = {'x': -1, 'y': -1}     # Store top-left coordinates of the last successful crop to improve continuity

MAX_HISTORY = 10
INI_PATH = path_util.INI_PATH

# Function implementations
def init_craft_engine():
    """
    Loads the CRAFT (Scout) ONNX model into memory.
    Ensures that the model is only loaded when the server starts.
    """
    global g_session
    model_path = path_util.CRAFT_MODEL_PATH
    providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']

    try:
        # Attempt to load with GPU support (CUDA)
        g_session = ort.InferenceSession(model_path, providers=providers)
        log(f"--- [Info] CRAFT Loaded. Providers: {g_session.get_providers()}")
    except Exception as e:
        # Fallback to CPU if CUDA fails
        log(f"--- [Error] CRAFT CUDA loading failed: {e}")
        g_session = ort.InferenceSession(model_path, providers=['CPUExecutionProvider'])

def init_ocr_engine():
    """Reads settings.ini and initializes the OCR engine based on ACTIVE_PROFILE."""
    global g_ocr, g_last_crop_pos, g_current_device, g_read_mode, g_is_jap_read_vertical, g_engine_name, g_jap_tagger, g_active_profile

    g_last_crop_pos = {'x': -1, 'y': -1}
    config = configparser.ConfigParser()
    lang_from_ini = 'eng'
    active_profile = 'Settings'

    if os.path.exists(INI_PATH):
        try:
            for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
                try:
                    with open(INI_PATH, 'r', encoding=enc) as f:
                        config.read_file(f)
                    break
                except: continue

            active_profile = config.get('Settings', 'ACTIVE_PROFILE', fallback='Settings')

            g_read_mode = config.get(active_profile, 'READ_MODE',
                                   fallback=config.get('Settings', 'READ_MODE', fallback='ADV'))

            jap_read_vertical = config.get(active_profile, 'JAP_READ_VERTICAL',
                                   fallback=config.get('Settings', 'JAP_READ_VERTICAL', fallback='0'))

            g_engine_name = config.get(active_profile, 'ENGINE',
                                     fallback=config.get('Settings', 'ENGINE', fallback='Gemini'))

            # Read LANG for the specific profile; fallback to global Settings if missing
            lang_from_ini = config.get(active_profile, 'LANG',
                                     fallback=config.get('Settings', 'LANG', fallback='eng'))

            g_active_profile = active_profile

            if lang_from_ini == 'jap' and jap_read_vertical == '1':
                g_is_jap_read_vertical = True
            else:
                g_is_jap_read_vertical = False

            log(f"[Config] Cached Settings -> Profile: {active_profile}, Mode: {g_read_mode}, ReadVertical: {g_jap_read_vertical}, Engine: {g_engine_name}")

        except Exception as e:
            log(f"--- [Warning] INI Read Error: {e} ---")

    if lang_from_ini == 'jap':
        if g_jap_tagger is None:
            try:
                g_jap_tagger = fugashi.Tagger()
                log("[System] Japanese Tagger (fugashi) initialized and cached.")
            except Exception as e:
                log(f"[Error] Failed to initialize fugashi: {e}")
    else:
        # 영어 모드로 전환 시 메모리 절약을 위해 태거 해제 (선택 사항)
        g_jap_tagger = None

    # Map profile language to PaddleOCR language codes
    paddle_lang = 'en' if lang_from_ini == 'eng' else 'japan'
    log(f"--- 🌐 OCR Engine: {paddle_lang.upper()} Mode (Profile: {active_profile}) ---")

    can_use_gpu = paddle.device.is_compiled_with_cuda() and paddle.device.cuda.device_count() > 0
    if can_use_gpu:
        try:
            # Attempt to use GPU (Requires CUDA & cuDNN)
            g_ocr = PaddleOCR(
                lang=paddle_lang,
                device='gpu',
                ocr_version='PP-OCRv5',
                use_textline_orientation=True
            )
            g_current_device = "GPU"
            log("--- 🚀 KO Trans: GPU Mode Activated ---")
        except Exception as e:
            log(f"--- ⚠️ GPU Init failed: {e} ---")
            can_use_gpu = False # Fallback to CPU mode on failure

    if not can_use_gpu:
        # Plan B: Fallback to CPU mode
        g_ocr = PaddleOCR(
            lang=paddle_lang,
            device='cpu',
            ocr_version='PP-OCRv5',
            use_textline_orientation=True
        )
        g_current_device = "CPU"
        log("--- 💻 KO Trans: Falling back to CPU Mode ---")

async def read_shm_with_flag(w, h):
    """Safely reads image from shared memory by checking status flags (0:Idle, 1:Writing, 2:Ready)"""
    img_size = w * h * 4

    # 1. Check flag (wait up to 100ms for data readiness)
    success = False
    last_flag = -1
    for _ in range(10):
        shm_obj.seek(0)
        # Read the first byte to determine memory state
        last_flag = int.from_bytes(shm_obj.read(1), "little")
        if last_flag == 2: # 2 indicates 'Ready' for consumption
            success = True
            break
        await asyncio.sleep(0.01)

    if not success:
        if last_flag != 0: # Log only if not in Idle state
            log(f"[SHM] ⚠️ Flag Timeout. Current Flag: {last_flag} (Expected: 2)")
        return None

    # 2. Read raw pixel data (pointer is at offset 1 after reading flag)
    raw_data = shm_obj.read(img_size)

    # 3. Reset flag to 0 (Idle) after reading to allow next write
    shm_obj.seek(0)
    shm_obj.write(b'\x00')

    return raw_data

# Lightweight endpoint for health checks
@app.get("/health")
async def health_check():
    global g_current_device
    return {"status": "online", "device": g_current_device}

# Endpoint to reload configuration and restart all engines
@app.get("/reload")
async def reload_engine():
    global g_current_device, g_active_profile
    try:
        log("[System] Reloading all engines via /reload...")

        # Offload heavy model initialization to a separate thread to keep the event loop responsive
        await asyncio.to_thread(init_ocr_engine)

        try:
            # Reload engine settings asynchronously to prevent blocking during API client setup
            await asyncio.to_thread(ai_engines.chatgpt_brain.reload_settings, g_active_profile)
            await asyncio.to_thread(ai_engines.gemini_brain.reload_settings, g_active_profile)
            await asyncio.to_thread(ai_engines.local_brain.reload_settings, g_active_profile)
            log(f"[Reload] AI Engines reloaded with profile '{g_active_profile}'.")
        except Exception as e:
            log(f"[Warning] AI Engine reload failed: {e}")

        return {
            "status": "success",
            "device": g_current_device,
            "message": f"Reloaded successfully with profile: {g_active_profile}"
        }
    except Exception as e:
        log(f"[Error] Reload failed:\n{traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))

def select_best_adv_group(groups, res_img, target_w, target_h):
    """ADV Mode Selection Logic: Picks the best dialogue box candidate based on scoring."""
    def calculate_score(g, target_img):
        num_boxes = len(g)
        avg_ar = sum(c['ar'] for c in g) / float(num_boxes)
        total_width = sum(c['box'][2] for c in g)

        total_brightness = 0
        for c in g:
            bx, by, bw, bh = c['box']
            roi = target_img[by:by+bh, bx:bx+bw]
            if roi.size > 0: total_brightness += np.mean(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY))
        darkness = (255 - (total_brightness / num_boxes)) / 255.0

        avg_cx = sum(c['box'][0] + c['box'][2]/2 for c in g) / float(num_boxes)
        center_bias = 1.0 - (abs(avg_cx - (target_w / 2)) / (target_w / 2))

        pos_weight = 1.0
        if g_last_crop_pos['x'] != -1 and g_last_crop_pos['y'] != -1:
            group_min_x = min(c['box'][0] for c in g)
            group_min_y = min(c['box'][1] for c in g)
            dist = math.sqrt((group_min_x - g_last_crop_pos['x'])**2 + (group_min_y - g_last_crop_pos['y'])**2)
            pos_weight = 1.0 + (5.0 * math.exp(-dist / 100.0))

        return (num_boxes ** 2) * total_width * avg_ar * center_bias * darkness * pos_weight

    return max(groups, key=lambda g: calculate_score(g, res_img))

def get_read_mode():
    global g_read_mode
    return g_read_mode

def is_jap_read_vertical():
    global g_is_jap_read_vertical
    return g_is_jap_read_vertical

def get_smart_crop(img, update_history=True):
    """
    Common detection flow for both ADV and NVL modes.
    Uses CRAFT to find candidates, then branches processing based on MODE.
    """
    global g_typical_h, g_h_history, g_session
    if img is None:
        log(f"[Error] get_smart_crop: Image is None")
        return None, []

    orig_h, orig_w = img.shape[:2]

    # Smart Scaling: Limit long dimension to 960px for optimal detection performance
    MAX_DIM = 960
    if orig_w > MAX_DIM or orig_h > MAX_DIM:
        if orig_w > orig_h:
            tw = MAX_DIM
            th = int(orig_h * (MAX_DIM / orig_w))
        else:
            th = MAX_DIM
            tw = int(orig_w * (MAX_DIM / orig_h))
    else:
        tw, th = orig_w, orig_h

    # Ensure dimensions are multiples of 32 for CRAFT ONNX model requirements
    target_w, target_h = (tw // 32 + 1) * 32, (th // 32 + 1) * 32
    res_img = cv2.resize(img, (target_w, target_h), interpolation=cv2.INTER_LINEAR)

    # 1. CRAFT Detection
    res_img_float = res_img.astype(np.float32)
    res_img_float -= np.array([123.68, 116.78, 103.94], dtype=np.float32)
    res_img_float /= 255.0
    blob = np.transpose(res_img_float, (2, 0, 1))[np.newaxis, :, :, :]
    outputs = g_session.run(None, {g_session.get_inputs()[0].name: blob})
    score_text = outputs[0][0, 0, :, :] if outputs[0].shape[1] in [1, 2] else outputs[0][0, :, :, 0]

    _, mask = cv2.threshold(score_text, 0.3, 255, cv2.THRESH_BINARY)
    mask = cv2.dilate(mask.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_RECT, (5, 3)), iterations=6)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    if not contours:
        return img, []

    temp_candidates = []
    img_area = target_w * target_h
    for cnt in contours:
        x, y, w, h = cv2.boundingRect(cnt)
        if (w * h) < (img_area * 0.0001): continue
        aspect_ratio = w / float(h) if h > 0 else 0
        if aspect_ratio < 0.5: continue

        # Filter candidates based on g_typical_h (learned dialogue height)
        if g_typical_h > 0:
            # Filter out tiny regions (probable noise)
            if h < g_typical_h * 0.7:
                continue

            # Filter out oversized regions (background or giant UI)
            if h > g_typical_h * 2.0:
                continue

        # Include width to prevent downstream errors
        temp_candidates.append({'cnt': cnt, 'box': (x, y, w, h), 'ar': aspect_ratio, 'h': h, 'w': w})

    if not temp_candidates:
        return img, []

    # Apply horizontal noise filtering only for single-box detections
    if len(temp_candidates) == 1 and g_typical_h > 0:
        cand = temp_candidates[0]
        single_w = cand['w']
        single_x = cand['box'][0]

        # Check if the box is positioned near the starting X-coordinate of previous dialogues
        is_near_start = False
        if g_last_crop_pos['x'] != -1:
            # Threshold: 1.5x character height
            if abs(single_x - g_last_crop_pos['x']) <= (g_typical_h * 3):
                is_near_start = True

        # Ignore if the box is short AND not near the starting X line (likely random UI noise)
        if single_w < g_typical_h * 5.0 and not is_near_start:
            return img, []

    raw_candidates = temp_candidates

    # 2. Boxing Line Grouping
    groups = []
    raw_candidates.sort(key=lambda c: (c['box'][1], c['box'][0]))
    for cand in raw_candidates:
        added = False
        cx, cy, cw, ch = cand['box']
        for g in groups:
            match_found = False
            for m in g:
                mx, my, mw, mh = m['box']
                v_dist = abs((cy + ch/2) - (my + mh/2))
                v_gap = cy - (my + mh)
                h_gap = cx - (mx + mw)
                h_gap_rev = mx - (cx + cw)
                x_dist = abs(cx - mx)
                max_h = max(ch, mh)

                # Absolute horizontal distance between two boxes
                abs_h_gap = max(0, h_gap, h_gap_rev)

                # A. The same line (Horizontal) - Tightening to avoid noise
                is_same_line = (v_dist < max_h * 0.5) and (abs_h_gap < max_h * 2.5)
                # B. Vertical stacking - Crucial for nametags
                is_stacked = (abs(v_gap) < max_h * 2) and (x_dist < max_h * 1.5 or abs_h_gap < max_h * 1.5)

                if is_same_line or is_stacked:
                    match_found = True; break
            if match_found: g.append(cand); added = True; break
        if not added: groups.append([cand])

    # 3. Branching based on Mode
    mode = get_read_mode()
    selected_boxes = []
    paragraph_groups = []

    if mode == 'NVL':
        # NVL Mode: Use DBSCAN to cluster all detected regions into paragraphs
        paragraph_groups = nvl_processor.get_nvl_paragraphs(raw_candidates)
        # Combine all paragraphs into a single list of boxes for processing
        for p in paragraph_groups:
            selected_boxes.extend(p)
        # Update g_last_crop_pos for NVL continuity
        if selected_boxes:
            all_pts = np.concatenate([c['cnt'] for c in selected_boxes])
            gx, _, _, _ = cv2.boundingRect(all_pts)
            g_last_crop_pos['x'] = gx
    else:
        # ADV Mode: Select the single best dialogue group
        best_group = select_best_adv_group(groups, res_img, target_w, target_h)

        if not best_group:
            selected_boxes = []
        else:
            # [Logical Merge] Find other groups on the same horizontal plane as the best group
            best_p = np.concatenate([c['cnt'] for c in best_group])
            bx, by, bw, bh = cv2.boundingRect(best_p)

            final_selected = list(best_group)
            for g in groups:
                if g is best_group: continue

                g_p = np.concatenate([c['cnt'] for c in g])
                gx, gy, gw, gh = cv2.boundingRect(g_p)

                # Check for vertical overlap (min 60%) to confirm they belong to the same line
                overlap_y = max(0, min(by + bh, gy + gh) - max(by, gy))
                if overlap_y > (min(bh, gh) * 0.6):
                    # Horizontal distance check to ensure it's within game UI bounds
                    dist_h = max(0, gx - (bx + bw), bx - (gx + gw))
                    if dist_h < target_w * 0.8:
                        final_selected.extend(g)

            selected_boxes = final_selected

        # Store last position for ADV persistence
        if selected_boxes:
            group_p = np.concatenate([c['cnt'] for c in selected_boxes])
            gx, gy, _, _ = cv2.boundingRect(group_p)
            g_last_crop_pos['x'], g_last_crop_pos['y'] = gx, gy

    if selected_boxes and update_history:
        avg_h = sum(c['h'] for c in selected_boxes) / len(selected_boxes)

        if (target_h * 0.02) < avg_h < (target_h * 0.15):
            g_h_history.append(avg_h)
            if len(g_h_history) > MAX_HISTORY:
                g_h_history.pop(0)

            temp_sorted = sorted(g_h_history)
            g_typical_h = temp_sorted[len(temp_sorted)//2]

    # Filtering is always performed relative to the current g_typical_h
    filter_lower = 0.6 if len(g_h_history) < 5 else 0.7
    candidates = []
    for cand in temp_candidates:
        if g_typical_h > 0:
            if cand['h'] < g_typical_h * filter_lower or cand['h'] > g_typical_h * 3.0:
                continue
        candidates.append(cand)

    # 4. Debug Visualization
    sx, sy = orig_w / target_w, orig_h / target_h
    debug_img = img.copy()

    # (1) Draw all raw candidates in green
    for cand in raw_candidates:
        cx, cy, cw, ch = cand['box']
        cv2.rectangle(debug_img, (int(cx * sx), int(cy * sy)),
                      (int((cx + cw) * sx), int((cy + ch) * sy)), (0, 255, 0), 1)

    # Improved Visualization for NVL: Draw red boxes for each paragraph separately
    if mode == 'NVL' and paragraph_groups:
        for group in paragraph_groups:
            all_pts = np.concatenate([c['cnt'] for c in group])
            gx, gy, gw, gh = cv2.boundingRect(all_pts)
            rx, ry, rw, rh = int(gx * sx), int(gy * sy), int(gw * sx), int(gh * sy)
            cv2.rectangle(debug_img, (rx - 10, ry - 10), (rx + rw + 10, ry + rh + 10), (0, 0, 255), 3)
    elif selected_boxes:
        # Calculate overall bounding box for red visualization (ADV or Fallback)
        all_pts = np.concatenate([c['cnt'] for c in selected_boxes])
        gx, gy, gw, gh = cv2.boundingRect(all_pts)
        rx, ry, rw, rh = int(gx * sx), int(gy * sy), int(gw * sx), int(gh * sy)
        cv2.rectangle(debug_img, (rx - 10, ry - 10), (rx + rw + 10, ry + rh + 10), (0, 0, 255), 3)

    if DEBUG:
        debug_save_path = os.path.join(tempfile.gettempdir(), "image_ko_trans_debug_craft.jpg")
        cv2.imwrite(debug_save_path, debug_img)

    # Return coordinates mapped back to original image size
    final_boxes = [{'x': int(c['box'][0]*sx), 'y': int(c['box'][1]*sy),
                    'w': int(c['box'][2]*sx), 'h': int(c['box'][3]*sy)} for c in selected_boxes]

    return img, final_boxes

@app.post("/detect")
async def do_detect(request: Request):
    try:
        data = await request.json()
        w, h = data.get("w"), data.get("h")

        if not w or not h:
            return PlainTextResponse("0,0,0")

        img_size = w * h * 4

        raw_data = await read_shm_with_flag(w, h)

        actual_size = len(raw_data)
        if actual_size < img_size:
            return PlainTextResponse("Data Underflow")

        img = np.frombuffer(raw_data, dtype=np.uint8).reshape((h, w, 4))
        full_img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)

        # Offload blocking CRAFT detection to a separate thread
        _, text_boxes = await asyncio.to_thread(get_smart_crop, full_img, False)

        count = len(text_boxes)
        area = sum(b['w'] * b['h'] for b in text_boxes)

        return PlainTextResponse(f"{count},{area},{int(g_typical_h)}")
    except Exception as e:
        log(f"[Error] Detect endpoint failed:\n{traceback.format_exc()}")
        return PlainTextResponse("0,0,0")

# Paddle OCR
@app.post("/ocr")
async def do_ocr(request: Request):
    """Endpoint for performing precision OCR on data read from shared memory"""
    global g_ocr
    try:
        data = await request.json()
        w, h = data.get("w"), data.get("h")

        if not w or not h:
            return PlainTextResponse("0,0,0")

        raw_data = await read_shm_with_flag(w, h)
        if raw_data is None:
            return PlainTextResponse("")

        img = np.frombuffer(raw_data, dtype=np.uint8).reshape((h, w, 4))
        full_img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)

        if DEBUG:
            debug_save_path = os.path.join(tempfile.gettempdir(), "image_ko_trans_capture.jpg")
            cv2.imwrite(debug_save_path, full_img)

        # Offload smart crop calculation to keep server responsive
        _, text_boxes = await asyncio.to_thread(get_smart_crop, full_img, True)
        if not text_boxes:
            return PlainTextResponse("")

        recognizer = getattr(g_ocr, 'paddlex_pipeline', None)
        internal_p = getattr(recognizer, '_pipeline', recognizer)
        engine = getattr(internal_p, 'text_rec_model', None)

        if not engine:
            log("[OCR] ❌ Paddle recognition engine is not initialized.")
            return PlainTextResponse("")

        # Image data is passed directly as a list instead of file paths to avoid I/O
        img_list = []
        for i, box in enumerate(text_boxes):
            x, y, w, h = box['x'], box['y'], box['w'], box['h']
            # Apply 30% padding relative to character height
            pad = int(h * 0.3)
            y1, y2 = max(0, y - pad), min(full_img.shape[0], y + h + pad)
            x1, x2 = max(0, x - pad), min(full_img.shape[1], x + w + pad)
            sub = full_img[y1:y2, x1:x2]

            if sub.size > 0 and h < 45:
                sub = cv2.resize(sub, None, fx=2.0, fy=2.0, interpolation=cv2.INTER_CUBIC)

            # Write crops to file only in DEBUG mode for performance
            if DEBUG:
                crop_path = os.path.join(tempfile.gettempdir(), f"image_ko_trans_crop_{i}.jpg")
                cv2.imwrite(crop_path, sub)

            img_list.append(sub)

        # Execute blocking OCR prediction in a thread pool to avoid freezing the server
        rec_results = await asyncio.to_thread(lambda: list(engine.predict(img_list)))

        raw_boxes = []
        for i, res in enumerate(rec_results):
            # TextRecResult objects support dict-like access via .get()
            text = res.get('rec_text', "").strip()
            score = float(res.get('rec_score', 0.0))

            if score >= 0.5 and text:
                box = text_boxes[i]
                raw_boxes.append({
                    'x': box['x'], 'y': box['y'] + box['h']/2,
                    'y_min': box['y'], 'y_max': box['y'] + box['h'],
                    'h': box['h'], 'text': text
                })

        # Row sorting and final text assembly (corrects reading order based on vertical overlap)
        if not raw_boxes:
            return PlainTextResponse("")

        raw_boxes.sort(key=lambda b: b['y_min'])
        rows = []
        while raw_boxes:
            base = raw_boxes.pop(0)
            curr_row, remaining = [base], []
            for b in raw_boxes:
                overlap = max(0, min(base['y_max'], b['y_max']) - max(base['y_min'], b['y_min']))
                if overlap > min(base['h'], b['h']) * 0.5:
                    curr_row.append(b)
                else:
                    remaining.append(b)
            curr_row.sort(key=lambda b: b['x'])
            rows.append(curr_row)
            raw_boxes = remaining

        final_text = " ".join(["".join([b['text'] for b in r]) for r in rows]).strip()
        final_text = fix_katakana_confusion(final_text)
        log(f"[OCR Result] Rows: {len(rows)} | Text: {final_text}")
        return PlainTextResponse(final_text)

    except Exception as e:
        log(f"[Exception] OCR Logic Error:\n{traceback.format_exc()}")
        return PlainTextResponse("")

# Dedicated Yomigana endpoint
@app.post("/furigana")
async def do_furigana(request: Request):
    try:
        data = await request.json()
        text = data.get("text", "")
        if not text:
            return PlainTextResponse("")

        result = get_jap_furigana(text)
        return PlainTextResponse(result)
    except Exception as e:
        log(f"[Error] Furigana Endpoint Error: {e}")
        return PlainTextResponse(text)

# Translate with AI
@app.post("/translate")
async def translate(request: Request):
    try:
        data = await request.json()
        text_to_translate = data.get("text", "")
        profile_name = data.get("profile", "Settings")
        model_name = data.get("model")

        if not text_to_translate: return PlainTextResponse("")

        engine_name = g_engine_name

        log(f"[Translate] Request: '{text_to_translate[:30]}...' | Engine: {engine_name}")

        # Map engine instances based on INI configuration
        if engine_name == "ChatGPT":
            selected_brain = ai_engines.chatgpt_brain
        elif engine_name == "Local":
            selected_brain = ai_engines.local_brain
        else:
            selected_brain = ai_engines.gemini_brain

        # Offload blocking network I/O for translation to a separate thread
        result = await asyncio.to_thread(selected_brain.get_translation, text_to_translate, profile_name, model_name)

        return PlainTextResponse(result)

    except Exception as e:
        log(f"[Error] Translation Pipeline Error:\n{traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))

def fix_katakana_confusion(text):
    is_kana = lambda c: '\u30a0' <= c <= '\u30ff'

    conf_map = {
        '力': 'カ', '口': 'ロ', '工': 'エ', '夕': 'タ', '二': 'ニ',
        '一': 'ー', 'へ': 'ヘ', '八': 'ハ', '卜': 'ト'
    }

    chars = list(text)
    for i in range(len(chars)):
        if chars[i] in conf_map:
            prev1 = chars[i-1] if i > 0 else ""
            prev2 = chars[i-2] if i > 1 else ""
            next1 = chars[i+1] if i < len(chars)-1 else ""
            next2 = chars[i+2] if i < len(chars)-2 else ""

            if chars[i] == '一':
                if prev1 and ('\u3040' <= prev1 <= '\u30ff'):
                    chars[i] = 'ー'
                continue

            if any(is_kana(c) for c in [prev1, prev2, next1, next2]):
                chars[i] = conf_map[chars[i]]

    return "".join(chars)

def get_jap_furigana(text):
    global g_jap_tagger

    # Regex pattern for identifying name tags
    name_pattern = r'^([\[［【(（].+?[\]］】)）][:：]?|[^:：\s]{1,12}[:：])\s*'

    match = re.match(name_pattern, text)
    if match:
        name_tag = match.group(0)
        dialogue_body = text[len(name_tag):]
    else:
        name_tag = ""
        dialogue_body = text

    # Morphological analysis and Yomigana processing only for the dialogue body
    if g_jap_tagger is None:
        try:
            g_jap_tagger = fugashi.Tagger()
        except:
            return text

    kanji_pattern = re.compile(r'[\u4e00-\u9faf]') # 한자 범위 체크

    result = []
    buf_text = ""
    buf_kana = ""

    for word in g_jap_tagger(dialogue_body):
        # Convert Katakana reading information to Hiragana
        kana = ""
        if word.feature.kana:
            kana = "".join([chr(ord(c) - 96) if 'ァ' <= c <= 'ヶ' else c for c in word.feature.kana])

        # Merge if it's a word containing Kanji or a suffix attached to the previous word
        if kanji_pattern.search(word.surface) or (buf_text and word.feature.pos1 == '接尾辞'):
            buf_text += word.surface
            buf_kana += kana
        else:
            if buf_text:
                result.append(f"{buf_text}({buf_kana})")
                buf_text = ""
                buf_kana = ""
            result.append(word.surface)

    # Handle remaining buffer
    if buf_text:
        result.append(f"{buf_text}({buf_kana})")

    # Combine raw name tag and Yomigana-added body, then return
    return name_tag + "".join(result)

if __name__ == '__main__':
    log("[System] KO Trans FastAPI Server starting on 127.0.0.1:5000...")

    # Start FastAPI server using Uvicorn
    uvicorn.run(app, host="127.0.0.1", port=5000, log_level="error")
