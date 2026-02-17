import os
import sys

if getattr(sys, 'frozen', False):
    ROOT_DIR = os.path.dirname(sys.executable)
    ENGINE_DIR = ROOT_DIR
else:
    ENGINE_DIR = os.path.dirname(os.path.abspath(__file__))
    ROOT_DIR = os.path.dirname(ENGINE_DIR)

INI_PATH = os.path.join(ROOT_DIR, "settings.ini")
VOICE_DIR = os.path.join(ROOT_DIR, "voice")

PROMPT_PATH = os.path.join(ENGINE_DIR, "english_helper_prompt.txt")
CRAFT_MODEL_PATH = os.path.join(ENGINE_DIR, "craft.onnx")