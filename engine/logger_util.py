import os
import datetime
import sys

# Global toggle for logging
DEBUG = True

# Define log file path in the script directory
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(SCRIPT_DIR, "ko_trans_server_log.txt") #

# Redirect stdout and stderr to the log file for environments without a console (e.g., pythonw)
if sys.stdout is None:
    try:
        sys.stdout = open(LOG_PATH, "a", encoding="utf-8", buffering=1) #
    except:
        pass

if sys.stderr is None:
    try:
        sys.stderr = open(LOG_PATH, "a", encoding="utf-8", buffering=1) #
    except:
        pass

def log(msg):
    """
    Common logging function that handles file rotation (1MB limit)
    and adds a timestamp to each message.
    """
    if not DEBUG:
        return

    max_size = 1 * 1024 * 1024  # 1MB size limit

    try:
        # Check if the log file exists and exceeds the size limit
        if os.path.exists(LOG_PATH) and os.path.getsize(LOG_PATH) > max_size:
            try:
                os.remove(LOG_PATH)
            except:
                pass

        # Generate timestamp and format the final message
        timestamp = datetime.datetime.now().strftime("[%Y-%m-%d %H:%M:%S]")
        formatted_msg = f"{timestamp} {msg}"

        # Print to console for real-time monitoring if available
        print(formatted_msg, flush=True)

    except Exception as e:
        # Fallback print if file logging fails
        pass