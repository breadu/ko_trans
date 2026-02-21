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
g_last_crop_pos = {'x': -1, 'y': -1}

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
        # Release tagger to save memory when switching to English mode
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

    # Check flag (wait up to 100ms for data readiness)
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

    # Read raw pixel data (pointer is at offset 1 after reading flag)
    raw_data = shm_obj.read(img_size)

    # Reset flag to 0 (Idle) after reading to allow next write
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
    """ADV Mode Selection Logic: Strictly transposes horizontal scoring to vertical mode."""
    is_vert = is_jap_read_vertical()

    def calculate_score(g, target_img):
        num_boxes = len(g)

        # Axis Swap: Height for vertical, Width for horizontal
        metric_dim = sum(c['box'][3] for c in g) if is_vert else sum(c['box'][2] for c in g)

        # Aspect Ratio Swap: Vertical favors tall (H/W), Horizontal favors wide (W/H)
        if is_vert:
            avg_ar = sum((c['h'] / c['w']) if c['w'] > 0 else 0 for c in g) / float(num_boxes)
        else:
            avg_ar = sum(c['ar'] for c in g) / float(num_boxes)

        total_brightness = 0
        for c in g:
            bx, by, bw, bh = c['box']
            roi = target_img[by:by+bh, bx:bx+bw]
            if roi.size > 0:
                total_brightness += np.mean(cv2.cvtColor(roi, cv2.COLOR_BGR2GRAY))
        darkness = (255 - (total_brightness / num_boxes)) / 255.0

        avg_cx = sum(c['box'][0] + c['box'][2]/2 for c in g) / float(num_boxes)
        center_bias = 1.0 - (abs(avg_cx - (target_w / 2)) / (target_w / 2))

        pos_weight = 1.0
        if g_last_crop_pos['x'] != -1 and g_last_crop_pos['y'] != -1:
            group_min_x = min(c['box'][0] for c in g)
            group_min_y = min(c['box'][1] for c in g)
            dist = math.sqrt((group_min_x - g_last_crop_pos['x'])**2 + (group_min_y - g_last_crop_pos['y'])**2)
            pos_weight = 1.0 + (5.0 * math.exp(-dist / 100.0))

        # Use the same scoring logic as horizontal, just with swapped metrics
        return (num_boxes ** 2) * metric_dim * avg_ar * center_bias * darkness * pos_weight

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
    Directly transposes existing horizontal logic for Japanese vertical reading.
    """
    global g_typical_h, g_h_history, g_session
    if img is None:
        log(f"[Error] get_smart_crop: Image is None")
        return None, [], -1.0

    orig_h, orig_w = img.shape[:2]
    is_vertical = is_jap_read_vertical()

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

    _, mask = cv2.threshold(score_text, 0.2, 255, cv2.THRESH_BINARY)

    # Kernel Transpose: (5,3) for horizontal, (1,9) for vertical connectivity to avoid hurigana
    k_size = (1, 9) if is_vertical else (5, 3)
    dilate_iter = 8 if is_vertical else 6

    mask = cv2.dilate(mask.astype(np.uint8), cv2.getStructuringElement(cv2.MORPH_RECT, k_size), iterations=dilate_iter)
    contours, _ = cv2.findContours(mask, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    if not contours:
        return img, [], -1.0

    temp_candidates = []
    img_area = target_w * target_h
    for cnt in contours:
        x, y, w, h = cv2.boundingRect(cnt)
        if (w * h) < (img_area * 0.0001): continue
        aspect_ratio = w / float(h) if h > 0 else 0

        # Aspect Ratio Filter Transpose: Filter out flat boxes in vertical, thin in horizontal
        if is_vertical:
            if aspect_ratio > 0.5: continue
            # Filter out extremely thin fragments (noise/small yomigana)
            if w < 5: continue
        else:
            if aspect_ratio < 0.5: continue


        # Metric Learning Transpose: width (w) for vertical columns, height (h) for horizontal lines
        metric_val = w if is_vertical else h
        if g_typical_h > 0:
            # Relaxed lower bound for vertical to catch thinner font columns or names
            lower_bound = g_typical_h * 0.4 if is_vertical else g_typical_h * 0.7
            if metric_val < lower_bound or metric_val > g_typical_h * 2.5:
                continue

        temp_candidates.append({'cnt': cnt, 'box': (x, y, w, h), 'ar': aspect_ratio, 'h': h, 'w': w})

    if not temp_candidates:
        return img, [], -1.0

    # Apply noise filtering only for horizontal mode (Preserved as is)
    if not is_vertical and len(temp_candidates) == 1 and g_typical_h > 0:
        cand = temp_candidates[0]
        single_w, single_x = cand['w'], cand['box'][0]
        is_near_start = False
        if g_last_crop_pos['x'] != -1:
            # Threshold: 1.5x character height
            if abs(single_x - g_last_crop_pos['x']) <= (g_typical_h * 3):
                is_near_start = True

        # Ignore if the box is short AND not near the starting X line (likely random UI noise)
        if single_w < g_typical_h * 5.0 and not is_near_start:
            return img, [], -1.0

    if is_vertical and len(temp_candidates) == 1 and g_typical_h > 0:
        cand = temp_candidates[0]
        single_y = cand['box'][1]

        if g_last_crop_pos['y'] != -1:
            # Relaxed Y-distance threshold from 5.0 to 10.0 to allow name tags further above text
            if abs(single_y - g_last_crop_pos['y']) > (g_typical_h * 10.0):
                log(f"[Filter] Ignored distant single box at Y:{single_y}")
                return img, [], -1.0

    raw_candidates = temp_candidates

    # 2. Boxing Line Grouping
    groups = []
    if is_vertical:
        # Grouping Transpose: Sort Right-to-Left, cluster by X-center and Y-proximity
        raw_candidates.sort(key=lambda c: (-c['box'][0], c['box'][1]))
        for cand in raw_candidates:
            added = False
            cx, cy, cw, ch = cand['box']
            for g in groups:
                match_found = False
                for m in g:
                    mx, my, mw, mh = m['box']
                    x_dist = abs((cx + cw/2) - (mx + mw/2))
                    y_gap = max(0, cy - (my + mh), my - (cy + ch))
                    max_w = max(cw, mw)
                    if x_dist < max_w * 0.5 and y_gap < max_w * 2.5:
                        match_found = True; break
                if match_found: g.append(cand); added = True; break
            if not added: groups.append([cand])
    else:
        # Horizontal Grouping (Standard)
        raw_candidates.sort(key=lambda c: (c['box'][1], c['box'][0]))
        for cand in raw_candidates:
            added = False
            cx, cy, cw, ch = cand['box']
            for g in groups:
                match_found = False
                for m in g:
                    mx, my, mw, mh = m['box']
                    v_dist = abs((cy + ch/2) - (my + mh/2))
                    h_gap = max(0, cx - (mx + mw), mx - (cx + cw))
                    x_dist = abs(cx - mx)
                    max_h = max(ch, mh)
                    if (v_dist < max_h * 0.5 and h_gap < max_h * 2.5) or (abs(cy - (my + mh)) < max_h * 2 and x_dist < max_h * 1.5):
                        match_found = True; break
                if match_found: g.append(cand); added = True; break
            if not added: groups.append([cand])

    # 3. Branching & Merge Logic
    mode = get_read_mode()
    selected_boxes = []
    paragraph_groups = []

    if mode == 'NVL':
        # NVL Mode: Group regions into paragraph-level boxes
        paragraph_groups = nvl_processor.get_nvl_paragraphs(raw_candidates)
        for group in paragraph_groups:
            for c in group:
                x, y, w, h = c['box']
                selected_boxes.append({'box': (x, y, w, h), 'w': w, 'h': h, 'cnt': c['cnt'], 'x': x})
    else:
        # ADV Mode selection using the transposed scoring
        best_group = select_best_adv_group(groups, res_img, target_w, target_h)
        if best_group:
            # Use chain-merging to include all relevant lines in the dialogue area
            merged_groups = [best_group]
            changed = True
            while changed:
                changed = False
                # Calculate current combined bounding box of all merged groups
                all_merged_pts = np.concatenate([c['cnt'] for g in merged_groups for c in g])
                m_x, m_y, m_w, m_h = cv2.boundingRect(all_merged_pts)

                for g in groups:
                    if any(g is x for x in merged_groups): continue

                    g_p = np.concatenate([c['cnt'] for c in g])
                    gx, gy, gw, gh = cv2.boundingRect(g_p)

                    # Dynamic thresholding based on reading direction
                    if is_vertical:
                        overlap = max(0, min(m_y + m_h, gy + gh) - max(m_y, gy))
                        dist = max(0, gx - (m_x + m_w), m_x - (gx + gw))
                        overlap_thresh = (min(m_h, gh) * 0.15)
                        # Increased vertical gap threshold to 6x typical width for sparse layouts
                        dist_thresh = (g_typical_h if g_typical_h > 0 else target_w * 0.05) * 6.0
                    else:
                        overlap = max(0, min(m_x + m_w, gx + gw) - max(m_x, gx))
                        dist = max(0, gy - (m_y + m_h), m_y - (gy + gh))
                        overlap_thresh = (min(m_w, gw) * 0.15)
                        # Increased horizontal gap threshold to 6x typical height
                        dist_thresh = (g_typical_h if g_typical_h > 0 else target_h * 0.05) * 6.0

                    if overlap > overlap_thresh and dist < dist_thresh:
                        merged_groups.append(g)
                        changed = True

            # Convert character blobs into selected boxes after chain merge
            for g in merged_groups:
                for c in g:
                    x, y, w, h = c['box']
                    selected_boxes.append({'box': (x, y, w, h), 'w': w, 'h': h, 'cnt': c['cnt'], 'x': x})

    # 4. Post-processing: Filter yomigana/noise and update persistent tracking
    if selected_boxes and g_typical_h > 0:
        # Lowered filter limit to 0.5 to safely keep punctuated or thin lines
        limit = g_typical_h * 0.5
        selected_boxes = [b for b in selected_boxes if (b['w'] if is_vertical else b['h']) >= limit]

    if selected_boxes:
        # Re-calculate tracking position based on filtered boxes
        all_pts = np.concatenate([b['cnt'] for b in selected_boxes])
        gx, gy, _, _ = cv2.boundingRect(all_pts)
        g_last_crop_pos['x'], g_last_crop_pos['y'] = gx, gy

    # Sort line boxes explicitly for Right-to-Left order before returning
    if is_vertical:
        selected_boxes.sort(key=lambda b: b['x'], reverse=True)
    else:
        selected_boxes.sort(key=lambda b: (b['box'][1], b['box'][0]))

    # 4. Debug Visualization & Mapping
    sx, sy = orig_w / target_w, orig_h / target_h
    debug_img = img.copy()

    # Draw all raw candidates in green
    for cand in raw_candidates:
        cx, cy, cw, ch = cand['box']
        cv2.rectangle(debug_img, (int(cx * sx), int(cy * sy)),
                      (int((cx + cw) * sx), int((cy + ch) * sy)), (0, 255, 0), 1)

    # Draw red "Detection Area" boxes
    if mode == 'NVL' and paragraph_groups:
        for group in paragraph_groups:
            all_pts = np.concatenate([c['cnt'] for c in group])
            gx, gy, gw, gh = cv2.boundingRect(all_pts)
            rx, ry, rw, rh = int(gx * sx), int(gy * sy), int(gw * sx), int(gh * sy)
            cv2.rectangle(debug_img, (rx - 5, ry - 5), (rx + rw + 5, ry + rh + 5), (0, 0, 255), 2)
    elif selected_boxes:
        all_pts = np.concatenate([b['cnt'] for b in selected_boxes])
        gx, gy, gw, gh = cv2.boundingRect(all_pts)
        rx, ry, rw, rh = int(gx * sx), int(gy * sy), int(gw * sx), int(gh * sy)
        cv2.rectangle(debug_img, (rx - 5, ry - 5), (rx + rw + 5, ry + rh + 5), (0, 0, 255), 2)

    if DEBUG and update_history:
        debug_save_path = os.path.join(tempfile.gettempdir(), "image_ko_trans_debug_craft.jpg")
        cv2.imwrite(debug_save_path, debug_img)

    # Update g_typical_h using the width(vertical) or height(horizontal) of line boxes
    pending_avg_val = -1.0
    if selected_boxes and update_history:
        should_learn = True
        if is_vertical:
            # Only learn if it's a tall column (H >= 2*W)
            total_h = sum(b['h'] for b in selected_boxes)
            total_w = sum(b['w'] for b in selected_boxes)
            if total_h < total_w * 2: should_learn = False

        if should_learn:
            avg_val = sum((b['w'] if is_vertical else b['h']) for b in selected_boxes) / len(selected_boxes)
            target_metric = target_w if is_vertical else target_h
            if (target_metric * 0.01) < avg_val < (target_metric * 0.2):
                pending_avg_val = avg_val

    # Return img, mapped boxes, and the pending learning value
    return img, [{'x': int(b['box'][0]*sx), 'y': int(b['box'][1]*sy),
                  'w': int(b['box'][2]*sx), 'h': int(b['box'][3]*sy)} for b in selected_boxes], pending_avg_val

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

        _, text_boxes, _ = await asyncio.to_thread(get_smart_crop, full_img, False)

        count = len(text_boxes)
        area = sum(b['w'] * b['h'] for b in text_boxes)

        return PlainTextResponse(f"{count},{area},{int(g_typical_h)}")
    except Exception as e:
        log(f"[Error] Detect endpoint failed:\n{traceback.format_exc()}")
        return PlainTextResponse("0,0,0")

# Paddle OCR
@app.post("/ocr")
async def do_ocr(request: Request):
    """Endpoint with Axis-Swapped RTL text assembly support."""
    global g_ocr, g_typical_h
    try:
        data = await request.json()
        w, h = data.get("w"), data.get("h")
        if not w or not h: return PlainTextResponse("0,0,0")

        raw_data = await read_shm_with_flag(w, h)
        if raw_data is None: return PlainTextResponse("")

        img = np.frombuffer(raw_data, dtype=np.uint8).reshape((h, w, 4))
        full_img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
        is_vert = is_jap_read_vertical()

        if DEBUG:
            cv2.imwrite(os.path.join(tempfile.gettempdir(), "image_ko_trans_capture.jpg"), full_img)

        # Offload smart crop calculation to keep server responsive
        _, text_boxes, pending_val = await asyncio.to_thread(get_smart_crop, full_img, True)
        if not text_boxes: return PlainTextResponse("")

        # Calculate the bounding box of the entire detected area for ROI feedback
        all_x = [b['x'] for b in text_boxes]
        all_y = [b['y'] for b in text_boxes]
        all_w = [b['w'] for b in text_boxes]
        all_h = [b['h'] for b in text_boxes]

        bx, by = min(all_x), min(all_y)
        bw = max(x + w for x, w in zip(all_x, all_w)) - bx
        bh = max(y + h for y, h in zip(all_y, all_h)) - by
        roi_str = f"{bx},{by},{bw},{bh}"

        recognizer = getattr(g_ocr, 'paddlex_pipeline', None)
        internal_p = getattr(recognizer, '_pipeline', recognizer)
        engine = getattr(internal_p, 'text_rec_model', None)
        if not engine: return PlainTextResponse("")

        img_list = []
        valid_indices = []
        for i, box in enumerate(text_boxes):
            bx_box, by_box, bw_box, bh_box = box['x'], box['y'], box['w'], box['h']
            char_size = bw_box if is_vert else bh_box

            pad = int(char_size * (0.6 if is_vert else 0.3))
            y1, y2 = max(0, by_box - pad), min(full_img.shape[0], by_box + bh_box + pad)
            x1, x2 = max(0, bx_box - pad), min(full_img.shape[1], bx_box + bw_box + pad)
            sub = full_img[y1:y2, x1:x2]

            if sub.size > 0:
                if is_vert and bh_box > bw_box * 1.5:
                    sub = cv2.rotate(sub, cv2.ROTATE_90_COUNTERCLOCKWISE)

                # Upscale small text lines
                if char_size < 45:
                    sub = cv2.resize(sub, None, fx=2.0, fy=2.0, interpolation=cv2.INTER_CUBIC)

                # Write crops to file only in DEBUG mode for performance
                if DEBUG:
                    crop_path = os.path.join(tempfile.gettempdir(), f"image_ko_trans_crop_{i}.jpg")
                    cv2.imwrite(crop_path, sub)

                img_list.append(sub)
                valid_indices.append(i)

        if not img_list: return PlainTextResponse("")

        rec_results = await asyncio.to_thread(lambda: list(engine.predict(img_list)))

        raw_boxes = []
        for i, res in enumerate(rec_results):
            # Parse results from the internal paddlex engine dict format
            text, score = res.get('rec_text', ""), float(res.get('rec_score', 0.0))
            if score >= 0.5 and text:
                box = text_boxes[valid_indices[i]]
                raw_boxes.append({'x': box['x'], 'y': box['y'], 'w': box['w'], 'h': box['h'], 'text': text})

        if not raw_boxes: return PlainTextResponse("")

        if is_vert:
            # Vertical RTL Assembly: Group columns Right-to-Left, sort within columns Top-to-Bottom
            raw_boxes.sort(key=lambda b: b['x'], reverse=True)
            lines = []
            while raw_boxes:
                base = raw_boxes.pop(0)
                curr_line, remaining = [base], []
                base_cx = base['x'] + base['w'] / 2
                for b in raw_boxes:
                    # Check for X-axis overlap to group characters into the same vertical column
                    if abs(base_cx - (b['x'] + b['w'] / 2)) < base['w'] * 0.8:
                        curr_line.append(b)
                    else:
                        remaining.append(b)
                # Sort characters within the column from top to bottom
                curr_line.sort(key=lambda b: b['y'])
                lines.append(curr_line)
                raw_boxes = remaining
            final_text = "".join(["".join([b['text'] for b in l]) for l in lines]).strip()
        else:
            # Standard Horizontal Assembly: Sort lines by Y then characters by X
            raw_boxes.sort(key=lambda b: b['y'])
            rows = []
            while raw_boxes:
                base = raw_boxes.pop(0)
                curr_row, remaining = [base], []
                for b in raw_boxes:
                    overlap = max(0, min(base['y']+base['h'], b['y']+b['h']) - max(base['y'], b['y']))
                    if overlap > min(base['h'], b['h']) * 0.5:
                        curr_row.append(b)
                    else:
                        remaining.append(b)
                curr_row.sort(key=lambda b: b['x'])
                rows.append(curr_row)
                raw_boxes = remaining
            final_text = " ".join(["".join([b['text'] for b in r]) for r in rows]).strip()

        if len(final_text) >= 5 and pending_val > 0:
            g_h_history.append(pending_val)
            if len(g_h_history) > MAX_HISTORY: g_h_history.pop(0)
            g_typical_h = sorted(g_h_history)[len(g_h_history)//2]
            log(f"[Learning] Verified scale learned: {int(pending_val)} (Text: {final_text[:10]}...)")
        elif pending_val > 0:
            log(f"[Learning] Learning skipped. Text too short ({len(final_text)} chars).")

        final_text = apply_custom_replacements(final_text)

        log(f"[OCR Result] Mode: {'Vert' if is_vert else 'Horiz'} | Text: {final_text}")
        return PlainTextResponse(f"{roi_str}|{fix_katakana_confusion(final_text)}")

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

def apply_custom_replacements(text):
    repl_map = {
        '°':'。', '`':'、', '|':'｜'
    }

    for src, dst in repl_map.items():
        text = text.replace(src, dst)

    return text

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

    kanji_pattern = re.compile(r'[\u4e00-\u9faf]')

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
