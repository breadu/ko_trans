import os
import json
import configparser
from google import genai
from google.genai import types
from openai import OpenAI
import path_util

# Logging toggle for debugging console output
DEBUG = False

def log(msg):
    if DEBUG:
        print(msg)

INI_PATH = path_util.INI_PATH
PROMPT_PATH = path_util.PROMPT_PATH

class BaseEngine:
    def __init__(self):
        # Stores conversation context (user and assistant turns)
        self.history = []
        # In-memory caches for frequently accessed data
        self.char_dict_cache = {}
        self.explanation_prompt_cache = None

    def _clear_caches(self):
        """Resets all memory caches when profile or settings change"""
        self.char_dict_cache = {}
        self.explanation_prompt_cache = None

    def _get_explanation_prompt(self):
        """Loads system instruction for word analysis from the prompt file"""
        if self.explanation_prompt_cache:
            return self.explanation_prompt_cache

        if os.path.exists(PROMPT_PATH):
            try:
                with open(PROMPT_PATH, 'r', encoding='utf-8') as f:
                    self.explanation_prompt_cache = f.read()
                    log(f"[System] Prompt cached. Size: {len(self.explanation_prompt_cache)} chars")
                    return self.explanation_prompt_cache
            except Exception as e:
                log(f"[Error] Failed to read prompt file ({PROMPT_PATH}): {e}")
        return "You are a professional English-Korean dictionary. Explain the word clearly."

    def _get_character_dict_str(self, profile_name):
        """Loads and formats character mapping dictionary for translation context"""
        if profile_name in self.char_dict_cache:
            return self.char_dict_cache[profile_name]

        config = configparser.ConfigParser()
        config.optionxform = str
        dict_path, enabled = "NONE", "0"

        # Sequential retry with different encodings to handle various INI file formats
        success_enc = None
        for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
            try:
                with open(INI_PATH, 'r', encoding=enc) as f:
                    config.read_file(f)
                enabled = config.get(profile_name, 'CHAR_DICT_ENABLED', fallback=config.get('Settings', 'CHAR_DICT_ENABLED', fallback='0'))
                dict_path = config.get(profile_name, 'CHAR_DICT_PATH', fallback=config.get('Settings', 'CHAR_DICT_PATH', fallback='NONE'))
                success_enc = enc
                break
            except: continue

        res_str = ""
        if enabled == "1" and os.path.exists(dict_path):
            try:
                with open(dict_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                # Formats JSON data into a Markdown table for better LLM comprehension
                rows = ["| Original Name (Source) | Korean Name (Output) | Character Context |", "|---|---|---|"]
                for char in data:
                    rows.append(f"| {char.get('name','')} | {char.get('korean_name','')} | {char.get('description','')} |")
                res_str = "\n".join(rows)
                log(f"[Dict] Profile '{profile_name}': {len(data)} characters loaded using {success_enc}")
            except Exception as e:
                log(f"[Error] Dictionary JSON load failed ({dict_path}): {e}")

        self.char_dict_cache[profile_name] = res_str
        return res_str

class GeminiEngine(BaseEngine):
    def __init__(self):
        super().__init__()
        self.client = self._setup_client()

    def reload_settings(self):
        """Triggered by profile changes to refresh API client and history"""
        log("[Gemini] Settings reloaded. History and caches cleared.")
        self._clear_caches()
        self.client = self._setup_client()
        self.history = []

    def _setup_client(self):
        config = configparser.ConfigParser()
        api_key = ""
        for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
            try:
                with open(INI_PATH, 'r', encoding=enc) as f:
                    config.read_file(f)
                api_key = config.get('Settings', 'GEMINI_API_KEY', fallback="")
                break
            except: continue

        if api_key:
            return genai.Client(api_key=api_key)
        else:
            log("[Warning] Gemini Client failed: API Key missing in Settings.")
            return None

    def get_explanation(self, text, model_name="gemini-2.5-flash-lite"):
        """Requests structured word analysis in JSON format"""
        if not self.client: return "⚠️ GEMINI_API_KEY missing."

        log(f"[Gemini] Word Explanation request: '{text[:30]}...' (Model: {model_name})")
        response = self.client.models.generate_content(
            model=model_name,
            contents=text,
            config=types.GenerateContentConfig(
                system_instruction=self._get_explanation_prompt(),
                response_mime_type="application/json",
                #thinking_config=types.ThinkingConfig(
                #    thinking_level="low"
                #)
            )
        )

        return json.loads(response.text)

    def get_translation(self, text, profile="Settings", model_name="gemini-2.5-flash-lite"):
        """Story-optimized translation using character context and dialogue history"""
        if not self.client: return "⚠️ GEMINI_API_KEY가 설정되지 않았습니다! Gateway의 Global Settings에서 키를 먼저 입력해 주세요!"
        current_dict_str = self._get_character_dict_str(profile)

        # Dynamic system prompt selection based on dictionary availability
        if current_dict_str:
            story_prompt = (
                "You are a professional story translator. Translate the text into natural Korean.\n\n"
                "### RULES:\n"
                "1. **TRANSLATE EVERYTHING**: Do not skip, summarize, or omit any part. Translate narrative and dialogue fully.\n"
                "2. Output ONLY the Korean translation. NO introduction, NO explanation, NO conversational filler.\n"
                "3. **NAME TAG FORMAT (STRICT)**: Apply the 'Name:' format ONLY when a character name is explicitly written in brackets (e.g., [Name], 『Name』, or 「Name」) at the very start of the source line. \n"
                "4. **NO INFERRED NAMES**: If a line of dialogue does not have a name explicitly attached to it in the source text, DO NOT add, guess, or infer a name tag. Translate it as a simple quote.\n\n"
                "### RULES for NAMES:\n"
                "1. **STRICT VERBATIM NAMES**: Use the name exactly as it is used in the source text. If only a given name is used, use only the given name. If only a surname is used, use only the surname. **NEVER expand to a full name unless it is written as a full name in the source.**\n"
                "2. **DICTIONARY AS SPELLING REFERENCE ONLY**: Use the provided character dictionary only to find the correct Korean spelling for the specific name mentioned. Do not use other parts of the dictionary entry that are not in the source.\n"
                "3. **PRESERVE HONORIFICS**: If the source includes honorifics (like -san, -kun, -sama), translate them naturally into Korean (씨, 군, 님 등).\n"
                "4. **NEVER ADD NAMES**: It is a critical failure to add a character name (e.g., '하루코:') if it is not present in the original text. Keep the original structure perfectly.\n\n"
                "5. Do not infer or add any information about the characters that is not explicitly present in the current input text.\n\n"
                "### CHARACTER REFERENCE TABLE:\n"
                f"{current_dict_str}"
            )
        else:
            story_prompt = (
                "You are a professional story translator specializing in creative media.\n"
                "Translate the provided text into natural, immersive Korean.\n\n"
                "### RULES:\n"
                "1. **TRANSLATE ALL TEXT**: Do not skip or omit any part of the input. Every sentence, including descriptions and narrative, must be fully translated.\n"
                "2. Output ONLY the Korean translation. NO intro/outro.\n"
                "3. **NAME TAG FORMAT**: If the source text starts with a name in brackets, format it as 'Name:' followed by the dialogue.\n"
                "4. Maintain the original tone and emotional nuance of the story."
            )

        try:
            # Limits context window to the last 10 turns to balance performance and relevancy
            history_len = len(self.history[-10:])
            log(f"[Gemini] Requesting: {model_name} | Profile: {profile} | History context: {history_len} turns")

            contents = [types.Content(role="model" if e['role']=="assistant" else e['role'], parts=[types.Part(text=e['content'])]) for e in self.history[-10:]]
            contents.append(types.Content(role="user", parts=[types.Part(text=text)]))
            response = self.client.models.generate_content(
                model=model_name or "gemini-2.5-flash-lite",
                contents=contents,
                config=types.GenerateContentConfig(
                    system_instruction=story_prompt,
                    # Disable all safety settings to prevent blocking of adult game dialogue.
                    safety_settings=[
                        types.SafetySetting(category="HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold="BLOCK_NONE"),
                        types.SafetySetting(category="HARM_CATEGORY_HATE_SPEECH", threshold="BLOCK_NONE"),
                        types.SafetySetting(category="HARM_CATEGORY_HARASSMENT", threshold="BLOCK_NONE"),
                        types.SafetySetting(category="HARM_CATEGORY_DANGEROUS_CONTENT", threshold="BLOCK_NONE"),
                    ]
                )
            )

            # Prevents cases where the response is blocked and text returns as None.
            if response.text:
                res = response.text.strip()
                self.history.extend([{"role":"user","content":text}, {"role":"assistant","content":res}])
                return res
            else:
                log("[Warning] Gemini response blocked despite BLOCK_NONE setting.")
                return "⚠️ 번역 실패: 제미나이 정책에 의해 응답이 차단되었습니다."

        except Exception as e:
            log(f"[Error] Gemini Translation Exception: {e}")
            return f"⚠️ Gemini Error: {str(e)}"

class ChatGPTEngine(BaseEngine):
    def __init__(self):
        super().__init__()
        self.client = self._setup_client()

    def reload_settings(self):
        log("[ChatGPT] Settings reloaded. History and caches cleared.")
        self._clear_caches()
        self.client = self._setup_client()
        self.history = []

    def _setup_client(self):
        config = configparser.ConfigParser()
        api_key = ""
        for enc in ['utf-16', 'utf-8-sig', 'utf-8']:
            try:
                with open(INI_PATH, 'r', encoding=enc) as f:
                    config.read_file(f)
                api_key = config.get('Settings', 'OPENAI_API_KEY', fallback="")
                break
            except: continue

        if api_key:
            return OpenAI(api_key=api_key)
        else:
            log("[Warning] ChatGPT Client failed: API Key missing in Settings.")
            return None

    def get_explanation(self, text, model_name="gpt-4.1-nano"):
        if not self.client: return "⚠️ OPENAI_API_KEY가 설정되지 않았습니다! Gateway의 Global Settings에서 키를 먼저 입력해 주세요!"

        log(f"[ChatGPT] Word Explanation request: '{text[:30]}...' (Model: {model_name})")
        response = self.client.chat.completions.create(
            model=model_name,
            messages=[
                {"role": "system", "content": self._get_explanation_prompt()},
                {"role": "user", "content": text}
            ],
            response_format={"type": "json_object"}
        )

        return json.loads(response.choices[0].message.content)

    def get_translation(self, text, profile="Settings", model_name="gpt-4.1-nano"):
        if not self.client:
            return "⚠️ OPENAI_API_KEY가 설정되지 않았습니다! Global Settings에서 키를 입력해 주세요."

        dict_str = self._get_character_dict_str(profile)
        if dict_str:
            system_content = (
                "You are a professional story translator. Translate the text into natural Korean.\n\n"
                "### RULES:\n"
                "1. **TRANSLATE EVERYTHING**: Do not skip, summarize, or omit any part. Translate narrative and dialogue fully.\n"
                "2. Output ONLY the Korean translation. NO introduction, NO explanation, NO conversational filler.\n"
                "3. **NAME TAG FORMAT (STRICT)**: Apply the 'Name:' format ONLY when a character name is explicitly written in brackets (e.g., [Name], 『Name』, or 「Name」) at the very start of the source line. \n"
                "4. **NO INFERRED NAMES**: If a line of dialogue does not have a name explicitly attached to it in the source text, DO NOT add, guess, or infer a name tag. Translate it as a simple quote.\n\n"
                "### RULES for NAMES:\n"
                "1. **STRICT VERBATIM NAMES**: Use the name exactly as it is used in the source text. If only a given name is used, use only the given name. If only a surname is used, use only the surname. **NEVER expand to a full name unless it is written as a full name in the source.**\n"
                "2. **DICTIONARY AS SPELLING REFERENCE ONLY**: Use the provided character dictionary only to find the correct Korean spelling for the specific name mentioned. Do not use other parts of the dictionary entry that are not in the source.\n"
                "3. **PRESERVE HONORIFICS**: If the source includes honorifics (like -san, -kun, -sama), translate them naturally into Korean (씨, 군, 님 등).\n"
                "4. **NEVER ADD NAMES**: It is a critical failure to add a character name (e.g., '하루코:') if it is not present in the original text. Keep the original structure perfectly.\n\n"
                "5. Do not infer or add any information about the characters that is not explicitly present in the current input text.\n\n"
                "### CHARACTER REFERENCE TABLE:\n"
                f"{dict_str}"
            )
        else:
            system_content = (
                "You are a professional story translator specializing in creative media.\n"
                "Translate the provided text into natural, immersive Korean.\n\n"
                "### RULES:\n"
                "1. **TRANSLATE ALL TEXT**: Do not skip or omit any part of the input. Every sentence, including descriptions and narrative, must be fully translated.\n"
                "2. Output ONLY the Korean translation. NO intro/outro.\n"
                "3. **NAME TAG FORMAT**: If the source text starts with a name in brackets, format it as 'Name:' followed by the dialogue.\n"
                "4. Maintain the original tone and emotional nuance of the story."
            )

        try:
            history_len = len(self.history[-10:])
            log(f"[ChatGPT] Requesting: {model_name} | Profile: {profile} | History turns: {history_len}")

            messages = [{"role": "system", "content": system_content}]
            messages.extend(self.history[-10:])
            messages.append({"role": "user", "content": text})
            response = self.client.chat.completions.create(model=model_name or "gpt-4.1-nano", messages=messages)
            res = response.choices[0].message.content.strip()
            self.history.extend([{"role":"user","content":text}, {"role":"assistant","content":res}])
            return res
        except Exception as e:
            log(f"[Error] ChatGPT Translation Exception: {e}")
            return f"⚠️ OpenAI Error: {str(e)}"

class LocalEngine(BaseEngine):
    def __init__(self):
        super().__init__()
        # Defaults to local Ollama API endpoint
        self.client = OpenAI(base_url="http://localhost:11434/v1", api_key="ollama")

    def reload_settings(self):
        log("[Local] Local history and caches cleared.")
        self._clear_caches()
        self.history = []

    def get_explanation(self, text, model_name="gemma3:12b"):
        log(f"[Local] Ollama Explanation: '{text[:30]}...' (Model: {model_name})")
        response = self.client.chat.completions.create(
            model=model_name,
            messages=[
                {"role": "system", "content":  self._get_explanation_prompt()},
                {"role": "user", "content": text}
            ],
            response_format={"type": "json_object"}
        )
        return json.loads(response.choices[0].message.content)

    def get_translation(self, text, profile="Settings", model_name="gemma3:12b"):
        current_dict_str = self._get_character_dict_str(profile)
        if current_dict_str:
            story_prompt = (
                "You are a professional story translator. Translate the text into natural Korean.\n\n"
                "### RULES:\n"
                "1. **TRANSLATE EVERYTHING**: Do not skip, summarize, or omit any part. Translate narrative and dialogue fully.\n"
                "2. Output ONLY the Korean translation. NO introduction, NO explanation, NO conversational filler.\n"
                "3. **NAME TAG FORMAT (STRICT)**: Apply the 'Name:' format ONLY when a character name is explicitly written in brackets (e.g., [Name], 『Name』, or 「Name」) at the very start of the source line. \n"
                "4. **NO INFERRED NAMES**: If a line of dialogue does not have a name explicitly attached to it in the source text, DO NOT add, guess, or infer a name tag. Translate it as a simple quote.\n\n"
                "### RULES for NAMES:\n"
                "1. **STRICT VERBATIM NAMES**: Use the name exactly as it is used in the source text. If only a given name is used, use only the given name. If only a surname is used, use only the surname. **NEVER expand to a full name unless it is written as a full name in the source.**\n"
                "2. **DICTIONARY AS SPELLING REFERENCE ONLY**: Use the provided character dictionary only to find the correct Korean spelling for the specific name mentioned. Do not use other parts of the dictionary entry that are not in the source.\n"
                "3. **PRESERVE HONORIFICS**: If the source includes honorifics (like -san, -kun, -sama), translate them naturally into Korean (씨, 군, 님 등).\n"
                "4. **NEVER ADD NAMES**: It is a critical failure to add a character name (e.g., '하루코:') if it is not present in the original text. Keep the original structure perfectly.\n\n"
                "5. Do not infer or add any information about the characters that is not explicitly present in the current input text.\n\n"
                "### CHARACTER REFERENCE TABLE:\n"
                f"{current_dict_str}"
            )
        else:
            story_prompt = (
                "You are a professional story translator specializing in creative media.\n"
                "Translate the provided text into natural, immersive Korean.\n\n"
                "### RULES:\n"
                "1. **TRANSLATE ALL TEXT**: Do not skip or omit any part of the input. Every sentence, including descriptions and narrative, must be fully translated.\n"
                "2. Output ONLY the Korean translation. NO intro/outro.\n"
                "3. DO NOT explain the grammar or context.\n"
                "4. **NAME TAG FORMAT**: If the source text starts with a name in brackets, format it as 'Name:' followed by the dialogue.\n"
                "4. Maintain the original tone and emotional nuance of the story."
            )

        try:
            log(f"[Local] Ollama Request: {model_name} | Profile: {profile} | History turns: {len(self.history[-10:])}")
            messages = [{"role": "system", "content": story_prompt}]
            messages.extend(self.history[-10:])
            messages.append({"role": "user", "content": text})
            response = self.client.chat.completions.create(model=model_name or "gemma3:12b", messages=messages)
            raw = response.choices[0].message.content.strip()

            # Filters out typical conversational artifacts often generated by local LLMs
            cleaned_text = raw
            stop_phrases = ["번역은 다음과 같습니다", "번역 결과:", "The translation is", "natural Korean translation"]
            for phrase in stop_phrases:
                if phrase in cleaned_text:
                    cleaned_text = cleaned_text.split(phrase)[-1].strip(": ").strip()

            self.history.extend([{"role":"user","content":text}, {"role":"assistant","content":cleaned_text}])
            if len(self.history) > 20: self.history = self.history[-20:]
            return cleaned_text
        except Exception as e:
            error_msg = str(e).lower()
            log(f"[Error] Local Engine Exception: {error_msg}")
            # Handling common connection errors for local model deployments
            if "connection error" in error_msg or "target machine actively refused" in error_msg:
                return "⚠️ Ollama 서버가 꺼져 있습니다! Ollama 앱을 실행했는지 확인해 주십시오."
            elif "not found" in error_msg or "404" in error_msg:
                return f"⚠️ {model_name} 모델이 없습니다! 터미널에서 'ollama run {model_name}'을 입력해서 모델을 받아 주세요."
            return f"⚠️ 로컬 엔진 오류: {str(e)}"

gemini_brain = GeminiEngine()
chatgpt_brain = ChatGPTEngine()
local_brain = LocalEngine()
