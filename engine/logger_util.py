import os
import sys
import logging
from logging.handlers import RotatingFileHandler

# Global toggle for logging
DEBUG = True
MAX_SIZE = 1 * 1024 * 1024  # 1MB size limit

# Specific keywords to filter out from stdout/stderr to clean the log
FILTER_KEYWORDS = [
    "AFC is enabled",
    "models.py:5466",
    "HTTP Request",
    "_client.py",
    "generativelanguage.googleapis.com"
]

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(SCRIPT_DIR, "ko_trans_server_log.txt")

def startup_log_check():
    try:
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > MAX_SIZE:
            os.remove(LOG_PATH)
    except Exception:
        pass

startup_log_check()

logger = logging.getLogger("KO_Trans_Server")
logger.setLevel(logging.INFO)
logger.propagate = False

# Silence common noisy third-party loggers at the source by setting level to WARNING
logging.getLogger("google").setLevel(logging.WARNING)
logging.getLogger("google.genai").setLevel(logging.WARNING)
logging.getLogger("google.genai.models").setLevel(logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("urllib3").setLevel(logging.WARNING)
logging.getLogger("openai").setLevel(logging.WARNING)


if not logger.handlers:
    handler = RotatingFileHandler(LOG_PATH, maxBytes=MAX_SIZE, backupCount=1, encoding="utf-8")
    formatter = logging.Formatter('[%(asctime)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
    handler.setFormatter(formatter)
    logger.addHandler(handler)

class StreamToLogger:
    def __init__(self, logger, log_level=logging.INFO):
        self.logger = logger
        self.log_level = log_level
        self._is_logging = False
        # satisfies some libraries checking for encoding
        self.encoding = "utf-8"

    def write(self, buf):
        if self._is_logging:
            return

        # Skip logic: ignore buffers containing noisy library keywords
        clean_buf = buf.strip()
        if not clean_buf:
            return

        if any(kw.lower() in clean_buf.lower() for kw in FILTER_KEYWORDS):
            return

        self._is_logging = True
        try:
            for line in clean_buf.splitlines():
                msg = line.rstrip()
                if msg:
                    self.logger.log(self.log_level, msg)
        finally:
            self._is_logging = False

    def flush(self):
        pass

    def isatty(self):
        return False

if sys.stdout is None or isinstance(sys.stdout, type(None)) or not hasattr(sys.stdout, 'isatty'):
    sys.stdout = StreamToLogger(logger, logging.INFO)
if sys.stderr is None or isinstance(sys.stderr, type(None)) or not hasattr(sys.stderr, 'isatty'):
    sys.stderr = StreamToLogger(logger, logging.ERROR)

def log(msg):
    if not DEBUG:
        return
    try:
        logger.info(msg)
    except Exception:
        pass