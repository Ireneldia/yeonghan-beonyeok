"""Ollama 공식 모델 검색과 로컬 다운로드 진행 상태."""
import json
import re
import threading
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

CATALOG = "https://ollama.com"
OLLAMA = "http://127.0.0.1:11434"
REGISTRY = "https://registry.ollama.ai"
_NAME = r"[A-Za-z0-9][A-Za-z0-9_.-]*"
_MODEL = re.compile(rf"{_NAME}(?::{_NAME})?")
_lock = threading.Lock()
_deleting = set()
_status = {"state": "idle", "model": "", "status": "", "completed": 0, "total": 0, "percent": None,
           "total_known": False}


class DownloadBusy(RuntimeError):
    pass


def installed() -> list[dict]:
    try:
        with urlopen(OLLAMA + "/api/tags", timeout=10) as response:
            payload = json.load(response)
        if not isinstance(payload, dict) or not isinstance(payload.get("models"), list):
            raise ValueError("invalid models")
        rows = []
        for item in payload["models"]:
            if not isinstance(item, dict) or not isinstance(item.get("name"), str) or not item["name"]:
                raise ValueError("invalid model")
            size = item.get("size", 0)
            if not isinstance(size, int) or isinstance(size, bool) or size < 0:
                raise ValueError("invalid size")
            rows.append({"id": item["name"], "name": item["name"], "size": size,
                         "digest": item.get("digest", ""),
                         "cloud": bool(item.get("remote_host") or item.get("remote_model")
                                       or item["name"].lower().endswith((":cloud", "-cloud")))})
        return rows
    except (OSError, ValueError) as e:
        raise RuntimeError("Ollama 설치 목록을 확인하지 못했습니다. Ollama 실행 상태를 확인하세요") from e


def _installed_key(model: str) -> str:
    return model if ":" in model.rsplit("/", 1)[-1] else model + ":latest"


def delete_installed(model: str):
    if not isinstance(model, str) or not model or len(model) > 1024 or any(ord(ch) < 32 for ch in model):
        raise ValueError("삭제할 설치 모델 이름을 확인하세요")
    key = _installed_key(model)
    with _lock:
        if key in _deleting or (_status["state"] == "downloading" and _installed_key(_status["model"]) == key):
            raise DownloadBusy("이 모델의 다운로드 또는 삭제가 진행 중입니다")
        _deleting.add(key)
    try:
        if not any(row["id"] == model for row in installed()):
            raise LookupError("설치된 모델을 찾을 수 없습니다. 목록을 새로고침하세요")
        request = Request(OLLAMA + "/api/delete", data=json.dumps({"model": model}).encode(),
                          headers={"Content-Type": "application/json"}, method="DELETE")
        try:
            with urlopen(request, timeout=30) as response:
                response.read()
        except HTTPError as e:
            if e.code == 404:
                raise LookupError("모델이 이미 삭제되었습니다. 목록을 새로고침하세요") from e
            raise RuntimeError("Ollama가 모델을 삭제하지 못했습니다") from e
        except OSError as e:
            raise RuntimeError("모델 삭제 결과를 확인하지 못했습니다. 설치 목록을 새로고침하세요") from e
    finally:
        with _lock:
            _deleting.discard(key)


def _validate_model(model: str, *, tag: bool = True) -> str:
    if not isinstance(model, str) or len(model) > 200 or not _MODEL.fullmatch(model):
        raise ValueError("올바른 Ollama 공식 모델 이름을 입력하세요")
    if not tag and ":" in model:
        raise ValueError("버전을 제외한 모델 이름을 입력하세요")
    if model.lower().endswith((":cloud", "-cloud")):
        raise ValueError("클라우드 모델은 로컬 다운로드 대상으로 사용할 수 없습니다")
    return model


class _Links(HTMLParser):
    """공식 페이지의 모델 링크만 읽고, 레이아웃별 중복 링크는 합친다."""
    def __init__(self):
        super().__init__()
        self.rows = {}
        self.current = None
        self.in_description = False

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "a":
            match = re.fullmatch(rf"/library/({_NAME}(?::{_NAME})?)", attrs.get("href", ""))
            self.current = {"id": match[1], "text": [], "description": [], "heading": False} if match else None
            self.in_description = False
        elif self.current:
            if tag == "h2":
                self.current["heading"] = True
            if tag == "p" and not self.current["description"]:
                self.in_description = True

    def handle_data(self, data):
        if self.current:
            self.current["text"].append(data)
            if self.in_description:
                self.current["description"].append(data)

    def handle_endtag(self, tag):
        if tag == "p":
            self.in_description = False
        if tag == "a" and self.current:
            row = self.current
            model = row["id"]
            if not model.lower().endswith((":cloud", "-cloud")) and (row["heading"] or ":" in model):
                item = self.rows.setdefault(model, {"id": model, "name": model})
                description = " ".join(" ".join(row["description"]).split())
                if row["heading"] and description:
                    item["description"] = description
                size = re.search(r"\b\d+(?:\.\d+)?\s*[KMGT]B\b", " ".join(row["text"]))
                if size:
                    item["size"] = size[0]
            self.current = None


def _catalog(path: str) -> list[dict]:
    try:
        with urlopen(Request(CATALOG + path, headers={"User-Agent": "yeonghan-beonyeok/0.1"}), timeout=20) as response:
            page = response.read(4_000_001)
    except HTTPError as e:
        if e.code == 404:
            raise ValueError("Ollama에서 해당 모델을 찾지 못했습니다") from e
        raise RuntimeError(f"Ollama 모델 목록 요청 실패 ({e.code})") from e
    except (URLError, TimeoutError) as e:
        raise RuntimeError("Ollama 모델 목록에 연결할 수 없습니다") from e
    if len(page) > 4_000_000:
        raise RuntimeError("Ollama 모델 목록 응답이 너무 큽니다")
    parser = _Links()
    parser.feed(page.decode("utf-8"))
    return list(parser.rows.values())


def search(query: str) -> list[dict]:
    if not isinstance(query, str) or len(query) > 100 or any(ord(c) < 32 for c in query):
        raise ValueError("검색어는 100자 이내로 입력하세요")
    return [row for row in _catalog("/search?" + urlencode({"q": query.strip()})) if ":" not in row["id"]]


def tags(model: str) -> list[dict]:
    model = _validate_model(model, tag=False)
    return [row for row in _catalog(f"/library/{model}/tags") if row["id"].startswith(model + ":")]


def download_status() -> dict:
    with _lock:
        return dict(_status)


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


def _manifest_layers(model: str) -> dict:
    name, _, tag = _validate_model(model).partition(":")
    request = Request(f"{REGISTRY}/v2/library/{name}/manifests/{tag or 'latest'}",
                      headers={"Accept": "application/vnd.docker.distribution.manifest.v2+json"})
    try:
        with urlopen(request, timeout=10) as response:
            manifest = json.load(response)
        if not isinstance(manifest, dict):
            return {}
        layers = {}
        for item in [manifest.get("config", {}), *manifest["layers"]]:
            digest, size = item["digest"], max(0, int(item["size"]))
            layers[digest] = (max(size, layers.get(digest, (0, 0))[0]), 0)
        return layers
    except (OSError, ValueError, KeyError, TypeError):
        # 레지스트리 목록이 없으면 Ollama 스트림에서 확인한 용량으로 진행한다.
        return {}


def _pull(model: str):
    layers = _manifest_layers(model)
    with _lock:
        _status.update(total=sum(layer[0] for layer in layers.values()), total_known=bool(layers),
                       percent=0 if layers else None)
    request = Request(OLLAMA + "/api/pull", data=json.dumps({"model": model, "stream": True}).encode(),
                      headers={"Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=60) as response:
            for line in response:
                if not line.strip():
                    continue
                item = json.loads(line)
                if item.get("error"):
                    raise RuntimeError(str(item["error"])[:300])
                digest = item.get("digest")
                if digest:
                    total, completed = layers.get(digest, (0, 0))
                    total = max(total, int(item.get("total", 0)))
                    completed = max(completed, int(item.get("completed", 0)))
                    layers[digest] = (total, min(completed, total))
                total = sum(layer[0] for layer in layers.values())
                completed = sum(layer[1] for layer in layers.values())
                done = item.get("status") == "success"
                if done:
                    show = Request(OLLAMA + "/api/show", data=json.dumps({"model": model}).encode(),
                                   headers={"Content-Type": "application/json"})
                    with urlopen(show, timeout=10) as metadata:
                        info = json.load(metadata)
                    if info.get("remote_model") or info.get("remote_host"):
                        raise RuntimeError("클라우드 모델입니다. 로컬 가중치를 제공하는 버전을 선택하세요")
                with _lock:
                    _status.update(status=item.get("status", "다운로드 중"), total=total,
                                   completed=total if done else completed,
                                   percent=100 if done else min(99, round(completed * 100 / total, 1)) if total else None)
                    if done:
                        _status["state"] = "done"
                if done:
                    return
        raise RuntimeError("완료 확인 전에 다운로드 연결이 끊겼습니다. 다시 시도하세요")
    except Exception as e:
        with _lock:
            _status.update(state="error", error=str(e)[:300], status="다운로드 실패")


def start_download(model: str) -> dict:
    model = _validate_model(model)
    if ":" not in model:
        model += ":latest"
    with _lock:
        if _installed_key(model) in _deleting:
            raise DownloadBusy("이 모델을 삭제하고 있습니다")
        if _status["state"] == "downloading":
            if _status["model"] != model:
                raise DownloadBusy("다른 모델을 다운로드하고 있습니다")
            return dict(_status)
        _status.clear()
        _status.update(state="downloading", model=model, status="다운로드 준비 중", completed=0, total=0,
                       percent=None, total_known=False)
        try:
            threading.Thread(target=_pull, args=(model,), daemon=True, name="ollama-download").start()
        except Exception:
            _status.update(state="error", status="다운로드 시작 실패", error="다운로드 작업을 시작하지 못했습니다")
            raise
        return dict(_status)
