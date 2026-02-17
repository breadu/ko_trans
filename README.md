# 🥊 KO Trans v1.0
### 실시간 게임 OCR 번역 및 단어 학습 도우미

**KO Trans**는 고성능 PaddleOCR과 최신 AI(Gemini, ChatGPT, Ollama)를 결합하여 게임 화면을 실시간으로 번역하고, 모르는 단어를 즉시 학습할 수 있도록 돕는 오픈소스 툴입니다.

---

## 🛠️ 설치 방법 (순서대로 따라하기)

가장 안정적인 구동을 위해 아래 안내된 버전을 반드시 지켜주세요.

### 1. CUDA Toolkit 설치 (v12.9 권장)
PaddlePaddle 라이브러리와의 최적의 호환성을 위해 **CUDA 12.9** 버전 설치가 필요합니다.
* **다운로드**: [NVIDIA CUDA 12.9 Archive](https://developer.nvidia.com/cuda-12-9-0-download-archive)
* **설치**: 운영체제(Windows 10/11)에 맞는 프로그램을 실행하고 **'빠른 설치'**를 선택하세요.

### 2. cuDNN 라이브러리 설정 (v9.x)
CUDA 연산을 보조하는 cuDNN 라이브러리를 추가해야 합니다.
* **다운로드**: [cuDNN Downloads](https://developer.nvidia.com/cudnn-downloads) (v9.x for CUDA 12 선택)
* **설정 방법**: 
    1. 설치 후 `C:\Program Files\NVIDIA\CUDNN\v9.19` 경로로 이동합니다.
    2. `bin\12.9\x64`, `include\12.9`, `lib\12.9\x64` 폴더 안의 모든 파일을 복사합니다.
    3. CUDA 설치 경로(보통 `C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9`)의 `bin`, `include`, `lib\x64` 폴더에 각각 **덮어씌우기(붙여넣기)** 합니다.

### 3. Python 설치 (v3.12 필수)
PaddleOCR은 현재 Python 3.14 버전을 지원하지 않으므로, 반드시 **Python 3.12**를 설치해야 합니다.
1. [Python 3.12.x 다운로드](https://www.python.org/downloads/release/python-31210/) 페이지 접속
2. **Windows installer (64-bit)** 클릭 후 실행
3. **[중요]** 설치 첫 화면 하단의 **Add python.exe to PATH**를 반드시 체크하세요!
4. **Install Now**를 눌러 설치 후 PC를 재부팅합니다.

### 4. 필요한 라이브러리 설치
`KO_Trans.exe`와 같은 폴더에 있는 `install_ko_trans.bat` 파일을 실행하세요. 번역 및 OCR 구동에 필요한 모든 환경이 자동으로 구축됩니다.

### 5. Gemini API 키 발급 (Google)
1. [Google AI Studio](https://aistudio.google.com/) 접속 및 로그인
2. 좌측 하단의 **Get API key** 메뉴 클릭 -> 우측 상단의 **API 키 만들기** 클릭 후 복사
3. 프로그램 실행 후 `F12` (메인 메뉴) -> `🌐 기본 설정 수정` -> `Gemini 키` 칸에 붙여넣기 후 `✔ 적용` 클릭
* **Tip**: 기본 모델은 `gemini-2.5-flash-lite`이며, 구글 무료 티어 내에서 비용 없이 사용 가능합니다.

### 6. OpenAI API 키 발급 (ChatGPT)
1. [OpenAI API Dashboard](https://platform.openai.com/) 접속 및 로그인
2. 좌측 메뉴 **API Keys** -> **+ Create new secret key** 클릭 후 복사
3. **결제 설정**: `Settings` > `Billing` 메뉴에서 최소 $5 이상의 크레딧을 충전해야 API가 작동합니다.
4. 프로그램 실행 후 `F12` -> `🌐 기본 설정 수정` -> `OpenAI 키` 칸에 붙여넣기 후 `✔ 적용` 클릭
* **Tip**: 기본 모델은 `gpt-4.1-nano`로 설정되어 비용 효율이 매우 뛰어납니다.

### 7. Ollama 설치 (로컬 AI 사용 시)
인터넷 없이 내 PC 자원을 사용해 번역하려면 Ollama가 필요합니다.
1. [Ollama 공식 홈페이지](https://ollama.com/)에서 설치 파일 다운로드 및 설치
2. 터미널(CMD) 실행 후 `ollama run gemma3:12b` 입력하여 모델 다운로드 (16GB VRAM 이상 권장)
3. 프로그램 설정의 `엔진` 항목에서 **Local**을 선택하고 적용하세요.

---

## 🎮 실행 및 사용 방법

### 1. 프로그램 실행
* `KO_Trans.exe`를 실행하면 OCR 서버가 자동으로 구동됩니다.
* **참고**: 처음 실행 시 엔진 최적화를 위해 **1분 이상** 소요될 수 있으니 잠시 기다려 주세요.

### 2. 메인 메뉴 (F12)
* 실행 중 `F12`를 누르면 **메인 메뉴** 화면이 나타납니다.
* 새로운 프로필 생성, 영역 설정, API 키 관리 등을 할 수 있습니다.

### 3. 번역 시작 및 중지 (Shift + F12)
* 번역을 시작하기 전에 **OCR 영역**과 **번역창 위치**를 먼저 설정해야 합니다.
* `Shift + F12`를 누르면 실시간 번역 오버레이가 활성화/비활성화됩니다.

### 4. 단어장/사전 사용 (Alt + F12)
* 현재 문장의 단어나 숙어 뜻을 자세히 보고 싶다면 `Alt + F12`를 누르세요.
* AI가 문맥에 맞는 단어 해석과 학습 팁을 제공합니다.
* **스크롤 제어**: AI 학습창 활성화 시 `Alt + F10`(위로), `Alt + F11`(아래로) 키로 내용을 넘겨볼 수 있습니다.

---

## 💡 캐릭터 사전 설정 (선택 사항)

번역 시 특정 인물의 이름을 고정하거나 캐릭터의 특징을 AI에게 학습시키고 싶을 때 사용하는 기능입니다. 이 설정은 **필수가 아닌 선택 사항**이며, 적용 시 훨씬 자연스러운 문맥의 번역 결과를 얻을 수 있습니다.

### 1. 사전 파일 준비
1. 프로그램 루트 디렉토리에 `character_dict` 폴더를 생성합니다.
2. 해당 폴더 안에 `.json` 파일을 생성합니다. (예: `sample.json`)
3. 아래의 형식을 참고하여 캐릭터 정보를 입력합니다.

### 2. JSON 포맷 예시
`name`에는 원문의 이름을, `korean_name`에는 출력될 한국어 이름을, `info`에는 캐릭터의 성별이나 성격 등 배경 지식을 입력합니다.

```json
[
  {
    "name": "透（とおる）",
    "korean_name": "토오루",
    "info": "본편의 주인공인 대학생. 172cm, 60kg. 평범한 인물이다."
  },
  {
    "name": "真理（まり）",
    "korean_name": "마리",
    "info": "본편의 히로인. 토오루와 같은 대학에 다니는 긴 검은 머리의 미인이다."
  }
]

---

## 📜 라이선스 및 크레딧
이 프로그램은 **PaddleOCR**, **CRAFT**, **FastAPI**, **AutoHotkey** 등의 오픈소스 프로젝트를 기반으로 제작되었습니다. 상세 내용은 `CREDITS.txt`를 확인해 주세요.

---
**Developed by Breadu Soft**