import sys
import os
import datetime
import cv2
import numpy as np
import traceback
import math
import tempfile
import logging
import configparser
import asyncio
import mmap
import fugashi
import re

# FastAPI imports
from fastapi import FastAPI, Request, Response, HTTPException
from fastapi.responses import JSONResponse, PlainTextResponse
import uvicorn

from paddleocr import PaddleOCR
import paddle
import onnxruntime as ort
import path_util
import ai_engines
from PIL import Image, ImageDraw, ImageFont
import nvl_processor

# Set to True to enable console logging
DEBUG = False

# Initialize FastAPI application
app = FastAPI(title="KO Trans Engine")

# --- Shared Memory Configuration ---
SHM_NAME = "KO_TRANS_SHM"
SHM_SIZE = 4000 * 2500 * 4 + 1 # Add 1 byte for status flag
shm_obj = mmap.mmap(-1, SHM_SIZE, tagname=SHM_NAME)

# Logging configuration using FastAPI/Uvicorn defaults
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("uvicorn")

# --- write logs in a file name "ko_trans_server_log.txt" ---
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def log(msg):
    if not DEBUG:
        return

    log_file = os.path.join(SCRIPT_DIR, "ko_trans_server_log.txt")
    max_size = 1 * 1024 * 1024  # 1MB

    try:
        if os.path.exists(log_file):
            if os.path.getsize(log_file) > max_size:
                os.remove(log_file) # Delete if exceeds 1MB

        with open(log_file, "a", encoding="utf-8") as f:
            timestamp = datetime.datetime.now().strftime("[%Y-%m-%d %H:%M:%S]")
            f.write(f"{timestamp} {msg}\n")

    except Exception as e:
        if sys.stdout is not None:
            print(f"Log Error: {e}")

log("--- 🥊 KO Trans: One-Shot OCR & Translation Engine (FastAPI) Activated ---")

# --- Define the Initialization Function ---
ocr = None
current_device = "Unknown"
global_typical_h = -1.0
alpha = 0.2
h_history = []
MAX_HISTORY = 10
INI_PATH = path_util.INI_PATH

def get_config_mode():
    """Reads the current MODE (ADV or NVL) from settings.ini."""
    config = configparser.ConfigParser()
    active_profile = 'Settings'
    if os.path.exists(INI_PATH):
        try:
            # Sequential retry with different encodings to handle various INI file formats
            for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
                try:
                    with open(INI_PATH, 'r', encoding=enc) as f:
                        config.read_file(f)
                    break
                except: continue

            active_profile = config.get('Settings', 'ACTIVE_PROFILE', fallback='Settings')
            return config.get(active_profile, 'READ_MODE', fallback=config.get('Settings', 'READ_MODE', fallback='ADV'))
        except:
            return 'ADV'
    return 'ADV'

def init_ocr_engine():
    """Reads settings.ini and initializes the OCR engine based on ACTIVE_PROFILE."""
    global ocr, last_crop_pos, current_device

    last_crop_pos = {'x': -1, 'y': -1}
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

            # Read LANG for the specific profile; fallback to global Settings if missing
            lang_from_ini = config.get(active_profile, 'LANG',
                                     fallback=config.get('Settings', 'LANG', fallback='eng'))

        except Exception as e:
            log(f"--- [Warning] INI Read Error: {e} ---")

    # Map profile language to PaddleOCR language codes
    paddle_lang = 'en' if lang_from_ini == 'eng' else 'japan'
    log(f"--- 🌐 OCR Engine: {paddle_lang.upper()} Mode (Profile: {active_profile}) ---")

    can_use_gpu = paddle.device.is_compiled_with_cuda() and paddle.device.cuda.device_count() > 0
    if can_use_gpu:
        try:
            # Attempt to use GPU (Requires CUDA & cuDNN)
            ocr = PaddleOCR(
                lang=paddle_lang,
                device='gpu',
                ocr_version='PP-OCRv5',
                use_textline_orientation=True
            )
            current_device = "GPU"
            log("--- 🚀 KO Trans: GPU Mode Activated ---")
        except Exception as e:
            log(f"--- ⚠️ GPU Init failed: {e} ---")
            can_use_gpu = False # Fallback to CPU mode on failure

    if not can_use_gpu:
        # Plan B: Fallback to CPU mode
        ocr = PaddleOCR(
            lang=paddle_lang,
            device='cpu',
            ocr_version='PP-OCRv5',
            use_textline_orientation=True
        )
        current_device = "CPU"
        log("--- 💻 KO Trans: Falling back to CPU Mode ---")

# Initialize engines on server startup
init_ocr_engine()

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
    global current_device
    return {"status": "online", "device": current_device}

# Endpoint to reload configuration and restart all engines
@app.get("/reload")
async def reload_engine():
    global current_device
    try:
        log("[System] Reloading all engines via /reload...")

        # Offload heavy model initialization to a separate thread to keep the event loop responsive
        await asyncio.to_thread(init_ocr_engine)

        try:
            # Reload engine settings asynchronously to prevent blocking during API client setup
            await asyncio.to_thread(ai_engines.chatgpt_brain.reload_settings)
        except Exception as e:
            log(f"[Warning] ChatGPT Brain reload failed: {e}")

        await asyncio.to_thread(ai_engines.gemini_brain.reload_settings)
        await asyncio.to_thread(ai_engines.local_brain.reload_settings)

        return {
            "status": "success",
            "device": current_device,
            "message": "All engines reloaded successfully"
        }
    except Exception as e:
        log(f"[Error] Reload failed:\n{traceback.format_exc()}")
        raise HTTPException(status_code=500, detail=str(e))

# CRAFT (The Scout) - ONNX Logic
model_path = path_util.CRAFT_MODEL_PATH
providers = ['CUDAExecutionProvider', 'CPUExecutionProvider']
try:
    session = ort.InferenceSession(model_path, providers=providers)
    log(f"--- [Info] CRAFT Loaded. Providers: {session.get_providers()}")
except Exception as e:
    log(f"--- [Error] CRAFT CUDA loading failed: {e}")
    session = ort.InferenceSession(model_path, providers=['CPUExecutionProvider'])

# Store top-left coordinates of the last successful crop to improve continuity
last_crop_pos = {'x': -1, 'y': -1}

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
        if last_crop_pos['x'] != -1 and last_crop_pos['y'] != -1:
            group_min_x = min(c['box'][0] for c in g)
            group_min_y = min(c['box'][1] for c in g)
            dist = math.sqrt((group_min_x - last_crop_pos['x'])**2 + (group_min_y - last_crop_pos['y'])**2)
            pos_weight = 1.0 + (5.0 * math.exp(-dist / 100.0))

        return (num_boxes ** 2) * total_width * avg_ar * center_bias * darkness * pos_weight

    return max(groups, key=lambda g: calculate_score(g, res_img))

def get_smart_crop(img, update_history=True):
    """
    Common detection flow for both ADV and NVL modes.
    Uses CRAFT to find candidates, then branches processing based on MODE.
    """
    global global_typical_h, h_history, alpha
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
    outputs = session.run(None, {session.get_inputs()[0].name: blob})
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

        # Filter candidates based on global_typical_h (learned dialogue height)
        if global_typical_h > 0:
            # Filter out tiny regions (probable noise)
            if h < global_typical_h * 0.7:
                continue

            # Filter out oversized regions (background or giant UI)
            if h > global_typical_h * 2.0:
                continue

        # Include width to prevent downstream errors
        temp_candidates.append({'cnt': cnt, 'box': (x, y, w, h), 'ar': aspect_ratio, 'h': h, 'w': w})

    if not temp_candidates:
        return img, []

    # Apply horizontal noise filtering only for single-box detections
    if len(temp_candidates) == 1 and global_typical_h > 0:
        cand = temp_candidates[0]
        single_w = cand['w']
        single_x = cand['box'][0]

        # Check if the box is positioned near the starting X-coordinate of previous dialogues
        is_near_start = False
        if last_crop_pos['x'] != -1:
            # Threshold: 1.5x character height
            if abs(single_x - last_crop_pos['x']) <= (global_typical_h * 3):
                is_near_start = True

        # Ignore if the box is short AND not near the starting X line (likely random UI noise)
        if single_w < global_typical_h * 5.0 and not is_near_start:
            log(f"[Filter] Single short box ignored (noise): w={single_w}, distance={abs(single_x - last_crop_pos['x'])}, global_typical_h={global_typical_h}")
            return img, []
        elif is_near_start and single_w < global_typical_h * 5.0:
            log(f"[Keep] Short box kept as it is near the start line: x={single_x}")

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
    mode = get_config_mode()
    selected_boxes = []
    paragraph_groups = []

    if mode == 'NVL':
        # NVL Mode: Use DBSCAN to cluster all detected regions into paragraphs
        paragraph_groups = nvl_processor.get_nvl_paragraphs(raw_candidates)
        # Combine all paragraphs into a single list of boxes for processing
        for p in paragraph_groups:
            selected_boxes.extend(p)
        # Update last_crop_pos for NVL continuity
        if selected_boxes:
            all_pts = np.concatenate([c['cnt'] for c in selected_boxes])
            gx, _, _, _ = cv2.boundingRect(all_pts)
            last_crop_pos['x'] = gx
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
            last_crop_pos['x'], last_crop_pos['y'] = gx, gy

    if selected_boxes and update_history:
        avg_h = sum(c['h'] for c in selected_boxes) / len(selected_boxes)

        if (target_h * 0.02) < avg_h < (target_h * 0.15):
            h_history.append(avg_h)
            if len(h_history) > MAX_HISTORY:
                h_history.pop(0)

            temp_sorted = sorted(h_history)
            global_typical_h = temp_sorted[len(temp_sorted)//2]

    # Filtering is always performed relative to the current global_typical_h
    filter_lower = 0.6 if len(h_history) < 5 else 0.7
    candidates = []
    for cand in temp_candidates:
        if global_typical_h > 0:
            if cand['h'] < global_typical_h * filter_lower or cand['h'] > global_typical_h * 3.0:
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
            log(f"[SHM/Detect] ❌ Error: Read only {actual_size}/{img_size} bytes.")
            return PlainTextResponse("Data Underflow")

        first_pixels = raw_data[:10].hex()

        img = np.frombuffer(raw_data, dtype=np.uint8).reshape((h, w, 4))
        full_img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)

        # Offload blocking CRAFT detection to a separate thread
        _, text_boxes = await asyncio.to_thread(get_smart_crop, full_img, False)

        count = len(text_boxes)
        area = sum(b['w'] * b['h'] for b in text_boxes)

        return PlainTextResponse(f"{count},{area},{int(global_typical_h)}")
    except Exception as e:
        log(f"[Error] Detect endpoint failed:\n{traceback.format_exc()}")
        return PlainTextResponse("0,0,0")

# Paddle OCR
@app.post("/ocr")
async def do_ocr(request: Request):
    """Endpoint for performing precision OCR on data read from shared memory"""
    global ocr
    try:
        data = await request.json()
        w, h = data.get("w"), data.get("h")

        if not w or not h:
            return PlainTextResponse("0,0,0")

        raw_data = await read_shm_with_flag(w, h)
        if raw_data is None:
            log("[OCR] ❌ Failed to read SHM data.")
            return PlainTextResponse("")

        img = np.frombuffer(raw_data, dtype=np.uint8).reshape((h, w, 4))
        full_img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)

        if DEBUG:
            debug_save_path = os.path.join(tempfile.gettempdir(), "image_ko_trans_capture.jpg")
            cv2.imwrite(debug_save_path, full_img)

        # Offload smart crop calculation to keep server responsive
        _, text_boxes = await asyncio.to_thread(get_smart_crop, full_img, True)
        if not text_boxes:
            log("[OCR] No text boxes found by CRAFT.")
            return PlainTextResponse("")

        recognizer = getattr(ocr, 'paddlex_pipeline', None)
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
                log(f"[OCR Line] Score: {score:.4f} | Text: {text}")

        # Row sorting and final text assembly (corrects reading order based on vertical overlap)
        if not raw_boxes:
            log("[OCR] Confidence too low or no text found in results.")
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

        config = configparser.ConfigParser()
        config.optionxform = str
        engine_name = "Gemini"

        if os.path.exists(INI_PATH):
            for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
                try:
                    with open(INI_PATH, 'r', encoding=enc) as f:
                        config.read_file(f)
                    # Inheritance logic: Profile Section -> Global Settings -> Default
                    engine_name = config.get(profile_name, 'ENGINE',
                                           fallback=config.get('Settings', 'ENGINE', fallback='Gemini'))
                    break
                except: continue

        log(f"[Translate] Request: '{text_to_translate[:30]}...' | Engine: {engine_name} | Model: {model_name}")

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

def get_jap_furigana(text):
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
    tagger = fugashi.Tagger()
    kanji_pattern = re.compile(r'[\u4e00-\u9faf]') # 한자 범위 체크

    result = []
    buf_text = ""
    buf_kana = ""

    for word in tagger(dialogue_body):
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
    uvicorn.run(app, host="127.0.0.1", port=5000, log_config=None)
