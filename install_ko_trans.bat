@echo off
setlocal
chcp 65001 >nul
title KO Trans AI 통합 설치 도우미
cd /d "%~dp0"

echo ======================================================
echo KO Trans AI 환경 설정을 시작합니다.
echo ======================================================

rem 1. 파이썬 설치 확인
python --version >nul 2>&1
if %errorlevel% neq 0 (
    echo 파이썬이 설치되어 있지 않습니다.
    echo 윈도우 설치 파일 [exe] 이 제공되는 마지막 안정 버전인
    echo Python 3.12.8 또는 3.12.10 설치를 강력히 권장합니다.
    pause
    exit /b
)

rem 2. engine 디렉토리 생성
if not exist "engine" mkdir "engine"
cd engine

rem 가상환경이 없으면 바로 생성 단계로 이동
if not exist "venv" goto CREATE_VENV

:ASK_REDO
echo.
echo ------------------------------------------------------
echo 이미 가상환경 [venv] 이 존재합니다.
echo 삭제하고 완전히 새로 설치하시겠습니까? [권장: 설치 오류 시 Y]
echo 'N'을 누르면 기존 환경에서 부족한 라이브러리만 추가로 설치합니다.
echo ------------------------------------------------------
set /p redo_choice="선택 [Y/N]: "

if /i "%redo_choice%"=="Y" goto DELETE_VENV
if /i "%redo_choice%"=="N" goto SKIP_DELETE
goto ASK_REDO

:DELETE_VENV
echo.
echo 실행 중인 서버 프로세스를 종료합니다...
rem 실행 중인 서버 프로세스 종료
taskkill /f /im pythonw.exe /t >nul 2>&1
timeout /t 1 /nobreak >nul

echo 기존 가상환경 삭제 중...
rmdir /s /q "venv"

if exist "venv" (
    echo.
    echo 에러: 가상환경 폴더를 삭제할 수 없습니다!
    echo 다른 프로그램에서 사용 중일 수 있으니,
    echo 실행 중인 모든 파이썬 창을 닫고 다시 시도해 주세요.
    pause
    exit /b
)
goto CREATE_VENV

:SKIP_DELETE
echo 기존 가상환경을 유지하며 필요한 라이브러리만 체크합니다.
goto ACTIVATE_VENV

:CREATE_VENV
echo 가상환경 [venv] 생성 중...
python -m venv venv

:ACTIVATE_VENV
set VENV_PYTHON="%~dp0engine\venv\Scripts\python.exe"

echo 가상환경 연결 및 라이브러리 설치 중...
%VENV_PYTHON% -m pip install --upgrade pip
%VENV_PYTHON% -m pip install fastapi uvicorn pydantic google-genai openai PySide6 scikit-learn requests numpy opencv-python Pillow onnxruntime mecab-python3 unidic-lite fugashi

:ASK_GPU
echo.
echo ------------------------------------------------------
echo 그래픽카드 [NVIDIA GPU] 가속을 사용하시겠습니까?
echo [CUDA 12.9 및 cuDNN 설치가 완료된 상태여야 합니다.]
echo 외장 그래픽카드가 있다면 'Y'를, 잘 모르겠다면 'N'을 누르세요.
echo [N을 선택하면 CPU 모드로 설치됩니다.]
echo ------------------------------------------------------
set /p gpu_choice="선택 [Y/N]: "

if /i "%gpu_choice%"=="Y" goto INSTALL_GPU
if /i "%gpu_choice%"=="N" goto INSTALL_CPU
goto ASK_GPU

:INSTALL_GPU
echo GPU 버전 라이브러리 설치를 시작합니다...
%VENV_PYTHON% -m pip uninstall -y paddlepaddle paddlepaddle-gpu onnxruntime onnxruntime-gpu
%VENV_PYTHON% -m pip install paddlepaddle-gpu==3.3.0 -i https://www.paddlepaddle.org.cn/packages/stable/cu129/
%VENV_PYTHON% -m pip install paddleocr
%VENV_PYTHON% -m pip uninstall -y onnxruntime
%VENV_PYTHON% -m pip install onnxruntime-gpu

echo.
echo OCR 모델 파일을 미리 다운로드합니다. [잠시만 기다려 주세요]
%VENV_PYTHON% -c "from paddleocr import PaddleOCR; PaddleOCR(lang='en', device='gpu', use_angle_cls=True, ocr_version='PP-OCRv5'); PaddleOCR(lang='japan', device='gpu', use_angle_cls=True, ocr_version='PP-OCRv5')"
goto FINISH

:INSTALL_CPU
echo CPU 버전 라이브러리 설치를 시작합니다...
%VENV_PYTHON% -m pip uninstall -y paddlepaddle paddlepaddle-gpu
%VENV_PYTHON% -m pip install paddlepaddle paddleocr
echo.
echo OCR 모델 파일을 미리 다운로드합니다. [잠시만 기다려 주세요]
%VENV_PYTHON% -c "from paddleocr import PaddleOCR; PaddleOCR(lang='en', device='cpu', use_angle_cls=True, ocr_version='PP-OCRv5'); PaddleOCR(lang='japan', device='cpu', use_angle_cls=True, ocr_version='PP-OCRv5')"
goto FINISH

:FINISH
echo ======================================================
echo 모든 설치가 완료되었습니다!
echo 이제 창을 닫고 KO_Trans.ahk를 실행해 주세요.
echo ======================================================
pause