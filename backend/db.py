import json, os, sqlite3, time, unicodedata, uuid
from contextlib import contextmanager
DB = os.path.join(os.environ.get("YH_DATA_DIR") or os.path.join(os.path.dirname(os.path.dirname(__file__)), "data"), "yh.sqlite")
_UNSET = object()

def conn():
    c = sqlite3.connect(DB); c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys=ON")
    return c

def init():
    with conn() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS docs(id TEXT PRIMARY KEY, name TEXT, subject TEXT, path TEXT, pages INT, created REAL);
        CREATE TABLE IF NOT EXISTS lookups(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id TEXT, page INT, kind TEXT,
            text TEXT, word_ids TEXT, result TEXT, status TEXT, error TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS questions(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id TEXT, text TEXT, raw TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS folders(id TEXT PRIMARY KEY, name TEXT NOT NULL UNIQUE, created REAL NOT NULL);
        """)
        c.execute("BEGIN IMMEDIATE")
        if "folder_id" not in {r[1] for r in c.execute("PRAGMA table_info(docs)")}:
            # 컬럼 추가와 이관을 한 트랜잭션으로 실행한다. 이후 루트 이동은 다시 이관하지 않는다.
            c.execute("ALTER TABLE docs ADD COLUMN folder_id TEXT REFERENCES folders(id)")
            subjects = [r[0] for r in c.execute("SELECT DISTINCT subject FROM docs WHERE subject IS NOT NULL")]
            for subject in subjects:
                name = subject.strip()
                if name:
                    folder_id, _ = _subject_folder(c, name)
                    c.execute("UPDATE docs SET folder_id=?, subject=? WHERE subject=?", (folder_id, name, subject))
            c.execute("UPDATE docs SET subject='' WHERE folder_id IS NULL")
        # 기존 조회·질문은 보존하면서 새 요청의 엔진을 기록한다.
        for table in ("lookups", "questions"):
            columns = {r[1] for r in c.execute(f"PRAGMA table_info({table})")}
            for name, definition in (("provider", "TEXT NOT NULL DEFAULT 'claude'"),
                                     ("model", "TEXT NOT NULL DEFAULT 'haiku'" if table == "lookups" else "TEXT NOT NULL DEFAULT 'sonnet'"),
                                     ("effort", "TEXT NOT NULL DEFAULT ''"), ("fast", "INTEGER NOT NULL DEFAULT 0")):
                if name not in columns:
                    c.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")

def _folder_name(name):
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > 200 or any(ord(ch) < 32 for ch in name):
        raise ValueError("폴더 이름은 줄바꿈 없이 1~200자로 입력하세요")
    return name.strip()

def _subject_folder(c, subject):
    name = (subject or "").strip()
    if not name:
        return None, ""
    c.execute("INSERT INTO folders(id,name,created) VALUES(?,?,?) ON CONFLICT(name) DO NOTHING",
              (uuid.uuid4().hex, name, time.time()))
    return c.execute("SELECT id,name FROM folders WHERE name=?", (name,)).fetchone()

def _folder_values(c, folder_id):
    if folder_id is None or folder_id == "":
        return None, ""
    row = c.execute("SELECT id,name FROM folders WHERE id=?", (folder_id,)).fetchone()
    if not row:
        raise LookupError("폴더를 찾을 수 없습니다")
    return row

def folders():
    with conn() as c:
        return [dict(r) for r in c.execute("SELECT f.*,COUNT(d.id) AS doc_count FROM folders f "
                                          "LEFT JOIN docs d ON d.folder_id=f.id GROUP BY f.id ORDER BY f.name")]

def create_folder(name):
    name = _folder_name(name)
    with conn() as c:
        row = {"id": uuid.uuid4().hex, "name": name, "created": time.time(), "doc_count": 0}
        c.execute("INSERT INTO folders(id,name,created) VALUES(?,?,?)", (row["id"], name, row["created"]))
        return row

def rename_folder(id, name):
    name = _folder_name(name)
    with conn() as c:
        c.execute("BEGIN IMMEDIATE")
        if not c.execute("UPDATE folders SET name=? WHERE id=?", (name, id)).rowcount:
            raise LookupError("폴더를 찾을 수 없습니다")
        c.execute("UPDATE docs SET subject=? WHERE folder_id=?", (name, id))
        return dict(c.execute("SELECT f.*,(SELECT COUNT(*) FROM docs WHERE folder_id=f.id) AS doc_count "
                              "FROM folders f WHERE f.id=?", (id,)).fetchone())

def add_doc(id, name, subject, path, pages, folder_id=_UNSET):
    with conn() as c:
        c.execute("BEGIN IMMEDIATE")
        if folder_id is _UNSET:
            folder_id, subject = _subject_folder(c, _folder_name(subject) if subject and subject.strip() else "")
        else:
            folder_id, subject = _folder_values(c, folder_id)
        c.execute("INSERT INTO docs(id,name,subject,path,pages,created,folder_id) VALUES(?,?,?,?,?,?,?)",
                  (id, name, subject, path, pages, time.time(), folder_id))

def docs():
    with conn() as c:
        return [dict(r) for r in c.execute("SELECT * FROM docs ORDER BY created DESC")]

def doc(id):
    with conn() as c:
        r = c.execute("SELECT * FROM docs WHERE id=?", (id,)).fetchone()
        return dict(r) if r else None

def rename_doc(id, name):
    if (not isinstance(name, str) or not name.strip() or len(name.strip()) > 200
            or any(unicodedata.category(ch) in ("Cc", "Cs") for ch in name)):
        raise ValueError("교안 이름은 제어문자 없이 1~200자로 입력하세요")
    with conn() as c:
        if not c.execute("UPDATE docs SET name=? WHERE id=?", (name.strip(), id)).rowcount:
            raise LookupError("문서를 찾을 수 없습니다")
        return dict(c.execute("SELECT * FROM docs WHERE id=?", (id,)).fetchone())

@contextmanager
def delete_documents(*, doc_id=None, folder_id=None):
    """선정→파일 임시 이동→기록 삭제 동안 폴더 이동과 새 문서 등록을 직렬화한다."""
    if (doc_id is None) == (folder_id is None):
        raise ValueError("문서 또는 폴더 하나를 지정하세요")
    with conn() as c:
        c.execute("BEGIN IMMEDIATE")
        if folder_id is not None:
            if not c.execute("SELECT id FROM folders WHERE id=?", (folder_id,)).fetchone():
                raise LookupError("폴더를 찾을 수 없습니다")
            rows = c.execute("SELECT * FROM docs WHERE folder_id=? ORDER BY created,id", (folder_id,)).fetchall()
        else:
            rows = c.execute("SELECT * FROM docs WHERE id=?", (doc_id,)).fetchall()
            if not rows: raise LookupError("문서를 찾을 수 없습니다")
        yield [dict(row) for row in rows]
        ids = [(row["id"],) for row in rows]
        for table, column in (("lookups", "doc_id"), ("questions", "doc_id"), ("docs", "id")):
            c.executemany(f"DELETE FROM {table} WHERE {column}=?", ids)
        if folder_id is not None:
            c.execute("DELETE FROM folders WHERE id=?", (folder_id,))

def set_subject(id, subject):
    with conn() as c:
        c.execute("BEGIN IMMEDIATE")
        if not c.execute("SELECT id FROM docs WHERE id=?", (id,)).fetchone():
            raise LookupError("문서를 찾을 수 없습니다")
        folder_id, subject = _subject_folder(c, _folder_name(subject) if subject and subject.strip() else "")
        c.execute("UPDATE docs SET folder_id=?, subject=? WHERE id=?", (folder_id, subject, id))

def set_folders(doc_ids, folder_id):
    if (not isinstance(doc_ids, list) or not 1 <= len(doc_ids) <= 500
            or any(not isinstance(id, str) or not id.strip() for id in doc_ids)):
        raise ValueError("이동할 교안 ID를 1~500개 지정하세요")
    if folder_id is not None and not isinstance(folder_id, str):
        raise ValueError("대상 폴더 ID를 확인하세요")
    # 중복 선택은 한 번만 이동하고, 응답은 처음 선택한 순서를 유지한다.
    ids = list(dict.fromkeys(doc_ids))
    placeholders = ",".join("?" for _ in ids)
    with conn() as c:
        c.execute("BEGIN IMMEDIATE")
        folder_id, subject = _folder_values(c, folder_id)
        found = c.execute(f"SELECT COUNT(*) FROM docs WHERE id IN ({placeholders})", ids).fetchone()[0]
        if found != len(ids):
            raise LookupError("선택한 교안 중 찾을 수 없는 문서가 있습니다")
        c.execute(f"UPDATE docs SET folder_id=?, subject=? WHERE id IN ({placeholders})",
                  [folder_id, subject, *ids])
        rows = {row["id"]: dict(row) for row in c.execute(f"SELECT * FROM docs WHERE id IN ({placeholders})", ids)}
        return [rows[id] for id in ids]

def set_folder(id, folder_id):
    return set_folders([id], folder_id)[0]

def add_lookup(doc_id, page, kind, text, word_ids, engine):
    with conn() as c:
        cur = c.execute("INSERT INTO lookups(doc_id,page,kind,text,word_ids,status,created,provider,model,effort,fast) "
                        "SELECT id,?,?,?,?,'pending',?,?,?,?,? FROM docs WHERE id=?",
                        (page, kind, text, json.dumps(word_ids), time.time(), engine["provider"], engine["model"],
                         engine.get("effort", ""), engine.get("fast", False), doc_id))
        if not cur.rowcount:
            raise LookupError("문서를 찾을 수 없습니다")
        return cur.lastrowid

def find_lookup(doc_id, page, kind, text, word_ids, engine):
    with conn() as c:
        r = c.execute("SELECT * FROM lookups WHERE doc_id=? AND page=? AND kind=? AND text=? AND word_ids=? ORDER BY id DESC LIMIT 1",
                      (doc_id, page, kind, text, json.dumps(word_ids))).fetchone()
        if r and r["status"] != "error" and (r["provider"], r["model"], r["effort"], bool(r["fast"])) == \
                (engine["provider"], engine["model"], engine.get("effort", ""), engine.get("fast", False)):
            return _row(r)

def set_result(id, result=None, error=None):
    with conn() as c:
        if error: c.execute("UPDATE lookups SET status='error', error=? WHERE id=?", (error, id))
        else: c.execute("UPDATE lookups SET status='done', result=? WHERE id=?", (json.dumps(result, ensure_ascii=False), id))

def lookups(doc_id):
    with conn() as c:
        return [_row(r) for r in c.execute(
            "SELECT * FROM lookups WHERE id IN (SELECT MAX(id) FROM lookups WHERE doc_id=? GROUP BY page,kind,text,word_ids) ORDER BY id", (doc_id,))]

def delete_lookup(id):
    with conn() as c:
        c.execute("DELETE FROM lookups WHERE (doc_id,page,kind,text,word_ids) IN "
                  "(SELECT doc_id,page,kind,text,word_ids FROM lookups WHERE id=?)", (id,))

def pending():
    with conn() as c:
        return [_row(r) for r in c.execute("SELECT * FROM lookups WHERE status='pending' ORDER BY id")]

def _row(r):
    if not r: return None
    d = dict(r); d["word_ids"] = json.loads(d["word_ids"] or "[]")
    d["result"] = json.loads(d["result"]) if d.get("result") else None
    d["fast"] = bool(d.get("fast"))
    return d

def add_question(doc_id, text, raw, engine=None):
    engine = engine or {"provider": "", "model": ""}
    with conn() as c:
        cur = c.execute("INSERT INTO questions(doc_id,text,raw,created,provider,model,effort,fast) "
                        "SELECT id,?,?,?,?,?,?,? FROM docs WHERE id=?",
                        (text, raw, time.time(), engine["provider"], engine["model"],
                         engine.get("effort", ""), engine.get("fast", False), doc_id))
        if not cur.rowcount:
            raise LookupError("문서를 찾을 수 없습니다")
        return cur.lastrowid

def questions(doc_id):
    with conn() as c:
        return [dict(r) for r in c.execute("SELECT * FROM questions WHERE doc_id=? ORDER BY id", (doc_id,))]

def update_question(id, text):
    with conn() as c:
        return c.execute("UPDATE questions SET text=? WHERE id=?", (text, id)).rowcount > 0

def delete_question(id):
    with conn() as c: c.execute("DELETE FROM questions WHERE id=?", (id,))

def all_words():
    with conn() as c:
        return [_row(r) for r in c.execute(
            "SELECT l.*, d.subject AS subject, d.name AS doc_name FROM lookups l JOIN docs d ON d.id=l.doc_id "
            "WHERE l.kind='word' AND l.status='done' AND l.id IN "
            "(SELECT MAX(id) FROM lookups GROUP BY doc_id,page,kind,text,word_ids) ORDER BY l.id")]
