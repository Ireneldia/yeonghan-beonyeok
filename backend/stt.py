"""질문 받아쓰기: 로컬 Whisper (faster-whisper). 오디오는 밖으로 안 나간다."""
from __future__ import annotations
import os, threading, time

# 모델은 HF 허브 자동 다운로드 대신 data/models/<이름>/ 에 직접 받아둔 것을 쓴다 (허브 다운로드가 자주 멈춤)
MODEL_NAME = os.environ.get("YH_WHISPER_MODEL", "faster-whisper-large-v3-turbo")
MODEL_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data", "models", MODEL_NAME)
_model = None
_lock = threading.Lock()
status = {"state": "idle", "model": MODEL_NAME, "error": "", "dir": MODEL_DIR}

def available() -> bool:
    return os.path.exists(os.path.join(MODEL_DIR, "model.bin")) and os.path.exists(os.path.join(MODEL_DIR, "config.json"))

def load():
    global _model
    with _lock:
        if _model is not None:
            return _model
        if not available():
            status.update(state="missing", error=f"모델 파일 없음: {MODEL_DIR}")
            raise RuntimeError(status["error"])
        from faster_whisper import WhisperModel
        status["state"] = "loading"
        try:
            _model = WhisperModel(MODEL_DIR, device="cpu", compute_type="int8", local_files_only=True)
        except Exception as e:
            status.update(state="error", error=str(e)[:200]); raise
        status.update(state="ready", error="")
        return _model

def preload():
    threading.Thread(target=lambda: _safe(load), daemon=True).start()

def _safe(fn):
    try: fn()
    except Exception: pass

def transcribe(path: str, terms: list[str], language: str = "ko") -> str:
    m = load()
    # 힌트: 교안 용어를 영어 표기 그대로 적도록 유도
    prompt = "전공 강의 예습 질문. 용어는 영어 원문 그대로: " + ", ".join(terms[:60]) if terms else None
    with _lock:
        segments, info = m.transcribe(path, language=language, beam_size=5, vad_filter=True,
                                      initial_prompt=prompt, condition_on_previous_text=False)
        text = " ".join(s.text.strip() for s in segments)
    return text.strip()
