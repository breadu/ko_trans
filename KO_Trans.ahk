#Requires AutoHotkey v2.0
; Ensure DPI awareness for accurate coordinate calculations across different monitors
DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
DllCall("SetProcessDpiAwarenessContext", "ptr", -4, "ptr")

OnExit(ExitHandler)

Global IS_BOOTING := true
IsBooting() {
    global IS_BOOTING
    return (IsSet(IS_BOOTING) && IS_BOOTING)
}

#Include Gdip_All.ahk
#Include OCR.ahk
#Include KO_Trans_ProfileManager.ahk

; ---------------------------------------------------------
; Global Configuration & Initialization
; ---------------------------------------------------------
Global OCR_TEST_MODE := false
Global ENGINE_DEVICE_MODE := "CPU"
Global WM_COPYDATA := 0x004A
Global POT_COMMAND := 0x0400
Global POT_GET_PLAYFILE_NAME := 0x6020
Global POT_GET_CURRENT_TIME := 0x5004
Global CURRENT_PROFILE := IniRead(INI_FILE, PROFILE_SETTINGS, "ACTIVE_PROFILE", PROFILE_SETTINGS)
Global SUPPORT_POTPLAYER_SUBTITLE := false

; ==============================================================================
; 1. CONFIGURATION - Hierarchical Loading (Process -> Settings -> Default)
; ==============================================================================
Global OCR_SERVER_URL := "http://127.0.0.1:5000/ocr"
Global CHATGPT_ENDPOINT := "http://127.0.0.1:5000/translate"
Global FURIGANA_ENDPOINT := "http://127.0.0.1:5000/furigana"

; Global variable initialization
Global OCR_X := DEFAULT_OCR_X, OCR_Y := DEFAULT_OCR_Y, OCR_W := DEFAULT_OCR_W, OCR_H := DEFAULT_OCR_H, OCR_LANG := DEFAULT_LANG
Global READ_MODE := DEFAULT_READ_MODE
Global OVERLAY_OPACITY:= DEFAULT_OVERLAY_OPACITY, OVERLAY_FONT_SIZE := DEFAULT_OVERLAY_FONT_SIZE
Global OVERLAY_FONT_COLOR := DEFAULT_OVERLAY_FONT_COLOR
Global GEMINI_API_KEY := "", OPENAI_API_KEY := ""
Global CHAR_DICT_ENABLED := 0, CHAR_DICT_PATH := "NONE"
Global KEY_TRIGGER := DEFAULT_KEY_TRIGGER, MOUSE_TRIGGER := DEFAULT_MOUSE_TRIGGER, PAD_TRIGGER := DEFAULT_PAD_TRIGGER
Global JAP_YOMIGANA := DEFAULT_JAP_YOMIGANA
Global JAP_READ_VERTICAL := DEFAULT_JAP_READ_VERTICAL
Global ActiveHotkeys := []
Global g_CurrentTimeMs := 0
Global originalWin := 0
Global btnClose := unset
Global BaselineBitmap := 0
Global StableChangeCount := 0
Global CursorExclusionRect := {x1: -1, y1: -1, x2: -1, y2: -1}
Global SplashGui := unset
Global lastHash := ""
Global WM_LBUTTONDOWN := 0x0201
Global LastTextROI := {x:0, y:0, w:0, h:0}

A_MenuMaskKey := "vkFF"  ; Prevent Ctrl key interference during hotkey execution

; Shared Memory Constants for Inter-process Communication
Global SHM_NAME := "KO_TRANS_SHM"
Global SHM_SIZE := 4000 * 2500 * 4 + 1
Global hMapFile := 0
Global pSharedMem := 0

; --- REORGANIZED: Overlay State Object ---
Global Overlay := {
    Gui: unset,
    Text: unset,
    btnClose: unset,
    IsActive: false,
    IsBusy: false,
    PendingRequest: false,
    PadLastState: 0,
    LastOcr: "",
    LastHash: "",
    X: 500, Y: 30, W: 1200, H: 210
}

; ---------------------------------------------------------
; Initializing Functions
; ---------------------------------------------------------
;OnMessage(WM_LBUTTONDOWN, DragTransWindow)
OnMessage(WM_COPYDATA, ProcessPotPlayerResponse)

InitSharedMemory()

; Initialize shared memory after GDI+ startup
If !pToken := Gdip_Startup() {
    MsgBox("GDI+ 시작에 실패했습니다.", "오류", 48)
    ExitApp()
}

ShowSplash()

try {
    ; Start the OCR Server asynchronously
    Run('wscript.exe "' A_ScriptDir '\start_ocr_server.vbs"', A_ScriptDir, "Hide")
    LogDebug("[System] Starting OCR Server...")

    ; Use the health check timer to monitor server status
    SetTimer(CheckServerStatusForSplash, 1000)
} catch Error as e {
    LogDebug("[Error] Failed to start KO Trans: " e.Message)
}

InitializeSettings()

LoadProfileSettings()

; ---------------------------------------------------------
; Function Implements
; ---------------------------------------------------------
InitSharedMemory() {
    Global hMapFile, pSharedMem, SHM_NAME, SHM_SIZE
    ; Try to open existing mapping; if fails, create a new one
    hMapFile := DllCall("OpenFileMapping", "UInt", 0xF001F, "Int", 0, "Str", SHM_NAME, "Ptr")
    if !hMapFile {
        hMapFile := DllCall("CreateFileMapping", "Ptr", -1, "Ptr", 0, "UInt", 0x04, "UInt", 0, "UInt", SHM_SIZE, "Str", SHM_NAME, "Ptr")
        LogDebug("[SharedMemory] Created new FileMapping: " . hMapFile)
    } else {
        LogDebug("[SharedMemory] Opened existing FileMapping: " . hMapFile)
    }
    pSharedMem := DllCall("MapViewOfFile", "Ptr", hMapFile, "UInt", 0xF001F, "UInt", 0, "UInt", 0, "Ptr", SHM_SIZE, "Ptr")
    LogDebug("[SharedMemory] MapViewOfFile pointer: " . pSharedMem)
}

WriteToSharedMemory(pBitmap) {
    Global pSharedMem
    if !pSharedMem {
        InitSharedMemory()
        if !pSharedMem {
            LogDebug("WriteToSharedMemory() ❌ Shared Memory not initialized!")
            return 0
        }
    }

    if (pBitmap <= 0) {
        LogDebug("[Error] WriteToSharedMemory: Invalid Bitmap handle.")
        return 0
    }

    Gdip_GetImageDimensions(pBitmap, &w, &h)

    ; Lock bits for reading raw pixel data. Gdip_LockBits returns 0 on success.
    if !Gdip_LockBits(pBitmap, 0, 0, w, h, &Stride, &Scan0, &BitmapData) {
        dataSize := w * h * 4

        if (pSharedMem != 0 && Scan0 != 0) {
            ; Status Flag: 1 indicates the producer is writing data
            NumPut("UChar", 1, pSharedMem, 0)

            ; Copy pixel data starting from the 1-byte offset (pSharedMem + 1)
            DllCall("ntdll\memcpy", "Ptr", pSharedMem + 1, "Ptr", Scan0, "Ptr", dataSize, "cdecl")

            ; Status Flag: 2 indicates the data is ready for the consumer (Python server)
            NumPut("UChar", 2, pSharedMem, 0)

            Gdip_UnlockBits(pBitmap, &BitmapData)
            return {w: w, h: h}
        }
        Gdip_UnlockBits(pBitmap, &BitmapData)
    }

    LogDebug("WriteToSharedMemory() ❌ Gdip_LockBits failed")
    return 0
}

ShowSplash() {
    Global SplashGui
    mascotPath := A_ScriptDir "\mascot.png"

    if !FileExist(mascotPath) {
        LogDebug("[Warning] mascot.png not found for splash screen.")
        return
    }

    SplashGui := Gui("+AlwaysOnTop -Caption +ToolWindow +LastFound -DPIScale")

    ; Define ChromaKey for transparency
    ChromaKey := "0xFF00FF"
    SplashGui.BackColor := ChromaKey

    SplashGui.Add("Pic", "x0 y0 h400 w-1 BackgroundTrans", mascotPath)

    ; Apply transparency to the ChromaKey color
    WinSetTransColor(ChromaKey, SplashGui)

    SplashGui.Show("Center NoActivate")
}

; Setup default INI values for the first run
InitializeSettings() {
    global INI_FILE
    if !FileExist(INI_FILE) {
        SplitPath(INI_FILE, , &dir)
        if !DirExist(dir)
            DirCreate(dir)

        ; Profile and OCR Area
        IniWrite(PROFILE_SETTINGS, INI_FILE, PROFILE_SETTINGS, INI_ACTIVE_PROFILE)
        IniWrite(DEFAULT_OCR_X, INI_FILE, PROFILE_SETTINGS, INI_OCR_X)
        IniWrite(DEFAULT_OCR_Y, INI_FILE, PROFILE_SETTINGS, INI_OCR_Y)
        IniWrite(DEFAULT_OCR_W, INI_FILE, PROFILE_SETTINGS, INI_OCR_W)
        IniWrite(DEFAULT_OCR_H, INI_FILE, PROFILE_SETTINGS, INI_OCR_H)

        ; Overlay Style
        IniWrite(DEFAULT_OVERLAY_X, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_X)
        IniWrite(DEFAULT_OVERLAY_Y, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_Y)
        IniWrite(DEFAULT_OVERLAY_W, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_W)
        IniWrite(DEFAULT_OVERLAY_H, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_H)
        IniWrite(DEFAULT_OVERLAY_OPACITY, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_OPACITY)
        IniWrite(DEFAULT_OVERLAY_FONT_SIZE, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_FONT_SIZE)
        IniWrite(DEFAULT_OVERLAY_FONT_COLOR, INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_FONT_COLOR)

        ; Language
        IniWrite(DEFAULT_LANG, INI_FILE, PROFILE_SETTINGS, INI_LANG)
        IniWrite(DEFAULT_JAP_YOMIGANA, INI_FILE, PROFILE_SETTINGS, INI_JAP_YOMIGANA)
        IniWrite(DEFAULT_JAP_READ_VERTICAL, INI_FILE, PROFILE_SETTINGS, INI_JAP_READ_VERTICAL)

        ; Engine and Models
        IniWrite(DEFAULT_ENGINE, INI_FILE, PROFILE_SETTINGS, INI_ENGINE)
        IniWrite(DEFAULT_GEMINI_MODEL, INI_FILE, PROFILE_SETTINGS, INI_GEMINI_MODEL)
        IniWrite(DEFAULT_GPT_MODEL, INI_FILE, PROFILE_SETTINGS, INI_GPT_MODEL)
        IniWrite(DEFAULT_LOCAL_MODEL, INI_FILE, PROFILE_SETTINGS, INI_LOCAL_MODEL)

        ; Control Triggers
        IniWrite(DEFAULT_KEY_TRIGGER, INI_FILE, PROFILE_SETTINGS, INI_KEY_TRIGGER)
        IniWrite(DEFAULT_MOUSE_TRIGGER, INI_FILE, PROFILE_SETTINGS, INI_MOUSE_TRIGGER)
        IniWrite(DEFAULT_PAD_TRIGGER, INI_FILE, PROFILE_SETTINGS, INI_PAD_TRIGGER)
        IniWrite(DEFAULT_OCR_START_TIME, INI_FILE, PROFILE_SETTINGS, INI_OCR_START_TIME)
        IniWrite(DEFAULT_AUTO_DETECT_ENABLED, INI_FILE, PROFILE_SETTINGS, INI_AUTO_DETECT_ENABLED)

        ; Read Mode and Targets
        IniWrite(DEFAULT_READ_MODE, INI_FILE, PROFILE_SETTINGS, INI_READ_MODE)
        IniWrite(DEFAULT_SHOW_OCR, INI_FILE, PROFILE_SETTINGS, INI_SHOW_OCR)
        IniWrite(DEFAULT_CAPTURE_TARGET, INI_FILE, PROFILE_SETTINGS, INI_CAPTURE_TARGET)
        IniWrite(DEFAULT_CAPTURE_PROCESS, INI_FILE, PROFILE_SETTINGS, INI_CAPTURE_PROCESS)

        ; Dictionary
        IniWrite(DEFAULT_CHAR_DICT_ENABLED, INI_FILE, PROFILE_SETTINGS, INI_CHAR_DICT_ENABLED)
        IniWrite(DEFAULT_CHAR_DICT_PATH, INI_FILE, PROFILE_SETTINGS, INI_CHAR_DICT_PATH)

        LogDebug("[Settings] Initial settings.ini created with default values.")
    }
}

; Load specific profile settings with inheritance support
LoadProfileSettings(forceProc := "") {
    global

    targetProc := (forceProc != "") ? forceProc : CURRENT_PROFILE

    CURRENT_PROFILE := targetProc
    LogDebug("[Profile] Loading Profile: " . targetProc)

    ; Load OCR coordinates
    Global OCR_X := IniRead(INI_FILE, targetProc, INI_OCR_X, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_X, DEFAULT_OCR_X))
    Global OCR_Y := IniRead(INI_FILE, targetProc, INI_OCR_Y, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_Y, DEFAULT_OCR_Y))
    Global OCR_W := IniRead(INI_FILE, targetProc, INI_OCR_W, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_W, DEFAULT_OCR_W))
    Global OCR_H := IniRead(INI_FILE, targetProc, INI_OCR_H, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_H, DEFAULT_OCR_H))

    ; Load Overlay settings
    Overlay.X := IniRead(INI_FILE, targetProc, INI_OVERLAY_X, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_X, DEFAULT_OVERLAY_X))
    Overlay.Y := IniRead(INI_FILE, targetProc, INI_OVERLAY_Y, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_Y, DEFAULT_OVERLAY_Y))
    Overlay.W := IniRead(INI_FILE, targetProc, INI_OVERLAY_W, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_W, DEFAULT_OVERLAY_W))
    Overlay.H := IniRead(INI_FILE, targetProc, INI_OVERLAY_H, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_H, DEFAULT_OVERLAY_H))

    Global OVERLAY_OPACITY := IniRead(INI_FILE, targetProc, INI_OVERLAY_OPACITY, IniRead(INI_FILE, PROFILE_SETTINGS, "OVERLAY_OPACITY", DEFAULT_OVERLAY_OPACITY))
    Global OVERLAY_FONT_SIZE := IniRead(INI_FILE, targetProc, INI_OVERLAY_FONT_SIZE, IniRead(INI_FILE, PROFILE_SETTINGS, "OVERLAY_FONT_SIZE", DEFAULT_OVERLAY_FONT_SIZE))
    Global OVERLAY_FONT_COLOR := IniRead(INI_FILE, targetProc, INI_OVERLAY_FONT_COLOR, IniRead(INI_FILE, PROFILE_SETTINGS, "OVERLAY_FONT_COLOR", DEFAULT_OVERLAY_FONT_COLOR))

    ; Load API Keys from Global section
    Global GEMINI_API_KEY := IniRead(INI_FILE, PROFILE_SETTINGS, INI_GEMINI_API_KEY, "")
    Global OPENAI_API_KEY := IniRead(INI_FILE, PROFILE_SETTINGS, INI_OPENAI_API_KEY, "")

    ; Load Language
    Global OCR_LANG := IniRead(INI_FILE, targetProc, INI_LANG, IniRead(INI_FILE, PROFILE_SETTINGS, INI_LANG, DEFAULT_LANG))
    Global JAP_YOMIGANA := IniRead(INI_FILE, targetProc, INI_JAP_YOMIGANA, IniRead(INI_FILE, PROFILE_SETTINGS, INI_JAP_YOMIGANA, DEFAULT_JAP_YOMIGANA))
    Global JAP_READ_VERTICAL := IniRead(INI_FILE, targetProc, INI_JAP_READ_VERTICAL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_JAP_READ_VERTICAL, DEFAULT_JAP_READ_VERTICAL))

    ; Dictionary settings
    Global CHAR_DICT_ENABLED := IniRead(INI_FILE, targetProc, INI_CHAR_DICT_ENABLED, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CHAR_DICT_ENABLED, DEFAULT_CHAR_DICT_ENABLED))
    Global CHAR_DICT_PATH := IniRead(INI_FILE, targetProc, INI_CHAR_DICT_PATH, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CHAR_DICT_PATH, DEFAULT_CHAR_DICT_PATH))

    ; Load models
    Global GEMINI_MODEL := IniRead(INI_FILE, targetProc, INI_GEMINI_MODEL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_GEMINI_MODEL, DEFAULT_GEMINI_MODEL))
    Global GPT_MODEL    := IniRead(INI_FILE, targetProc, INI_GPT_MODEL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_GPT_MODEL, DEFAULT_GPT_MODEL))
    Global LOCAL_MODEL  := IniRead(INI_FILE, targetProc, INI_LOCAL_MODEL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_LOCAL_MODEL, DEFAULT_LOCAL_MODEL))

    ; Load trigger settings
    Global KEY_TRIGGER   := IniRead(INI_FILE, targetProc, INI_KEY_TRIGGER, IniRead(INI_FILE, PROFILE_SETTINGS, INI_KEY_TRIGGER, DEFAULT_KEY_TRIGGER))
    Global MOUSE_TRIGGER := IniRead(INI_FILE, targetProc, INI_MOUSE_TRIGGER, IniRead(INI_FILE, PROFILE_SETTINGS, INI_MOUSE_TRIGGER, DEFAULT_MOUSE_TRIGGER))
    Global PAD_TRIGGER   := IniRead(INI_FILE, targetProc, INI_PAD_TRIGGER, IniRead(INI_FILE, PROFILE_SETTINGS, INI_PAD_TRIGGER, DEFAULT_PAD_TRIGGER))

    Global OCR_START_TIME := IniRead(INI_FILE, targetProc, INI_OCR_START_TIME, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_START_TIME, DEFAULT_OCR_START_TIME))
    Global AUTO_DETECT_ENABLED := IniRead(INI_FILE, targetProc, INI_AUTO_DETECT_ENABLED, IniRead(INI_FILE, PROFILE_SETTINGS, INI_AUTO_DETECT_ENABLED, DEFAULT_AUTO_DETECT_ENABLED))

    Global CAPTURE_TARGET  := IniRead(INI_FILE, targetProc, INI_CAPTURE_TARGET, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CAPTURE_TARGET, DEFAULT_CAPTURE_TARGET))
    Global CAPTURE_PROCESS := IniRead(INI_FILE, targetProc, INI_CAPTURE_PROCESS, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CAPTURE_PROCESS, DEFAULT_CAPTURE_PROCESS))

    Global SHOW_OCR := IniRead(INI_FILE, targetProc, INI_SHOW_OCR, IniRead(INI_FILE, PROFILE_SETTINGS, INI_SHOW_OCR, DEFAULT_SHOW_OCR))
    Global READ_MODE := IniRead(INI_FILE, targetProc, INI_READ_MODE, IniRead(INI_FILE, PROFILE_SETTINGS, INI_READ_MODE, DEFAULT_READ_MODE))
}

CheckServerStatusForSplash() {
    Global OCR_SERVER_URL, SplashGui, ENGINE_DEVICE_MODE, IS_BOOTING
    static retryCount := 0

    SetTimer(CheckServerStatusForSplash, 0)

    retryCount++

    checkUrl := StrReplace(OCR_SERVER_URL, "/ocr", "/health")
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(800, 800, 800, 800)
        http.Open("GET", checkUrl, false)
        http.Send()

        if (http.Status == 200) {
            ; Check whether server is running on GPU or CPU
            if RegExMatch(http.ResponseText, '"device"\s*:\s*"([^"]+)"', &match)
                ENGINE_DEVICE_MODE := match[1]

            ; Close the Splash Screen once the server is ready
            if (IsSet(SplashGui) && SplashGui is Gui) {
                SplashGui.Destroy()
            }

            IS_BOOTING := false

            BigToolTip("✅ KO Trans 시작!", 2000)
            LogDebug("KO Trans Server is now online. (Attempts: " . retryCount . ")")
            return
        }
    } catch {
        ; Silence retry noise
    }

    if (retryCount > 60) {
        if (IsSet(SplashGui) && SplashGui is Gui) {
            SplashGui.Destroy()
        }
        BigToolTip("⚠️ OCR 서버를 시작할 수 없습니다!", 3000)
        return
    }

    SetTimer(CheckServerStatusForSplash, 1000)
}


CheckServerStatus() {
    Global OCR_SERVER_URL, SplashGui, ENGINE_DEVICE_MODE

    checkUrl := StrReplace(OCR_SERVER_URL, "/ocr", "/health")

    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")

        ; Set timeouts (2 seconds for each stage)
        http.SetTimeouts(2000, 2000, 2000, 2000)

        ; Synchronous GET request to health endpoint
        http.Open("GET", checkUrl, false)
        http.Send()

        if (http.Status == 200) {
            ; Check whether server is running on GPU or CPU
            if RegExMatch(http.ResponseText, '"device"\s*:\s*"([^"]+)"', &match)
                ENGINE_DEVICE_MODE := match[1]

            LogDebug("[System] Server Online. Device: " . ENGINE_DEVICE_MODE)

            return true
        } else {
            throw Error("Server returned status: " . http.Status)
        }
    } catch {
        LogDebug("[System] Server Offline. Tried URL: " . checkUrl)
        return false
    }

    return true
}

; ---------------------------------------------------------
; PotPlayer Subtitle Integration Logic
; ---------------------------------------------------------
ProcessPotPlayerResponse(wParam, lParam, msg, hwnd) {
    global originalWin, g_CurrentTimeMs, WaitingForPotResponse

    if (!IsSet(WaitingForPotResponse) || !WaitingForPotResponse)
        return true

    dwData := NumGet(lParam, 0, "Ptr")

    ; Verify if the response contains the file name
    if (dwData != POT_GET_PLAYFILE_NAME)
        return true

    lpData := NumGet(lParam, A_PtrSize * 2, "Ptr")
    moviePath := StrGet(lpData, "UTF-8")
    SplitPath(moviePath, , &dir, , &nameNoExt)
    basePath := dir "\" nameNoExt

    ; Look for English or default SRT files
    srtPath := ""
    if FileExist(basePath ".en.srt")
        srtPath := basePath ".en.srt"
    else if FileExist(basePath ".srt")
        srtPath := basePath ".srt"

    if (srtPath = "") {
        LogDebug("[PotPlayer] Subtitle file not found for: " . moviePath)
        return true
    }

    LogDebug("[PotPlayer] Loading subtitles from: " . srtPath)
    srtContent := FileRead(srtPath)
    subs := []
    ; Parse SRT format into memory
    Loop Parse, srtContent, "`n", "`r"
    {
        line := Trim(A_LoopField)
        if RegExMatch(line, "^\d+$")
            subs.Push({start: 0, end: 0, text: ""})
        else if InStr(line, " --> ") {
            timeArray := StrSplit(line, " --> ")
            subs[subs.Length].start := ConvertSRTTimeToMs(timeArray[1])
            subs[subs.Length].end := ConvertSRTTimeToMs(timeArray[2])
        } else if (line != "" && subs.Length > 0)
            subs[subs.Length].text .= (subs[subs.Length].text ? " " : "") line
    }

    ; Find subtitle matching current playback time
    targetIdx := 0
    for index, sub in subs {
        if (g_CurrentTimeMs >= sub.start && g_CurrentTimeMs <= sub.end) {
            targetIdx := index
            break
        }
    }

    if (targetIdx > 0) {
        finalText := subs[targetIdx].text
        LogDebug("[PotPlayer] Found subtitle index: " . targetIdx)

        ; Intelligent Merging: Combine multi-line sentences spanning across SRT blocks
        tempIdx := targetIdx
        Loop 2 {
            if (tempIdx <= 1) {
                break
            }
            if !RegExMatch(subs[tempIdx-1].text, "[.!?]\s*$") {
                finalText := subs[tempIdx-1].text " " finalText
                tempIdx--
            } else {
                break
            }
        }
        tempIdx := targetIdx
        Loop 2 {
            if (tempIdx >= subs.Length) {
                break
            }
            if !RegExMatch(subs[tempIdx].text, "[.!?]\s*$") {
                finalText := finalText " " subs[tempIdx+1].text
                tempIdx++
            } else {
                break
            }
        }

        SendToAIWordOverlay(finalText)
    }
    return true
}

; ---------------------------------------------------------
; Main Trigger: Alt+F12 (Context-aware Lookup)
; ---------------------------------------------------------
#HotIf !WinActive("Editor") && !WinActive("Gateway")
!F12::LookupDictionary()
#HotIf

LookupDictionary() {
    if (IsBooting()) {
        return
    }

    LoadProfileSettings()
    global originalWin := WinActive("A")
    LogDebug("[Hotkey] Alt+F12 pressed. Target Window: " . WinGetTitle("A"))
    global WaitingForPotResponse := false

    ; If PotPlayer is active, use SRT lookup instead of OCR
    if (SUPPORT_POTPLAYER_SUBTITLE and (WinActive("ahk_class PotPlayer64") or WinActive("ahk_class PotPlayer")))
    {
        hWndPot := originalWin
        global WaitingForPotResponse := true
        global g_CurrentTimeMs := SendMessage(POT_COMMAND, POT_GET_CURRENT_TIME, 0,, "ahk_id " hWndPot)
        SendMessage(POT_COMMAND, POT_GET_PLAYFILE_NAME, A_ScriptHwnd,, "ahk_id " hWndPot)
    }
    else if (CAPTURE_TARGET == CAPTURE_TARGET_CLIPBOARD)
    {
        clipboardText := Trim(A_Clipboard)
        if (clipboardText != "") {
            LogDebug("[Trigger] Alt+F12 - Using Clipboard for dictionary lookup.")
            SendToAIWordOverlay(clipboardText)
        } else {
            BigToolTip("⚠️ 클립보드에 텍스트가 없습니다.")
        }
    }
    else
    {
        ; Standard OCR capture for other windows
        hwndTarget := (CAPTURE_TARGET == CAPTURE_TARGET_WINDOW) ? WinExist("ahk_exe " . CAPTURE_PROCESS) : 0
        if (CAPTURE_TARGET == CAPTURE_TARGET_WINDOW && (!hwndTarget || WinGetMinMax("ahk_id " hwndTarget) == -1)) {
            BigToolTip("⚠️ 대상 윈도우가 없습니다: " . CAPTURE_PROCESS)
            return
        }

        pBitmap := CapturePhysicalScreen(OCR_X, OCR_Y, OCR_W, OCR_H, hwndTarget, true)
        if (pBitmap <= 0) {
            BigToolTip("⚠️ 캡처 실패")
            return
        }

        imgInfo := WriteToSharedMemory(pBitmap)
        Gdip_DisposeImage(pBitmap)
        if (!imgInfo) {
            BigToolTip("⚠️ 캡처 실패")
            return
        }

        resultText := TriggerOCRForWord(imgInfo)
        if (InStr(resultText, "|")) {
            parts := StrSplit(resultText, "|")
            resultText := parts[2]
        }

        if (resultText != "" && !InStr(resultText, "No text found")) {
            LogDebug("[OCR] Word Trigger Success. Result: " . SubStr(resultText, 1, 40))
            SendToAIWordOverlay(resultText)
        } else {
            LogDebug("[OCR] Word Trigger failed or no text found.")
            BigToolTip("OCR 실패")
        }
    }
}

; ---------------------------------------------------------
; Capture Logic (DPI-aware & WGC Support)
; ---------------------------------------------------------
CapturePhysicalScreen(x, y, w, h, hwnd := 0, forceFresh := false) {
    static lastHwnd := 0
    static pDevice := 0, pFramePool := 0, pSession := 0

    oldContext := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    pBitmap := 0
    pFullBitmap := 0

    ; Mode 1: Full Screen Capture using BitBlt
    if (hwnd == 0) {
        hhdc := DllCall("GetDC", "Ptr", 0, "Ptr")
        chdc := DllCall("CreateCompatibleDC", "Ptr", hhdc, "Ptr")
        hbm  := DllCall("CreateCompatibleBitmap", "Ptr", hhdc, "Int", w, "Int", h, "Ptr")
        obm  := DllCall("SelectObject", "Ptr", chdc, "Ptr", hbm, "Ptr")
        DllCall("BitBlt", "Ptr", chdc, "Int", 0, "Int", 0, "Int", w, "Int", h, "Ptr", hhdc, "Int", x, "Int", y, "UInt", 0x00CC0020)
        DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBitmap := 0)
        DllCall("SelectObject", "Ptr", chdc, "Ptr", obm)
        DllCall("DeleteObject", "Ptr", hbm)
        DllCall("DeleteDC", "Ptr", chdc)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hhdc)
    }
    else {
        ; Mode 2: Window-specific capture using Windows Graphics Capture (WGC)
        Loop 2 {
            try {
                if (!WinExist("ahk_id " hwnd) || WinGetMinMax("ahk_id " hwnd) == -1) {
                    return 0
                }

                ; Calculate the difference between the actual window area and the visible area (Shadow Border correction)
                rectActual := Buffer(16, 0)
                DllCall("GetWindowRect", "ptr", hwnd, "ptr", rectActual)
                aw := NumGet(rectActual, 8, "int") - NumGet(rectActual, 0, "int")
                ah := NumGet(rectActual, 12, "int") - NumGet(rectActual, 4, "int")

                rectVisible := Buffer(16, 0)
                DllCall("Dwmapi.dll\DwmGetWindowAttribute", "ptr", hwnd, "uint", 9, "ptr", rectVisible, "uint", 16)

                ; Extract horizontal/vertical offset values caused by transparent borders
                offsetX := NumGet(rectVisible, 0, "int") - NumGet(rectActual, 0, "int")
                offsetY := NumGet(rectVisible, 4, "int") - NumGet(rectActual, 4, "int")

                if (forceFresh || hwnd != lastHwnd || !pSession) {
                    if (pSession) {
                        try OCR.CloseIClosable(pSession)
                        pSession := 0 ; Reset to ensure clean session state
                    }
                    if (pFramePool) {
                        try OCR.CloseIClosable(pFramePool)
                        pFramePool := 0 ; Reset to ensure clean pool state
                    }

                    if (!pDevice) {
                        DllCall("D3D11\D3D11CreateDevice", "ptr", 0, "int", 1, "ptr", 0, "uint", 0x20, "ptr", 0, "uint", 0, "uint", 7, "ptr*", &pDevPtr := 0, "ptr*", 0, "ptr*", &pCtxPtr := 0)
                        pDevice := ComValue(13, pDevPtr)
                    }

                    GCI_Statics := OCR.CreateClass("Windows.Graphics.Capture.GraphicsCaptureItem", "{A87EBEA5-457C-5788-AB47-0CF1D3637E74}")
                    IInterop := ComObjQuery(GCI_Statics, "{3628E81B-3CAC-4C60-B7F4-23CE0E0C3356}")
                    IID_IGCI := OCR.CLSIDFromString("{79c3f95b-31f7-4ec2-a464-632ef5d30760}")
                    ComCall(3, IInterop, "ptr", hwnd, "ptr", IID_IGCI, "ptr*", &pItemPtr := 0)
                    pItem := ComValue(13, pItemPtr)

                    ; Match the frame pool size to the actual window size (aw, ah) to prevent image distortion (scaling)
                    nw := aw, nh := ah

                    DXGIDevice := ComObjQuery(pDevice, "{54ec77fa-1377-44e6-8c32-88fd5f44c84c}")
                    DllCall("D3D11\CreateDirect3D11DeviceFromDXGIDevice", "ptr", DXGIDevice, "ptr*", &gDevPtr := 0)
                    Direct3DDevice := ComValue(13, gDevPtr)

                    PoolStatics := OCR.CreateClass("Windows.Graphics.Capture.Direct3D11CaptureFramePool", "{7784056a-67aa-4d53-ae54-1088d5a8ca21}")
                    ComCall(6, PoolStatics, "ptr", Direct3DDevice, "int", 87, "int", 2, "int64", (Integer(nh) << 32) | Integer(nw), "ptr*", &pPoolPtr := 0)
                    pFramePool := ComValue(13, pPoolPtr)
                    ComCall(10, pFramePool, "ptr", pItem, "ptr*", &pSessPtr := 0)
                    pSession := ComValue(13, pSessPtr)

                    try {
                        pSession3 := ComObjQuery(pSession, "{f2cdd966-22ae-5ea1-9596-3a289344c3be}")
                        if (pSession3) {
                            ComCall(7, pSession3, "int", 0)
                        }
                    }

                    ComCall(6, pSession)

                    Sleep(200)
                    lastHwnd := (forceFresh) ? 0 : hwnd
                }

                ; Self-healing logic for frame acquisition
                ; Drain the frame pool to ensure we acquire the most recent frame and avoid stale data
                pFramePtr := 0
                loop {
                    ComCall(7, pFramePool, "ptr*", &pNextFramePtr := 0)
                    if (pNextFramePtr == 0)
                        break

                    if (pFramePtr != 0)
                        ObjRelease(pFramePtr)

                    pFramePtr := pNextFramePtr
                }

                if (pFramePtr == 0) {
                    if (pSession) {
                        try OCR.CloseIClosable(pSession)
                    }
                    if (pFramePool) {
                        try OCR.CloseIClosable(pFramePool)
                    }
                    pSession := pFramePool := lastHwnd := 0

                    if (A_Index == 1) {
                        Sleep(100)
                        continue
                    }
                    return 0
                }
                pFrame := ComValue(13, pFramePtr)

                ComCall(6, pFrame, "ptr*", &pSurfPtr := 0)
                pSurface := ComValue(13, pSurfPtr)
                ComCall(11, OCR.SoftwareBitmapStatics, "ptr", pSurface, "ptr*", &sBmpPtr := 0)
                sBitmap := ComValue(13, sBmpPtr)
                OCR.WaitForAsync(&sBitmap)

                ComCall(8, sBitmap, "uint*", &psw := 0), ComCall(9, sBitmap, "uint*", &psh := 0)
                nsw := Integer(psw), nsh := Integer(psh)

                ComCall(15, sBitmap, "int", 2, "ptr*", &BmpBufPtr := 0)
                BitmapBuffer := ComValue(13, BmpBufPtr)
                MemoryBuffer := ComObjQuery(BitmapBuffer, "{fbc4dd2a-245b-11e4-af98-689423260cf8}")
                ComCall(6, MemoryBuffer, "ptr*", &MemBufRefPtr := 0)
                MemoryBufferReference := ComValue(13, MemBufRefPtr)
                BufferByteAccess := ComObjQuery(MemoryBufferReference, "{5b0d3235-4dba-4d44-865e-8f1d0e4fd04d}")
                ComCall(3, BufferByteAccess, "ptr*", &pData := 0, "uint*", &nSize := 0)

                pFullBitmap := Gdip_CreateBitmap(nsw, nsh)
                Gdip_LockBits(pFullBitmap, 0, 0, nsw, nsh, &Stride, &Scan0, &BitmapData)

                if (Scan0 != 0 && pData != 0 && nSize > 0) {
                    DllCall("ntdll\memcpy", "ptr", Scan0, "ptr", pData, "ptr", Integer(nSize), "cdecl")
                } else {
                    LogDebug("[Error] memcpy skipped in CapturePhysicalScreen: Invalid pointer or size.")
                }

                Gdip_UnlockBits(pFullBitmap, &BitmapData)

                ; Apply calculated offset to align crop area with the actual visible area
                ix := Integer(x) + offsetX
                iy := Integer(y) + offsetY
                iw := Integer(w)
                ih := Integer(h)
                pBitmap := Gdip_CloneBitmapArea(pFullBitmap, ix, iy, iw, ih)

                BufferByteAccess := MemoryBufferReference := MemoryBuffer := BitmapBuffer := 0
                OCR.CloseIClosable(sBitmap), OCR.CloseIClosable(pFrame)

                break
            } catch Error as e {
                lastHwnd := 0
                if (A_Index == 1)
                    continue
                return 0
            } finally {
                Gdip_DisposeImage(pFullBitmap)
            }
        }
    }

    DllCall("SetThreadDpiAwarenessContext", "ptr", oldContext, "ptr")
    return pBitmap
}

; ---------------------------------------------------------
; Helper Functions
; ---------------------------------------------------------
TriggerOCRForWord(imgInfo) {
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(1000, 1000, 1000, 3000)
        http.Open("POST", OCR_SERVER_URL, false)
        http.SetRequestHeader("Content-Type", "application/json")
        payload := '{"w": ' imgInfo.w ', "h": ' imgInfo.h '}'
        http.Send(payload)

        return http.ResponseText
    } catch {
        LogDebug("[Error] OCR Server is unreachable for Word Trigger.")
        return "Server is off!"
    }
}

; Function for requesting Yomigana from the server
GetFurigana(text) {
    try {
        if (text == "") {
            return ""
        }
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(500, 500, 500, 1000)
        http.Open("POST", FURIGANA_ENDPOINT, false)
        http.SetRequestHeader("Content-Type", "application/json")

        ; Newlines (`n, `r) and tabs (`t) must be escaped to prevent JSON format corruption
        safeText := StrReplace(text, "\", "\\")
        safeText := StrReplace(safeText, '"', '\"')
        safeText := StrReplace(safeText, "`n", "\n")
        safeText := StrReplace(safeText, "`r", "\r")
        safeText := StrReplace(safeText, "`t", "\t")

        payload := '{"text": "' . safeText . '"}'
        http.Send(payload)

        return http.ResponseText
    } catch {
        return text
    }
}

ConvertSRTTimeToMs(timeStr) {
    timeStr := StrReplace(timeStr, ",", ".")
    parts := StrSplit(timeStr, ":")
    hh := parts[1] * 3600000
    mm := parts[2] * 60000
    secParts := StrSplit(parts[3], ".")
    ss := secParts[1] * 1000
    ms := (secParts.Length > 1) ? secParts[2] : 0
    return hh + mm + ss + ms
}

BigToolTip(text, duration := 2000) {
    static myGui := 0

    if (myGui) {
        try myGui.Destroy()
        myGui := 0
    }

    if (text == "")
        return
    try {
        myGui := Gui("+AlwaysOnTop -Caption +ToolWindow")
        myGui.BackColor := "FFFFE1"
        myGui.SetFont("s24", "Segoe UI")
        myGui.Add("Text", "Center", text)
        myGui.Show("NA xCenter y800")

        if (duration > 0) {
            thisGui := myGui
            SetTimer(ObjBindMethod(thisGui, "Destroy"), -duration)
        }
    } catch Error as e {
        LogDebug("[Error] Failed to create BigToolTip: " . e.Message)
    }
}

Default_Gui_Exist(title) {
    return WinExist(title " ahk_class AutoHotkeyGUI")
}

; ---------------------------------------------------------
; Shift+F12: Toggle Real-time Subtitle Overlay
; ---------------------------------------------------------
+F12:: ShowTransOverlay(!IsOverlayActive())

ShowTransOverlay(show) {
    global Overlay, INI_FILE, OVERLAY_OPACITY, OVERLAY_FONT_SIZE, AUTO_DETECT_ENABLED

    if (IsBooting()) {
        return
    }

    ; Prevent redundant calls if the state is already as requested
    if (show == Overlay.IsActive)
        return

    if (show) {
        ; Prevent double activation during server check
        Overlay.IsActive := true

        ; Cleanup any leftover "ghost" overlay windows
        if WinExist("TranslationOverlay ahk_class AutoHotkeyGUI") {
            try WinKill("TranslationOverlay ahk_class AutoHotkeyGUI")
            Sleep(100)
        }

        LoadProfileSettings()
        Overlay.PadLastState := 0
        LogDebug("[System] Activating Subtitle Overlay...")

        isServerOn := CheckServerStatus()

        ; Calculate system border thickness caused by the +Resize option.
        ; This is necessary because Windows adds invisible borders for resizing, which shifts the GUI.
        borderX := DllCall("GetSystemMetrics", "Int", 32, "Int") + DllCall("GetSystemMetrics", "Int", 92, "Int")
        borderY := DllCall("GetSystemMetrics", "Int", 33, "Int") + DllCall("GetSystemMetrics", "Int", 92, "Int")

        ; Subtract the border thickness so that the visible area aligns exactly with the saved coordinates.
        showX := Overlay.X - borderX
        showY := Overlay.Y - borderY

        Overlay.Gui := Gui("+AlwaysOnTop -Caption +ToolWindow +Resize -DPIScale -MinimizeBox +E0x08000000", "TranslationOverlay")
        Overlay.Gui.BackColor := "000000"
        WinSetTransparent(OVERLAY_OPACITY, Overlay.Gui)

        Overlay.Gui.SetFont("s" OVERLAY_FONT_SIZE " c" OVERLAY_FONT_COLOR, "Segoe UI")
        Overlay.Text := Overlay.Gui.Add("Text", "x10 y10 w" (Overlay.W - 50) " h" (Overlay.H - 20),
            isServerOn ? "설정한 트리거 키를 눌러 번역을 시작하세요! 🥊"
                : "⚠️ OCR 서버 연결 실패. 엔진이 켜져 있는지 확인하세요!"
        )

        Overlay.Gui.SetFont("s18")
        Overlay.Loading := Overlay.Gui.Add("Text", "x0 y0 w35 h35 Hidden cYellow", "⏳")
        Overlay.Gui.SetFont("s" OVERLAY_FONT_SIZE " c" OVERLAY_FONT_COLOR)

        Overlay.btnClose := Overlay.Gui.Add("Button", "w30 h30 -Tabstop", "X")

        ; Close button explicitly calls for hiding
        Overlay.btnClose.OnEvent("Click", (*) => ShowTransOverlay(false))
        Overlay.Gui.OnEvent("Close", (*) => ShowTransOverlay(false))
        Overlay.Gui.OnEvent("Size", TransOverlay_Size)

        OnMessage(0x0112, (wParam, *) => (wParam & 0xFFF0 = 0xF020 ? 0 : ""))
        OnMessage(WM_LBUTTONDOWN, DragTransWindow)

        ; Use the corrected showX and showY for precise positioning
        Overlay.Gui.Show("x" showX " y" showY " w" Overlay.W " h" Overlay.H " NA")

        if (AUTO_DETECT_ENABLED == "1" && CAPTURE_TARGET != CAPTURE_TARGET_CLIPBOARD) {
            LogDebug("[System] Auto-Detection enabled. Starting WatchArea timer.")
            SetTimer(WatchArea, 500)
        }

        UpdateTriggerHotkeys()
    } else {
        LogDebug("[System] Deactivating Subtitle Overlay.")
        Overlay.IsActive := false
        Overlay.IsBusy := false
        Overlay.PendingRequest := false

        Overlay.LastOcr := ""
        Overlay.LastHash := ""

        ; Clear text control to prevent ghosting before destruction
        if Overlay.HasProp("Text")
            Overlay.Text.Value := ""

        SetTimer(WatchArea, 0)
        SetTimer(TriggerOCRForTranslate, 0)

        if (IsSet(BaselineBitmap) && BaselineBitmap) {
            Gdip_DisposeImage(BaselineBitmap)
            BaselineBitmap := 0
        }

        UpdateTriggerHotkeys()

        ; Ensure all GUI objects are explicitly deleted to free memory
        if Overlay.HasProp("Gui") {
            Overlay.Gui.Destroy()
            Overlay.DeleteProp("Gui")
        }
        Overlay.DeleteProp("Text")
        Overlay.DeleteProp("btnClose")
        if Overlay.HasProp("Loading")
            Overlay.DeleteProp("Loading")
    }
}

IsOverlayActive() {
    global Overlay
    return Overlay.IsActive
}

TransOverlay_Size(thisGui, minMax, width, height) {
    global Overlay

    if Overlay.HasProp("Text") {
        Overlay.Text.Move(,, width - 50, height - 20)
    }

    if Overlay.HasProp("Loading") {
        Overlay.Loading.Move(width - 40, height - 40)
    }

    if Overlay.HasProp("btnClose") {
        Overlay.btnClose.Move(width - 30, 0)
    }

    if (Overlay.HasProp("Gui")) {
        WinRedraw("ahk_id " Overlay.Gui.Hwnd)
    }
}

; Main OCR loop for real-time translation
TriggerOCRForTranslate() {
    Global Overlay, OCR_X, OCR_Y, OCR_W, OCR_H, READ_MODE, OCR_START_TIME, ENGINE_DEVICE_MODE
    Global CAPTURE_TARGET, CAPTURE_TARGET_CLIPBOARD, JAP_YOMIGANA, OCR_LANG, SHOW_OCR
    Global LastTextROI
    static FailCount := 0
    ocrResult := ""

    if (!Overlay.IsActive || CAPTURE_TARGET == CAPTURE_TARGET_CLIPBOARD) {
        Overlay.IsBusy := false
        Overlay.PendingRequest := false
        return
    }

    try {
        Loop {
            hwndTarget := 0
            if (CAPTURE_TARGET == CAPTURE_TARGET_WINDOW) {
                hwndTarget := WinExist("ahk_exe " . CAPTURE_PROCESS)

                ; Check if target window exists and is not minimized
                if (!hwndTarget || WinGetMinMax("ahk_id " hwndTarget) == -1) {
                    if (Overlay.IsActive && Overlay.HasProp("Gui")) {
                        Overlay.Text.Value := "⚠️ 캡처 대상 윈도우를 찾을 수 없습니다.`n프로세스(" . CAPTURE_PROCESS . ") 실행 여부를 확인하세요!"
                        try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
                    }

                    SetLoading(false, "Target Window Hidden or Minimized")
                    Overlay.IsBusy := false
                    return
                }
            }

            Overlay.PendingRequest := false
            Overlay.IsBusy := true

            ; Display loading indicator (hourglass)
            SetLoading(true, "Process Started")

            Sleep(OCR_START_TIME)

            ; --- Step 1: Detect Screen Changes (Smart Wait) ---
            maxWait := 10
            isChanged := false
            initialHash := Overlay.LastHash

            Loop maxWait {
                currentHash := GetAreaHash(OCR_X, OCR_Y, OCR_W, OCR_H, hwndTarget)

                if (initialHash == "") {
                    isChanged := true
                    Overlay.LastHash := currentHash
                    break
                }

                if (currentHash != initialHash) {
                    LogDebug("[SmartWait] Screen change detected.")
                    Overlay.LastHash := currentHash
                    isChanged := true
                    break
                }
                Sleep(100)
            }

            if (!isChanged) {
                break
            }

            ; --- Step 2: Adaptive Stability Check ---
            ; Use different stability settings for GPU (fast/precise) vs CPU (slower/efficient)
            requiredStableCount := (ENGINE_DEVICE_MODE == "GPU") ? 2 : 1
            checkInterval := (ENGINE_DEVICE_MODE == "GPU") ? 150 : 50

            stableCount := 0, prevCount := 0, prevArea := 0
            maxChecks := (ENGINE_DEVICE_MODE == "GPU") ? 20 : 30

            Loop maxChecks {
                pBitmap := CapturePhysicalScreen(OCR_X, OCR_Y, OCR_W, OCR_H, hwndTarget)
                if (pBitmap <= 0) {
                    continue
                }

                imgInfo := WriteToSharedMemory(pBitmap)
                Gdip_DisposeImage(pBitmap)
                if (!imgInfo) {
                    continue
                }

                try {
                    http_detect := ComObject("WinHttp.WinHttpRequest.5.1")
                    http_detect.SetTimeouts(1000, 1000, 1000, 3000)
                    http_detect.Open("POST", StrReplace(OCR_SERVER_URL, "/ocr", "/detect"), false)
                    http_detect.SetRequestHeader("Content-Type", "application/json")
                    payload := '{"w": ' imgInfo.w ', "h": ' imgInfo.h '}'
                    http_detect.Send(payload)

                    ; Parse simplified detection string "count,area,typical_h"
                    res := StrSplit(http_detect.ResponseText, ",")
                    currCount := (res.Length >= 1) ? Integer(res[1]) : 0
                    currArea  := (res.Length >= 2) ? Integer(res[2]) : 0
                } catch {
                    LogDebug("[Stability] ❌ Server connection lost during stability check.")
                    throw Error("Server Offline")
                }

                if (currCount == 0) {
                    stableCount := 0
                    prevArea := 0
                    Sleep(checkInterval)
                    continue
                }

                ; Reset stability if rapid area changes occur (30%+ change indicates transition or noise)
                areaChange := (prevArea > 0) ? (Abs(currArea - prevArea) / prevArea) * 100 : 0
                if (areaChange > 30.0) {
                    stableCount := 0
                }
                else if (prevArea > 0 && currCount == prevCount && areaChange < 5.0) {
                    stableCount++
                } else {
                    stableCount := 0
                }

                prevCount := currCount
                prevArea := currArea

                if (stableCount >= requiredStableCount) {
                    LogDebug("[Stability] Screen Stable. Proceeding.")
                    break
                }
                Sleep(checkInterval)
            }

            ; --- Step 3: Capture and OCR Request (with Retry Logic) ---
            Loop 2 {
                 pBitmap := CapturePhysicalScreen(OCR_X, OCR_Y, OCR_W, OCR_H, hwndTarget, (A_Index == 2))
                if (pBitmap <= 0) {
                    BigToolTip("⚠️ 캡처 실패")
                    return
                }

                imgInfo := WriteToSharedMemory(pBitmap)
                Gdip_DisposeImage(pBitmap)
                if (!imgInfo) {
                    BigToolTip("⚠️ 캡처 실패")
                    return
                }

                try {
                    http := ComObject("WinHttp.WinHttpRequest.5.1")
                    http.SetTimeouts(1000, 1000, 1000, 3000)
                    http.Open("POST", OCR_SERVER_URL, false)
                    http.SetRequestHeader("Content-Type", "application/json")
                    payload := '{"w": ' imgInfo.w ', "h": ' imgInfo.h '}'
                    http.Send(payload)

                    if !http.WaitForResponse(30) {
                        LogDebug("[Error] OCR Request Timeout")
                        return
                    }

                    LogDebug("[OCR] Request Sent. Target: " . (CAPTURE_TARGET == 0 ? "Screen" : "Process: " . CAPTURE_PROCESS))

                    ; Parse response containing ROI coordinates separated by a pipe (|)
                    rawResponse := Trim(http.ResponseText)
                    if (InStr(rawResponse, "|")) {
                        parts := StrSplit(rawResponse, "|")
                        coords := StrSplit(parts[1], ",")
                        LastTextROI := {x: coords[1], y: coords[2], w: coords[3], h: coords[4]}
                        ocrResult := parts[2]
                        FailCount := 0 ; Reset fail count on success
                    } else {
                        ocrResult := rawResponse
                        ; Automatic ROI Reset: If no text is found 5 times, reset ROI to scan the whole area
                        FailCount++
                        if (FailCount >= 5) {
                            LastTextROI := {x:0, y:0, w:0, h:0}
                            FailCount := 0
                            LogDebug("[ROI] Text lost. Resetting ROI to global scan.")
                        }
                    }

                    ; OCR Test Mode Logic
                    if (OCR_TEST_MODE) {
                        if !ProcessExist("Textractor.exe") {
                            BigToolTip("OCR 테스트 모드이나, 테스트 준비가 완료되지 않았습니다", 3000) ;
                        } else {
                            clipText := Trim(A_Clipboard)
                            if (clipText != "" && ocrResult != "" && RegExMatch(clipText, "[^\s\p{P}\p{S}]")) {
                                sim := GetSimilarity(ocrResult, clipText)
                                if (sim < 0.95) {
                                    if !DirExist(A_ScriptDir "\test")
                                        DirCreate(A_ScriptDir "\test")
                                    ts := FormatTime(, "yyyy-MM-dd HH.mm.ss")
                                    FileAppend(ts " [OCR] " ocrResult "`n" ts " [TEXT] " clipText "`n`n", A_ScriptDir "\test\ocr_fail.txt", "UTF-8")
                                    try FileMove(A_Temp "\image_ko_trans_debug_craft.jpg", A_ScriptDir "\test\image_ko_trans_debug_craft_" ts ".jpg", 1)
                                }
                            }
                        }
                    }

                    if (ocrResult != "" && !InStr(ocrResult, "No text found")) {
                        trans_similarity := GetSimilarity(ocrResult, Overlay.LastOcr)

                        ; If current OCR is too similar to previous, wait for a visual change
                        if (trans_similarity > 0.85) {
                            if (A_Index == 1) {
                                Overlay.LastHash := ""
                                LogDebug("[OCR] Duplicate detected. trans_similarity=" . trans_similarity . " Waiting for real change...")

                                Loop 15 {
                                    Sleep(300)
                                    newHash := GetAreaHash(OCR_X, OCR_Y, OCR_W, OCR_H, hwndTarget)
                                    if (Abs(newHash - currentHash) > 500000) {
                                        LogDebug("[OCR] Visual change detected. Render wait...")
                                        Sleep(1800)
                                        break
                                    }
                                }
                                continue
                            } else {
                                LogDebug("[OCR] Still Duplicate after 2nd attempt. Skipping.")
                                return
                            }
                        }
                        else {
                            break
                        }
                    }
                } catch {
                    if (Overlay.IsActive && Overlay.HasProp("Gui") && WinExist("ahk_id " Overlay.Gui.Hwnd)) {
                        Overlay.Text.Value := "⚠️ OCR 서버가 오프라인 상태입니다!`n서버(Python)가 켜져 있는지 확인해 주세요!"
                        try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
                    }
                    LogDebug("[Error] OCR Server connection failed.")

                    Overlay.IsBusy := false
                    Overlay.PendingRequest := false
                    return
                }
            }

            if (ocrResult == "" || InStr(ocrResult, "No text found")) {
                if (AUTO_DETECT_ENABLED == "0") {
                    if (Overlay.IsActive && Overlay.HasProp("Gui") && WinExist("ahk_id " Overlay.Gui.Hwnd)) {
                        Overlay.Text.Value := '"............"'
                        try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
                    }
                }
            }
            else {
                trans_similarity := GetSimilarity(ocrResult, Overlay.LastOcr)
                if (trans_similarity > 0.85) {
                    break
                } else {
                    Overlay.LastOcr := ocrResult
                    LogDebug("[OCR] New text detected: " . SubStr(ocrResult, 1, 40) . "...")

                    ; Prioritize text cleaning
                    cleanedOriginal := CleanTextForOverlay(ocrResult, READ_MODE)
                    displayOriginal := cleanedOriginal

                    ; Immediately acquire and display Yomigana
                    if (SHOW_OCR == "1" && Overlay.IsActive) {
                        if (JAP_YOMIGANA == "1" && OCR_LANG == "jap") {
                            displayOriginal := GetFurigana(cleanedOriginal)
                        }
                        Overlay.Text.Value := displayOriginal
                        try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
                    }

                    translatedText := Translate(ocrResult, CURRENT_PROFILE)

                    if (Overlay.IsActive && Overlay.HasProp("Gui") && WinExist("ahk_id " Overlay.Gui.Hwnd)) {
                        if (SHOW_OCR == "1") {
                            Overlay.Text.Value := displayOriginal . "`n" . CleanTextForOverlay(translatedText, READ_MODE)
                        } else {
                            Overlay.Text.Value := CleanTextForOverlay(translatedText, READ_MODE)
                        }
                        try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
                    }

                    if Overlay.HasProp("Loading") {
                        Overlay.Loading.Visible := false
                    }
                }
            }

            if (!Overlay.PendingRequest || !Overlay.IsActive) {
                break
            }
            LogDebug("[System] Re-looping due to PendingRequest.")
            Sleep(600)
        }
    } catch Error as e {
        if (e.Message == "Server Offline") {
            if (Overlay.HasProp("Text"))
                Overlay.Text.Value := "⚠️ 서버 연결이 끊겼습니다! 엔진 확인이 필요합니다. 🥊"
        }
    } finally {
        SetLoading(false, "Process Finished")
        Overlay.IsBusy := false
    }
}

SetLoading(status, reason := "") {
    Global Overlay
    if (Overlay.HasProp("Loading") && Overlay.IsActive && Overlay.HasProp("Gui")) {
        try {
            Overlay.Loading.Visible := status
        } catch Error as e {
            LogDebug("[Error] Loading Control Update Error: " . e.Message)
        }
    }
}

; Calculate string similarity using Levenshtein distance algorithm
GetSimilarity(s1, s2) {
    if (s1 == s2) {
        return 1.0
    }
    s1 := RegExReplace(s1, "[\s\t\r\n　]+", ""), s2 := RegExReplace(s2, "[\s\t\r\n　]+", "")
    l1 := StrLen(s1), l2 := StrLen(s2)
    if (l1 == 0 || l2 == 0) {
        return 0.0
    }

    v0 := []
    Loop l2 + 1
        v0.Push(A_Index - 1)
    v1 := []
    Loop l2 + 1
        v1.Push(0)

    Loop l1 {
        i := A_Index
        v1[1] := i
        Loop l2 {
            j := A_Index
            cost := (SubStr(s1, i, 1) == SubStr(s2, j, 1)) ? 0 : 1
            v1[j + 1] := Min(v1[j] + 1, v0[j + 1] + 1, v0[j] + cost)
        }
        Loop l2 + 1
            v0[A_Index] := v1[A_Index]
    }

    dist := v0[l2 + 1]
    maxLen := Max(l1, l2)
    similarity := 1.0 - (dist / maxLen)

    ; Apply length-based penalty using Absolute difference
    ; If the length difference is more than 5 characters, it's likely a new sentence in NVL mode.
    if (Abs(l1 - l2) >= 5) {
        similarity -= 0.2
    }

    return Max(0.0, similarity)
}

; Text preprocessing to improve readability on the overlay
CleanTextForOverlay(txt, readMode := "ADV") {
    if (txt == "")
        return ""

    original := txt
    txt := Trim(txt, "`n`r `t")

    ; Standardize various double quote variants
    txt := RegExReplace(txt, "[“”＂]", '"')
    txt := RegExReplace(txt, "[\r\n\t]+", " ")
    txt := RegExReplace(txt, "\s{2,}", " ")
    txt := RegExReplace(txt, "[▼▽▶▷]", "")

    ; Auto-close/open missing quotes and brackets
    quoteCount := StrSplit(txt, '"').Length - 1
    if (quoteCount > 0 && Mod(quoteCount, 2) != 0) {
        if (RegExMatch(txt, '"$') && !RegExMatch(txt, '^"'))
            txt := '"' . txt
        else if (RegExMatch(txt, '^"') && !RegExMatch(txt, '"$'))
            txt := txt . '"'
    }

    openB := StrSplit(txt, '「').Length - 1
    closeB := StrSplit(txt, '」').Length - 1
    if (openB > closeB)
        txt := txt . "」"
    else if (closeB > openB)
        txt := "「" . txt
    openDB := StrSplit(txt, '『').Length - 1
    closeDB := StrSplit(txt, '』').Length - 1
    if (openDB > closeDB)
        txt := txt . "』"
    else if (closeDB > openDB)
        txt := "『" . txt

    openAB := StrSplit(txt, '«').Length - 1
    closeAB := StrSplit(txt, '»').Length - 1
    if (openAB > closeAB)
        txt := txt . "»"
    else if (closeAB > openAB)
        txt := "«" . txt

    bracketPattern := "(?:\[[^\]]*\]|[\(\（][^\)\）]*[\)\）]|『[^』]*』|「[^」]*」|«[^»]*»|\x22[^\x22]*\x22|\x27[^\x27]*\x27)"

    if (readMode == "NVL") {
        txt := RegExReplace(txt, "(:|：|\]|」|』|»)\s+(?=[\x22『「\[«])", "$1 ")
        txt := RegExReplace(txt, bracketPattern . "(*SKIP)(*F)|(\s+)(?=[^:：\s`n]{1,10}(?:[:：]|\[[^\]]+\]|「[^」]+」|『[^』]+』))", "`n")
        txt := RegExReplace(txt, "(" . bracketPattern . ")\s+(?!`n|$)", "$1`n")
        txt := RegExReplace(txt, bracketPattern . "(*SKIP)(*F)|(?<!^)([?.!？！。])\s+(?!`n|$)", "$1`n")
    } else {
        txt := RegExReplace(txt, "(?<=[^ \x22』」»\.!\?？！])\s+([\x22『「«])", " $1")
        txt := RegExReplace(txt, "^([^:：`n]{20,}(?:[:：]|\[[^\]]+\]))\s+(?!$)", "$1`n")
        txt := RegExReplace(txt, "([^`n]{20,}(?:[』」\]»]|\x22(?=\s)))\s*([\x22『「«])(?!$)", "$1`n$2")
        txt := RegExReplace(txt, "(?m)^([ \x22『「«][^`n]{20,}?[\x22』」»])\s+(?=[^ \x22『「«\.!\?？！])(?!$)", "$1`n")
    }

    markedTxt := RegExReplace(txt, bracketPattern . "(*SKIP)(*F)|([.?!。？！]+)\s+(?!$)|([…]+)\s+(?!$)", "$1$2<BR>")
    markedTxt := RegExReplace(markedTxt, "([』」\x22])\s+(?!$|<BR>|`n)", "$1<BR>")

    finalTxt := ""
    currentLine := ""

    for segment in StrSplit(markedTxt, "<BR>")
    {
        if (segment == "")
            continue

        if (currentLine == "") {
            currentLine := segment
        }
        else if (readMode == "ADV" && StrLen(currentLine) < 20) {
            if RegExMatch(currentLine, "[.?!。？！]$")
                currentLine .= " " segment
            else
                currentLine .= segment
        } else {
            finalTxt .= currentLine . "`n"
            currentLine := segment
        }
    }
    txt := finalTxt . currentLine
    txt := RegExReplace(txt, "`n\s*(\x22)\s*`n", "`n$1")
    txt := RegExReplace(txt, "\n+", "`n")
    txt := RegExReplace(txt, "(?m)^ +", "")
    txt := RegExReplace(txt, " {2,}", " ")
    txt := Trim(txt, "`n`r `t")

    if (original != txt) {
        LogDebug("[CleanText] Final: " . txt)
    }

    return txt
}

; Periodically watch the defined area for visual changes
WatchArea() {
    Global BaselineBitmap, StableChangeCount, Overlay, OCR_X, OCR_Y, OCR_W, OCR_H
    Global CAPTURE_TARGET, CAPTURE_TARGET_CLIPBOARD
    Global CursorExclusionRect

    if (!Overlay.IsActive || Overlay.IsBusy || CAPTURE_TARGET == CAPTURE_TARGET_CLIPBOARD)
        return

    oldContext := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

    hwndTarget := (CAPTURE_TARGET == CAPTURE_TARGET_WINDOW) ? WinExist("ahk_exe " . CAPTURE_PROCESS) : 0
    if (hwndTarget && WinGetMinMax("ahk_id " hwndTarget) == -1)
        return

    currentBitmap := CapturePhysicalScreen(OCR_X, OCR_Y, OCR_W, OCR_H, hwndTarget)
    if (BaselineBitmap == 0) {
        BaselineBitmap := currentBitmap
        DllCall("SetThreadDpiAwarenessContext", "ptr", oldContext, "ptr")
        return
    }

    ; Perform randomized pixel sampling to check for mismatches against baseline
    Gdip_GetImageDimensions(currentBitmap, &width, &height)
    mismatchCount := 0

    if !Gdip_LockBits(currentBitmap, 0, 0, width, height, &Stride1, &Scan0_1, &Bdata1) {
        if !Gdip_LockBits(BaselineBitmap, 0, 0, width, height, &Stride2, &Scan0_2, &Bdata2) {
            Loop 1000 {
                rx := Random(0, width - 1)
                ry := Random(0, height - 1)

                ; Direct memory access for high performance sampling
                pix1 := NumGet(Scan0_1, (ry * Stride1) + (rx * 4), "UInt")
                pix2 := NumGet(Scan0_2, (ry * Stride2) + (rx * 4), "UInt")

                if (pix1 != pix2) {
                    ; Calculate differences for each channel (0-255)
                    r1 := (pix1 >> 16) & 0xFF, g1 := (pix1 >> 8) & 0xFF, b1 := pix1 & 0xFF
                    r2 := (pix2 >> 16) & 0xFF, g2 := (pix2 >> 8) & 0xFF, b2 := pix2 & 0xFF

                    ; Sum of color differences (Color Distance)
                    diff := Abs(r1 - r2) + Abs(g1 - g2) + Abs(b1 - b2)

                    ; Ignore subtle changes (sum less than 30) as noise!
                    if (diff > 30)
                        mismatchCount++
                }
            }
            Gdip_UnlockBits(BaselineBitmap, &Bdata2)
        }
        Gdip_UnlockBits(currentBitmap, &Bdata1)
    }

    ; Confirm change if persistent across 2 polling cycles
    if (mismatchCount > 10) {
        StableChangeCount++

        if (StableChangeCount >= 2) {
            LogDebug("[WatchArea] Screen change confirmed (" . mismatchCount . " points).")

            StableChangeCount := 0
            Gdip_DisposeImage(BaselineBitmap)
            BaselineBitmap := currentBitmap

            SetTimer(TriggerOCRForTranslate, -10)
        } else {
            Gdip_DisposeImage(currentBitmap)
        }
    } else {
        StableChangeCount := 0
        Gdip_DisposeImage(currentBitmap)
    }

    DllCall("SetThreadDpiAwarenessContext", "ptr", oldContext, "ptr")
}

; Fast grid-based hashing of the target screen area
GetAreaHash(x, y, w, h, hwnd := 0) {
    Global LastTextROI, OCR_LANG, JAP_READ_VERTICAL
    oldContext := DllCall("SetThreadDpiAwarenessContext", "ptr", -4, "ptr")

    pBitmap := CapturePhysicalScreen(x, y, w, h, hwnd)
    if (pBitmap <= 0) {
        DllCall("SetThreadDpiAwarenessContext", "ptr", oldContext, "ptr")
        return 0
    }
    Gdip_GetImageDimensions(pBitmap, &width, &height)

    hash := 0
    ; Sample points for visual fingerprinting
    if !Gdip_LockBits(pBitmap, 0, 0, width, height, &Stride, &Scan0, &Bdata) {
        ; ROI-Focused High-Density Hashing
        ; If a text area is already known, perform a dense scan there for thin fonts
        if (LastTextROI.w > 0) {
            isVert := (OCR_LANG == "jap" && JAP_READ_VERTICAL == "1")
            ; [Increased Horizontal Grid Density: 40x20 instead of 30x15 to match global scan precision
            gridX := isVert ? 8 : 20
            gridY := isVert ? 30 : 10

            Loop gridX {
                curX := LastTextROI.x + Integer((LastTextROI.w / (gridX + 1)) * A_Index)
                Loop gridY {
                    curY := LastTextROI.y + Integer((LastTextROI.h / (gridY + 1)) * A_Index)

                    ; Boundary safety check
                    if (curX >= 0 && curX < width && curY >= 0 && curY < height) {
                        pix := NumGet(Scan0, (curY * Stride) + (curX * 4), "UInt")
                        ; Using 0xF0 mask for higher sensitivity to micro-changes in font edges
                        hash += (pix & 0xC0C0C0)
                    }
                }
            }

            ; Sparse 10x10 background scan to detect global UI changes
            Loop 6 {
                gX := Integer((width / 7) * A_Index)
                Loop 6 {
                    gY := Integer((height / 7) * A_Index)
                    pix := NumGet(Scan0, (gY * Stride) + (gX * 4), "UInt")
                    hash += (pix & 0x808080)
                }
            }
        } else {
            ; Sample 800 points (40x20 grid) for visual fingerprinting
            Loop 40 {
                stepX := Integer((width / 41) * A_Index)
                Loop 20 {
                    stepY := Integer((height / 21) * A_Index)
                    pix := NumGet(Scan0, (stepY * Stride) + (stepX * 4), "UInt")

                    ; Apply "Fuzzy Hashing" by masking out lower 5 bits of each RGB channel
                    ; This ignores micro-noise and dithering for a more stable hash value
                    stablePix := pix & 0xE0E0E0
                    hash += stablePix
                }
            }
        }
        Gdip_UnlockBits(pBitmap, &Bdata)
    }

    Gdip_DisposeImage(pBitmap)
    DllCall("SetThreadDpiAwarenessContext", "ptr", oldContext, "ptr")

    return hash
}

; Forward text to the chosen AI translation engine
Translate(inputText, profileName := PROFILE_SETTINGS) {
    currentEngine := IniRead(INI_FILE, profileName, "ENGINE", DEFAULT_ENGINE)
    targetModel := (currentEngine = ENGINE_GEMINI) ? GEMINI_MODEL : (currentEngine = ENGINE_OPENAI) ? GPT_MODEL : LOCAL_MODEL

    LogDebug("[Translate] Engine: " . currentEngine . " | Model: " . targetModel . " | Input: " . SubStr(inputText, 1, 40) . "...")

    safeText := inputText
    safeText := StrReplace(safeText, "\", "\\")
    safeText := StrReplace(safeText, '"', '\"')
    safeText := StrReplace(safeText, "`n", "\n")
    safeText := StrReplace(safeText, "`r", "\r")
    safeText := StrReplace(safeText, "`t", "\t")

    jsonPayload := '{"text": "' . safeText . '", "profile": "' . profileName . '", "model": "' . targetModel . '"}'

    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("POST", CHATGPT_ENDPOINT, false)
        whr.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        whr.Send(jsonPayload)

        if (whr.Status != 200) {
            LogDebug("[Error] Translation failed. Status: " . whr.Status)
            return "서버 오류: " . whr.Status
        }

        response := whr.ResponseText
        whr := ""

        LogDebug("[Translate] Success. Output length: " . StrLen(response))
        return response

    } catch Error as e {
        LogDebug("[Error] Translation Exception: " . e.Message)
        return "오류: " . e.Message
    }
}

; ---------------------------------------------------------
; Dynamic Trigger Hotkey Registration (Keyboard, Mouse, Gamepad)
; ---------------------------------------------------------
UpdateTriggerHotkeys() {
    global ActiveHotkeys, KEY_TRIGGER, MOUSE_TRIGGER, PAD_TRIGGER, Overlay
    global CAPTURE_TARGET, CAPTURE_TARGET_CLIPBOARD
    global AUTO_DETECT_ENABLED := IniRead(INI_FILE, CURRENT_PROFILE, "AUTO_DETECT_ENABLED", IniRead(INI_FILE, PROFILE_SETTINGS, "AUTO_DETECT_ENABLED", "0"))

    for hk in ActiveHotkeys
        try Hotkey(hk, "Off")
    ActiveHotkeys := []

    try SetTimer(WatchPadButton, 0)

    if (!Overlay.IsActive) {
        LogDebug("[System] Overlay inactive. Triggers cleared.")
        OnClipboardChange(OnClipboardChangeHandler, 0)
        return
    }

    if (CAPTURE_TARGET == CAPTURE_TARGET_CLIPBOARD) {
        OnClipboardChange(OnClipboardChangeHandler, 1)
        LogDebug("[Trigger] Clipboard monitoring enabled.")
    } else {
        OnClipboardChange(OnClipboardChangeHandler, 0)
    }

    ; Manual triggers are only active when automatic detection is disabled
    if (AUTO_DETECT_ENABLED == "0") {
        for k in [KEY_TRIGGER, MOUSE_TRIGGER] {
            if (k != "" && k != "NONE" && k != "없음") {
                try {
                    fullHk := "~*" . k
                    Hotkey(fullHk, NextPageTriggerHandler, "On")
                    ActiveHotkeys.Push(fullHk)
                }
            }
        }

        if (PAD_TRIGGER != "" && PAD_TRIGGER != "NONE" && PAD_TRIGGER != "없음") {
            SetTimer(WatchPadButton, 50)
            LogDebug("[Trigger] Pad Monitoring active: " . PAD_TRIGGER)
        }
    } else {
        LogDebug("[System] Auto-Detection active. Manual triggers disabled.")
    }
}

; Poll for gamepad button states using XInput
WatchPadButton() {
    global PAD_TRIGGER, Overlay
    static hasWarnedDirectX := false

    if (!Overlay.IsActive) {
        Overlay.PadLastState := 0
        SetTimer(WatchPadButton, 0)
        return
    }

    xiState := Buffer(16, 0)
    currentState := 0
    foundUserIndex := -1

    Loop 4 {
        uIdx := A_Index - 1
        status := -1
        try {
            status := DllCall("XInput1_4\XInputGetState", "uint", uIdx, "ptr", xiState)
        } catch {
            try {
                status := DllCall("XInput1_3\XInputGetState", "uint", uIdx, "ptr", xiState)
            } catch {
                if (!hasWarnedDirectX) {
                    MsgBox("🎮 게임패드 지원을 위한 DirectX 구성 요소가 없습니다.`n`n"
                         . "패드 트리거를 사용하려면 'DirectX 최종 사용자 런타임' 설치가 필요합니다.`n"
                         . "마이크로소프트 공식 홈페이지에서 다운로드해 주세요.", "DirectX 미설치 안내", 48)
                    hasWarnedDirectX := true
                }
                SetTimer(WatchPadButton, 0)
                return
            }
        }

        buttons := NumGet(xiState, 4, "ushort")
        if (buttons > 0) {
            if (InStr(PAD_TRIGGER, "1") || InStr(PAD_TRIGGER, "A")) {
                if (buttons & 0x1000) { ; XINPUT_GAMEPAD_A
                    currentState := 1
                    foundUserIndex := uIdx
                    break
                }
            } else if (InStr(PAD_TRIGGER, "2") || InStr(PAD_TRIGGER, "B")) {
                if (buttons & 0x2000) { ; XINPUT_GAMEPAD_B
                    currentState := 1
                    foundUserIndex := uIdx
                    break
                }
            }
        }
    }

    if (currentState && !Overlay.PadLastState) {
        LogDebug("[Trigger] XInput Success! User: " . foundUserIndex . ", Button: " . PAD_TRIGGER)
        NextPageTriggerHandler(PAD_TRIGGER)
    }

    Overlay.PadLastState := currentState
}

NextPageTriggerHandler(hk) {
    if (!Overlay.IsActive)
        return

    if (AUTO_DETECT_ENABLED == "0" && Overlay.HasProp("Gui") && WinActive("ahk_id " Overlay.Gui.Hwnd)) {
        Overlay.Text.Value := "⚠️ 오버레이 창이 선택되어 있습니다!`n번역하려는 게임 창을 클릭하여 활성화해주세요! 🥊"
        LogDebug("[Trigger] Manual trigger ignored - Overlay has focus.")
        return
    }

    if (Default_Gui_Exist("OverlayPreview") || Default_Gui_Exist("CaptureArea")
        || Default_Gui_Exist("Gateway") || Default_Gui_Exist("Editor"))
    {
        return
    }

    if InStr(hk, "Button") {
        MouseGetPos(,, &hoverHwnd)
        if (IsSet(Overlay) && Overlay.HasProp("Gui") && hoverHwnd == Overlay.Gui.Hwnd)
            return
    }

    if (Overlay.IsBusy) {
        Overlay.PendingRequest := true
    } else {
        if (CAPTURE_TARGET == CAPTURE_TARGET_CLIPBOARD) {
            OnClipboardChangeHandler(1)
        } else {
            SetTimer(TriggerOCRForTranslate, -10)
        }
    }
}

; Handler for dragging the overlay window
DragTransWindow(wParam, lParam, msg, hwnd) {
    global Overlay
    if (IsSet(Overlay) && Overlay.IsActive && Overlay.HasProp("Gui") && hwnd = Overlay.Gui.Hwnd) {
        PostMessage(0xA1, 2,,, "ahk_id " hwnd)
    }
}

; Launch or update the standalone Python study overlay
SendToAIWordOverlay(text) {
    Global originalWin, CURRENT_PROFILE, INI_FILE, DEFAULT_ENGINE
    Global GEMINI_MODEL, GPT_MODEL, LOCAL_MODEL

    BigToolTip("🔍 AI 단어 분석을 시작합니다...", 2000)

    currentEngine := IniRead(INI_FILE, CURRENT_PROFILE, "ENGINE", IniRead(INI_FILE, PROFILE_SETTINGS, "ENGINE", DEFAULT_ENGINE))
    targetModel := (currentEngine == "Gemini") ? GEMINI_MODEL : (currentEngine == "ChatGPT") ? GPT_MODEL : LOCAL_MODEL

    static targetTitle := "🥊 KO Trans"
    DetectHiddenWindows(true)

    if !WinExist(targetTitle) {
        safeText := StrReplace(text, '"', '\"')
        pythonPath := A_ScriptDir "\engine\venv\Scripts\pythonw.exe"
        clientPath := A_ScriptDir "\engine\overlay_client.py"
        LogDebug("[System] Starting Python client overlay...")
        Run('"' . pythonPath . '" "' . clientPath . '" "' . safeText . '" "' . currentEngine . '" "' . targetModel . '"')

        if !WinWait(targetTitle, , 5) {
            LogDebug("[Error] Failed to start Python Overlay client.")
            return
        }

        WinActivate(targetTitle)
        Sleep(150)
        if (originalWin)
            WinActivate("ahk_id " originalWin)
        return
    }

    combinedData := text . "|" . currentEngine . "|" . targetModel

    ptrText := Buffer(StrLen(combinedData) * 2 + 2)
    StrPut(combinedData, ptrText, "UTF-16")

    cds := Buffer(A_PtrSize * 3)
    NumPut("Ptr", 0, cds, 0)
    NumPut("UInt", ptrText.Size, cds, A_PtrSize)
    NumPut("Ptr", ptrText.Ptr, cds, A_PtrSize * 2)

    try {
        SendMessage(0x004A, A_ScriptHwnd, cds.Ptr, , targetTitle, , , , 500)
        LogDebug("[System] Sent text to existing Python client.")
    } catch {
        LogDebug("[Error] Failed to send WM_COPYDATA.")
        BigToolTip("시스템이 바쁩니다 - 잠시 후 다시 시도해 주세요")
    }
}

; Update the overlay UI and hotkeys when switching profiles
UpdateOverlayToActiveProfile(forceProc := "", doReload := true) {
    global Overlay, OVERLAY_OPACITY, OVERLAY_FONT_SIZE, OVERLAY_FONT_COLOR, CURRENT_PROFILE, OCR_SERVER_URL, ENGINE_DEVICE_MODE

    LoadProfileSettings(forceProc)
    IniWrite(CURRENT_PROFILE, INI_FILE, PROFILE_SETTINGS, "ACTIVE_PROFILE")

    if (doReload) {
        ReloadEngine()
    }

    if (Overlay.IsActive && Overlay.HasProp("Gui") && WinExist("ahk_id " Overlay.Gui.Hwnd)) {
        ; Calculate system border thickness caused by the +Resize option.
        ; This ensures the visible client area stays aligned with the saved coordinates when moving.
        borderX := DllCall("GetSystemMetrics", "Int", 32, "Int") + DllCall("GetSystemMetrics", "Int", 92, "Int")
        borderY := DllCall("GetSystemMetrics", "Int", 33, "Int") + DllCall("GetSystemMetrics", "Int", 92, "Int")

        WinSetTransparent(OVERLAY_OPACITY, Overlay.Gui)
        Overlay.Gui.SetFont("s" OVERLAY_FONT_SIZE " c" OVERLAY_FONT_COLOR, "Segoe UI")
        Overlay.Text.SetFont("s" OVERLAY_FONT_SIZE " c" OVERLAY_FONT_COLOR)

        ; Move the window while subtracting the invisible border offsets.
        Overlay.Gui.Move(Overlay.X - borderX, Overlay.Y - borderY, Overlay.W, Overlay.H)

        WinRedraw("ahk_id " Overlay.Gui.Hwnd)
        UpdateTriggerHotkeys()
        LogDebug("[System] Overlay updated for profile: " CURRENT_PROFILE)
    }
}


; ---------------------------------------------------------
; Remote Scroll Controls for Study Overlay Window
; ---------------------------------------------------------
!F10:: ; Alt + F10 (Scroll Up)
{
    DetectHiddenWindows(true)
    targetTitle := "🥊 KO Trans"
    if WinExist(targetTitle)
    {
        ControlSend("{Up 7}", , targetTitle)
    }
}

!F11:: ; Alt + F11 (Scroll Down)
{
    DetectHiddenWindows(true)
    targetTitle := "🥊 KO Trans"
    if WinExist(targetTitle)
    {
        ControlSend("{Down 7}", , targetTitle)
    }
}

ExitHandler(ExitReason, ExitCode) {
    global pToken
    if (pToken) {
        Gdip_Shutdown(pToken)
        LogDebug("[System] GDI+ Shutdown completed. Reason: " . ExitReason)
    }
}

; Clipboard change handler
OnClipboardChangeHandler(Type) {
    global Overlay, CAPTURE_TARGET, CAPTURE_TARGET_CLIPBOARD, CURRENT_PROFILE, READ_MODE, SHOW_OCR, JAP_YOMIGANA, OCR_LANG

    if (!Overlay.IsActive || CAPTURE_TARGET != CAPTURE_TARGET_CLIPBOARD || Type != 1)
        return

    try {
        clipboardText := Trim(A_Clipboard)
        if (clipboardText == "")
            return

        similarity := GetSimilarity(clipboardText, Overlay.LastOcr)
        if (similarity > 0.85) {
            LogDebug("[Clipboard] Duplicate detected. Skipping.")
            return
        }

        Overlay.LastOcr := clipboardText
        LogDebug("[Clipboard] New text detected: " . SubStr(clipboardText, 1, 40) . "...")

        SetLoading(true, "Clipboard Change")

        cleanedOriginal := CleanTextForOverlay(clipboardText, READ_MODE)
        displayOriginal := cleanedOriginal

        if (SHOW_OCR == "1" && Overlay.IsActive) {
            if (JAP_YOMIGANA == "1" && OCR_LANG == "jap") {
                displayOriginal := GetFurigana(cleanedOriginal)
            }
            Overlay.Text.Value := displayOriginal
            try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
        }

        translatedText := Translate(clipboardText, CURRENT_PROFILE)

        if (Overlay.IsActive && Overlay.HasProp("Gui") && WinExist("ahk_id " Overlay.Gui.Hwnd)) {
            if (SHOW_OCR == "1") {
                Overlay.Text.Value := displayOriginal . "`n" . CleanTextForOverlay(translatedText, READ_MODE)
            } else {
                Overlay.Text.Value := CleanTextForOverlay(translatedText, READ_MODE)
            }
            try WinRedraw("ahk_id " Overlay.Gui.Hwnd)
        }
    } catch Error as e {
        LogDebug("[Error] Clipboard Translation Failed: " . e.Message)
    } finally {
        SetLoading(false, "Clipboard Done")
    }
}
