import json, os, sqlite3, time
DB = os.path.join(os.environ.get("YH_DATA_DIR") or os.path.join(os.path.dirname(os.path.dirname(__file__)), "data"), "yh.sqlite")

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
        """)
        c.execute("BEGIN IMMEDIATE")
        # 기존 조회·질문은 보존하면서 새 요청의 엔진을 기록한다.
        for table in ("lookups", "questions"):
            columns = {r[1] for r in c.execute(f"PRAGMA table_info({table})")}
            for name, definition in (("provider", "TEXT NOT NULL DEFAULT 'claude'"),
                                     ("model", "TEXT NOT NULL DEFAULT 'haiku'" if table == "lookups" else "TEXT NOT NULL DEFAULT 'sonnet'"),
                                     ("effort", "TEXT NOT NULL DEFAULT ''"), ("fast", "INTEGER NOT NULL DEFAULT 0")):
                if name not in columns:
                    c.execute(f"ALTER TABLE {table} ADD COLUMN {name} {definition}")

def add_doc(id, name, subject, path, pages):
    with conn() as c:
        c.execute("INSERT INTO docs VALUES(?,?,?,?,?,?)", (id, name, subject, path, pages, time.time()))

def docs():
    with conn() as c:
        return [dict(r) for r in c.execute("SELECT * FROM docs ORDER BY created DESC")]

def doc(id):
    with conn() as c:
        r = c.execute("SELECT * FROM docs WHERE id=?", (id,)).fetchone()
        return dict(r) if r else None

def set_subject(id, subject):
    with conn() as c: c.execute("UPDATE docs SET subject=? WHERE id=?", (subject, id))

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
