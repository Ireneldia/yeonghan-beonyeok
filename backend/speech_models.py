"""Hugging Face ASR 모델 검색과 앱이 관리하는 로컬 설치."""
from __future__ import annotations

import json
import os
import re
import shutil
import struct
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

# Hub 환경 설정은 import 때 읽힌다. 이 환경에서 정지했던 Xet 대신 공식 HTTP 경로를 기본으로 쓴다.
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
from huggingface_hub import hf_hub_download
from huggingface_hub.utils import validate_repo_id
from tqdm.auto import tqdm

import model_fit

ROOT = Path(__file__).resolve().parents[1]
DATA = Path(os.environ.get("YH_DATA_DIR") or ROOT / "data")
MODELS = DATA / "models" / "stt"
SETTINGS = DATA / "stt-settings.json"
LEGACY_ID = "legacy:faster-whisper"
LEGACY_DIR = ROOT / "data" / "models" / os.environ.get("YH_WHISPER_MODEL", "faster-whisper-large-v3-turbo")
DEFAULTS = ("mlx-community/Qwen3-ASR-1.7B-8bit", "mlx-community/Qwen3-ASR-0.6B-8bit",
            "mlx-community/whisper-large-v3-turbo-asr-fp16")
_lock = threading.RLock()
_status = dict(state="idle", model="", status="", completed=0, total=0, percent=None, total_known=False)
_METADATA_FILES = {"config.json", "generation_config.json", "preprocessor_config.json", "processor_config.json",
                   "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "added_tokens.json",
                   "normalizer.json", "vocab.json", "merges.txt", "vocabulary.txt", "vocabulary.json",
                   "tokenizer.model", "chat_template.json", "model.safetensors.index.json"}


class DownloadBusy(RuntimeError):
    pass


def _id(model: str) -> str:
    if not isinstance(model, str) or model.count("/") != 1:
        raise ValueError("Hugging Face의 작성자/모델 이름을 입력하세요")
    try:
        validate_repo_id(model)
    except ValueError as e:
        raise ValueError("올바른 Hugging Face 모델 이름을 입력하세요") from e
    return model


def _directory(model: str) -> Path:
    directory = MODELS / _id(model).replace("/", "--")
    if directory.is_symlink() or directory.resolve().parent != MODELS.resolve():
        raise ValueError("앱이 관리하는 모델 경로가 아닙니다")
    return directory


def _allowed_file(name: str) -> bool:
    return isinstance(name, str) and (name in _METADATA_FILES or name == "model.bin"
                                     or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*\.safetensors", name) is not None)


def _json_url(url: str) -> dict | list:
    try:
        with urlopen(Request(url, headers={"User-Agent": "yeonghan-beonyeok/0.1"}), timeout=15) as response:
            raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise ValueError("metadata too large")
        return json.loads(raw)
    except (OSError, ValueError) as e:
        raise RuntimeError("Hugging Face 모델 정보를 확인하지 못했습니다") from e


def _engine(config: dict, library: str, tags: list, files) -> str | None:
    names = set(files)
    if config.get("auto_map"):
        return None
    mlx = library in ("mlx", "mlx-audio") or "mlx" in tags
    weights = any(name.endswith(".safetensors") for name in names)
    if mlx and weights and config.get("model_type") == "qwen3_asr":
        thinker = config.get("thinker_config", {})
        if (isinstance(thinker, dict) and isinstance(thinker.get("audio_config"), dict)
                and isinstance(thinker.get("text_config"), dict)
                and thinker["audio_config"].get("model_type") == "qwen3_asr_audio_encoder"
                and thinker["text_config"].get("model_type") == "qwen3"
                and {"tokenizer_config.json", "vocab.json", "merges.txt", "preprocessor_config.json"} <= names):
            return "mlx-qwen3-asr"
    if (mlx and weights and config.get("model_type") == "whisper"
            and all(isinstance(config.get(key), int) and config[key] > 0
                    for key in ("d_model", "encoder_layers", "decoder_layers", "num_mel_bins"))
            and {"tokenizer.json", "preprocessor_config.json"} <= names):
        return "mlx-whisper"
    if (library == "ctranslate2" or "ctranslate2" in tags) and {"model.bin", "tokenizer.json"} <= names:
        if isinstance(config.get("suppress_ids"), list):
            return "faster-whisper"
    return None


def _fit(size: int | None) -> dict:
    machine = model_fit.hardware()
    budget = machine.get("budget_bytes")
    result = dict(level="unknown", label="정보 부족", required_bytes=None, budget_bytes=budget,
                  basis="speech-single-model-estimate", confidence="low", note="녹음 길이와 동시 실행 모델에 따라 사용량이 달라집니다")
    if not size or not budget:
        return result
    # ponytail: ASR 가중치 + 작업 여유 추정. 모델별 실측 최대 사용량이 생기면 대체한다.
    required = size + max(model_fit.GIB, int(size * 0.6))
    level = "red" if required > budget else "green" if required <= budget * 0.85 else "yellow"
    result.update(level=level, label={"green": "메모리 여유 예상", "yellow": "여유 적음", "red": "메모리 부족 예상"}[level],
                  required_bytes=required, note="ASR 작업 여유를 포함한 참고 추정 · 녹음 길이와 다른 모델의 메모리는 별도")
    return result


def _inspect(model: str) -> tuple[dict, dict]:
    model = _id(model)
    info = _json_url("https://huggingface.co/api/models/" + model + "?blobs=true")
    if not isinstance(info, dict) or not re.fullmatch(r"[0-9a-f]{40,64}", info.get("sha", "")):
        raise RuntimeError("모델의 고정 버전을 확인하지 못했습니다")
    revision = info["sha"]
    config = _json_url(f"https://huggingface.co/{model}/resolve/{revision}/config.json")
    if not isinstance(config, dict):
        raise RuntimeError("모델 설정이 올바르지 않습니다")
    files = {}
    for item in info.get("siblings", []):
        name = item.get("rfilename")
        if _allowed_file(name):
            size = item.get("size", (item.get("lfs") or {}).get("size"))
            files[name] = size if isinstance(size, int) and not isinstance(size, bool) and size > 0 else None
    library, tags = info.get("library_name", ""), info.get("tags") or []
    engine = _engine(config, library, tags, files)
    reason = "승인이나 별도 로그인이 필요한 모델은 지원하지 않습니다" if info.get("gated") else ""
    if not engine and not reason:
        reason = "현재 앱은 MLX Qwen3-ASR, MLX Audio Whisper, CTranslate2 Whisper 형식만 지원합니다"
    card = info.get("cardData") or {}
    declared = card.get("language", []) if isinstance(card, dict) else []
    if isinstance(declared, str): declared = [declared]
    languages = {lang for lang in [*tags, *declared] if lang in ("ko", "en")}
    languages.update({"Korean": "ko", "English": "en"}[name] for name in config.get("support_languages", [])
                     if name in ("Korean", "English"))
    if model in DEFAULTS:
        languages.update(("ko", "en"))
    size = sum(files.values()) if files and all(value is not None for value in files.values()) else None
    row = dict(id=model, name=model, engine=engine, size=size, languages=sorted(languages),
               installed=False, supported=bool(engine and not reason), fit=_fit(size))
    if reason: row["reason"] = reason
    record = {**row, "revision": revision, "files": files, "library_name": library, "tags": tags}
    return row, record


def _valid_files(directory: Path, record: dict) -> bool:
    try:
        files = record["files"]
        if not isinstance(files, dict) or "config.json" not in files:
            return False
        for name, size in files.items():
            path = directory / name
            if not _allowed_file(name) or path.is_symlink() or not path.is_file() or not isinstance(size, int) or size <= 0 or path.stat().st_size != size:
                return False
            if name.endswith(".safetensors"):
                with path.open("rb") as stream:
                    header_size = struct.unpack("<Q", stream.read(8))[0]
                    if not 2 <= header_size <= min(16_000_000, size - 8): return False
                    header = json.loads(stream.read(header_size))
                tensors = [item for key, item in header.items() if key != "__metadata__"]
                if not tensors or any(not isinstance(t, dict) or not isinstance(t.get("data_offsets"), list)
                                      or len(t["data_offsets"]) != 2 or not 0 <= t["data_offsets"][0] <= t["data_offsets"][1] <= size - header_size - 8
                                      for t in tensors): return False
        config = json.loads((directory / "config.json").read_text())
        if _engine(config, record.get("library_name", ""), record.get("tags", []), files) != record["engine"]:
            return False
        for name in ("tokenizer_config.json", "preprocessor_config.json"):
            if name in files and json.loads((directory / name).read_text()).get("auto_map"):
                return False
        if "model.safetensors.index.json" in files:
            index = json.loads((directory / "model.safetensors.index.json").read_text())
            if any(name not in files for name in index.get("weight_map", {}).values()): return False
        return True
    except (OSError, ValueError, KeyError, TypeError, AttributeError, struct.error):
        return False


def _record(model: str) -> dict | None:
    directory = _directory(model)
    marker = directory / ".installed.json"
    try:
        if marker.is_symlink(): return None
        record = json.loads(marker.read_text())
        if (record.get("id") != model or record.get("engine") not in ("mlx-qwen3-asr", "mlx-whisper", "faster-whisper")
                or not re.fullmatch(r"[0-9a-f]{40,64}", record.get("revision", ""))
                or not _valid_files(directory, record)):
            return None
        return record
    except (OSError, ValueError, AttributeError):
        return None


def _legacy() -> dict | None:
    if not all((LEGACY_DIR / name).is_file() and (LEGACY_DIR / name).stat().st_size > 0 for name in ("config.json", "model.bin", "tokenizer.json")):
        return None
    size = sum(path.stat().st_size for path in LEGACY_DIR.iterdir() if path.is_file())
    return dict(id=LEGACY_ID, name="기존 faster-whisper 모델", engine="faster-whisper", size=size,
                languages=["ko", "en"], installed=True, supported=True, fit=_fit(size), protected=True)


def installed() -> list[dict]:
    rows = []
    with _lock:
        if MODELS.exists():
            for directory in MODELS.iterdir():
                if not directory.is_dir() or directory.is_symlink(): continue
                try:
                    model = json.loads((directory / ".installed.json").read_text()).get("id")
                    record = _record(model)
                    if not record or _directory(model) != directory: continue
                    rows.append({key: record[key] for key in ("id", "name", "engine", "size", "languages", "supported")}
                                | {"installed": True, "fit": _fit(record["size"])})
                except (OSError, ValueError, KeyError, TypeError, AttributeError):
                    continue
        legacy = _legacy()
        if legacy: rows.append(legacy)
    return rows


def metadata(model: str) -> dict:
    row = next((row for row in installed() if row["id"] == model), None)
    if not row: raise LookupError("설치가 완료된 음성 모델을 찾을 수 없습니다")
    return row


def model_path(model: str) -> Path:
    with _lock:
        metadata(model)
        return (LEGACY_DIR if model == LEGACY_ID else _directory(model)).resolve()


def catalog(q: str = "") -> list[dict]:
    if not isinstance(q, str) or len(q) > 100 or any(ord(c) < 32 for c in q):
        raise ValueError("검색어는 100자 이내로 입력하세요")
    q = q.strip()
    local = {row["id"]: row for row in installed()}
    ids = [model for model in DEFAULTS if not q or q.casefold() in model.casefold()]
    primary = set(ids)
    if q:
        common = {"search": q, "sort": "downloads", "direction": -1, "limit": 8}
        urls = ["https://huggingface.co/api/models?" + urlencode({**common, **filter_}) for filter_ in
                ({"pipeline_tag": "automatic-speech-recognition"}, {"filter": "mlx"})]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(_json_url, urls))
        for index, rows in enumerate(results):
            if not isinstance(rows, list): raise RuntimeError("음성 모델 검색 결과가 올바르지 않습니다")
            found = [item["id"] for item in rows[:8] if isinstance(item, dict) and isinstance(item.get("id"), str)]
            ids.extend(found)
            if index == 0: primary.update(found)
        try: ids.insert(0, _id(q))
        except ValueError: pass
    matching_local = [model for model in local if not q or q.casefold() in model.casefold()]
    primary.update(matching_local)
    ids.extend(matching_local)
    def describe(model):
        if model in local: return local[model]
        try: return _inspect(model)[0]
        except (ValueError, RuntimeError):
            return dict(id=model, name=model, engine=None, size=None, languages=[], installed=False,
                        supported=False, reason="모델 설정을 확인하지 못했습니다", fit=_fit(None))
    with ThreadPoolExecutor(max_workers=4) as pool:
        return [row for row in pool.map(describe, dict.fromkeys(ids)) if row["id"] in primary or row["supported"]]


def settings() -> dict:
    with _lock:
        try:
            value = json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}
            return {"model": value.get("model", ""), "language": value.get("language", "auto"),
                    "term_hints": value.get("term_hints", True)}
        except (OSError, ValueError, AttributeError) as e:
            raise RuntimeError("음성 모델 설정을 읽지 못했습니다") from e


def _write_json(path: Path, value: dict):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(value, stream, ensure_ascii=False)
    try: os.replace(temporary, path)
    finally: temporary.unlink(missing_ok=True)


def save_settings(value: dict) -> dict:
    with _lock:
        value = {**settings(), **value}
        if not isinstance(value.get("model"), str) or value.get("language") not in ("auto", "ko", "en") or not isinstance(value.get("term_hints"), bool):
            raise ValueError("음성 모델, 언어 또는 용어 힌트 설정을 확인하세요")
        if value["model"]: metadata(value["model"])
        value = {key: value[key] for key in ("model", "language", "term_hints")}
        _write_json(SETTINGS, value)
        return value


def download_status() -> dict:
    with _lock: return dict(_status)


def clear_download(model: str) -> dict:
    if not isinstance(model, str):
        raise ValueError("닫을 다운로드의 모델 이름을 확인하세요")
    with _lock:
        if _status["state"] == "downloading":
            raise DownloadBusy("진행 중인 다운로드는 닫을 수 없습니다")
        if _status["model"] != model:
            raise DownloadBusy("다운로드 상태가 변경됐습니다. 다시 확인하세요")
        _status.clear()
        _status.update(state="idle", model="", status="", completed=0, total=0, percent=None,
                       total_known=False)
        return dict(_status)


def _download(model: str):
    try:
        row, record = _inspect(model)
        if not row["supported"]: raise ValueError(row.get("reason", "지원하지 않는 음성 모델입니다"))
        if row["size"] is None: raise RuntimeError("전체 파일 용량을 확인하지 못했습니다")
        directory = _directory(model)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / ".installed.json").unlink(missing_ok=True)
        progress = {name: 0 for name in record["files"]}
        with _lock:
            _status.update(total=row["size"], total_known=True, percent=0)
        for filename, size in record["files"].items():
            if (directory / filename).is_symlink(): raise ValueError("모델 파일이 외부 경로를 가리킵니다")
            class Progress(tqdm):
                target = filename
                expected = size
                def __init__(self, *args, **kwargs):
                    kwargs.pop("name", None)
                    kwargs["disable"] = True
                    super().__init__(*args, **kwargs)
                    self.report()
                def report(self):
                    progress[self.target] = min(self.expected, max(0, int(self.n)))
                    with _lock:
                        completed = sum(progress.values())
                        _status.update(completed=completed, percent=min(99, round(completed * 100 / row["size"], 1)), status=self.target)
                def update(self, n=1):
                    self.n += n or 0
                    self.report()
                def update_transfer(self, n=0): pass  # Xet 재구성 바이트만 세고 네트워크 바를 중복 합산하지 않는다.
                def set_transfer_postfix_str(self, *args, **kwargs): pass
            hf_hub_download(model, filename, revision=record["revision"], local_dir=directory,
                            token=False, endpoint="https://huggingface.co", tqdm_class=Progress)
            progress[filename] = size
            with _lock:
                completed = sum(progress.values())
                _status.update(completed=completed, percent=min(99, round(completed * 100 / row["size"], 1)), status=filename)
        if not _valid_files(directory, record): raise RuntimeError("모델 파일 검증에 실패했습니다. 다운로드를 다시 시도하세요")
        with _lock:
            _write_json(directory / ".installed.json", record)
            _status.update(state="done", completed=row["size"], percent=100, status="다운로드 완료")
    except Exception as e:
        with _lock:
            message = str(e)[:300] if type(e) in (ValueError, RuntimeError) else "모델 다운로드에 실패했습니다. 네트워크와 남은 디스크 공간을 확인하세요"
            _status.update(state="error", status="다운로드 실패", error=message)


def start_download(model: str) -> dict:
    model = _id(model)
    with _lock:
        if _status["state"] == "downloading":
            if _status["model"] == model: return dict(_status)
            raise DownloadBusy("다른 음성 모델을 다운로드하고 있습니다")
        _directory(model)
        record = _record(model)
        _status.clear()
        if record:
            _status.update(state="done", model=model, total=record["size"], completed=record["size"], percent=100,
                           total_known=True, status="이미 설치되어 있습니다")
        else:
            _status.update(state="downloading", model=model, total=0, completed=0, percent=None,
                           total_known=False, status="모델 정보 확인 중")
            try: threading.Thread(target=_download, args=(model,), daemon=True, name="speech-download").start()
            except Exception:
                _status.update(state="error", status="다운로드 시작 실패")
                raise
        return dict(_status)


def delete_installed(model: str):
    with _lock:
        if model == LEGACY_ID: raise ValueError("기존 Whisper 원본은 앱에서 삭제하지 않습니다")
        if _status["state"] == "downloading" and _status["model"] == model:
            raise DownloadBusy("다운로드 중인 음성 모델은 삭제할 수 없습니다")
        if settings()["model"] == model:
            raise DownloadBusy("선택 중인 음성 모델은 먼저 선택을 해제하세요")
        directory = _directory(model)
        if not _record(model): raise LookupError("설치된 음성 모델을 찾을 수 없습니다")
        shutil.rmtree(directory)
