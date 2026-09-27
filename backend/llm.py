"""LLM 호출부. Claude Code 헤드리스(`claude -p`)를 기본으로 쓰고,
나중에 API로 바꾸려면 ask() 하나만 교체하면 된다."""
from __future__ import annotations
import json, os, re, subprocess, shutil

CLAUDE = shutil.which("claude") or os.path.expanduser("~/.local/bin/claude")
MODEL = os.environ.get("YH_MODEL", "haiku")
WORKDIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "data")

SYSTEM = (
    "너는 한국 대학생의 영어 전공 교안 읽기를 돕는 번역 보조다. "
    "묻는 것에만 답하고, 설명·인사·머리말을 붙이지 않는다. 한국어로 답한다."
)

def ask(prompt: str, system: str = SYSTEM, timeout: int = 120, model: str | None = None) -> str:
    cmd = [CLAUDE, "-p", "--model", model or MODEL, "--output-format", "text",
           "--no-session-persistence", "--tools", "",
           "--system-prompt", system, prompt]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=WORKDIR)
    if r.returncode != 0:
        raise RuntimeError(f"claude exit {r.returncode}: {r.stderr.strip()[:300]}")
    return r.stdout.strip()

def _json(text: str) -> dict:
    m = re.search(r"\{.*\}", text, re.S)
    return json.loads(m.group(0)) if m else {}

def word_meaning(word: str, sentence: str, page_text: str, subject: str = "") -> dict:
    p = (
        f"과목: {subject or '전공 과목'}\n"
        f"슬라이드 전체 텍스트:\n---\n{page_text[:4000]}\n---\n"
        f"이 슬라이드에서 단어 \"{word}\"가 쓰인 문장: \"{sentence}\"\n\n"
        "이 문맥에서 이 단어의 한국어 뜻을 JSON 한 줄로만 답해.\n"
        '{"meaning": "교안 위에 작게 적을 뜻. 2~8자. 전공 용어면 통용되는 한국어 용어", '
        '"note": "필요할 때만 한 문장 보충. 없으면 빈 문자열"}'
    )
    d = _json(ask(p))
    if not d.get("meaning"):
        raise RuntimeError("no meaning")
    return {"meaning": d["meaning"].strip(), "note": (d.get("note") or "").strip()}

def sentence_translation(sentence: str, page_text: str, subject: str = "") -> dict:
    p = (
        f"과목: {subject or '전공 과목'}\n"
        f"슬라이드 전체 텍스트:\n---\n{page_text[:4000]}\n---\n"
        f"번역할 문장: \"{sentence}\"\n\n"
        "이 문장을 한국어로 번역해. 전공 용어는 한국어 뒤에 영어를 괄호로 붙여. "
        "수식·기호·코드는 그대로 둬. JSON 한 줄로만 답해.\n"
        '{"translation": "번역", "note": "이 문장이 슬라이드에서 하는 역할이나 이해에 필요한 보충. 한 문장. 없으면 빈 문자열"}'
    )
    d = _json(ask(p))
    if not d.get("translation"):
        raise RuntimeError("no translation")
    return {"translation": d["translation"].strip(), "note": (d.get("note") or "").strip()}

def fix_transcript(transcript: str, terms: list[str], subject: str = "") -> str:
    p = (
        f"과목: {subject or '전공 과목'}\n"
        f"교안에 나오는 용어들: {', '.join(terms[:150])}\n\n"
        f"음성 인식 결과: \"{transcript}\"\n\n"
        "학생이 교안을 예습하며 말로 한 질문이다. 다음을 지켜 정리해.\n"
        "- 음성 인식 오류(특히 영어 전공 용어가 한글로 적힌 것)를 위 용어 목록을 참고해 영어 원문으로 고친다.\n"
        "- 말로 읽은 수식·기호·변수는 LaTeX로 적는다. 인라인은 $...$ (예: 'f of n은 g of n 더하기 h of n' → $f(n) = g(n) + h(n)$, '2의 w승' → $2^w$).\n"
        "- 말투와 뜻은 그대로 두고, 군더더기(어, 음, 그러니까)만 빼서 질문 문장으로 자연스럽게 만든다.\n"
        "- 내용을 더하거나 답하지 않는다.\n"
        "고친 문장만 답해. 따옴표·설명 없이."
    )
    return ask(p, model=os.environ.get("YH_FIX_MODEL", "sonnet")).strip().strip('"')
