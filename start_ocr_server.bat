@echo off

rem 1. Check if an existing pythonw.exe process is currently running
tasklist /fi "ImageName eq pythonw.exe" | findstr /i "pythonw.exe" >nul

rem 2. Terminate the process if it is found to prevent port conflicts
if %errorlevel% == 0 (
    echo [Info] Found running server. Terminating process...
    taskkill /f /im pythonw.exe /t
    timeout /t 1 /nobreak >nul
) else (
    echo [Info] Server is not currently running. Skipping kill command.
)

rem 3. Start the OCR server using relative paths for portability
rem Note: %~dp0 refers to the drive and directory path of the current batch file.
start "" "%~dp0engine\venv\Scripts\pythonw.exe" "%~dp0engine\ocr_server_paddle.py"
