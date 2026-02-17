#Requires AutoHotkey v2.0
#SingleInstance Force

; ==============================================================================
; Default Configuration Values
; ==============================================================================
Global ENGINE_GEMINI := "Gemini"
Global ENGINE_OPENAI := "ChatGPT"
Global ENGINE_LOCAL := "Local"

Global CAPTURE_TARGET_SCREEN := "Screen"
Global CAPTURE_TARGET_WINDOW := "Window"
Global CAPTURE_TARGET_CLIPBOARD := "Clipboard"

Global READ_MODE_ADV := "ADV"
Global READ_MODE_NVL := "NVL"

; Input Trigger Constants
Global KEY_NONE := "NONE"
Global KEY_ENTER := "Enter"
Global KEY_SPACE := "Space"
Global MOUSE_NONE := "NONE"
Global MOUSE_LBUTTON := "LButton"
Global MOUSE_RBUTTON := "RButton"
Global PAD_NONE := "NONE"
Global PAD_JOY1 := "Joy1"
Global PAD_JOY2 := "Joy2"

; Initial Coordinates and Styles
Global DEFAULT_OCR_X := 0
Global DEFAULT_OCR_Y := 0
Global DEFAULT_OCR_W := 800
Global DEFAULT_OCR_H := 300
Global DEFAULT_OVERLAY_X := 100
Global DEFAULT_OVERLAY_Y := 50
Global DEFAULT_OVERLAY_W := 1200
Global DEFAULT_OVERLAY_H := 300
Global DEFAULT_LANG := "eng"
Global DEFAULT_ENGINE := ENGINE_GEMINI
Global DEFAULT_OVERLAY_OPACITY := 180
Global DEFAULT_OVERLAY_FONT_SIZE := 20
Global DEFAULT_OVERLAY_FONT_COLOR := "FFFFFF"
Global DEFAULT_CHAR_DICT_ENABLED := "0"
Global DEFAULT_CHAR_DICT_PATH := "NONE"
Global DEFAULT_GEMINI_MODEL := "gemini-2.5-flash-lite"
Global DEFAULT_GPT_MODEL := "gpt-4.1-nano"
Global DEFAULT_LOCAL_MODEL := "gemma3:12b"

Global DEFAULT_KEY_TRIGGER := KEY_ENTER
Global DEFAULT_MOUSE_TRIGGER := MOUSE_LBUTTON
Global DEFAULT_PAD_TRIGGER := PAD_NONE

Global DEFAULT_OCR_START_TIME := 500
Global DEFAULT_AUTO_DETECT_ENABLED := "0"

Global DEFAULT_READ_MODE := READ_MODE_ADV
Global DEFAULT_SHOW_OCR := "1"
Global DEFAULT_CAPTURE_TARGET := CAPTURE_TARGET_SCREEN
Global DEFAULT_CAPTURE_PROCESS := "NONE"
Global DEFAULT_JAP_YOMIGANA := 0

Global CAPTURE_WINDOW_NOT_SELECTED := "윈도우가 선택되지 않았습니다"
Global CHAR_DICT_NOT_SELECTED := "파일이 선택되지 않았습니다"

; ==============================================================================
; INI Key Mapping Constants
; ==============================================================================
Global PROFILE_SETTINGS := "Settings"

Global INI_ACTIVE_PROFILE := "ACTIVE_PROFILE"
Global INI_GEMINI_API_KEY := "GEMINI_API_KEY"
Global INI_OPENAI_API_KEY := "OPENAI_API_KEY"
Global INI_OCR_X := "OCR_X"
Global INI_OCR_Y := "OCR_Y"
Global INI_OCR_W := "OCR_W"
Global INI_OCR_H := "OCR_H"
Global INI_LANG := "LANG"
Global INI_ENGINE := "ENGINE"
Global INI_OVERLAY_X := "OVERLAY_X"
Global INI_OVERLAY_Y := "OVERLAY_Y"
Global INI_OVERLAY_W := "OVERLAY_W"
Global INI_OVERLAY_H := "OVERLAY_H"
Global INI_OVERLAY_OPACITY := "OVERLAY_OPACITY"
Global INI_OVERLAY_FONT_SIZE := "OVERLAY_FONT_SIZE"
Global INI_OVERLAY_FONT_COLOR := "OVERLAY_FONT_COLOR"
Global INI_CHAR_DICT_ENABLED := "CHAR_DICT_ENABLED"
Global INI_CHAR_DICT_PATH := "CHAR_DICT_PATH"
Global INI_GEMINI_MODEL := "GEMINI_MODEL"
Global INI_GPT_MODEL := "GPT_MODEL"
Global INI_LOCAL_MODEL := "LOCAL_MODEL"
Global INI_KEY_TRIGGER := "KEY_TRIGGER"
Global INI_MOUSE_TRIGGER := "MOUSE_TRIGGER"
Global INI_PAD_TRIGGER := "PAD_TRIGGER"
Global INI_OCR_START_TIME := "OCR_START_TIME"
Global INI_AUTO_DETECT_ENABLED := "AUTO_DETECT_ENABLED"
Global INI_READ_MODE := "READ_MODE"
Global INI_SHOW_OCR := "SHOW_OCR"
Global INI_CAPTURE_TARGET := "CAPTURE_TARGET"
Global INI_CAPTURE_PROCESS := "CAPTURE_PROCESS"
Global INI_JAP_YOMIGANA := "JAP_YOMIGANA"

; ---------------------------------------------------------
; Path and State Initialization
; ---------------------------------------------------------
Global DebugLogFile := A_ScriptDir "\ko_trans_debug_log.txt"
Global WasOverlayActiveBeforeGUI := false
Global DEBUG_MODE := false

Global INI_FILE := A_ScriptDir "\settings.ini"

OnMessage(0x0201, DragWindow)

; ---------------------------------------------------------
; Step 1: Gateway UI Entry Point (F12)
; ---------------------------------------------------------
F12:: ShowGateway()

; Manages GUI stack by activating already open windows
ActivateExistingGui() {
    Global Manager_Gateway, Manager_ListGui, Manager_EditGui, Manager_SelectorGui, CaptureAreaGui, OverlayGui

    ; Close selectors if open to return to the main menu
    if IsSet(CaptureAreaGui) && CaptureAreaGui {
        try CaptureAreaGui.Destroy()
        CaptureAreaGui := 0

        try Manager_EditGui.Destroy()
        Manager_EditGui := 0
        LogDebug("[Manager] Destroyed CaptureArea and returned to Menu.")
        return false
    }

    if IsSet(OverlayGui) && OverlayGui {
        try OverlayGui.Destroy()
        OverlayGui := 0

        try Manager_EditGui.Destroy()
        Manager_EditGui := 0
        LogDebug("[Manager] Destroyed OverlayPreview and returned to Menu.")
        return false
    }

    ; Hierarchical check to activate the most relevant open GUI
    for guiVarName in ["OverlayGui", "Manager_EditGui", "Manager_ListGui", "Manager_SelectorGui", "Manager_Gateway"] {
        try {
            if IsSet(%guiVarName%) && %guiVarName% {
                if WinExist(%guiVarName%) {
                    WinActivate(%guiVarName%)
                    return true
                }
            }
        } catch {
            %guiVarName% := 0
        }
    }
    return false
}

ShowGateway() {
    Global WasOverlayActiveBeforeGUI, Manager_Gateway, CURRENT_PROFILE, originalWin

    if (IsBooting()) {
        BigToolTip("⏳ OCR 엔진 준비 중입니다. 잠시만 기다려 주세요...", 1000)
        return
    }

    mascotPath := A_ScriptDir "\mascot_face.png"

    if ActivateExistingGui() {
        return
    }

    originalWin := WinExist("A")
    Manager_CheckOverlay(true)

    deviceStatus := Manager_GetEngineStatus()
    statusColor := (deviceStatus == "GPU") ? "c4CAF50" : (deviceStatus == "CPU") ? "cFFB300" : "cGray"

    Manager_Gateway := Gui("+AlwaysOnTop -Caption +Border", "Gateway")
    Manager_Gateway.BackColor := "0x1A1A1A"

    ; --- Header ---
    Manager_Gateway.SetFont("s16 Bold c1E90FF", "Segoe UI")
    Manager_Gateway.Add("Text", "x20 y15 w500 Center", "🥊 KO Trans - V1.0")

    ; --- Mascot Section ---
    if FileExist(mascotPath) {
        Manager_Gateway.Add("Pic", "x25 y60 w140 h-1 BackgroundTrans", mascotPath)
    }

    ; --- Profile Info ---
    Manager_Gateway.SetFont("s10 Norm cGray")
    Manager_Gateway.Add("Text", "x200 y65 w310", "활성화된 프로필:")

    displayColor := (CURRENT_PROFILE == PROFILE_SETTINGS) ? "c4CAF50" : "cFF5252"
    displayName := (CURRENT_PROFILE == PROFILE_SETTINGS) ? "Global" : CURRENT_PROFILE

    Manager_Gateway.SetFont("s15 Bold " . displayColor)
    Manager_Gateway.Add("Text", "x200 y85 w310", displayName)

    Manager_Gateway.SetFont("s9 Norm cGray")
    Manager_Gateway.Add("Text", "x200 y125 w80", "엔진 상태:")
    Manager_Gateway.SetFont("s9 Bold " . statusColor)
    Manager_Gateway.Add("Text", "x280 y125 w100", deviceStatus)

    ; Start/Stop Toggle Button
    btnText := WasOverlayActiveBeforeGUI ? "⛔ 번역 중지" : "🚀 번역 시작 (Shift+F12)"
    btnColor := WasOverlayActiveBeforeGUI ? "cFF5252" : "cWhite"

    Manager_Gateway.SetFont("s11 Bold " . btnColor)
    BtnStart := Manager_Gateway.Add("Button", "x200 y145 w310 h55", btnText)
    BtnStart.OnEvent("Click", (*) => (
        Manager_Gateway.Destroy(),
        Manager_Gateway := 0,
        WasOverlayActiveBeforeGUI ? (WasOverlayActiveBeforeGUI := false, ShowTransOverlay(false)) : ShowTransOverlay(true)
    ))

    ; --- Management Controls ---
    Manager_Gateway.SetFont("s10 Norm cWhite")

    Manager_Gateway.Add("Button", "x30 y235 w235 h55", "📁 프로필 선택").OnEvent("Click", (*) => HandleChoice("Select"))
    Manager_Gateway.Add("Button", "x275 y235 w235 h55", "➕ 새 프로필").OnEvent("Click", (*) => Manager_CreateProfile())

    Manager_Gateway.Add("Button", "x30 y300 w235 h55", "🎮 현재 프로필 수정").OnEvent("Click", (*) => HandleChoice(CURRENT_PROFILE))
    Manager_Gateway.Add("Button", "x275 y300 w235 h55", "🌐 기본 설정 수정").OnEvent("Click", (*) => HandleChoice(PROFILE_SETTINGS))

    Manager_Gateway.Add("Button", "x30 y365 w480 h45", "📜 프로필 목록 관리").OnEvent("Click", (*) => HandleChoice("List"))

    Manager_Gateway.SetFont("s10 Bold cGray")
    Manager_Gateway.Add("Button", "x510 y5 w25 h25", "X").OnEvent("Click", (*) => (Manager_Cleanup()))

    Manager_Gateway.Show("w540 h425")
    LogDebug("[Manager] Gateway UI opened. Active Profile: " . CURRENT_PROFILE)
}

; Asks Python server for current execution device
Manager_GetEngineStatus() {
    try {
        whr := ComObject("WinHttp.WinHttpRequest.5.1")
        whr.Open("GET", "http://127.0.0.1:5000/health", true)
        whr.Send()

        if (whr.WaitForResponse(1.5)) {
            if RegExMatch(whr.ResponseText, '"device"\s*:\s*"([^"]+)"', &match)
                return match[1]
        }
    }
    LogDebug("[Manager] Engine Status Check Failed - Offline")
    return "오프라인"
}

; Handles automatic deactivation and restoration of the translation overlay
Manager_CheckOverlay(IsStart) {
    Global WasOverlayActiveBeforeGUI, Overlay

    if (IsStart) {
        if (WasOverlayActiveBeforeGUI || !IsOverlayActive())
            return

        WasOverlayActiveBeforeGUI := true
        LogDebug("[Manager] Overlay state saved (Active). Disabling for Manager GUI.")
        ShowTransOverlay(false)
    }
    else {
        if WasOverlayActiveBeforeGUI {
            ; Explicitly turn ON if it was active before
            if (!IsOverlayActive()) {
                LogDebug("[Manager] Restoring Overlay state (Active).")
                ShowTransOverlay(true)
            }
            WasOverlayActiveBeforeGUI := false
        }
    }
}

; Destroys all management GUIs and restores original window focus
Manager_Cleanup() {
    Global Manager_Gateway, Manager_ListGui, Manager_EditGui, Manager_SelectorGui

    for guiVar in ["Manager_Gateway", "Manager_ListGui", "Manager_EditGui", "Manager_SelectorGui"] {
        if IsSet(%guiVar%) && %guiVar% {
            %guiVar%.Destroy()
            %guiVar% := 0
        }
    }

    Manager_CheckOverlay(false)
    if (originalWin && WinExist(originalWin)) {
        WinActivate(originalWin)
    }
}

; ---------------------------------------------------------
; Profile Creation with name validation
; ---------------------------------------------------------
Manager_CreateProfile() {
    Global INI_FILE, Manager_Gateway

    if IsSet(Manager_Gateway) && Manager_Gateway {
        Manager_Gateway.Destroy()
        Manager_Gateway := 0
    }

    newName := ""
    Loop {
        ib := InputBox("새로운 프로필 이름을 입력하세요.`n(예: 무라마사, Ever17)", "새 프로필 생성", "w300 h130")

        if (ib.Result == "Cancel" || ib.Value == "") {
            ShowGateway()
            return
        }

        newName := Trim(ib.Value)

        ; Validate name for forbidden characters
        if RegExMatch(newName, "[\[\]]") {
            MsgBox("프로필 이름에 [ 또는 ] 기호는 사용할 수 없습니다.", "오류", 48)
            continue
        }

        ; Check for duplicates in INI
        existing := IniRead(INI_FILE, newName, INI_OCR_X, "NOT_FOUND")
        if (existing != "NOT_FOUND") {
            MsgBox("이미 존재하는 프로필 이름입니다.", "경고", 4096)
            continue
        }

        break
    }

    LogDebug("[Manager] Creating new profile: " . newName)

    ; Initialize new section with default values
    IniWrite(DEFAULT_OCR_X, INI_FILE, newName, INI_OCR_X)
    IniWrite(DEFAULT_OCR_Y, INI_FILE, newName, INI_OCR_Y)
    IniWrite(DEFAULT_OCR_W, INI_FILE, newName, INI_OCR_W)
    IniWrite(DEFAULT_OCR_H, INI_FILE, newName, INI_OCR_H)
    IniWrite(DEFAULT_OVERLAY_X, INI_FILE, newName, INI_OVERLAY_X)
    IniWrite(DEFAULT_OVERLAY_Y, INI_FILE, newName, INI_OVERLAY_Y)
    IniWrite(DEFAULT_OVERLAY_W, INI_FILE, newName, INI_OVERLAY_W)
    IniWrite(DEFAULT_OVERLAY_H, INI_FILE, newName, INI_OVERLAY_H)

    IniWrite(DEFAULT_LANG, INI_FILE, newName, INI_LANG)
    IniWrite(DEFAULT_ENGINE, INI_FILE, newName, INI_ENGINE)
    IniWrite(DEFAULT_GEMINI_MODEL, INI_FILE, newName, INI_GEMINI_MODEL)
    IniWrite(DEFAULT_GPT_MODEL, INI_FILE, newName, INI_GPT_MODEL)
    IniWrite(DEFAULT_LOCAL_MODEL, INI_FILE, newName, INI_LOCAL_MODEL)

    IniWrite(DEFAULT_OVERLAY_OPACITY, INI_FILE, newName, INI_OVERLAY_OPACITY)
    IniWrite(DEFAULT_OVERLAY_FONT_SIZE, INI_FILE, newName, INI_OVERLAY_FONT_SIZE)
    IniWrite(DEFAULT_OVERLAY_FONT_COLOR, INI_FILE, newName, INI_OVERLAY_FONT_COLOR)
    IniWrite(DEFAULT_READ_MODE, INI_FILE, newName, INI_READ_MODE)
    IniWrite(DEFAULT_SHOW_OCR, INI_FILE, newName, INI_SHOW_OCR)

    IniWrite(DEFAULT_KEY_TRIGGER, INI_FILE, newName, INI_KEY_TRIGGER)
    IniWrite(DEFAULT_MOUSE_TRIGGER, INI_FILE, newName, INI_MOUSE_TRIGGER)
    IniWrite(DEFAULT_PAD_TRIGGER, INI_FILE, newName, INI_PAD_TRIGGER)
    IniWrite(DEFAULT_OCR_START_TIME, INI_FILE, newName, INI_OCR_START_TIME)
    IniWrite(DEFAULT_AUTO_DETECT_ENABLED, INI_FILE, newName, INI_AUTO_DETECT_ENABLED)

    IniWrite(DEFAULT_CAPTURE_TARGET, INI_FILE, newName, INI_CAPTURE_TARGET)
    IniWrite(DEFAULT_CAPTURE_PROCESS, INI_FILE, newName, INI_CAPTURE_PROCESS)
    IniWrite(DEFAULT_CHAR_DICT_ENABLED, INI_FILE, newName, INI_CHAR_DICT_ENABLED)
    IniWrite(DEFAULT_CHAR_DICT_PATH, INI_FILE, newName, INI_CHAR_DICT_PATH)
    IniWrite(DEFAULT_JAP_YOMIGANA, INI_FILE, newName, INI_JAP_YOMIGANA)

    MsgBox("[" newName "] 프로필이 생성되었습니다.`n이제 에디터에서 세부 설정을 조정해주세요!", "성공", 64)

    UpdateOverlayToActiveProfile(newName)
}

HandleChoice(choice) {
    Global Manager_Gateway
    Manager_Gateway.Destroy()
    Manager_Gateway := 0

    if (choice == "List") {
        Manager_ShowList()
    } else if (choice == "Select") {
        ShowProfileSelector()
    } else {
        Manager_ShowEditor(choice)
    }
}

; ---------------------------------------------------------
; Profile List UI using ListView
; ---------------------------------------------------------
Manager_ShowList() {
    Global Manager_ListGui, INI_FILE

    if IsSet(Manager_ListGui) && Manager_ListGui {
        try {
            if WinExist(Manager_ListGui) {
                WinActivate(Manager_ListGui)
                return
            }
        } catch {
            Manager_ListGui := 0
        }
    }

    Manager_ListGui := Gui("+AlwaysOnTop -Caption +Border", "ProfileList")
    Manager_ListGui.BackColor := "0x1A1A1A"

    Manager_ListGui.SetFont("s14 Bold c1E90FF")
    Manager_ListGui.Add("Text", "x20 y15 w460", "🥊 프로필 목록")

    Manager_ListGui.SetFont("s10 Norm cWhite")
    Manager_ListGui.Add("Button", "x465 y10 w25 h25", "X").OnEvent("Click", (*) => (Manager_Cleanup(), ShowGateway()))

    LV := Manager_ListGui.Add("ListView", "x20 y60 w460 h250 Background2D2D2D cWhite +Grid", ["프로필 이름", "언어", "엔진"])

    try {
        sections := IniRead(INI_FILE)
    } catch {
        sections := ""
    }

    Loop Parse, sections, "`n", "`r" {
        if (A_LoopField == "" || A_LoopField == PROFILE_SETTINGS) {
            continue
        }
        lang := IniRead(INI_FILE, A_LoopField, INI_LANG, "-")
        engine := IniRead(INI_FILE, A_LoopField, INI_ENGINE, "-")
        LV.Add("", A_LoopField, lang, engine)
    }

    LV.ModifyCol(1, 230)
    LV.ModifyCol(2, 100)
    LV.ModifyCol(3, 100)

    BtnBack := Manager_ListGui.Add("Button", "x20 y330 w100 h40", "⬅ 뒤로")
    BtnBack.OnEvent("Click", (*) => (Manager_ListGui.Destroy(), Manager_ListGui := 0, ShowGateway()))

    BtnDelete := Manager_ListGui.Add("Button", "x135 y330 w110 h40", "🗑️ 삭제")
    BtnDelete.OnEvent("Click", (*) => (
        row := LV.GetNext(),
        row ? (
            Section := LV.GetText(row),
            (Section == CURRENT_PROFILE) ? MsgBox("현재 활성화된 프로필은 삭제할 수 없습니다.", "경고", 4096) : (
                confirm := MsgBox("[" Section "] 프로필을 완전히 삭제할까요?", "삭제 확인", 4132),
                confirm == "Yes" ? (IniDelete(INI_FILE, Section), LV.Delete(row)) : ""
            )
        ) : MsgBox("삭제할 프로필을 먼저 선택해 주세요!", "경고", 4096)
    ))

    BtnRename := Manager_ListGui.Add("Button", "x255 y330 w110 h40", "✏️ 이름 변경")
    BtnRename.OnEvent("Click", (*) => Manager_RenameProfile(LV))

    BtnEdit := Manager_ListGui.Add("Button", "x375 y330 w105 h40 Default", "✅ 편집")
    BtnEdit.OnEvent("Click", (*) => (
        row := LV.GetNext(),
        row ? (
            Section := LV.GetText(row),
            Manager_ListGui.Destroy(),
            Manager_ListGui := 0,
            Manager_ShowEditor(Section)
        ) : MsgBox("편집할 프로필을 먼저 선택해 주세요!", "경고", 4096)
    ))

    Manager_ListGui.Show("w500 h400")
}


; ---------------------------------------------------------
; Handle profile renaming
; ---------------------------------------------------------
Manager_RenameProfile(LV) {
    Global INI_FILE, CURRENT_PROFILE, Manager_ListGui

    row := LV.GetNext()
    if !row {
        MsgBox("이름을 변경할 프로필을 먼저 선택해 주세요!", "경고", 4096)
        return
    }

    oldName := LV.GetText(row)
    Manager_ListGui.Opt("-AlwaysOnTop")

    ib := InputBox("'" oldName "'의 새로운 이름을 입력해 주세요.`n(한글, 띄어쓰기 가능)", "프로필 이름 변경", "w300 h130", oldName)
    Manager_ListGui.Opt("+AlwaysOnTop")

    if (ib.Result == "Cancel" || ib.Value == "" || ib.Value == oldName)
        return

    newName := Trim(ib.Value)

    if RegExMatch(newName, "[\[\]]") {
        MsgBox("프로필 이름에 [ 또는 ] 기호는 사용할 수 없습니다!", "오류", 48)
        return
    }

    try {
        if (IniRead(INI_FILE, newName, INI_OCR_X, "NOT_FOUND") != "NOT_FOUND") {
            MsgBox("이미 같은 이름의 프로필이 있습니다!", "경고", 4096)
            return
        }

        LogDebug("[Manager] Renaming profile: " . oldName . " -> " . newName)
        sectionData := IniRead(INI_FILE, oldName)

        Loop Parse, sectionData, "`n", "`r" {
            if (A_LoopField == "")
                continue
            pair := StrSplit(A_LoopField, "=", , 2)
            if (pair.Length == 2)
                IniWrite(pair[2], INI_FILE, newName, pair[1])
        }

        IniDelete(INI_FILE, oldName)

        if (CURRENT_PROFILE == oldName) {
            global CURRENT_PROFILE := newName
            IniWrite(newName, INI_FILE, PROFILE_SETTINGS, "ACTIVE_PROFILE")
        }

        LV.Modify(row, , newName)
        MsgBox("프로필 이름이 '" newName "'(으)로 변경되었습니다!", "성공", 4096)

    } catch Error as e {
        LogDebug("[Error] Failed to rename profile: " . e.Message)
        MsgBox("이름 변경 중 에러 발생: " e.Message, "오류", 48)
    }
}

; ---------------------------------------------------------
; Comprehensive Editor GUI with hierarchical value loading
; ---------------------------------------------------------
Manager_ShowEditor(TargetSection) {
    Global Manager_EditGui, INI_FILE

    if IsSet(Manager_EditGui) && Manager_EditGui {
        try {
            if WinExist(Manager_EditGui) {
                WinActivate(Manager_EditGui)
                return
            }
        } catch {
            Manager_EditGui := 0
        }
    }
    LogDebug("[Manager] Editor UI opened for section: " . TargetSection)

    ; Load API keys (Global only)
    currGeminiKey := IniRead(INI_FILE, PROFILE_SETTINGS, INI_GEMINI_API_KEY, "")
    currOpenaiKey := IniRead(INI_FILE, PROFILE_SETTINGS, INI_OPENAI_API_KEY, "")

    ; Load configuration data (inheritance logic applied)
    currX := IniRead(INI_FILE, TargetSection, INI_OCR_X, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_X, DEFAULT_OCR_X))
    currY := IniRead(INI_FILE, TargetSection, INI_OCR_Y, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_Y, DEFAULT_OCR_Y))
    currW := IniRead(INI_FILE, TargetSection, INI_OCR_W, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_W, DEFAULT_OCR_W))
    currH := IniRead(INI_FILE, TargetSection, INI_OCR_H, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_H, DEFAULT_OCR_H))

    currOverlayX := IniRead(INI_FILE, TargetSection, INI_OVERLAY_X, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_X, DEFAULT_OVERLAY_X))
    currOverlayY := IniRead(INI_FILE, TargetSection, INI_OVERLAY_Y, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_Y, DEFAULT_OVERLAY_Y))
    currOverlayW := IniRead(INI_FILE, TargetSection, INI_OVERLAY_W, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_W, DEFAULT_OVERLAY_W))
    currOverlayH := IniRead(INI_FILE, TargetSection, INI_OVERLAY_H, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_H, DEFAULT_OVERLAY_H))

    currLang := IniRead(INI_FILE, TargetSection, INI_LANG, IniRead(INI_FILE, PROFILE_SETTINGS, INI_LANG, DEFAULT_LANG))
    currEngine := IniRead(INI_FILE, TargetSection, INI_ENGINE, IniRead(INI_FILE, PROFILE_SETTINGS, INI_ENGINE, DEFAULT_ENGINE))

    currKey := IniRead(INI_FILE, TargetSection, INI_KEY_TRIGGER, IniRead(INI_FILE, PROFILE_SETTINGS, INI_KEY_TRIGGER, DEFAULT_KEY_TRIGGER))
    currMouse := IniRead(INI_FILE, TargetSection, INI_MOUSE_TRIGGER, IniRead(INI_FILE, PROFILE_SETTINGS, INI_MOUSE_TRIGGER, DEFAULT_MOUSE_TRIGGER))
    currPad := IniRead(INI_FILE, TargetSection, INI_PAD_TRIGGER, IniRead(INI_FILE, PROFILE_SETTINGS, INI_PAD_TRIGGER, DEFAULT_PAD_TRIGGER))

    engineIdx := (currEngine == ENGINE_GEMINI ? 1 : (currEngine == ENGINE_OPENAI ? 2 : 3))

    currOpacity := IniRead(INI_FILE, TargetSection, INI_OVERLAY_OPACITY, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_OPACITY, DEFAULT_OVERLAY_OPACITY))
    currFontSize := IniRead(INI_FILE, TargetSection, INI_OVERLAY_FONT_SIZE, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_FONT_SIZE, DEFAULT_OVERLAY_FONT_SIZE))
    currFontColor := IniRead(INI_FILE, TargetSection, INI_OVERLAY_FONT_COLOR, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OVERLAY_FONT_COLOR, DEFAULT_OVERLAY_FONT_COLOR))

    currDictEnabled := IniRead(INI_FILE, TargetSection, INI_CHAR_DICT_ENABLED, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CHAR_DICT_ENABLED, DEFAULT_CHAR_DICT_ENABLED))
    currDictPath := IniRead(INI_FILE, TargetSection, INI_CHAR_DICT_PATH, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CHAR_DICT_PATH, DEFAULT_CHAR_DICT_PATH))

    currGeminiModel := IniRead(INI_FILE, TargetSection, INI_GEMINI_MODEL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_GEMINI_MODEL, DEFAULT_GEMINI_MODEL))
    currGptModel := IniRead(INI_FILE, TargetSection, INI_GPT_MODEL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_GPT_MODEL, DEFAULT_GPT_MODEL))
    currLocalModel := IniRead(INI_FILE, TargetSection, INI_LOCAL_MODEL, IniRead(INI_FILE, PROFILE_SETTINGS, INI_LOCAL_MODEL, DEFAULT_LOCAL_MODEL))

    currOCRStartTime := IniRead(INI_FILE, TargetSection, INI_OCR_START_TIME, IniRead(INI_FILE, PROFILE_SETTINGS, INI_OCR_START_TIME, DEFAULT_OCR_START_TIME))
    currAutoDetect := IniRead(INI_FILE, TargetSection, INI_AUTO_DETECT_ENABLED, IniRead(INI_FILE, PROFILE_SETTINGS, INI_AUTO_DETECT_ENABLED, DEFAULT_AUTO_DETECT_ENABLED))

    currReadMode := IniRead(INI_FILE, TargetSection, INI_READ_MODE, IniRead(INI_FILE, PROFILE_SETTINGS, INI_READ_MODE, DEFAULT_READ_MODE))
    currShowOcr := IniRead(INI_FILE, TargetSection, INI_SHOW_OCR, IniRead(INI_FILE, PROFILE_SETTINGS, INI_SHOW_OCR, DEFAULT_SHOW_OCR))

    currCaptureTarget := IniRead(INI_FILE, TargetSection, INI_CAPTURE_TARGET, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CAPTURE_TARGET, DEFAULT_CAPTURE_TARGET))
    currCaptureProcess := IniRead(INI_FILE, TargetSection, INI_CAPTURE_PROCESS, IniRead(INI_FILE, PROFILE_SETTINGS, INI_CAPTURE_PROCESS, DEFAULT_CAPTURE_PROCESS))
    currJapYomigana := IniRead(INI_FILE, TargetSection, INI_JAP_YOMIGANA, IniRead(INI_FILE, PROFILE_SETTINGS, INI_JAP_YOMIGANA, DEFAULT_JAP_YOMIGANA))

    Manager_EditGui := Gui("+AlwaysOnTop -Caption +Border", "Editor")
    Manager_EditGui.BackColor := "0x1A1A1A"

    if (TargetSection == PROFILE_SETTINGS) {
        displayTitle := "기본(Global)"
        headerColor := "c4CAF50"
        themeColor := "4CAF50"
    } else {
        displayTitle := TargetSection
        headerColor := "cFF5252"
        themeColor := "FF5252"
    }

    Manager_EditGui.SetFont("s12 Bold " . headerColor)
    Manager_EditGui.Add("Text", "x20 y15 w400", "🥊 설정: [" . displayTitle . "]")

    Manager_EditGui.SetFont("s10 Norm cWhite")
    Manager_EditGui.Add("Button", "x475 y10 w25 h25", "X").OnEvent("Click", (*) => (Manager_Cleanup()))

    C := {}

    Tab := Manager_EditGui.Add("Tab3", "x10 y50 w490 h605 cWhite", ["기본 / 고급 설정", "출력 / 작동 제어"])

    ; =========================================================================
    ; Tab 1: AI and Dictionary
    ; =========================================================================
    Tab.UseTab(1)

    if (TargetSection == PROFILE_SETTINGS) {
        Manager_EditGui.SetFont("s10 Norm cWhite")
        Manager_EditGui.Add("GroupBox", "x20 y90 w470 h105 cGray", "AI API 키 (기본 설정 전용)")

        Manager_EditGui.SetFont("s9 cGray")
        Manager_EditGui.Add("Text", "x35 y118", "Gemini 키:")
        C.EditGemini := Manager_EditGui.Add("Edit", "x115 y115 w355 r1 Background1A1A1A cWhite", currGeminiKey)
        Manager_EditGui.Add("Text", "x35 y153", "OpenAI 키:")
        C.EditOpenAI := Manager_EditGui.Add("Edit", "x115 y150 w355 r1 Background1A1A1A cWhite", currOpenaiKey)
        yStart := 225
    } else {
        yStart := 90
    }

    Manager_EditGui.SetFont("s10 Norm cWhite")

    Manager_EditGui.Add("GroupBox", "x20 y" . yStart . " w470 h65 cGray", "번역 언어")
    Manager_EditGui.Add("Text", "x35 y" . (yStart + 32) . " w40", "언어:")
    C.DDLLang := Manager_EditGui.Add("DropDownList", "x85 y" . (yStart + 29) . " w80 Choose" (currLang == "eng" ? 1 : 2), ["eng", "jap"])
    C.ChkJapYomigana := Manager_EditGui.Add("CheckBox", "x220 y" . (yStart + 32) . " cWhite " (currJapYomigana == "1" ? "Checked" : ""), "일본어에서 한자 요미가나 추가")

    yAI := yStart + 75
    Manager_EditGui.Add("GroupBox", "x20 y" . yAI . " w470 h65 cGray", "번역 AI 엔진")
    Manager_EditGui.Add("Text", "x35 y" . (yAI + 32) . " w40", "엔진:")
    C.DDLEngine := Manager_EditGui.Add("DropDownList", "x85 y" . (yAI + 29) . " w100 Choose" engineIdx, [ENGINE_GEMINI, ENGINE_OPENAI, ENGINE_LOCAL])

    Manager_EditGui.Add("Text", "x210 y" . (yAI + 32) . " w40", "모델:")
    initialModel := (currEngine == ENGINE_GEMINI ? currGeminiModel : (currEngine == ENGINE_OPENAI ? currGptModel : currLocalModel))
    C.EditModel := Manager_EditGui.Add("Edit", "x255 y" . (yAI + 29) . " w210 Background1A1A1A cWhite", initialModel)

    ; Dynamic model name switcher cache
    C.ModelCache := {Gemini: currGeminiModel, ChatGPT: currGptModel, Local: currLocalModel}
    C.DDLEngine.OnEvent("Change", (ctrl, *) => (
        C.EditModel.Value := (ctrl.Text == ENGINE_GEMINI ? C.ModelCache.Gemini : (ctrl.Text == ENGINE_OPENAI ? C.ModelCache.ChatGPT : C.ModelCache.Local))
    ))

    yDict := yAI + 75
    Manager_EditGui.Add("GroupBox", "x20 y" . yDict . " w470 h75 cGray", "캐릭터 사전 (JSON)")
    C.ChkDict := Manager_EditGui.Add("CheckBox", "x35 y" . (yDict + 33) . " cWhite " (currDictEnabled == "1" ? "Checked" : ""), "사용")

    Manager_EditGui.SetFont("s9 cWhite")
    C.TxtDictPath := Manager_EditGui.Add("Text", "x110 y" . (yDict + 35) . " w240 h22 Left +Background1A1A1A", (currDictPath == "" || currDictPath == DEFAULT_CHAR_DICT_PATH ? CHAR_DICT_NOT_SELECTED : currDictPath))
    Manager_EditGui.SetFont("s10 Norm cWhite")
    C.BtnFile := Manager_EditGui.Add("Button", "x365 y" . (yDict + 28) . " w110 h32", "📁 파일 열기")

    C.TxtDictPath.Enabled := (currDictEnabled == "1"), C.BtnFile.Enabled := (currDictEnabled == "1")
    C.ChkDict.OnEvent("Click", (ctrl, *) => (C.TxtDictPath.Enabled := ctrl.Value, C.BtnFile.Enabled := ctrl.Value))
    C.BtnFile.OnEvent("Click", (*) => (
        Manager_EditGui.Opt("-AlwaysOnTop"),
        f := FileSelect(3, , "사전 파일 선택", "JSON Files (*.json)"),
        Manager_EditGui.Opt("+AlwaysOnTop"),
        (f != "") ? (C.TxtDictPath.Value := f) : ""
    ))

    ; =========================================================================
    ; Tab 2: Visual and Trigger Controls
    ; =========================================================================
    Tab.UseTab(2)

    Manager_EditGui.SetFont("s10 Norm cWhite")
    Manager_EditGui.Add("GroupBox", "x30 y95 w450 h110 cGray", "시각적 영역 (캡처 및 오버레이)")
    Manager_EditGui.SetFont("s9 Norm cGray")

    Manager_EditGui.Add("Text", "x45 y125", "OCR 영역:")
    Manager_EditGui.Add("Text", "x130 y125", "X:"), C.TxtOCR_X := Manager_EditGui.Add("Text", "x142 y125 w35 cWhite", currX)
    Manager_EditGui.Add("Text", "x180 y125", "Y:"), C.TxtOCR_Y := Manager_EditGui.Add("Text", "x192 y125 w35 cWhite", currY)
    Manager_EditGui.Add("Text", "x230 y125", "W:"), C.TxtOCR_W := Manager_EditGui.Add("Text", "x245 y125 w40 cWhite", currW)
    Manager_EditGui.Add("Text", "x288 y125", "H:"), C.TxtOCR_H := Manager_EditGui.Add("Text", "x303 y125 w35 cWhite", currH)
    Manager_EditGui.Add("Button", "x345 y115 w120 h32", "🔍 영역 선택").OnEvent("Click", (*) => (
        (C.DDLCaptureTarget.Text == "특정 윈도우" && (C.TxtCaptureProcess.Value == CAPTURE_WINDOW_NOT_SELECTED || !WinExist("ahk_exe " . C.TxtCaptureProcess.Value))) ?
        MsgBox("캡처 대상 윈도우가 실행 중이지 않거나 선택되지 않았습니다.", "오류", 4096) :
        (Manager_EditGui.Hide(), ShowCaptureArea(C.TxtOCR_X, C.TxtOCR_Y, C.TxtOCR_W, C.TxtOCR_H, themeColor, C.DDLCaptureTarget.Text, C.TxtCaptureProcess.Value))
    ))

    Manager_EditGui.Add("Text", "x45 y175", "오버레이 영역:")
    Manager_EditGui.Add("Text", "x130 y175", "X:"), C.TxtOV_X := Manager_EditGui.Add("Text", "x142 y175 w35 cWhite", currOverlayX)
    Manager_EditGui.Add("Text", "x180 y175", "Y:"), C.TxtOV_Y := Manager_EditGui.Add("Text", "x192 y175 w35 cWhite", currOverlayY)
    Manager_EditGui.Add("Text", "x230 y175", "W:"), C.TxtOV_W := Manager_EditGui.Add("Text", "x245 y175 w40 cWhite", currOverlayW)
    Manager_EditGui.Add("Text", "x288 y175", "H:"), C.TxtOV_H := Manager_EditGui.Add("Text", "x303 y175 w35 cWhite", currOverlayH)
    Manager_EditGui.Add("Button", "x345 y165 w120 h32", "🔍 영역 선택").OnEvent("Click", (*) =>
        (Manager_EditGui.Hide(), ShowOverlayPreviewArea(C.TxtOV_X, C.TxtOV_Y, C.TxtOV_W, C.TxtOV_H, C.SliderFont.Value, C.SliderOpacity.Value, C.TxtColorVal.Value)))

    Manager_EditGui.SetFont("s10 Norm cWhite")
    Manager_EditGui.Add("GroupBox", "x30 y215 w450 h65 cGray", "다음 페이지 트리거 키")
    keyOpts := ["없음", KEY_ENTER, KEY_SPACE], mouseOpts := ["없음", "왼쪽 클릭", "오른쪽 클릭"], padOpts := ["없음", "A버튼", "B버튼"]

    GetIdx(arr, val) {
        for i, v in arr {
            if (v == val)
                return i
        }
        return 1
    }

    Manager_EditGui.SetFont("s9 cGray")
    Manager_EditGui.Add("Text", "x45 y245", "키보드:"), C.ComboKey := Manager_EditGui.Add("ComboBox", "x100 yp-3 w75 Choose" GetIdx(keyOpts, currKey), keyOpts)
    Manager_EditGui.Add("Text", "x190 yp+3", "마우스:"), revMouse := (currMouse==MOUSE_LBUTTON?"왼쪽 클릭":currMouse==MOUSE_RBUTTON?"오른쪽 클릭":"없음"), C.ComboMouse := Manager_EditGui.Add("ComboBox", "x235 yp-3 w90 Choose" GetIdx(mouseOpts, revMouse), mouseOpts)
    Manager_EditGui.Add("Text", "x340 yp+3", "패드:"), revPad := (currPad==PAD_JOY1?"A버튼":currPad==PAD_JOY2?"B버튼":"없음"), C.ComboPad := Manager_EditGui.Add("ComboBox", "x380 yp-3 w90 Choose" GetIdx(padOpts, revPad), padOpts)

    C.ComboPad.OnEvent("Change", (ctrl, *) => (
        (ctrl.Text != "없음") ? CheckDirectXForPad() : ""
    ))

    CheckDirectXForPad() {
        if !(FileExist(A_WinDir "\System32\XInput1_4.dll") || FileExist(A_WinDir "\System32\XInput1_3.dll")) {
            MsgBox("⚠️ 시스템에 DirectX 게임패드 라이브러리가 없습니다.`n"
                 . "이대로 설정하면 패드 트리거가 작동하지 않습니다.", "알림", 48)
        }
    }

    Manager_EditGui.SetFont("s10 Norm cWhite")
    Manager_EditGui.Add("GroupBox", "x30 y290 w450 h65 cGray", "OCR 영역 인식 설정")
    Manager_EditGui.SetFont("s9 Norm cWhite")

    Manager_EditGui.Add("Text", "x45 y320", "OCR 시작 지연 시간:")
    C.EditOCRStartTime := Manager_EditGui.Add("Edit", "x165 y317 w50 Number cWhite Background1A1A1A", currOCRStartTime)
    ud := Manager_EditGui.Add("UpDown", "Range200-2000 0x80", currOCRStartTime)
    ud.OnNotify(-722, (ctrl, lParam) => (
        delta := NumGet(lParam, A_PtrSize * 3 + 4, "Int"),
        newVal := ctrl.Value + (delta * 100),
        (newVal >= 200 && newVal <= 2000) ? (ctrl.Value := newVal) : "",
        true
    ))
    Manager_EditGui.Add("Text", "x220 y320", "ms")

    C.ChkAutoDetect := Manager_EditGui.Add("CheckBox", "x270 y320 cWhite " (currAutoDetect == "1" ? "Checked" : ""), "화면 자동 인식 사용")

    Manager_EditGui.SetFont("s10 Norm cWhite")
    Manager_EditGui.Add("GroupBox", "x30 y365 w450 h65 cGray", "읽기 모드 / OCR 표시 설정")
    Manager_EditGui.SetFont("s9 Norm cWhite")
    Manager_EditGui.Add("Text", "x45 y395", "읽기 모드:")
    C.DDLReadMode := Manager_EditGui.Add("DropDownList", "x130 y392 w80 Choose" (currReadMode == "NVL" ? 2 : 1), ["일반", "노벨"])
    C.ChkShowOcr := Manager_EditGui.Add("CheckBox", "x270 y395 cWhite " (currShowOcr == "1" ? "Checked" : ""), "OCR 결과 표시")

    Manager_EditGui.SetFont("s10 Norm cWhite")
    Manager_EditGui.Add("GroupBox", "x30 y440 w450 h65 cGray", "캡처 대상 설정")
    Manager_EditGui.SetFont("s9 Norm cWhite")
    Manager_EditGui.Add("Text", "x45 y470", "캡처 대상:")
    C.DDLCaptureTarget := Manager_EditGui.Add("DropDownList", "x110 y467 w90 Choose" (currCaptureTarget == CAPTURE_TARGET_WINDOW ? 2 : (currCaptureTarget == CAPTURE_TARGET_CLIPBOARD ? 3 : 1)), ["전체 화면", "특정 윈도우", "클립보드"])
    processName := (currCaptureProcess ==  DEFAULT_CAPTURE_PROCESS ? CAPTURE_WINDOW_NOT_SELECTED :  currCaptureProcess)
    C.TxtCaptureProcess := Manager_EditGui.Add("Text", "x210 y470 w120 cWhite", (currCaptureTarget == CAPTURE_TARGET_SCREEN ? "전체 화면" : (currCaptureTarget == CAPTURE_TARGET_CLIPBOARD ? "클립보드" : processName)))
    if (C.TxtCaptureProcess.Value == CAPTURE_WINDOW_NOT_SELECTED) {
        C.TxtCaptureProcess.SetFont("cRed")
    }

    C.BtnSelectWindow := Manager_EditGui.Add("Button", "x340 y462 w120 h32", "윈도우 선택")

    ; Dynamic control of window selection based on capture mode
    C.BtnSelectWindow.Enabled := (currCaptureTarget == CAPTURE_TARGET_WINDOW)
    C.DDLCaptureTarget.OnEvent("Change", (ctrl, *) => (
        (ctrl.Text == "전체 화면") ? (
            C.TxtCaptureProcess.Value := "전체 화면",
            C.TxtCaptureProcess.SetFont("cWhite"),
            C.BtnSelectWindow.Enabled := false,
            captureTarget := CAPTURE_TARGET_SCREEN
        ) : (ctrl.Text == "클립보드") ? (
            C.TxtCaptureProcess.Value := "클립보드",
            C.TxtCaptureProcess.SetFont("cWhite"),
            C.BtnSelectWindow.Enabled := false,
            captureTarget := CAPTURE_TARGET_CLIPBOARD
        ) : (
            C.BtnSelectWindow.Enabled := true,
            (currCaptureProcess == DEFAULT_CAPTURE_PROCESS) ? (
                C.TxtCaptureProcess.Value := CAPTURE_WINDOW_NOT_SELECTED,
                C.TxtCaptureProcess.SetFont("cRed")
            ) : (
                C.TxtCaptureProcess.Value := currCaptureProcess,
                C.TxtCaptureProcess.SetFont("cWhite")
            ),
            captureTarget := CAPTURE_TARGET_WINDOW
        ),

        ; Highlight coordinate reset when switching modes
        (captureTarget != currCaptureTarget) ? (
            C.TxtOCR_X.Value := DEFAULT_OCR_X, C.TxtOCR_Y.Value := DEFAULT_OCR_Y,
            C.TxtOCR_W.Value := DEFAULT_OCR_W, C.TxtOCR_H.Value := DEFAULT_OCR_H,
            C.TxtOCR_X.SetFont("cRed"), C.TxtOCR_Y.SetFont("cRed"), C.TxtOCR_W.SetFont("cRed"), C.TxtOCR_H.SetFont("cRed")
        ) : (
            C.TxtOCR_X.Value := currX, C.TxtOCR_Y.Value := currY,
            C.TxtOCR_W.Value := currW, C.TxtOCR_H.Value := currH,
            C.TxtOCR_X.SetFont("cWhite"), C.TxtOCR_Y.SetFont("cWhite"), C.TxtOCR_W.SetFont("cWhite"), C.TxtOCR_H.SetFont("cWhite")
        )
    ))
    ; Call StartWindowPicker() when Select Window button is clicked
    C.BtnSelectWindow.OnEvent("Click", (*) => (pName := StartWindowPicker(), (pName != "") ? C.TxtCaptureProcess.Value := pName : "", C.TxtCaptureProcess.SetFont("cWhite")))

    Manager_EditGui.SetFont("s10 cWhite")
    Manager_EditGui.Add("Text", "x40 y525", "투명도:")
    C.SliderOpacity := Manager_EditGui.Add("Slider", "x110 y525 w310 Range0-255", currOpacity)
    C.TextOpacityVal := Manager_EditGui.Add("Text", "x430 y530 w50 Right c1E90FF", Round((currOpacity/255)*100) "%")
    C.SliderOpacity.OnEvent("Change", (*) => C.TextOpacityVal.Value := Round((C.SliderOpacity.Value/255)*100) "%")
    Manager_EditGui.Add("Text", "x40 y565", "글꼴 크기:")
    C.SliderFont := Manager_EditGui.Add("Slider", "x110 y565 w310 Range10-50", currFontSize)
    C.TextFontVal := Manager_EditGui.Add("Text", "x430 y570 w50 Right c1E90FF", C.SliderFont.Value "px")
    C.SliderFont.OnEvent("Change", (*) => C.TextFontVal.Value := C.SliderFont.Value "px")
    Manager_EditGui.Add("Text", "x40 y605", "글꼴 색상:")

    C.BtnColor := Manager_EditGui.Add("Button", "x120 y598 w100 h30", "🎨 색상 선택")
    C.TxtColorVal := Manager_EditGui.Add("Text", "x230 y605 w100 c" . currFontColor, currFontColor)
    C.BtnColor.OnEvent("Click", (*) => (
        newColor := Manager_ChooseColor(C.TxtColorVal.Value),
        (newColor != "") ? (C.TxtColorVal.Value := newColor, C.TxtColorVal.SetFont("c" . newColor)) : ""
    ))

    ; =========================================================================
    ; Bottom UI Controls
    ; =========================================================================
    Tab.UseTab()
    BtnBack := Manager_EditGui.Add("Button", "x20 y660 w110 h40", "⬅ 뒤로")
    BtnBack.OnEvent("Click", (*) => (Manager_EditGui.Destroy(), Manager_EditGui := 0, ShowGateway()))

    BtnReset := Manager_EditGui.Add("Button", "x195 y660 w110 h40", "🔄 초기화")
    BtnReset.OnEvent("Click", (*) => Manager_ResetToDefault(TargetSection, C))

    BtnApply := Manager_EditGui.Add("Button", "x370 y660 w110 h40 Default", "✔ 적용")
    BtnApply.OnEvent("Click", (*) => SaveAndApply(TargetSection,
        C.TxtOCR_X.Value, C.TxtOCR_Y.Value, C.TxtOCR_W.Value, C.TxtOCR_H.Value,
        C.TxtOV_X.Value, C.TxtOV_Y.Value, C.TxtOV_W.Value, C.TxtOV_H.Value,
        C.DDLLang.Text, C.DDLEngine.Text, C.EditModel.Value,
        C.SliderOpacity.Value, C.SliderFont.Value, C.TxtColorVal.Value,
        C.ChkDict.Value, C.TxtDictPath.Value,
        C.ChkJapYomigana.Value,
        C.ComboKey.Text, C.ComboMouse.Text, C.ComboPad.Text,
        (TargetSection==PROFILE_SETTINGS?C.EditGemini.Value:""),
        (TargetSection==PROFILE_SETTINGS?C.EditOpenAI.Value:""),
        C.EditOCRStartTime.Value, C.ChkAutoDetect.Value, C.DDLReadMode.Text, C.ChkShowOcr.Value,
        C.DDLCaptureTarget.Text, C.TxtCaptureProcess.Value
    ))

    Manager_EditGui.Show("w510 h725")
    LogDebug("[Manager] Editor UI shown for profile: " . TargetSection)
}

; Replaces cursor with crosshair to select a target process window
StartWindowPicker() {
    Global Manager_EditGui
    Manager_EditGui.Opt("+Disabled")

    ; Change to crosshair cursor (Arrow: 32515)
    hCursor := DllCall("LoadCursor", "Ptr", 0, "Int", 32515, "Ptr")
    DllCall("SetSystemCursor", "Ptr", hCursor, "Int", 32512)

    resultProcess := ""
    Loop {
        ToolTip("번역할 게임 화면을 클릭해 주세요! (ESC: 취소)")

        if GetKeyState("LButton", "P") {
            KeyWait("LButton")
            MouseGetPos(,, &targetHwnd)
            try {
                resultProcess := WinGetProcessName("ahk_id " targetHwnd)
                LogDebug("[Manager] Window picker selected: " . resultProcess . " (HWND: " . targetHwnd . ")")
            }
            break
        }

        if GetKeyState("Escape", "P") {
            KeyWait("Escape")
            LogDebug("[Manager] Window picker cancelled by user.")
            break
        }
        Sleep(10)
    }

    ; Reset system cursor
    DllCall("SystemParametersInfo", "UInt", 0x57, "UInt", 0, "Ptr", 0, "UInt", 0)

    ToolTip()
    Manager_EditGui.Opt("-Disabled")
    Manager_EditGui.Show()

    return resultProcess
}

Manager_ChooseColor(DefaultColor := "FFFFFF") {
    ; Static buffer to store 16 custom colors (preserves user choices during the session)
    static CustomColors := Buffer(64, 0)

    ; 1. Convert RGB hex string to Windows COLORREF (BGR) integer
    ; Takes "FFFFFF", converts to 0xFFFFFF integer, and reorders bytes to BGR
    currRGB := Integer("0x" . DefaultColor)
    currBGR := ((currRGB & 0xFF) << 16) | (currRGB & 0xFF00) | ((currRGB >> 16) & 0xFF)

    ; 2. Initialize the CHOOSECOLOR structure (Required for the API call)
    ; Structure size: A_PtrSize * 9 covers the mandatory fields for AHK v2
    cc := Buffer(A_PtrSize * 9, 0)
    NumPut("UInt", cc.Size, cc, 0)                ; lStructSize: Total size of the structure
    NumPut("Ptr",  WinExist("A"), cc, A_PtrSize)   ; hwndOwner: Active window handle as the parent
    NumPut("UInt", currBGR, cc, A_PtrSize * 3)    ; rgbResult: Initial color to highlight
    NumPut("Ptr",  CustomColors.Ptr, cc, A_PtrSize * 4) ; lpCustColors: Pointer to custom color array

    ; Flags: CC_ANYCOLOR (0x100) | CC_FULLOPEN (0x002) | CC_RGBINIT (0x001)
    ; This ensures the dialog opens fully expanded and initialized with the current color
    NumPut("UInt", 0x103, cc, A_PtrSize * 5)

    ; 3. Call the comdlg32.dll ChooseColor function
    if DllCall("comdlg32\ChooseColor", "Ptr", cc.Ptr) {
        ; Extract the result (Windows returns color in BGR format)
        newBGR := NumGet(cc, A_PtrSize * 3, "UInt")

        ; 4. Convert BGR back to the standard RGB hex string format
        newRGB := ((newBGR & 0xFF) << 16) | (newBGR & 0xFF00) | ((newBGR >> 16) & 0xFF)

        ; Return formatted as a 6-digit hex string (e.g., 00D4FF)
        return Format("{:06X}", newRGB)
    }

    ; Return white color if the user closes or cancels the dialog
    return "FFFFFF"
}

; ---------------------------------------------------------
; Profile Selector UI for manual switching
; ---------------------------------------------------------
ShowProfileSelector() {
    global Manager_SelectorGui, INI_FILE, CURRENT_PROFILE

    try {
        sectionsText := FileRead(INI_FILE)
    } catch {
        MsgBox("저장된 프로필이 없습니다!", "경고", 4096)
        return
    }

    displayList := []
    actualList := []

    Loop Parse, sectionsText, "`n", "`r" {
        if RegExMatch(A_LoopField, "^\[(.+)\]$", &match) {
            sectionName := match[1]
            actualList.Push(sectionName)
            displayList.Push(sectionName == PROFILE_SETTINGS ? "기본(Global)" : sectionName)
        }
    }

    Manager_SelectorGui := Gui("+AlwaysOnTop -Caption +Border +ToolWindow", "Shield Profile Selector")
    Manager_SelectorGui.BackColor := "1A1A1A"

    headerColor := (CURRENT_PROFILE == PROFILE_SETTINGS) ? "c4CAF50" : "cFF5252"

    Manager_SelectorGui.SetFont("s14 Bold " . headerColor, "Segoe UI")
    Manager_SelectorGui.Add("Text", "x15 y15 w240", "프로필 선택 🥊")

    Manager_SelectorGui.SetFont("s10 Norm cWhite")
    Manager_SelectorGui.Add("Button", "x265 y10 w25 h25", "X").OnEvent("Click", (*) => (Manager_Cleanup(), ShowGateWay()))

    currentIdx := 1
    for i, name in actualList {
        if (name == CURRENT_PROFILE) {
            currentIdx := i
            break
        }
    }

    Manager_SelectorGui.SetFont("s11 Norm cWhite")
    lb := Manager_SelectorGui.Add("ListBox", "r8 w280 x10 y50 Choose" currentIdx " Background252525 cWhite", displayList)

    lb.OnEvent("Change", (ctrl, *) => SelectProfile(ctrl.Value))

    Manager_SelectorGui.Add("Button", "x10 y260 w280 h35", "취소").OnEvent("Click", (*) => (Manager_Cleanup(), ShowGateWay()))
    Manager_SelectorGui.Add("Button", "Default w0 h0", "확인").OnEvent("Click", (*) => SelectProfile(lb.Value))

    Manager_SelectorGui.OnEvent("Escape", (*) => Manager_Cleanup())
    Manager_SelectorGui.Show("w300 h310")

    SelectProfile(idx) {
        if (idx > 0) {
            selectedActual := actualList[idx]
            if (selectedActual == CURRENT_PROFILE)
                return

            LogDebug("[Manager] Manual Profile Switch: " . CURRENT_PROFILE . " -> " . selectedActual)
            Manager_Cleanup()

            SetTimer(() => UpdateOverlayToActiveProfile(selectedActual), -10)
        }
    }
}

; ---------------------------------------------------------
; Drag-to-select OCR area with WGC window mapping support
; ---------------------------------------------------------
ShowCaptureArea(Target_X, Target_Y, Target_W, Target_H, SelectorColor, Mode, Process) {
    global CaptureAreaGui, btnClose, Manager_EditGui

    if IsSet(Overlay)
        Overlay.IsBusy := true

    startX := Target_X.Value, startY := Target_Y.Value
    tVisibleX := 0, tVisibleY := 0

    ; Calculate correction values when in specific window capture mode
    if (Mode == "특정 윈도우" && WinExist("ahk_exe " . Process)) {
        hwndTarget := WinExist("ahk_exe " . Process)
        if (WinGetMinMax("ahk_id " hwndTarget) == -1)
            WinRestore("ahk_id " hwndTarget)

        WinActivate("ahk_id " hwndTarget)
        WinWaitActive("ahk_id " hwndTarget,, 0.5)

        rectVisible := Buffer(16, 0)
        DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwndTarget, "uint", 9, "ptr", rectVisible, "uint", 16)

        tVisibleX := NumGet(rectVisible, 0, "int")
        tVisibleY := NumGet(rectVisible, 4, "int")

        startX += tVisibleX, startY += tVisibleY
    }

    ; Get system border thickness (SM_CXSIZEFRAME + SM_CXPADDEDBORDER) caused by the +Resize option.
    borderX := DllCall("GetSystemMetrics", "Int", 32, "Int") + DllCall("GetSystemMetrics", "Int", 92, "Int")
    borderY := DllCall("GetSystemMetrics", "Int", 33, "Int") + DllCall("GetSystemMetrics", "Int", 92, "Int")

    ; Pull the window frame outwards by the border thickness so that the 'visible area' aligns with startX/Y.
    startX -= borderX
    startY -= borderY

    CaptureAreaGui := Gui("+AlwaysOnTop +Resize -Caption +ToolWindow", "CaptureArea")
    CaptureAreaGui.Opt("-DPIScale")

    CaptureAreaGui.BackColor := SelectorColor
    WinSetTransparent(180, CaptureAreaGui)

    btnClose := CaptureAreaGui.Add("Button", "w40 h38", "X")
    btnClose.OnEvent("Click", OnConfirm)

    OnConfirm(*) {
        global CaptureAreaGui

        ; Retrieve accurate client area dimensions
        WinGetClientPos(&cX, &cY, &outW, &outH, CaptureAreaGui.Hwnd)

        ; In specific window mode, subtract the visible starting point and save only 'pure relative coordinates'.
        if (Mode == "특정 윈도우" && tVisibleX != 0) {
            ; Calculating based on cX and cY completely eliminates the 2-3 pixel error.
            outX := cX - tVisibleX
            outY := cY - tVisibleY
        } else {
            outX := cX
            outY := cY
        }

        Target_X.Value := outX, Target_Y.Value := outY, Target_W.Value := outW, Target_H.Value := outH
        CaptureAreaGui.Destroy()
        CaptureAreaGui := 0

        LogDebug("[Manager] Area Confirmed (Client Base): X=" outX " Y=" outY " W=" outW " H=" outH)
        if IsSet(Overlay)
            Overlay.IsBusy := false

        Manager_EditGui.Show()
    }

    CaptureAreaGui.OnEvent("Close", (*) => (Overlay.IsBusy := false))
    CaptureAreaGui.OnEvent("Size", CaptureArea_Size)
    CaptureAreaGui.Show("x" startX " y" startY " w" Target_W.Value " h" Target_H.Value)
}

CaptureArea_Size(thisGui, minMax, width, height) {
    global btnClose
    if IsSet(btnClose) {
        btnClose.Move(width - 40, 0)
    }
}

; ---------------------------------------------------------
; Live preview UI for overlay position and font sizing
; ---------------------------------------------------------
ShowOverlayPreviewArea(Target_X, Target_Y, Target_W, Target_H, FontSize, Opacity, FontColor) {
    global OverlayGui, btnOverlayClose, Manager_EditGui, OverlayText

    if IsSet(Overlay)
        Overlay.IsBusy := true

    sampleStr := "This is a test phrase for configuring the overlay area. "
               . "It helps estimate the position and size where actual game subtitles will appear.`n"
               . "이것은 오버레이 영역을 설정하기 위한 테스트 문구입니다. "
               . "실제 게임 자막이 나타날 위치와 크기를 가늠하는 데 도움이 됩니다.`n"

    OverlayGui := Gui("+AlwaysOnTop +Resize -Caption +ToolWindow", "OverlayPreview")
    OverlayGui.Opt("-DPIScale")
    OverlayGui.BackColor := "000000"

    WinSetTransparent(Opacity, OverlayGui)

    OverlayGui.SetFont("s" FontSize " c" FontColor, "Segoe UI")
    OverlayText := OverlayGui.Add("Text", "x15 y15 w" (Target_W.Value - 50) " h" (Target_H.Value - 20), sampleStr)

    OverlayGui.SetFont("s10 Norm cWhite")
    btnOverlayClose := OverlayGui.Add("Button", "w30 h30", "X")

    btnOverlayClose.OnEvent("Click", OnOverlayConfirm)
    OverlayGui.OnEvent("Size", OverlayPreview_Size)

    OnOverlayConfirm(*) {
        global Overlay, OverlayGui
        WinGetPos(&outX, &outY, &outW, &outH, OverlayGui.Hwnd)
        WinGetClientPos(, , &outW, &outH, OverlayGui.Hwnd)

        Target_X.Value := outX
        Target_Y.Value := outY
        Target_W.Value := outW
        Target_H.Value := outH

        OverlayGui.Destroy()
        global OverlayGui := 0
        LogDebug("[Manager] Overlay Area Confirmed: X=" outX " Y=" outY " W=" outW " H=" outH)

        if IsSet(Overlay)
            Overlay.IsBusy := false

        Manager_EditGui.Show()
    }
    OverlayGui.OnEvent("Close", (*) => (Overlay.IsBusy := false))

    OverlayGui.Show("x" Target_X.Value " y" Target_Y.Value " w" Target_W.Value " h" Target_H.Value)
}

OverlayPreview_Size(thisGui, minMax, width, height) {
    global btnOverlayClose, OverlayText
    try {
        if IsSet(btnOverlayClose) && btnOverlayClose && btnOverlayClose.Hwnd
            btnOverlayClose.Move(width - 35, 5)
    }

    try {
        if IsSet(OverlayText) && OverlayText && OverlayText.Hwnd {
            OverlayText.Move(,, width - 50, height - 20)
        }
    }

    if (IsSet(thisGui) && thisGui.Hwnd) {
        WinRedraw("ahk_id " thisGui.Hwnd)
    }
}

DragWindow(wParam, lParam, msg, hwnd) {
    global CaptureAreaGui, OverlayGui

    try {
        if (IsSet(CaptureAreaGui) && CaptureAreaGui && WinExist(CaptureAreaGui) == hwnd) {
            PostMessage(0xA1, 2, , , "ahk_id " hwnd)
        }
        else if (IsSet(OverlayGui) && OverlayGui && WinExist(OverlayGui) == hwnd) {
            PostMessage(0xA1, 2, , , "ahk_id " hwnd)
        }
    } catch {
    }
}

; Log management with automatic rotation (1MB limit)
LogDebug(message) {
    global DEBUG_MODE, DebugLogFile

    if (!DEBUG_MODE) {
        return
    }

    if FileExist(DebugLogFile) {
        fileSize := FileGetSize(DebugLogFile)
        if (fileSize > 1048576) { ; 1MB Limit
            try {
                FileDelete(DebugLogFile)
                timestamp_sys := FormatTime(, "yyyy-MM-dd HH:mm:ss") . "." . A_MSec
                FileAppend(timestamp_sys . ": [System] Log file exceeded 1MB and was auto-deleted. Starting new log.`n", DebugLogFile, "UTF-8")
            } catch as e {
            }
        }
    }

    timestamp := FormatTime(, "yyyy-MM-dd HH:mm:ss") . "." . A_MSec

    try {
        FileAppend(timestamp . ": " . message . "`n", DebugLogFile, "UTF-8")
    } catch as e {
    }
}

; Factory reset settings for the current profile UI
Manager_ResetToDefault(TargetSection, C) {
    if MsgBox("모든 설정을 공장 초기값으로 되돌릴까요?", "설정 초기화 확인", 4132) == "No"
        return

    LogDebug("[Manager] Resetting settings to default for Profile: " . TargetSection)
    C.TxtOCR_X.Value := DEFAULT_OCR_X, C.TxtOCR_Y.Value := DEFAULT_OCR_Y, C.TxtOCR_W.Value := DEFAULT_OCR_W, C.TxtOCR_H.Value := DEFAULT_OCR_H
    C.TxtOV_X.Value := DEFAULT_OVERLAY_X, C.TxtOV_Y.Value := DEFAULT_OVERLAY_Y, C.TxtOV_W.Value := DEFAULT_OVERLAY_W, C.TxtOV_H.Value := DEFAULT_OVERLAY_H

    C.DDLLang.Choose(1)
    C.DDLEngine.Choose(1)
    C.ChkJapYomigana.Value := DEFAULT_JAP_YOMIGANA

    C.SliderOpacity.Value := DEFAULT_OVERLAY_OPACITY
    C.TextOpacityVal.Value := Round((DEFAULT_OVERLAY_OPACITY / 255) * 100) . "%"

    C.SliderFont.Value := DEFAULT_OVERLAY_FONT_SIZE
    C.TextFontVal.Value := DEFAULT_OVERLAY_FONT_SIZE "px"

    C.TxtColorVal.Value := DEFAULT_OVERLAY_FONT_COLOR
    C.TxtColorVal.SetFont("c" . DEFAULT_OVERLAY_FONT_COLOR)

    C.ChkDict.Value := 0
    C.TxtDictPath.Value := CHAR_DICT_NOT_SELECTED
    C.TxtDictPath.Enabled := false
    C.BtnFile.Enabled := false

    C.ComboKey.Choose(2), C.ComboMouse.Choose(2), C.ComboPad.Choose(1)

    if (TargetSection == PROFILE_SETTINGS) {
        C.EditGemini.Value := "", C.EditOpenAI.Value := ""
    }

    C.EditModel.Value := DEFAULT_GEMINI_MODEL
    C.ModelCache := {Gemini: DEFAULT_GEMINI_MODEL, ChatGPT: DEFAULT_GPT_MODEL, Local: DEFAULT_LOCAL_MODEL}

    C.EditOCRStartTime.Value := DEFAULT_OCR_START_TIME
    C.ChkAutoDetect.Value := DEFAULT_AUTO_DETECT_ENABLED

    C.DDLReadMode.Choose(1)
    C.ChkShowOcr.Value := DEFAULT_SHOW_OCR
    C.DDLCaptureTarget.Choose(1)
    C.TxtCaptureProcess.Value := "전체 화면"
    C.BtnSelectWindow.Enabled := false
}

Manager_IsValidPath(FilePath) {
    if (FilePath == "" || FilePath == CHAR_DICT_NOT_SELECTED) {
        return false
    }
    if RegExMatch(FilePath, '[*?"<>|]') {
        return false
    }
    if !RegExMatch(FilePath, "i)^([a-z]:\\|\\\\)") {
        return false
    }
    attr := FileExist(FilePath)
    if (attr == "" || InStr(attr, "D")) {
        return false
    }
    return true
}

; Saves configuration and notifies Python server if critical settings changed
SaveAndApply(Section, valX, valY, valW, valH, valOverlayX, valOverlayY, valOverlayW, valOverlayH, valLang, valEngine, valModel,
    valOpacity, valFontSize, valFontColor, valDictEnabled, valDictPath, valJapYomigana, valKey, valMouse, valPad, valGemini, valOpenAI, valOCRStartTime, valAutoDetect,
    valReadMode, valShowOcr, valCaptureTarget, valCaptureProcess) {
    Global INI_FILE, Manager_EditGui

    valOCRStartTime := Integer(StrReplace(String(valOCRStartTime), ",", ""))
    if (!IsNumber(valOCRStartTime) || valOCRStartTime < 200 || valOCRStartTime > 2000) {
        MsgBox("OCR 시작 지연 시간은 200에서 2000 사이의 숫자여야 합니다!", "경고", 4096)
        return
    }

    valCaptureTarget := (valCaptureTarget == "전체 화면" ? CAPTURE_TARGET_SCREEN : (valCaptureTarget == "클립보드" ? CAPTURE_TARGET_CLIPBOARD : CAPTURE_TARGET_WINDOW))
    if (valCaptureTarget == CAPTURE_TARGET_WINDOW && (valX < 0 || valY < 0)) {
        MsgBox("인식 대상이 '특정 윈도우'인 경우, OCR 영역의 X와 Y 좌표는 마이너스(-) 값을 가질 수 없습니다!`n`n윈도우 내부 영역만 지정 가능하니 좌표를 확인해주세요.", "경고", 4096)
        return
    }

    if (valCaptureTarget == CAPTURE_TARGET_SCREEN || valCaptureTarget == CAPTURE_TARGET_CLIPBOARD || valCaptureProcess == CAPTURE_WINDOW_NOT_SELECTED) {
        valCaptureProcess := DEFAULT_CAPTURE_PROCESS
    }

    if (valCaptureTarget == CAPTURE_TARGET_WINDOW && valCaptureProcess == DEFAULT_CAPTURE_PROCESS) {
         MsgBox("캡처할 윈도우를 선택해 주세요!", "경고", 4096)
         return
    }

    if (valDictPath == CHAR_DICT_NOT_SELECTED) {
        valDictPath := DEFAULT_CHAR_DICT_PATH
    }
    else if (valDictPath != DEFAULT_CHAR_DICT_PATH && !Manager_IsValidPath(valDictPath)) {
        valDictPath := DEFAULT_CHAR_DICT_PATH
    }

    try {
        oldCaptureTarget := IniRead(INI_FILE, Section, "CAPTURE_TARGET", CAPTURE_TARGET_SCREEN)
        modelKey := (valEngine == ENGINE_GEMINI ? INI_GEMINI_MODEL : (valEngine == ENGINE_OPENAI ? INI_GPT_MODEL : INI_LOCAL_MODEL))
        oldModel := IniRead(INI_FILE, Section, modelKey, "")
        oldLang := IniRead(INI_FILE, Section, INI_LANG, "")
        oldEngine := IniRead(INI_FILE, Section, INI_ENGINE, "")
        oldDictEn := IniRead(INI_FILE, Section, INI_CHAR_DICT_ENABLED, "")
        oldDictPath := IniRead(INI_FILE, Section, INI_CHAR_DICT_PATH, "")
        oldJapYomigana := IniRead(INI_FILE, Section, INI_JAP_YOMIGANA, "")

        oldGemini := (Section == PROFILE_SETTINGS) ? IniRead(INI_FILE, PROFILE_SETTINGS, INI_GEMINI_API_KEY, "") : ""
        oldOpenAI := (Section == PROFILE_SETTINGS) ? IniRead(INI_FILE, PROFILE_SETTINGS, INI_OPENAI_API_KEY, "") : ""

        ; Check if changes require immediate Python engine refresh
        isServerRequired := (valLang != oldLang || valEngine != oldEngine || valModel != oldModel
                            || valDictEnabled != oldDictEn || valDictPath != oldDictPath
                            || (Section == PROFILE_SETTINGS && (valGemini != oldGemini || valOpenAI != oldOpenAI)))
        if (isServerRequired) {
            reloadReason := (valLang != oldLang ? "[Lang] " : "") . (valEngine != oldEngine ? "[Engine] " : "") . (valModel != oldModel ? "[Model] " : "") . (valDictEnabled != oldDictEn ? "[DictToggle] " : "") . (valDictPath != oldDictPath ? "[DictPath] " : "")
            LogDebug("[Manager] SaveAndApply: Server reload required for Profile [" . Section . "]. Reasons: " . reloadReason)
        } else {
            LogDebug("[Manager] SaveAndApply: Settings saved for Profile [" . Section . "]. No server reload needed.")
        }

        valKey := (valKey == "없음" ? KEY_NONE : valKey)
        valMouse := (valMouse == "왼쪽 클릭" ? MOUSE_LBUTTON : valMouse == "오른쪽 클릭" ? MOUSE_RBUTTON : MOUSE_NONE)
        valPad := (valPad == "A버튼" ? PAD_JOY1 : valPad == "B버튼" ? PAD_JOY2 : PAD_NONE)

        valReadMode := (valReadMode == "노벨" ? READ_MODE_NVL : READ_MODE_ADV)

        ; Write settings to INI
        IniWrite(valX, INI_FILE, Section, INI_OCR_X), IniWrite(valY, INI_FILE, Section, INI_OCR_Y)
        IniWrite(valW, INI_FILE, Section, INI_OCR_W), IniWrite(valH, INI_FILE, Section, INI_OCR_H)
        IniWrite(valOverlayX, INI_FILE, Section, INI_OVERLAY_X), IniWrite(valOverlayY, INI_FILE, Section, INI_OVERLAY_Y)
        IniWrite(valOverlayW, INI_FILE, Section, INI_OVERLAY_W), IniWrite(valOverlayH, INI_FILE, Section, INI_OVERLAY_H)
        IniWrite(valLang, INI_FILE, Section, INI_LANG), IniWrite(valEngine, INI_FILE, Section, INI_ENGINE)
        IniWrite(valOpacity, INI_FILE, Section, INI_OVERLAY_OPACITY), IniWrite(valFontSize, INI_FILE, Section, INI_OVERLAY_FONT_SIZE)
        IniWrite(valFontColor, INI_FILE, Section, INI_OVERLAY_FONT_COLOR)
        IniWrite(valDictEnabled, INI_FILE, Section, INI_CHAR_DICT_ENABLED), IniWrite(valDictPath, INI_FILE, Section, INI_CHAR_DICT_PATH)
        IniWrite(valJapYomigana, INI_FILE, Section, INI_JAP_YOMIGANA)
        IniWrite(valModel, INI_FILE, Section, modelKey)
        IniWrite(valKey, INI_FILE, Section, INI_KEY_TRIGGER)
        IniWrite(valMouse, INI_FILE, Section, INI_MOUSE_TRIGGER)
        IniWrite(valPad, INI_FILE, Section, INI_PAD_TRIGGER)
        IniWrite(valOCRStartTime, INI_FILE, Section, INI_OCR_START_TIME)
        IniWrite(valAutoDetect, INI_FILE, Section, INI_AUTO_DETECT_ENABLED)
        IniWrite(valReadMode, INI_FILE, Section, INI_READ_MODE)
        IniWrite(valShowOcr, INI_FILE, Section, INI_SHOW_OCR)
        IniWrite(valCaptureTarget, INI_FILE, Section, INI_CAPTURE_TARGET)
        IniWrite(valCaptureProcess, INI_FILE, Section, INI_CAPTURE_PROCESS)

        if (Section == PROFILE_SETTINGS) {
            IniWrite(valGemini, INI_FILE, PROFILE_SETTINGS, INI_GEMINI_API_KEY)
            IniWrite(valOpenAI, INI_FILE, PROFILE_SETTINGS, INI_OPENAI_API_KEY)
        }

        UpdateOverlayToActiveProfile(Section, isServerRequired)

        if (oldCaptureTarget != valCaptureTarget) {
            MsgBox("[" Section "] 캡처 대상이 변경되었으므로, 캡처 영역을 초기화하였습니다!", "성공", 4096)
        }
        else {
            MsgBox("[" Section "] 설정이 저장 및 적용되었습니다!", "성공", 4096)
        }
        Manager_Cleanup()
    } catch Error as e {
        LogDebug("[Error] Failed to save settings: " . e.Message)
        MsgBox("저장 실패: " e.Message, "오류", 4096)
    }
}
