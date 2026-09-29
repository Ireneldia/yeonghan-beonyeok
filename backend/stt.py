"""선택한 로컬 ASR 실행. 오디오·가중치 로딩에는 네트워크를 사용하지 않는다."""
from __future__ import annotations

import gc
from pathlib import Path
import threading

_model = None
_loaded_id = ""
_loaded_engine = ""
# 모델 교체·추론·삭제를 한 잠금으로 묶어 실행 중인 가중치를 지우지 않는다.
_lock = threading.RLock()
_status_lock = threading.Lock()
status = {"state": "idle", "model": "", "error": "", "engine": "", "gpu": False,
          "active_model": None, "peak_memory_bytes": None}


def _publish(**values):
    with _status_lock:
        status.update(values)


def status_snapshot() -> dict:
    # 추론 잠금을 기다리지 않아 녹음 처리 중에도 상태를 조회할 수 있다.
    with _status_lock:
        return dict(status)


def _selection(selection=None) -> dict:
    import speech_models
    value = speech_models.settings() if selection is None else selection
    if not isinstance(value, dict) or not isinstance(value.get("model"), str):
        raise ValueError("음성 모델 선택을 확인하세요")
    if not value["model"]:
        raise LookupError("질문 받아쓰기 모델을 먼저 선택하세요")
    language, hints = value.get("language", "auto"), value.get("term_hints", True)
    if language not in ("auto", "ko", "en") or not isinstance(hints, bool):
        raise ValueError("음성 언어 또는 용어 힌트 설정을 확인하세요")
    return {"model": value["model"], "language": language, "term_hints": hints}


def _release():
    global _model, _loaded_id, _loaded_engine
    engine = _loaded_engine
    _model = None
    _loaded_id = _loaded_engine = ""
    gc.collect()
    if engine.startswith("mlx-"):
        import mlx.core as mx
        mx.synchronize()
        mx.clear_cache()


def unload():
    with _lock:
        _release()
        _publish(state="idle", model="", engine="", error="", gpu=False, active_model=None, peak_memory_bytes=None)


def delete_model(model_id: str):
    import speech_models
    with _lock:
        if _loaded_id == model_id:
            unload()
        return speech_models.delete_installed(model_id)


def _whisper_token_alias(tokenizer):
    # mlx-audio 0.5.7은 <|nospeech|>를 조회하지만 HF 일부 모델은 <|nocaptions|>를 쓴다.
    # 미등록 토큰의 EOS fallback을 그대로 두면 디코더가 EOS를 금지해 반복 생성한다.
    vocab = tokenizer.get_vocab()
    if "<|nospeech|>" not in vocab and "<|nocaptions|>" in vocab:
        no_speech = vocab["<|nocaptions|>"]
        convert = tokenizer.convert_tokens_to_ids
        def with_alias(tokens):
            return no_speech if isinstance(tokens, str) and tokens == "<|nospeech|>" else convert(tokens)
        tokenizer.convert_tokens_to_ids = with_alias


def _load_mlx(path: Path, engine: str):
    import mlx.core as mx
    from mlx_audio.utils import apply_quantization, load_config, load_weights
    from transformers import AutoTokenizer, WhisperFeatureExtractor, WhisperProcessor

    if not mx.metal.is_available():
        raise RuntimeError("이 음성 모델은 Apple Silicon의 Metal GPU가 필요합니다")
    mx.set_default_device(mx.gpu)
    config = load_config(path)
    if config.get("auto_map"):
        raise ValueError("외부 Python 코드가 필요한 음성 모델은 실행하지 않습니다")
    if engine == "mlx-qwen3-asr":
        from mlx_audio.stt.models.qwen3_asr import Qwen3ASRModel as Model, ModelConfig
    else:
        from mlx_audio.stt.models.whisper import Model, ModelConfig
    model = Model(ModelConfig.from_dict(config))
    weights = model.sanitize(load_weights(path))
    apply_quantization(model, config, weights, getattr(model, "model_quant_predicate", None))
    model.load_weights(list(weights.items()), strict=True)
    mx.eval(model.parameters())
    model.eval()
    # mlx-audio 0.5.7의 기본 Qwen hook은 trust_remote_code=True이므로 호출하지 않는다.
    local = {"local_files_only": True, "trust_remote_code": False}
    if engine == "mlx-qwen3-asr":
        model._tokenizer = AutoTokenizer.from_pretrained(str(path), **local)
        model._feature_extractor = WhisperFeatureExtractor.from_pretrained(str(path), **local)
        model.config.model_repo = str(path)
    else:
        model._processor = WhisperProcessor.from_pretrained(str(path), **local)
        _whisper_token_alias(model._processor.tokenizer)
    return model


def _load(model_id: str):
    global _model, _loaded_id, _loaded_engine
    import speech_models

    metadata = speech_models.metadata(model_id)
    path = Path(speech_models.model_path(model_id))
    if not path.is_absolute() or not path.is_dir():
        raise FileNotFoundError("설치가 완료된 로컬 음성 모델 폴더를 찾을 수 없습니다")
    engine = metadata.get("engine")
    if engine not in ("faster-whisper", "mlx-whisper", "mlx-qwen3-asr") or not metadata.get("supported"):
        raise ValueError("현재 실행 환경이 지원하는 음성 모델을 선택하세요")
    if _loaded_id == model_id and _model is not None:
        _publish(state="ready", error="", engine=engine, gpu=engine.startswith("mlx-"))
        return _model, engine
    _release()
    _publish(state="loading", model=model_id, engine=engine, gpu=False, error="", peak_memory_bytes=None)
    if engine == "faster-whisper":
        # faster-whisper는 이 파일이 없으면 local_files_only=True여도 토크나이저를 원격 조회한다.
        if not (path / "tokenizer.json").is_file():
            raise FileNotFoundError("Whisper 폴더에 로컬 tokenizer.json이 없습니다")
        from faster_whisper import WhisperModel
        model = WhisperModel(str(path), device="cpu", compute_type="int8", local_files_only=True)
    else:
        model = _load_mlx(path, engine)
    _model, _loaded_id, _loaded_engine = model, model_id, engine
    _publish(state="ready", gpu=engine.startswith("mlx-"))
    return model, engine


def _failed(error: Exception):
    missing = isinstance(error, (LookupError, FileNotFoundError))
    message = str(error)[:250] or "음성 모델 실행에 실패했습니다"
    if isinstance(error, ImportError):
        message = "음성 실행 패키지가 없습니다. requirements.txt의 설치 상태를 확인하세요"
    _publish(state="missing" if missing else "error", error=message)
    return message


def preload():
    # 미선택 상태에서 모델을 고르거나 다운로드하지 않는다.
    try:
        import speech_models
        selection = speech_models.settings()
    except Exception as error:
        _failed(error)
        return
    if not selection.get("model"):
        return
    def warm():
        with _lock:
            try:
                choice = _selection(selection)
                _publish(model=choice["model"], active_model=choice["model"])
                _load(choice["model"])
            except Exception as error:
                _failed(error)
            finally:
                _publish(active_model=None)
    threading.Thread(target=warm, daemon=True, name="speech-preload").start()


def _decode_audio(path: str):
    from faster_whisper.audio import decode_audio
    if not Path(path).is_file():
        raise ValueError("녹음 파일을 찾을 수 없습니다")
    # 이미 설치된 PyAV로 WebM/Opus와 MP4 등을 모두 16 kHz mono float32로 디코딩한다.
    return decode_audio(path, sampling_rate=16000)


def transcribe(path: str, terms: list[str], selection=None) -> str:
    with _lock:
        try:
            choice = _selection(selection)
            _publish(model=choice["model"], active_model=choice["model"], engine="", gpu=False,
                     error="", peak_memory_bytes=None)
            model, engine = _load(choice["model"])
            language = None if choice["language"] == "auto" else choice["language"]
            hints = list(dict.fromkeys(term.strip() for term in terms
                                      if isinstance(term, str) and term.strip()))[:60] if choice["term_hints"] else []
            _publish(state="transcribing")
            if engine == "faster-whisper":
                if not Path(path).is_file():
                    raise ValueError("녹음 파일을 찾을 수 없습니다")
                prompt = "전공 강의 예습 질문. 용어는 영어 원문 그대로: " + ", ".join(hints) if hints else None
                segments, _ = model.transcribe(path, language=language, beam_size=5, vad_filter=True,
                                              initial_prompt=prompt, condition_on_previous_text=False)
                text = " ".join(segment.text.strip() for segment in segments)
            else:
                import mlx.core as mx
                mx.set_default_device(mx.gpu)
                mx.reset_peak_memory()
                audio = _decode_audio(path)
                if not len(audio) or not audio.any():
                    text = ""
                elif engine == "mlx-qwen3-asr":
                    result = model.generate(audio, language={"ko": "Korean", "en": "English"}.get(language),
                                            hotwords=hints or None, temperature=0.0, max_tokens=8192, verbose=False)
                    if getattr(result, "generation_tokens", 0) >= 8192:
                        raise RuntimeError("받아쓰기 길이 제한에 도달했습니다. 녹음을 나누어 다시 시도하세요")
                    text = result.text
                else:
                    # 이 MLX Whisper 버전은 beam search를 지원하지 않아 greedy decoding을 사용한다.
                    result = model.generate(audio, language=language, task="transcribe", temperature=0.0,
                                            initial_prompt=", ".join(hints) or None,
                                            condition_on_previous_text=False, return_timestamps=False, verbose=False)
                    text = result.text
                mx.synchronize()
                _publish(peak_memory_bytes=int(mx.get_peak_memory()))
            _publish(state="ready", error="")
            return text.strip()
        except Exception as error:
            raise RuntimeError(_failed(error)) from None
        finally:
            _publish(active_model=None)
