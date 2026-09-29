from __future__ import annotations
import asyncio, io, json, os, re, shutil, time, uuid
from concurrent.futures import ThreadPoolExecutor
from fastapi import FastAPI, UploadFile, File, Form, HTTPException
from fastapi.responses import FileResponse, Response, JSONResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Literal
import fitz

import db, llm, pdfx, match as matcher, anki, stt, local_models

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.environ.get("YH_DATA_DIR") or os.path.join(ROOT, "data"); DOCS = os.path.join(DATA, "docs"); EXPORTS = os.path.join(DATA, "exports")
PROMPTS = os.path.join(ROOT, "prompts")
for d in (DOCS, EXPORTS): os.makedirs(d, exist_ok=True)
db.init()

app = FastAPI(title="영한번역")
pool = ThreadPoolExecutor(max_workers=3)
_meta_cache: dict[str, dict] = {}

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
def get_llm_models():
    return llm.models()

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

# ---------- 페이지 메타 ----------
def page_meta(doc_id: str, pno: int) -> dict:
    key = f"{doc_id}:{pno}"
    if key not in _meta_cache:
        d = db.doc(doc_id)
        if not d: raise HTTPException(404, "doc")
        cache = os.path.join(DOCS, f"{doc_id}.p{pno}.json")
        if os.path.exists(cache):
            _meta_cache[key] = json.load(open(cache, encoding="utf-8"))
        else:
            with fitz.open(d["path"]) as f:
                if pno < 0 or pno >= len(f): raise HTTPException(404, "page")
                m = pdfx.extract_page(f[pno])
            json.dump(m, open(cache, "w", encoding="utf-8"), ensure_ascii=False)
            _meta_cache[key] = m
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
            meta = page_meta(item["doc_id"], item["page"])
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
            db.set_result(lid, result=res)
        except Exception as e:
            db.set_result(lid, error=str(e)[:300])
        finally:
            queue.task_done()

@app.on_event("startup")
async def _start():
    stt.preload()
    for _ in range(3):
        asyncio.create_task(worker())
    for it in db.pending():
        await queue.put(it["id"])

# ---------- 문서 ----------
@app.get("/api/docs")
def list_docs():
    return db.docs()

@app.post("/api/docs")
async def upload(file: UploadFile = File(...), subject: str = Form("")):
    if not file.filename.lower().endswith(".pdf"): raise HTTPException(400, "PDF만")
    doc_id = uuid.uuid4().hex[:10]
    path = os.path.join(DOCS, f"{doc_id}.pdf")
    with open(path, "wb") as f: shutil.copyfileobj(file.file, f)
    name = re.sub(r"\.pdf$", "", file.filename, flags=re.I)
    db.add_doc(doc_id, name, subject, path, pdfx.page_count(path))
    return db.doc(doc_id)

@app.get("/api/docs/{doc_id}")
def get_doc(doc_id: str):
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    return d

class SubjectIn(BaseModel):
    subject: str
@app.post("/api/docs/{doc_id}/subject")
def set_subject(doc_id: str, body: SubjectIn):
    db.set_subject(doc_id, body.subject.strip()); return {"ok": True}

@app.get("/api/docs/{doc_id}/page/{pno}.png")
def page_png(doc_id: str, pno: int, scale: float = 2.0):
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    return Response(pdfx.render_page(d["path"], pno, scale), media_type="image/png",
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
    meta = page_meta(doc_id, body.page)
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
        lid = db.add_lookup(doc_id, body.page, body.kind, text, body.word_ids, engine)
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
    with db.conn() as c:
        changed = c.execute("UPDATE lookups SET status='pending', error=NULL WHERE id=? "
                            "AND EXISTS(SELECT 1 FROM docs WHERE docs.id=lookups.doc_id)", (lid,)).rowcount
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
        terms = _doc_terms(doc_id)
        try:
            text = await asyncio.get_event_loop().run_in_executor(pool, llm.fix_transcript, text, terms, d.get("subject") or d["name"], engine)
        except Exception as e:
            error = str(e)[:300]
    try:
        qid = db.add_question(doc_id, text, body.raw, engine if not error else None)
    except LookupError as e:
        raise HTTPException(404, str(e))
    return {"id": qid, "text": text, "raw": body.raw, "provider": engine["provider"] if engine and not error else "",
            "model": engine["model"] if engine and not error else "", "error": error,
            "effort": engine["effort"] if engine and not error else "", "fast": engine["fast"] if engine and not error else False}

@app.post("/api/docs/{doc_id}/questions/audio")
async def add_q_audio(doc_id: str, file: UploadFile = File(...)):
    """녹음 파일 → Whisper(한국어) → 교정 → 저장"""
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    tmp = os.path.join(DATA, f"q_{uuid.uuid4().hex[:8]}.webm")
    with open(tmp, "wb") as f: shutil.copyfileobj(file.file, f)
    loop = asyncio.get_event_loop()
    try:
        terms = _doc_terms(doc_id)
        raw = await loop.run_in_executor(pool, stt.transcribe, tmp, terms)
    except Exception as e:
        raise HTTPException(500, f"받아쓰기 실패: {str(e)[:120]}")
    finally:
        try: os.remove(tmp)
        except OSError: pass
    if not raw: raise HTTPException(400, "들린 말이 없어요")
    return {"raw": raw}

@app.get("/api/stt/status")
def stt_status(): return stt.status

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
    d = db.doc(doc_id); terms: dict[str, int] = {}
    with fitz.open(d["path"]) as f:
        for p in f:
            for w in re.findall(r"[A-Za-z][A-Za-z\-]{3,}", p.get_text()):
                terms[w] = terms.get(w, 0) + 1
    stop = {"this","that","with","from","then","than","into","when","which","where","there","these","those","have","will","each","also","only","some","such","more","most","other","their","about","between","after","before","while","because"}
    return [t for t, _ in sorted(terms.items(), key=lambda kv: -kv[1]) if t.lower() not in stop][:150]

# ---------- 내보내기 ----------
@app.post("/api/docs/{doc_id}/export")
def export(doc_id: str):
    d = db.doc(doc_id)
    if not d: raise HTTPException(404)
    items = [l for l in db.lookups(doc_id) if l["status"] == "done"]
    word_ann = [{"page": l["page"], "word_ids": l["word_ids"], "meaning": l["result"]["meaning"], "text": l["text"]} for l in items if l["kind"] == "word" and l["word_ids"]]
    sent_ann = [{"page": l["page"], "english": l["text"], "korean": l["result"]["translation"], "note": l["result"].get("note", "")} for l in items if l["kind"] == "sentence"]
    metas = {p: page_meta(doc_id, p) for p in {a["page"] for a in word_ann}}
    out = os.path.join(EXPORTS, f"{d['name']}_번역.pdf")
    pdfx.export(d["path"], out, word_ann, sent_ann, metas)
    return {"path": out, "words": len(word_ann), "sentences": len(sent_ann)}

@app.get("/api/docs/{doc_id}/export/download")
def export_dl(doc_id: str):
    d = db.doc(doc_id); out = os.path.join(EXPORTS, f"{d['name']}_번역.pdf")
    if not os.path.exists(out): raise HTTPException(404, "먼저 내보내기")
    return FileResponse(out, filename=os.path.basename(out), media_type="application/pdf")

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

app.mount("/", StaticFiles(directory=os.path.join(ROOT, "frontend"), html=True), name="fe")
