"""음성 인식 결과를 현재 페이지의 단어·문장과 맞춘다."""
from __future__ import annotations
import re
from rapidfuzz import fuzz, process
from rapidfuzz.distance import Levenshtein

def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", " ", s.lower()).strip()

def _tokens(s: str) -> list[str]:
    return [t for t in _norm(s).split() if t]

def match(transcript: str, words: list[dict], sentences: list[dict]) -> dict | None:
    """반환: {"kind": "word"|"sentence", "word_ids": [...], "text": str, "score": float}"""
    toks = _tokens(transcript)
    if not toks:
        return None
    page_words = [(w["i"], _norm(w["t"])) for w in words if _norm(w["t"])]
    if not page_words:
        return None
    # 문장 후보: 토큰이 3개 이상이면 문장 우선
    if len(toks) >= 3 and sentences:
        best, best_score = None, 0.0
        q = " ".join(toks)
        for s in sentences:
            st = _norm(s["t"])
            if not st: continue
            sc = fuzz.token_set_ratio(q, st) / 100.0
            # 짧은 문장이 긴 발화에 부분 매칭되는 걸 억제
            ratio = min(len(_tokens(st)), len(toks)) / max(len(_tokens(st)), len(toks))
            sc = sc * (0.6 + 0.4 * ratio)
            if sc > best_score:
                best, best_score = s, sc
        if best and best_score >= 0.55:
            return {"kind": "sentence", "word_ids": best["w"], "text": best["t"], "score": round(best_score, 2)}
    # 단어 후보: 발화의 각 토큰을 페이지 단어와 맞춰 가장 좋은 것
    # 페이지 단어를 하위 토큰으로도 펼친다 ("breadth-first" → "breadth", "first")
    choices: dict[int, str] = {}
    for i, t in page_words:
        choices[i] = t
        for k, sub in enumerate(t.split()):
            if len(sub) >= 3: choices[i + 100000 * (k + 1)] = sub
    best = None
    for tok in toks:
        if len(tok) < 3: continue
        r = process.extractOne(tok, choices, scorer=Levenshtein.normalized_similarity)
        if r and (best is None or r[1] > best[1]):
            best = r
    if best and best[1] >= 0.6:
        wid = best[2] % 100000
        return {"kind": "word", "word_ids": [wid], "text": words[wid]["t"], "score": round(best[1], 2)}
    return None
