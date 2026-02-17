import sys
import os
import configparser
import ctypes
import struct
import re
import time
from urllib.parse import unquote
from ctypes import wintypes
from PySide6.QtWidgets import QApplication, QWidget, QVBoxLayout, QHBoxLayout, QTextBrowser, QPushButton, QLabel, QSizeGrip
from PySide6.QtCore import Qt, QPoint, QTimer, QThread, Signal, QEvent, QUrl
from PySide6.QtMultimedia import QMediaPlayer, QAudioOutput
import ai_engines
import path_util

# Set to True to enable console logging for development
DEBUG = False

def log(msg):
    if DEBUG:
        print(msg)

# Maps engine names to shared AI engine instances
ENGINE_MAP = {
    "ChatGPT": ai_engines.chatgpt_brain,
    "Gemini": ai_engines.gemini_brain,
    "Local": ai_engines.local_brain
}

# Windows Message constant for inter-process communication
WM_COPYDATA = 0x004A

# Structure for handling pointer data passed via SendMessage from AHK
class COPYDATASTRUCT(ctypes.Structure):
    _fields_ = [
        ('dwData', wintypes.LPARAM),
        ('cbData', wintypes.DWORD),
        ('lpData', wintypes.LPVOID)
    ]

# Default UI configuration constants
DEFAULT_X = 1400
DEFAULT_Y = 200
DEFAULT_W = 450
DEFAULT_H = 600
DEFAULT_FONT = 20
INI_PATH = path_util.INI_PATH
VOICE_DIR = path_util.VOICE_DIR

class VoiceIndex:
    """
    Manages the mapping between words and local pronunciation audio files.
    Parses a specialized binary index file to enable low-latency lookup.
    """
    def __init__(self, voice_dir):
        self.voice_dir = voice_dir
        self.index_map = {}
        self.load_index()

    def load_index(self):
        """
        Parses word.idx which follows the LNVI (Local Network Voice Index) format.
        Binary pattern: [Word(UTF-16LE)][\x00\x00\x00][RelPath(ASCII)].mp3[\x00]
        """
        idx_path = os.path.join(self.voice_dir, "word.idx")
        if not os.path.exists(idx_path):
            log(f"[Warning] VoiceIndex file not found at {idx_path}")
            return

        try:
            with open(idx_path, 'rb') as f:
                data = f.read()
            # Regex to capture words and their corresponding relative file paths
            pattern = re.compile(rb'(?P<word>.+?)\x00\x00\x00(?P<path>[^\x00]+\.mp3)\x00')
            for match in pattern.finditer(data):
                try:
                    word_bytes = match.group('word')
                    if len(word_bytes) % 2 != 0: word_bytes += b'\x00'
                    word = word_bytes.decode('utf-16le', errors='ignore').strip().lower()
                    path = match.group('path').decode('ascii', errors='ignore')
                    self.index_map[word] = path
                except: continue

            log(f"[System] VoiceIndex loaded: {len(self.index_map)} entries.")

        except Exception as e:
            log(f"[Error] Failed to load index: {e}")

    def get_path(self, word):
        """Returns absolute path for a word's MP3 file if it exists in the index."""
        rel_path = self.index_map.get(word.lower().strip())
        return os.path.join(self.voice_dir, rel_path.replace('\\', os.sep)) if rel_path else None

class AIWorker(QThread):
    """Executes AI explanation requests in a background thread to keep UI responsive."""
    finished = Signal(dict)
    error = Signal(str)

    def __init__(self, engine_obj, text, model_name):
        super().__init__()
        self.engine_obj = engine_obj
        self.text = text
        self.model_name = model_name

    def run(self):
        try:
            # Calls the explanation method of the selected engine (Gemini/GPT/Local)
            result = self.engine_obj.get_explanation(self.text, self.model_name)
            self.finished.emit(result)
        except Exception as e:
            self.error.emit(str(e))

def get_ini_encoding():
    """Detects INI file encoding to handle BOM or UTF-16 variations from AHK."""
    if not os.path.exists(INI_PATH):
        return 'utf-8'
    for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
        try:
            with open(INI_PATH, 'r', encoding=enc) as f:
                f.read()
            return enc
        except:
            continue
    return 'utf-8'

def load_settings():
    """Retrieves window position and font size from shared configuration."""
    config = configparser.ConfigParser()
    config.optionxform = str
    encoding = get_ini_encoding()

    s = {
        'x': DEFAULT_X, 'y': DEFAULT_Y,
        'w': DEFAULT_W, 'h': DEFAULT_H,
        'font': DEFAULT_FONT
    }

    if os.path.exists(INI_PATH):
        try:
            with open(INI_PATH, 'r', encoding=encoding) as f:
                config.read_file(f)

            if config.has_section('Settings'):
                s['x'] = config.getint('Settings', 'WORD_X', fallback=DEFAULT_X)
                s['y'] = config.getint('Settings', 'WORD_Y', fallback=DEFAULT_Y)
                s['w'] = config.getint('Settings', 'WORD_W', fallback=DEFAULT_W)
                s['h'] = config.getint('Settings', 'WORD_H', fallback=DEFAULT_H)
                s['font'] = config.getint('Settings', 'WORD_FONT', fallback=DEFAULT_FONT)
            log(f"[System] Settings loaded from INI ({encoding})")
        except Exception as e:
            log(f"[Error] Failed to load settings: {e}")
    return s

def save_settings(x, y, w, h):
    """Persists current window geometry back to the INI file."""
    config = configparser.ConfigParser()
    config.optionxform = str
    encoding = get_ini_encoding()

    try:
        if os.path.exists(INI_PATH):
            with open(INI_PATH, 'r', encoding=encoding) as f:
                config.read_file(f)

        if not config.has_section('Settings'):
            config.add_section('Settings')

        config.set('Settings', 'WORD_X', str(x))
        config.set('Settings', 'WORD_Y', str(y))
        config.set('Settings', 'WORD_W', str(w))
        config.set('Settings', 'WORD_H', str(h))

        with open(INI_PATH, 'w', encoding=encoding) as f:
            config.write(f, space_around_delimiters=False)
        log(f"[System] Geometry settings saved to INI.")
    except Exception as e:
        log(f"[Error] Failed to save settings: {e}")

def format_to_html(data, voice_manager=None):
    """
    Converts structured AI response into a rich-text HTML format for display.
    Prioritizes source-specific meanings (meaning_src) over generic translations.
    """
    html = ""
    # Header: Full Korean translation
    if data.get("full_translation"):
        html += f"<div style='color: #B388FF; font-weight: bold; font-size: 1.1em;'>KR: {data['full_translation']}</div><br>"

    # Grammatical context
    if data.get("sentence_explanation"):
        html += f"<div style='color: #cccccc; font-style: italic;'>{data['sentence_explanation']}</div><hr style='border: 0.5px solid #333;'>"

    # Vocabulary section with pronunciation and audio links
    for item in data.get("vocabulary", []):
        word_text = item.get('word', '')

        html += f"<b style='color: #ffd700; font-size: 1.2em;'>{word_text}</b> "
        html += f"<span style='color: #888888;'>{item.get('pronunciation', '')}</span>"

        # Audio link logic for local MP3 playback
        if voice_manager:
            mp3_path = voice_manager.get_path(word_text)
            if mp3_path:
                html += f" <a href='play:{mp3_path}' style='color: #00d4ff; text-decoration: none;'>🔊</a>"

        html += "<br>"
        html += f"<div style='margin-left: 10px;'>"

        meaning_src = item.get('meaning_src', item.get('meaning_en', 'Unknown'))
        html += f"<b style='color: #ffffff;'>Definition:</b> <span style='color: #ffffff;'>{meaning_src}</span><br>"
        html += f"<b>Meaning:</b> {item.get('meaning_ko', '')}<br>"

        # Context-aware examples
        for ex in item.get("examples", []):
            source_example = ex.get('en_or_jp', ex.get('en', ''))
            html += f"<span style='color: #e0e0e0;'>• {source_example}</span><br>"
            html += f"<span style='color: #aaaaaa; font-size: 0.9em;'>  ({ex.get('ko', '')})</span><br>"

        if item.get("tip"):
            html += f"<div style='color: #90ee90; font-size: 0.9em;'>💡 Tip: {item['tip']}</div>"
        html += "</div><br>"
    return html

class StudyOverlay(QWidget):
    """
    Floating resident window for word analysis.
    Designed for non-intrusive 'Resident Study' mode alongside games.
    """
    def __init__(self):
        super().__init__()
        log("[System] Initializing StudyOverlay Client...")

        self.old_pos = None
        self.settings = load_settings()

        # Audio engine setup
        self.player = QMediaPlayer()
        self.audio_output = QAudioOutput()
        self.player.setAudioOutput(self.audio_output)
        self.voice_manager = VoiceIndex(VOICE_DIR)

        # Process management
        self.worker = None
        self.timeout_timer = QTimer(self)
        self.timeout_timer.setSingleShot(True)
        self.timeout_timer.timeout.connect(self.on_ai_timeout)

        self.initUI()
        log("[System] StudyOverlay GUI initialized.")

    def initUI(self):
        # Specific title for AHK window matching
        self.setWindowTitle("🥊 KO Trans")

        # UI Behavior: Stay in background but always visible
        self.setAttribute(Qt.WA_ShowWithoutActivating)
        self.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool)
        self.setAttribute(Qt.WA_TranslucentBackground)

        self.setGeometry(self.settings['x'], self.settings['y'], self.settings['w'], self.settings['h'])

        self.main_layout = QVBoxLayout()
        self.main_layout.setContentsMargins(0, 0, 0, 0)

        self.container = QWidget()
        self.container.setObjectName("MainContainer")

        # Visual styling for a game-like UI
        self.container.setStyleSheet("""
            QWidget#MainContainer {
                background-color: rgba(20, 25, 30, 235);
                border: 2px solid #00d4ff;
                border-radius: 12px;
            }
        """)
        container_layout = QVBoxLayout(self.container)

        self.title_label = QLabel("🥊 KO Trans")
        self.update_title_style(False)
        container_layout.addWidget(self.title_label)

        self.text_area = QTextBrowser()
        self.text_area.setReadOnly(True)
        self.text_area.setOpenExternalLinks(False)
        self.text_area.setOpenLinks(False)
        self.text_area.anchorClicked.connect(self.handle_link_click)

        self.text_area.setStyleSheet(f"""
            QTextBrowser {{
                background-color: transparent;
                color: #ffffff;
                font-family: 'Malgun Gothic', 'Segoe UI';
                font-size: {self.settings['font']}px;
                border: none;
            }}
        """)

        self.text_area.setHtml("<i style='color: #888;'>Waking up...</i>")
        container_layout.addWidget(self.text_area)

        button_hbox = QHBoxLayout()

        # Hide Button minimizes visibility without terminating the process
        btn_hide = QPushButton("HIDE")
        btn_hide.clicked.connect(self.close_and_save)
        btn_hide.setCursor(Qt.PointingHandCursor)
        btn_hide.setStyleSheet("""
            QPushButton {
                background-color: #222; color: #00d4ff; border: 1px solid #00d4ff;
                font-weight: bold; padding: 10px; border-radius: 5px;
            }
            QPushButton:hover { background-color: #00d4ff; color: #000; }
        """)
        button_hbox.addWidget(btn_hide, 3)

        btn_exit = QPushButton("EXIT")
        btn_exit.clicked.connect(self.full_exit_and_save)
        btn_exit.setCursor(Qt.PointingHandCursor)
        btn_exit.setStyleSheet("""
            QPushButton {
                background-color: #331111; color: #ff4444; border: 1px solid #ff4444;
                font-weight: bold; padding: 10px; border-radius: 5px;
            }
            QPushButton:hover { background-color: #ff4444; color: #000; }
        """)
        button_hbox.addWidget(btn_exit, 1)

        container_layout.addLayout(button_hbox)

        self.main_layout.addWidget(self.container)
        self.setLayout(self.main_layout)

        # Grip for manual resizing
        self.sizegrip = QSizeGrip(self)
        self.sizegrip.setFixedSize(20, 20)
        self.sizegrip.setStyleSheet("background-color: rgba(0, 212, 255, 100); border-radius: 10px;")
        self.sizegrip.raise_()

        self.loading_label = QLabel("⏳ 분석 중...", self.container)
        self.loading_label.setAlignment(Qt.AlignCenter)
        self.loading_label.setStyleSheet("""
            background-color: rgba(0, 0, 0, 180);
            color: #00d4ff;
            font-size: 24px;
            font-weight: bold;
            border-radius: 10px;
        """)
        self.loading_label.hide()

    def handle_link_click(self, url):
        """Interprets custom 'play:' internal URLs to trigger local audio playback."""
        link_str = unquote(url.toString())
        if link_str.startswith("play:"):
            file_path = link_str[5:]
            normalized_path = os.path.normpath(file_path)

            if os.path.exists(normalized_path):
                self.player.setSource(QUrl.fromLocalFile(normalized_path))
                self.player.play()
                log(f"[Audio] Playing: {os.path.basename(normalized_path)}")
            else:
                log(f"[Warning] Audio file missing: {normalized_path}")

    def update_title_style(self, focused):
        """Dynamically highlights title color based on window focus state."""
        color = "#ffffff" if focused else "#00d4ff"
        self.title_label.setStyleSheet(f"color: {color}; font-weight: bold; font-family: 'Segoe UI'; font-size: 14px;")

    def changeEvent(self, event):
        """Tracks activation changes to update visual focus indicators."""
        if event.type() == QEvent.ActivationChange:
            self.update_title_style(self.isActiveWindow())
        super().changeEvent(event)

    def nativeEvent(self, eventType, message):
        """
        Intercepts Windows messages to handle data updates from AHK via SendMessage.
        Payload is expected to be a UTF-16 pipe-separated string: "Text|Engine|Model"
        """
        msg = wintypes.MSG.from_address(message.__int__())

        if msg.message == WM_COPYDATA:
            cds = COPYDATASTRUCT.from_address(msg.lParam)
            # Decodes payload from the memory address provided by AHK
            received_payload = ctypes.string_at(cds.lpData, cds.cbData).decode('utf-16').strip('\x00')
            log(f"[WM_COPYDATA] Received data: {received_payload[:50]}...")

            parts = received_payload.split('|', 2)
            if len(parts) >= 3:
                text, engine_name, model_name = parts[0], parts[1], parts[2]
            else:
                text, engine_name, model_name = received_payload, "Gemini", "gemini-2.0-flash"

            self.show()
            QTimer.singleShot(0, lambda: self.run_ai_task(text, engine_name, model_name))
            return True, 0
        return super().nativeEvent(eventType, message)

    def run_ai_task(self, input_text, engine_name="Gemini", model_name="gemini-2.0-flash"):
        """Initiates the AI explanation process for a given input text."""
        if self.worker and self.worker.isRunning():
            self.worker.terminate()
            self.worker.wait()

        selected_engine = ENGINE_MAP.get(engine_name, ai_engines.gemini_brain)

        if hasattr(selected_engine, 'reload_settings'):
            selected_engine.reload_settings()

        log(f"[AI] Starting task - Engine: {engine_name} | Model: {model_name}")
        self.text_area.setHtml(f"<i style='color: #00d4ff;'>[{engine_name}] Analyzing with {model_name}...</i>")

        QApplication.setOverrideCursor(Qt.WaitCursor)

        self.loading_label.setGeometry(self.container.rect())
        self.loading_label.show()
        self.loading_label.raise_()

        self.worker = AIWorker(selected_engine, input_text, model_name)
        self.worker.finished.connect(self.on_ai_success)
        self.worker.error.connect(self.on_ai_error)
        self.worker.start()

        # Hard limit for API response time
        self.timeout_timer.start(60000)

    def stop_loading_ui(self):
        self.loading_label.hide()
        QApplication.restoreOverrideCursor()

    def on_ai_success(self, result_json):
        self.timeout_timer.stop()
        self.stop_loading_ui()
        log("[AI] Analysis completed successfully.")
        html_content = format_to_html(result_json, self.voice_manager)
        self.text_area.setHtml(html_content)

    def on_ai_error(self, error_msg):
        self.timeout_timer.stop()
        self.stop_loading_ui()
        log(f"[Error] AI Worker Error: {error_msg}")
        self.display_debug_info(f"AI API Error: {error_msg}")

    def on_ai_timeout(self):
        self.stop_loading_ui()

        if self.worker and self.worker.isRunning():
            self.worker.terminate()
            self.worker.wait()
            log("[Error] AI Worker timed out (60s).")
            self.display_debug_info("Connection Timeout: AI is taking too long to respond.")

    def display_debug_info(self, msg):
        """Renders error information and troubleshooting tips on the screen."""
        debug_html = f"""
            <div style='color: #ff4444; font-weight: bold;'>⚠️ ANALYSIS INTERRUPTED</div>
            <div style='color: #ffffff; margin-top: 10px;'>{msg}</div>
            <hr style='border: 0.5px solid #333;'>
            <div style='color: #888; font-size: 0.9em;'>
                <b>Tips:</b><br>
                • Check your internet connection.<br>
                • Your API key might be over the limit.<br>
                • Try again in a few seconds.
            </div>
        """
        self.text_area.setHtml(debug_html)

    def resizeEvent(self, event):
        """Relocates the resize grip based on new window dimensions."""
        self.sizegrip.move(self.width() - 20, self.height() - 20)
        self.sizegrip.raise_()
        super().resizeEvent(event)

    def close_and_save(self):
        """Hides the window and saves current position to INI."""
        geo = self.geometry()
        save_settings(geo.x(), geo.y(), geo.width(), geo.height())
        self.hide()

    def full_exit_and_save(self):
        """Terminates the client after saving current geometry."""
        geo = self.geometry()
        save_settings(geo.x(), geo.y(), geo.width(), geo.height())
        QApplication.instance().quit()

    def mousePressEvent(self, event):
        """Captures mouse position for dragging start."""
        if event.button() == Qt.LeftButton:
            if not self.sizegrip.underMouse():
                self.old_pos = event.globalPosition().toPoint()

    def mouseMoveEvent(self, event):
        """Moves window based on mouse drag delta."""
        if self.old_pos is not None:
            delta = event.globalPosition().toPoint() - self.old_pos
            self.move(self.x() + delta.x(), self.y() + delta.y())
            self.old_pos = event.globalPosition().toPoint()

    def mouseReleaseEvent(self, event):
        """Resets dragging state."""
        self.old_pos = None


if __name__ == "__main__":
    app = QApplication(sys.argv)
    ex = StudyOverlay()

    if len(sys.argv) >= 4:
        # Command line execution: [1]Text, [2]Engine, [3]Model
        ex.show()
        ex.run_ai_task(sys.argv[1], sys.argv[2], sys.argv[3])
    elif len(sys.argv) > 1:
        # Fallback to defaults if only text is provided via command line
        ex.show()
        ex.run_ai_task(sys.argv[1])
    else:
        # Start in empty or standby state if executed without arguments
        # ex.show()
        # ex.run_ai_task("But Mistress, surely there is no feedback from a ranged weapon.")
        pass

    sys.exit(app.exec())
