from __future__ import annotations
import asyncio, json, math, os, re, shutil, sqlite3, tempfile, threading, uuid
from collections import OrderedDict
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor
from multiprocessing import get_context
from pathlib import Path
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, Request
from fastapi.responses import Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ValidationError
from typing import Literal
from urllib.parse import quote

import db, llm, pdfx, match as matcher, anki, stt, local_models, speech_models, document_import

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("YH_DATA_DIR") or os.path.join(ROOT, "data"); DOCS = os.path.join(DATA, "docs"); EXPORTS = os.path.join(DATA, "exports")
PROMPTS = os.path.join(ROOT, "prompts")
for d in (DOCS, EXPORTS): os.makedirs(d, exist_ok=True)
db.init()

app = FastAPI(title="영한번역")
pool = ThreadPoolExecutor(max_workers=3)
_pdf_pool = ProcessPoolExecutor(max_workers=1, mp_context=get_context("spawn"))
_workers: list[asyncio.Task] = []
_meta_cache: OrderedDict[str, dict] = OrderedDict()
_terms_cache: OrderedDict[str, list[str]] = OrderedDict()
# 파일 삭제는 PDF worker가 작업을 마칠 때까지 기다린다. 모든 PyMuPDF 호출은 한 프로세스에서 실행한다.
_doc_files_lock = threading.RLock()

def _pdf_call(function, *args):
    return _pdf_pool.submit(function, *args).result()

async def _finish_file_work(work):
    try:
        return await asyncio.shield(work)
    except asyncio.CancelledError:
        # 실행 중인 worker가 파일을 쓰는 동안 임시 디렉터리를 먼저 지우지 않는다.
        while not work.done():
            try: await asyncio.shield(work)
            except asyncio.CancelledError: continue
            except Exception: break
        if not work.cancelled(): work.exception()
        raise

def _copy_upload(source, destination):
    with open(destination, "wb") as target:
        shutil.copyfileobj(source, target)

# ---------- AI 모드 ----------
class LLMSettings(BaseModel):
    provider: Literal["codex", "local", "claude"]
    codex_model: str
    local_model: str
    claude_model: str = "haiku"
    codex_effort: str = ""
    local_effort: str = ""
    claude_effort: str = ""
    codex_fast: bool = False

class Engine(BaseModel):
    provider: Literal["codex", "local", "claude"]
    model: str
    effort: str = ""
    fast: bool = False

@app.get("/api/llm/settings")
def get_llm_settings():
    return llm.settings()

@app.put("/api/llm/settings")
def set_llm_settings(body: LLMSettings):
    try:
        return llm.save_settings(body.model_dump(exclude_unset=True))
    except ValueError as e:
        raise HTTPException(400, str(e))
    except (RuntimeError, OSError, TimeoutError) as e:
        raise HTTPException(503, str(e)[:200])

@app.get("/api/llm/models")
def get_llm_models(refresh: bool = False):
    return llm.models(refresh=refresh)

@app.get("/api/llm/local/search")
def search_local_models(q: str = ""):
    try:
        return llm.fit_catalog(local_models.search(q), families=True)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except RuntimeError as e:
        raise HTTPException(502, str(e))

@app.get("/api/llm/local/tags")
def local_model_tags(model: str):
    try:
        return llm.fit_catalog(local_models.tags(model))
    except ValueError as e:
        raise HTTPException(400, str(e))
    except RuntimeError as e:
        raise HTTPException(502, str(e))

class DownloadIn(BaseModel):
    model: str

@app.post("/api/llm/local/download")
def download_local_model(body: DownloadIn):
    try:
        return local_models.start_download(body.model)
    except local_models.DownloadBusy as e:
        raise HTTPException(409, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))

@app.get("/api/llm/local/download")
def local_download_status():
    return local_models.download_status()

@app.delete("/api/llm/local/download")
def clear_local_download(body: DownloadIn):
    try:
        return local_models.clear_download(body.model)
    except local_models.DownloadBusy as e:
        raise HTTPException(409, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))

@app.get("/api/llm/local/installed")
def installed_local_models():
    try:
        result = llm.fit_catalog(local_models.installed())
        for model in result["models"]:
            if model.get("cloud"):
                model["fit"].update(level="unknown", label="클라우드 모델", required_bytes=None,
                                    note="로컬 가중치가 없는 클라우드 연결 항목입니다")
        return result
    except RuntimeError as e:
        raise HTTPException(503, str(e))

@app.delete("/api/llm/local/installed")
def delete_local_model(body: DownloadIn):
    try:
        local_models.delete_installed(body.model)
        return {"ok": True}
    except local_models.DownloadBusy as e:
        raise HTTPException(409, str(e))
    except LookupError as e:
        raise HTTPException(404, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))
    except RuntimeError as e:
        raise HTTPException(503, str(e))

# ---------- 질문 받아쓰기 모델 ----------
class STTSettings(BaseModel):
    model: str
    language: Literal["auto", "ko", "en"] = "auto"
    term_hints: bool = True

def _speech_action(action, *args):
    try:
        return action(*args)
    except speech_models.DownloadBusy as e:
        raise HTTPException(409, str(e)) from e
    except LookupError as e:
        raise HTTPException(404, str(e)) from e
    except ValueError as e:
        raise HTTPException(400, str(e)) from e
    except (RuntimeError, OSError) as e:
        raise HTTPException(503, str(e)) from e

@app.get("/api/stt/settings")
def get_stt_settings():
    return _speech_action(speech_models.settings)

@app.put("/api/stt/settings")
def set_stt_settings(body: STTSettings):
    return _speech_action(speech_models.save_settings, body.model_dump())

@app.get("/api/stt/models")
def search_stt_models(q: str = ""):
    return {"models": _speech_action(speech_models.catalog, q)}

@app.get("/api/stt/installed")
def installed_stt_models():
    return {"models": _speech_action(speech_models.installed)}

@app.delete("/api/stt/installed")
def delete_stt_model(body: DownloadIn):
    _speech_action(stt.delete_model, body.model)
    return {"ok": True}

@app.post("/api/stt/download")
def download_stt_model(body: DownloadIn):
    return _speech_action(speech_models.start_download, body.model)

@app.get("/api/stt/download")
def stt_download_status():
    return speech_models.download_status()

@app.delete("/api/stt/download")
def clear_stt_download(body: DownloadIn):
    return _speech_action(speech_models.clear_download, body.model)

# ---------- 페이지 메타 ----------
def _valid_meta(meta) -> bool:
    def number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)
    try:
        return (isinstance(meta, dict) and meta.get("_cache_version") == pdfx.META_VERSION
                and all(number(meta[key]) and meta[key] > 0 for key in ("w", "h"))
                and isinstance(meta["text"], str) and isinstance(meta["words"], list)
                and isinstance(meta["sentences"], list) and number(meta["right"])
                and all(word["i"] == index and isinstance(word["t"], str)
                        and all(number(word[key]) for key in ("x0", "y0", "x1", "y1", "gap"))
                        and all(isinstance(word[key], int) for key in ("b", "l"))
                        for index, word in enumerate(meta["words"]))
                and all(sentence["i"] == index and isinstance(sentence["t"], str)
                        and isinstance(sentence["w"], list)
                        and all(isinstance(id, int) and 0 <= id < len(meta["words"]) for id in sentence["w"])
                        for index, sentence in enumerate(meta["sentences"])))
    except (KeyError, TypeError, AttributeError):
        return False

def page_meta(doc_id: str, pno: int) -> dict:
    with _doc_files_lock:
        d = get_doc(doc_id)
        if pno < 0 or pno >= d["pages"]: raise HTTPException(404, "page")
        key = f"{doc_id}:{pno}"
        if key not in _meta_cache:
            cache = os.path.join(DOCS, f"{doc_id}.p{pno}.json")
            try:
                with open(cache, encoding="utf-8") as f: meta = json.load(f)
            except (OSError, ValueError):
                meta = None
            if not _valid_meta(meta):
                meta = _pdf_call(pdfx.page_metadata, d["path"], pno)
                meta["_cache_version"] = pdfx.META_VERSION
                with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=DOCS, delete=False) as f:
                    temporary = f.name
                    try: json.dump(meta, f, ensure_ascii=False)
                    except BaseException:
                        f.close(); os.remove(temporary)
                        raise
                try: os.replace(temporary, cache)
                finally:
                    if os.path.exists(temporary): os.remove(temporary)
            _meta_cache[key] = meta
            if len(_meta_cache) > 128: _meta_cache.popitem(last=False)
        _meta_cache.move_to_end(key)
        return _meta_cache[key]

# ---------- 큐 ----------
queue: asyncio.Queue = asyncio.Queue()

async def worker():
    loop = asyncio.get_event_loop()
    while True:
        lid = await queue.get()
        try:
            with db.conn() as c:
                r = c.execute("SELECT * FROM lookups WHERE id=?", (lid,)).fetchone()
            if not r or r["status"] != "pending":
                continue
            item = db._row(r); d = db.doc(item["doc_id"])
            if not d:
                continue
            meta = await asyncio.to_thread(page_meta, item["doc_id"], item["page"])
            engine = {key: item[key] for key in ("provider", "model", "effort", "fast")}
            subject = d.get("subject") or d["name"]
            if item["kind"] == "word":
                wid = item["word_ids"][0] if item["word_ids"] else None
                sent = ""
                if wid is not None and "s" in meta["words"][wid]:
                    sent = meta["sentences"][meta["words"][wid]["s"]]["t"]
                res = await loop.run_in_executor(pool, llm.word_meaning, item["text"], sent, meta["text"], subject, engine)
            else:
                res = await loop.run_in_executor(pool, llm.sentence_translation, item["text"], meta["text"], subject, engine)
            await asyncio.to_thread(db.set_result, lid, result=res)
        except Exception as e:
            await asyncio.to_thread(db.set_result, lid, error=str(e)[:300])
        finally:
            queue.task_done()

@app.on_event("startup")
async def _start():
    stt.preload()
    for _ in range(3):
        _workers.append(asyncio.create_task(worker()))
    for it in db.pending():
        await queue.put(it["id"])

@app.on_event("shutdown")
async def _stop():
    for task in _workers: task.cancel()
    await asyncio.gather(*_workers, return_exceptions=True)
    _workers.clear()
    await asyncio.to_thread(_pdf_pool.shutdown, wait=True, cancel_futures=True)
    pool.shutdown(wait=False, cancel_futures=True)

# ---------- 과목 폴더·문서 ----------
class FolderIn(BaseModel):
    name: str

@app.get("/api/folders")
def list_folders():
    return db.folders()

@app.post("/api/folders")
def create_folder(body: FolderIn):
    try:
        return db.create_folder(body.name)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except sqlite3.IntegrityError:
        raise HTTPException(409, "이미 있는 폴더 이름입니다") from None

@app.delete("/api/folders/{folder_id}")
def delete_folder(folder_id: str):
    return _delete_documents(folder_id=folder_id)

@app.patch("/api/folders/{folder_id}")
def rename_folder(folder_id: str, body: FolderIn):
    try:
        return db.rename_folder(folder_id, body.name)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except LookupError as e:
        raise HTTPException(404, str(e))
    except sqlite3.IntegrityError:
        raise HTTPException(409, "이미 있는 폴더 이름입니다") from None

@app.get("/api/docs")
def list_docs():
    return db.docs()

@app.get("/api/import/formats")
def import_formats():
    return document_import.formats()

@app.post("/api/docs")
async def upload(request: Request, file: UploadFile = File(...), subject: str = Form(""),
                 folder_id: str | None = Form(None)):
    filename = (file.filename or "").replace("\\", "/").rsplit("/", 1)[-1]
    extension = Path(filename).suffix.lower()
    if extension not in document_import.SUPPORTED_EXTENSIONS:
        raise HTTPException(415, "지원하지 않는 문서 형식입니다")
    # 폴더 필드가 생략된 구형 클라이언트만 subject로 폴더를 선택한다. 빈 폴더 필드는 루트다.
    folder = {"folder_id": folder_id} if "folder_id" in await request.form() else {}
    doc_id = uuid.uuid4().hex[:10]
    path = Path(DOCS) / f"{doc_id}.pdf"
    try:
        with tempfile.TemporaryDirectory(prefix=".import-", dir=DOCS) as directory:
            source, output = Path(directory) / ("source" + extension), Path(directory) / "validated.pdf"
            def prepare():
                _copy_upload(file.file, source)
                return _pdf_call(document_import.copy_pdf, source, output)
            work = asyncio.get_running_loop().run_in_executor(None, prepare)
            pages = await _finish_file_work(work)
            def publish():
                with _doc_files_lock:
                    os.replace(output, path)
                    try:
                        db.add_doc(doc_id, filename[:-len(extension)], subject, str(path), pages, **folder)
                    except Exception:
                        path.unlink()
                        raise
                    return db.doc(doc_id)
            return await _finish_file_work(asyncio.get_running_loop().run_in_executor(None, publish))
    except LookupError as error:
        raise HTTPException(404, str(error)) from error
    except ValueError as error:
        raise HTTPException(400, str(error)) from error
    except OSError as error:
        raise HTTPException(500, "문서 파일을 저장하지 못했습니다") from error

@app.get("/api/docs/{doc_id}")
def get_doc(doc_id: str):
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    return d

class DocNameIn(BaseModel):
    name: str

@app.patch("/api/docs/{doc_id}")
def rename_doc(doc_id: str, body: DocNameIn):
    try:
        return db.rename_doc(doc_id, body.name)
    except ValueError as e:
        raise HTTPException(400, str(e))
    except LookupError as e:
        raise HTTPException(404, str(e))

def _export_path(doc_id: str) -> str:
    return os.path.join(EXPORTS, f"{doc_id}_번역.pdf")

def _owned_doc_files(d: dict) -> list[str]:
    doc_id = d["id"]
    if not re.fullmatch(r"[0-9a-f]{10,32}", doc_id):
        raise HTTPException(409, "문서 파일 식별자를 확인할 수 없어 삭제하지 않았습니다")
    pdf = os.path.abspath(os.path.join(DOCS, f"{doc_id}.pdf"))
    paths = [pdf] if os.path.abspath(d["path"]) == pdf else []
    paths.extend(os.path.join(DOCS, name) for name in os.listdir(DOCS)
                 if re.fullmatch(re.escape(doc_id) + r"\.p\d+\.json", name))
    paths.append(_export_path(doc_id))
    for path in paths:
        if os.path.isdir(path) and not os.path.islink(path):
            raise HTTPException(500, "문서 자원 경로에 폴더가 있어 삭제하지 않았습니다")
    return [path for path in paths if os.path.lexists(path)]

@app.delete("/api/docs/{doc_id}")
def delete_doc(doc_id: str):
    return _delete_documents(doc_id=doc_id)

def _delete_documents(*, doc_id=None, folder_id=None):
    with _doc_files_lock:
        moved = []
        try:
            with db.delete_documents(doc_id=doc_id, folder_id=folder_id) as documents:
                deleted_ids = {d["id"] for d in documents}
                for d in documents:
                    for path in _owned_doc_files(d):
                        # 같은 디렉터리의 임시 이름으로 옮겨 DB 실패 시 되돌릴 수 있게 한다.
                        temporary = os.path.join(os.path.dirname(path), f".delete-{uuid.uuid4().hex}-{os.path.basename(path)}")
                        os.replace(path, temporary)
                        moved.append((path, temporary))
        except Exception as error:
            failed = []
            for path, temporary in reversed(moved):
                try: os.replace(temporary, path)
                except OSError: failed.append(temporary)
            if failed:
                raise HTTPException(500, f"삭제를 취소했지만 파일 복원을 완료하지 못했습니다. 보관 위치: {failed[0]}") from error
            if isinstance(error, HTTPException): raise
            if isinstance(error, LookupError): raise HTTPException(404, str(error)) from error
            raise HTTPException(500, "삭제하지 못했습니다. 폴더·문서 기록과 파일은 유지됩니다") from error
        for key in list(_meta_cache):
            if key.split(":", 1)[0] in deleted_ids: del _meta_cache[key]
        for id in deleted_ids: _terms_cache.pop(id, None)
        failed = []
        for _, temporary in moved:
            try: os.remove(temporary)
            except OSError: failed.append(temporary)
        result = {"ok": True}
        if folder_id is not None:
            result["deleted_doc_ids"] = [d["id"] for d in documents]
        if failed:
            result["warning"] = f"문서 기록은 삭제됐지만 파일 정리를 완료하지 못했습니다. 임시 보관 위치: {failed[0]}"
        return result

class SubjectIn(BaseModel):
    subject: str
@app.post("/api/docs/{doc_id}/subject")
def set_subject(doc_id: str, body: SubjectIn):
    try:
        db.set_subject(doc_id, body.subject)
        return {"ok": True}
    except LookupError as e:
        raise HTTPException(404, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))

class DocFolderIn(BaseModel):
    folder_id: str | None

class DocsMoveIn(DocFolderIn):
    doc_ids: list[str]

@app.post("/api/docs/move")
def move_docs_to_folder(body: DocsMoveIn):
    try:
        return {"docs": db.set_folders(body.doc_ids, body.folder_id)}
    except LookupError as e:
        raise HTTPException(404, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))

@app.put("/api/docs/{doc_id}/folder")
def move_doc_to_folder(doc_id: str, body: DocFolderIn):
    try:
        return db.set_folder(doc_id, body.folder_id)
    except LookupError as e:
        raise HTTPException(404, str(e))
    except ValueError as e:
        raise HTTPException(400, str(e))

@app.get("/api/docs/{doc_id}/pages")
def page_sizes_api(doc_id: str, response: Response):
    with _doc_files_lock:
        document = get_doc(doc_id)
        sizes = _pdf_call(pdfx.page_sizes, document["path"])
    response.headers["Cache-Control"] = "max-age=3600"
    return sizes

@app.get("/api/docs/{doc_id}/page/{pno}.png")
def page_png(doc_id: str, pno: int, scale: float = 2.0):
    with _doc_files_lock:
        d = get_doc(doc_id)
        if not 0 <= pno < d["pages"]: raise HTTPException(404, "page")
        try: image = _pdf_call(pdfx.render_page, d["path"], pno, scale)
        except ValueError as error: raise HTTPException(400, str(error)) from error
        return Response(image, media_type="image/png",
                        headers={"Cache-Control": "max-age=3600"})

@app.get("/api/docs/{doc_id}/page/{pno}/meta")
def page_meta_api(doc_id: str, pno: int):
    m = page_meta(doc_id, pno)
    return {"words": m["words"], "sentences": m["sentences"], "w": m["w"], "h": m["h"], "right": m.get("right", m["w"])}

# ---------- 조회 ----------
class LookupIn(BaseModel):
    page: int
    kind: str          # word | sentence
    text: str
    word_ids: list[int] = []

@app.post("/api/docs/{doc_id}/lookup")
async def lookup(doc_id: str, body: LookupIn):
    if body.kind not in ("word", "sentence"): raise HTTPException(400)
    meta = await asyncio.to_thread(page_meta, doc_id, body.page)
    if not body.word_ids or any(i < 0 or i >= len(meta["words"]) for i in body.word_ids):
        raise HTTPException(400, "올바른 단어 범위를 선택하세요")
    text = body.text.strip()
    text = re.sub(r"(\w)-\s+([a-z])", r"\1\2", text)      # 줄바꿈 하이픈 "rep- resent" → represent
    if body.kind == "word":
        text = re.sub(r"^[^\w]+|[^\w]+$", "", text)
    if not text: raise HTTPException(400, "empty")
    engine = llm.selection()
    ex = db.find_lookup(doc_id, body.page, body.kind, text, body.word_ids, engine)
    if ex: return ex
    try:
        lid = await asyncio.to_thread(db.add_lookup, doc_id, body.page, body.kind, text, body.word_ids, engine)
    except LookupError as e:
        raise HTTPException(404, str(e))
    await queue.put(lid)
    result = db.find_lookup(doc_id, body.page, body.kind, text, body.word_ids, engine)
    if not result: raise HTTPException(404, "문서를 찾을 수 없습니다")
    return result

@app.get("/api/docs/{doc_id}/lookups")
def get_lookups(doc_id: str):
    get_doc(doc_id)
    return db.lookups(doc_id)

@app.delete("/api/lookups/{lid}")
def del_lookup(lid: int):
    db.delete_lookup(lid); return {"ok": True}

@app.post("/api/lookups/{lid}/retry")
async def retry_lookup(lid: int):
    def retry():
        with db.conn() as c:
            return c.execute("UPDATE lookups SET status='pending', error=NULL WHERE id=? "
                             "AND EXISTS(SELECT 1 FROM docs WHERE docs.id=lookups.doc_id)", (lid,)).rowcount
    changed = await asyncio.to_thread(retry)
    if not changed: raise HTTPException(404, "조회 기록을 찾을 수 없습니다")
    await queue.put(lid); return {"ok": True}

# ---------- 음성 매칭 ----------
class MatchIn(BaseModel):
    page: int
    transcript: str
@app.post("/api/docs/{doc_id}/match")
def match_api(doc_id: str, body: MatchIn):
    m = page_meta(doc_id, body.page)
    r = matcher.match(body.transcript, m["words"], m["sentences"])
    return r or {}

# ---------- 질문 ----------
class QIn(BaseModel):
    raw: str
    fix: bool = True
    engine: Engine | None = None
@app.post("/api/docs/{doc_id}/questions")
async def add_q(doc_id: str, body: QIn):
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    text = body.raw.strip()
    engine = None
    error = None
    if body.fix and text:
        try:
            engine = llm.validate_engine(body.engine.model_dump()) if body.engine else llm.selection()
        except ValueError as e:
            raise HTTPException(400, str(e))
        terms = await asyncio.to_thread(_doc_terms, doc_id)
        try:
            text = await asyncio.get_event_loop().run_in_executor(pool, llm.fix_transcript, text, terms, d.get("subject") or d["name"], engine)
        except Exception as e:
            error = str(e)[:300]
    try:
        qid = await asyncio.to_thread(db.add_question, doc_id, text, body.raw, engine if not error else None)
    except LookupError as e:
        raise HTTPException(404, str(e))
    return {"id": qid, "text": text, "raw": body.raw, "provider": engine["provider"] if engine and not error else "",
            "model": engine["model"] if engine and not error else "", "error": error,
            "effort": engine["effort"] if engine and not error else "", "fast": engine["fast"] if engine and not error else False}

@app.post("/api/docs/{doc_id}/questions/audio")
async def add_q_audio(doc_id: str, file: UploadFile = File(...), selection: str | None = Form(None)):
    """녹음 시작 때 선택한 모델과 언어로 받아쓴다. 교정은 별도 질문 저장 요청에서 수행한다."""
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    if selection is None:
        chosen = speech_models.settings()
    else:
        try: chosen = STTSettings.model_validate_json(selection).model_dump()
        except (ValidationError, ValueError) as e:
            raise HTTPException(400, "음성 인식 설정을 확인하세요") from e
    if not chosen["model"]:
        raise HTTPException(400, "모델 관리에서 질문 받아쓰기 모델을 선택하세요")
    tmp = os.path.join(DATA, f"q_{uuid.uuid4().hex[:8]}.webm")
    loop = asyncio.get_event_loop()
    try:
        await _finish_file_work(loop.run_in_executor(None, _copy_upload, file.file, tmp))
        terms = await asyncio.to_thread(_doc_terms, doc_id) if chosen["term_hints"] else []
        raw = await _finish_file_work(loop.run_in_executor(pool, stt.transcribe, tmp, terms, chosen))
    except Exception as e:
        get_doc(doc_id)
        code = 404 if isinstance(e, LookupError) else 400 if isinstance(e, ValueError) else 503
        raise HTTPException(code, f"받아쓰기 실패: {str(e)[:180]}") from e
    finally:
        try: os.remove(tmp)
        except OSError: pass
    get_doc(doc_id)
    if not raw: raise HTTPException(400, "들린 말이 없어요")
    return {"raw": raw}

@app.get("/api/stt/status")
def stt_status(): return _speech_action(stt.status_snapshot)

@app.get("/api/docs/{doc_id}/questions")
def get_qs(doc_id: str):
    get_doc(doc_id)
    return db.questions(doc_id)

class QEdit(BaseModel):
    text: str
@app.put("/api/questions/{qid}")
def edit_q(qid: int, body: QEdit):
    if not db.update_question(qid, body.text): raise HTTPException(404, "질문을 찾을 수 없습니다")
    return {"ok": True}
@app.delete("/api/questions/{qid}")
def del_q(qid: int): db.delete_question(qid); return {"ok": True}

@app.get("/api/docs/{doc_id}/questions/prompt")
def q_prompt(doc_id: str):
    d = get_doc(doc_id); qs = db.questions(doc_id)
    tpl = open(os.path.join(PROMPTS, "예습질문-프롬프트.md"), encoding="utf-8").read()
    lst = "\n".join(f"{i+1}. {q['text']}" for i, q in enumerate(qs)) or "(질문 없음)"
    out = tpl.replace("{교안 이름}", d["name"])
    out = re.sub(r"\{질문 목록[^}]*\}", lst, out)
    return {"prompt": out}

@app.get("/api/prompts/summary")
def summary_prompt():
    return {"prompt": open(os.path.join(PROMPTS, "요약-프롬프트.md"), encoding="utf-8").read()}

def _doc_terms(doc_id: str) -> list[str]:
    with _doc_files_lock:
        d = get_doc(doc_id)
        if doc_id not in _terms_cache:
            _terms_cache[doc_id] = _pdf_call(pdfx.document_terms, d["path"])
            if len(_terms_cache) > 32: _terms_cache.popitem(last=False)
        _terms_cache.move_to_end(doc_id)
        return _terms_cache[doc_id]

# ---------- 내보내기 ----------
@app.post("/api/docs/{doc_id}/export")
def export(doc_id: str):
    with _doc_files_lock:
        d = get_doc(doc_id)
        items = [l for l in db.lookups(doc_id) if l["status"] == "done"]
        word_ann = [{"page": l["page"], "word_ids": l["word_ids"], "meaning": l["result"]["meaning"], "text": l["text"]} for l in items if l["kind"] == "word" and l["word_ids"]]
        sent_ann = [{"page": l["page"], "english": l["text"], "korean": l["result"]["translation"], "note": l["result"].get("note", "")} for l in items if l["kind"] == "sentence"]
        metas = {p: page_meta(doc_id, p) for p in {a["page"] for a in word_ann}}
        out = _export_path(doc_id)
        _pdf_call(pdfx.export, d["path"], out, word_ann, sent_ann, metas)
    return {"path": out, "words": len(word_ann), "sentences": len(sent_ann)}

@app.get("/api/docs/{doc_id}/export/download")
def export_dl(doc_id: str):
    with _doc_files_lock:
        d = get_doc(doc_id)
        try: source = open(_export_path(doc_id), "rb")
        except FileNotFoundError: raise HTTPException(404, "먼저 내보내기를 실행하세요") from None
    def chunks():
        with source:
            yield from iter(lambda: source.read(64 * 1024), b"")
    return StreamingResponse(chunks(), media_type="application/pdf", headers={
        "Content-Disposition": "attachment; filename*=UTF-8''" + quote(d["name"] + "_번역.pdf", safe="")})

@app.post("/api/anki")
def anki_export():
    rows = db.all_words()
    words = []
    for r in rows:
        meta = page_meta(r["doc_id"], r["page"]); ctx = ""
        if r["word_ids"] and "s" in meta["words"][r["word_ids"][0]]:
            ctx = meta["sentences"][meta["words"][r["word_ids"][0]]["s"]]["t"]
        words.append({"word": r["text"], "meaning": r["result"]["meaning"], "context": ctx, "subject": r.get("subject") or r["doc_name"]})
    paths = anki.build(words, EXPORTS)
    return {"files": paths, "count": len(words)}

@app.get("/api/vocab")
def vocab():
    return [{"id": r["id"], "word": r["text"], "meaning": r["result"]["meaning"], "subject": r.get("subject") or r["doc_name"], "doc": r["doc_name"], "page": r["page"] + 1} for r in db.all_words()]

@app.middleware("http")
async def _no_cache_static(request, call_next):
    resp = await call_next(request)
    if not request.url.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-cache"
    return resp

app.mount("/", StaticFiles(directory=os.path.join(ROOT, "web", "dist"), html=True, check_dir=False), name="fe")
