import json, os, sqlite3, time
DB = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data", "yh.sqlite")

def conn():
    c = sqlite3.connect(DB); c.row_factory = sqlite3.Row
    return c

def init():
    with conn() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS docs(id TEXT PRIMARY KEY, name TEXT, subject TEXT, path TEXT, pages INT, created REAL);
        CREATE TABLE IF NOT EXISTS lookups(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id TEXT, page INT, kind TEXT,
            text TEXT, word_ids TEXT, result TEXT, status TEXT, error TEXT, created REAL);
        CREATE TABLE IF NOT EXISTS questions(id INTEGER PRIMARY KEY AUTOINCREMENT, doc_id TEXT, text TEXT, raw TEXT, created REAL);
        """)

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

def add_lookup(doc_id, page, kind, text, word_ids):
    with conn() as c:
        cur = c.execute("INSERT INTO lookups(doc_id,page,kind,text,word_ids,status,created) VALUES(?,?,?,?,?,'pending',?)",
                        (doc_id, page, kind, text, json.dumps(word_ids), time.time()))
        return cur.lastrowid

def find_lookup(doc_id, page, kind, text):
    with conn() as c:
        r = c.execute("SELECT * FROM lookups WHERE doc_id=? AND page=? AND kind=? AND text=? AND status!='error'",
                      (doc_id, page, kind, text)).fetchone()
        return _row(r)

def set_result(id, result=None, error=None):
    with conn() as c:
        if error: c.execute("UPDATE lookups SET status='error', error=? WHERE id=?", (error, id))
        else: c.execute("UPDATE lookups SET status='done', result=? WHERE id=?", (json.dumps(result, ensure_ascii=False), id))

def lookups(doc_id):
    with conn() as c:
        return [_row(r) for r in c.execute("SELECT * FROM lookups WHERE doc_id=? ORDER BY id", (doc_id,))]

def delete_lookup(id):
    with conn() as c: c.execute("DELETE FROM lookups WHERE id=?", (id,))

def pending():
    with conn() as c:
        return [_row(r) for r in c.execute("SELECT * FROM lookups WHERE status='pending' ORDER BY id")]

def _row(r):
    if not r: return None
    d = dict(r); d["word_ids"] = json.loads(d["word_ids"] or "[]")
    d["result"] = json.loads(d["result"]) if d.get("result") else None
    return d

def add_question(doc_id, text, raw):
    with conn() as c:
        cur = c.execute("INSERT INTO questions(doc_id,text,raw,created) VALUES(?,?,?,?)", (doc_id, text, raw, time.time()))
        return cur.lastrowid

def questions(doc_id):
    with conn() as c:
        return [dict(r) for r in c.execute("SELECT * FROM questions WHERE doc_id=? ORDER BY id", (doc_id,))]

def update_question(id, text):
    with conn() as c: c.execute("UPDATE questions SET text=? WHERE id=?", (text, id))

def delete_question(id):
    with conn() as c: c.execute("DELETE FROM questions WHERE id=?", (id,))

def all_words():
    with conn() as c:
        return [_row(r) for r in c.execute(
            "SELECT l.*, d.subject AS subject, d.name AS doc_name FROM lookups l JOIN docs d ON d.id=l.doc_id WHERE l.kind='word' AND l.status='done' ORDER BY l.id")]
