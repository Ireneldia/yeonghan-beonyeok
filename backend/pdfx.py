"""PDF 추출·렌더링·내보내기 (PyMuPDF)."""
from __future__ import annotations
import glob, math, os, re
import fitz

META_VERSION = 3
_FONT = None
_FONTOBJ = None
def korean_font() -> str | None:
    """PyMuPDF는 CFF(.otf)에서 글리프가 깨지는 경우가 있어 TTF만 쓴다."""
    global _FONT
    if _FONT is None:
        cands = []
        for d in [os.path.expanduser("~/Library/Fonts"), "/Library/Fonts", "/System/Library/Fonts/Supplemental"]:
            for name in ["NanumGothic.ttf", "NotoSansKR-Regular.ttf", "NotoSansCJKkr-Regular.ttf", "AppleGothic.ttf"]:
                cands += glob.glob(os.path.join(d, name))
        _FONT = cands[0] if cands else ""
    return _FONT or None

def font_obj() -> fitz.Font:
    global _FONTOBJ
    if _FONTOBJ is None:
        f = korean_font()
        _FONTOBJ = fitz.Font(fontfile=f) if f else fitz.Font("korea")
    return _FONTOBJ

_END = re.compile(r"[.?!:;]\s*$")
_TERM = re.compile(r"[.?!]['\")\]]*$")
_ABBR = {"e.g.", "i.e.", "fig.", "eq.", "vs.", "cf.", "etc.", "sec.", "no.", "ch.", "pp."}

def _is_term(word: str) -> bool:
    """단어가 문장 끝인가 (약어·소수점·단일 대문자 제외)"""
    if not _TERM.search(word): return False
    w = word.lower().rstrip("'\")]")
    if w in _ABBR: return False
    if re.fullmatch(r"[a-z]\.", w): return False          # "A." 같은 이니셜
    if re.fullmatch(r"\d+\.\d*", w): return False        # 3.14
    return True

def extract_page(page: fitz.Page) -> dict:
    """단어 박스와 문장 추출. 슬라이드(짧은 줄)는 줄 단위, 본문(긴 줄)은 마침표 단위."""
    import unicodedata
    raw = page.get_text("words")  # x0,y0,x1,y1,word,block,line,wordno
    words = []
    for i, (x0, y0, x1, y1, w, b, l, n) in enumerate(raw):
        w = unicodedata.normalize("NFKC", w)
        words.append({"i": i, "t": w, "x0": x0, "y0": y0, "x1": x1, "y1": y1, "b": b, "l": l})
    # 블록 → 줄 → 단어
    blocks: dict[int, dict[int, list]] = {}
    for w in words:
        blocks.setdefault(w["b"], {}).setdefault(w["l"], []).append(w["i"])
    def line_key(ids): return (min(words[i]["y0"] for i in ids), min(words[i]["x0"] for i in ids))
    sentences: list[dict] = []
    def add(ids):
        if ids:
            t = " ".join(words[i]["t"] for i in ids)
            t = re.sub(r"(\w)-\s+([a-z])", r"\1\2", t)      # 줄바꿈 하이픈 "num- bers" → numbers
            sentences.append({"i": len(sentences), "w": ids, "t": t})
    slide_lines: list[list[int]] = []          # 슬라이드형 블록의 줄들은 모아서 전역 순서로 처리
    for b in sorted(blocks, key=lambda b: min(line_key(ids) for ids in blocks[b].values())):
        lines = [ids for _, ids in sorted(blocks[b].items(), key=lambda kv: line_key(kv[1]))]
        texts = [" ".join(words[i]["t"] for i in ids) for ids in lines]
        avg = sum(len(t) for t in texts) / len(texts)
        terms = sum(1 for ids in lines for i in ids if _is_term(words[i]["t"]))
        if avg > 55 or terms >= 2:                 # 본문(prose): 마침표 단위
            cur = []
            for ids in lines:
                for i in ids:
                    cur.append(i)
                    if _is_term(words[i]["t"]):
                        add(cur); cur = []
            add(cur)
        else:
            slide_lines.extend(lines)
    # 슬라이드: 줄 단위. 앞 줄이 구두점 없이 끝나고 다음 줄이 소문자로 시작하며 바로 아래(줄 높이 2.5배 안)면 이어붙인다 (블록 경계 무시)
    slide_lines.sort(key=line_key)
    def lx0(ids): return min(words[i]["x0"] for i in ids)
    def lx1(ids): return max(words[i]["x1"] for i in ids)
    maxx1 = max((lx1(ids) for ids in slide_lines), default=0)
    cur: list[list[int]] = []
    for ids in slide_lines:
        text = " ".join(words[i]["t"] for i in ids)
        cont = False
        if cur:
            prev_ids = cur[-1]
            prev = " ".join(words[i]["t"] for line in cur for i in line)
            ph = max(words[i]["y1"] for i in prev_ids) - min(words[i]["y0"] for i in prev_ids)
            dy = min(words[i]["y0"] for i in ids) - max(words[i]["y1"] for i in prev_ids)
            # 실측: 진짜 줄바꿈은 앞 줄 x1이 최대 x1의 84~95%, 줄 간격 0.72배. 코드/불릿 줄은 66%, 0.5~1.2배.
            wrapped = lx1(prev_ids) >= 0.8 * maxx1
            cont = wrapped and (not _END.search(prev)) and text[:1].islower() and dy < ph * 1.0 and lx0(ids) >= lx0(prev_ids) - 5
        if not cont:
            add([i for line in cur for i in line]); cur = []
        cur.append(ids)
    add([i for line in cur for i in line])
    for s_ in sentences:
        for i in s_["w"]:
            words[i]["s"] = s_["i"]
    # 줄 끝 하이픈: "rep-" 다음 줄 "resent" → join
    for b, lines_ in blocks.items():
        ordered = [ids for _, ids in sorted(lines_.items(), key=lambda kv: line_key(kv[1]))]
        for k in range(len(ordered) - 1):
            last, first = words[ordered[k][-1]], words[ordered[k + 1][0]]
            if last["t"].endswith("-") and len(last["t"]) > 1 and first["t"][:1].islower():
                last["join"] = first["i"]
    # 선택 영역·읽기 순서는 유지하고 주석에만 보수적인 글자 그리기 경계를 사용한다.
    # bboxlog는 단어보다 큰 text paint operation 단위이므로 교차 영역만 합친다.
    painted = []
    for kind, bounds, *_ in page.get_bboxlog():
        if kind not in ("fill-text", "stroke-text"): continue
        box = fitz.Rect(bounds)
        if not box.is_empty and all(math.isfinite(value) for value in box): painted.append(box)
    for word in words:
        box = fitz.Rect(word["x0"], word["y0"], word["x1"], word["y1"])
        hits = [box & paint for paint in painted if box.intersects(paint)]
        ink = fitz.Rect(hits[0]) if hits else fitz.Rect(box)
        for hit in hits[1:]: ink |= hit
        if ink.is_empty or not all(math.isfinite(value) for value in ink): ink = fitz.Rect(box)
        if page.rotation:
            box *= page.rotation_matrix
            ink *= page.rotation_matrix
        word.update(x0=box.x0, y0=box.y0, x1=box.x1, y1=box.y1,
                    ink=dict(x0=ink.x0, y0=ink.y0, x1=ink.x1, y1=ink.y1))
    # 뜻풀이 여유는 선택용 폰트 line box가 아닌 글자 그리기 영역 사이에서 잰다.
    for w in words:
        ink = w["ink"]
        below = [other["ink"]["y0"] for other in words if other is not w
                 and other["ink"]["y0"] > ink["y1"] - 1
                 and other["ink"]["x1"] > ink["x0"] - 2 and other["ink"]["x0"] < ink["x1"] + 2]
        w["gap"] = round(min(below) - ink["y1"], 3) if below else 99
    right = max((w["x1"] for w in words), default=page.rect.width)
    return {"words": words, "sentences": sentences, "text": page.get_text(),
            "w": page.rect.width, "h": page.rect.height, "right": right}

def render_page(path: str, pno: int, scale: float = 2.0) -> bytes:
    if not math.isfinite(scale) or not 0.5 <= scale <= 4:
        raise ValueError("페이지 배율은 0.5~4 사이여야 합니다")
    with fitz.open(path) as document:
        page = document[pno]
        width, height = page.rect.width, page.rect.height
        limit = min(8192 / width, 8192 / height, math.sqrt(16_000_000 / (width * height)))
        if scale >= limit: scale = limit * 0.999  # 픽셀 반올림까지 포함해 약 16MP 이내로 제한한다.
        pix = page.get_pixmap(matrix=fitz.Matrix(scale, scale), alpha=False)
        return pix.tobytes("png")

def page_metadata(path: str, pno: int) -> dict:
    with fitz.open(path) as document:
        return extract_page(document[pno])

def page_sizes(path: str) -> list[dict]:
    with fitz.open(path) as document:
        return [{"w": page.rect.width, "h": page.rect.height} for page in document]

def document_terms(path: str) -> list[str]:
    terms: dict[str, int] = {}
    with fitz.open(path) as document:
        for page in document:
            for word in re.findall(r"[A-Za-z][A-Za-z\-]{3,}", page.get_text()):
                terms[word] = terms.get(word, 0) + 1
    stop = {"this","that","with","from","then","than","into","when","which","where","there","these","those","have","will","each","also","only","some","such","more","most","other","their","about","between","after","before","while","because"}
    return [term for term, _ in sorted(terms.items(), key=lambda item: -item[1]) if term.lower() not in stop][:150]

RED = (0.85, 0.1, 0.1)

def _annotation_layout(meta: dict, row: list[dict]) -> dict:
    """확대율과 무관한 PDF 단위. 단어 아래에 두고 공간이 부족하면 하단 설명에 보존한다."""
    boxes = [word.get("ink", word) for word in row]
    left, right = min(box["x0"] for box in boxes), max(box["x1"] for box in boxes)
    y0, y1 = min(box["y0"] for box in boxes), max(box["y1"] for box in boxes)
    gap = min(meta["h"] - y1, *(word.get("gap", 99) for word in row))
    size = min(7.5, (gap - 2) / 1.1, (y1 - y0) * 0.5)
    return dict(mode="below" if size >= 4.5 else "note", center=(left + right) / 2,
                top=y1 + 1.5, size=size)

def export(path: str, out: str, word_ann: list[dict], sent_ann: list[dict], pages_meta: dict[int, dict]):
    """word_ann: {page, word_ids, meaning}; sent_ann: {page, english, korean, note}.
    문장 번역이 있는 페이지는 아래로 늘려서 블록을 쓴다."""
    with fitz.open(path) as src, fitz.open() as dst:
        by_page_w: dict[int, list] = {}
        by_page_s: dict[int, list] = {}
        for a in word_ann: by_page_w.setdefault(a["page"], []).append(a)
        for a in sent_ann: by_page_s.setdefault(a["page"], []).append(a)
        for pno in range(len(src)):
            sp = src[pno]; W, H = sp.rect.width, sp.rect.height
            notes = by_page_s.get(pno, [])
            meta = pages_meta.get(pno)
            word_labels = []
            for annotation in by_page_w.get(pno, []):
                if not meta: continue
                words = [meta["words"][i] for i in annotation["word_ids"] if 0 <= i < len(meta["words"])]
                if not words: continue
                first = min(words, key=lambda word: (word["y0"], word["x0"]))
                row = [word for word in words if (word["b"], word["l"]) == (first["b"], first["l"])]
                word_labels.append((annotation, words, _annotation_layout(meta, row)))
            fs = 9
            # 문장 블록: 그릴 문단을 먼저 만들고, 같은 줄바꿈 함수로 높이를 정확히 잰다
            paras: list[tuple[str, float, tuple]] = []
            for n in notes:
                paras.append(("▪ " + n["english"], fs, (0.2, 0.2, 0.2)))
                paras.append(("→ " + n["korean"], fs, RED))
                if n.get("note"):
                    paras.append(("  ※ " + n["note"], fs - 1, (0.4, 0.4, 0.4)))
                paras.append(("", 4, None))                     # 문단 사이 4pt
            # 본문 사방이 빽빽하면 뜻을 겹쳐 그리지 않고 페이지 아래에 보존한다.
            for annotation, words, layout in word_labels:
                if layout["mode"] == "note":
                    paras.append((f"{annotation.get('text') or words[0]['t']}: {annotation['meaning']}", fs, RED))
            extra = 0
            if paras:
                extra = 12 + sum(len(_wrap(t, W - 40, sz)) * sz * 1.45 if col else sz for t, sz, col in paras) + 14
            np_ = dst.new_page(width=W, height=H + extra)
            rotation = sp.rotation
            sp.set_rotation(0)  # 메모리 사본만 변경하며 원본 파일은 저장하지 않는다.
            if sp.get_contents():
                np_.show_pdf_page(fitz.Rect(0, 0, W, H), src, pno, rotate=-rotation)
            for a, ws, layout in word_labels:
                rows: dict[float, list] = {}
                for w in ws:
                    ink = w.get("ink", w)
                    rows.setdefault(round(ink["y1"], 0), []).append(ink)
                for _, r in rows.items():
                    yy = max(w["y1"] for w in r) + 0.5
                    np_.draw_line((min(w["x0"] for w in r), yy), (max(w["x1"] for w in r), yy), color=RED, width=0.8)
                if layout["mode"] == "below":
                    size = layout["size"]
                    width = _measure(a["meaning"], size)
                    if width > W - 4:
                        size *= (W - 4) / width
                        width = W - 4
                    x = max(2, min(W - width - 2, layout["center"] - width / 2))
                    _text(np_, (x, layout["top"] + font_obj().ascender * size), a["meaning"], size)
            if paras:
                y = H + 12
                np_.draw_rect(fitz.Rect(0, H, W, H + extra), color=None, fill=(1, 0.97, 0.95))
                for t, sz, col in paras:
                    if col is None: y += sz; continue
                    y = _para(np_, 20, y, W - 40, t, sz, col)
        dst.save(out, garbage=3, deflate=True)

def _text(page, pt, s, size, color=RED):
    tw = fitz.TextWriter(page.rect)
    tw.append(pt, s, font=font_obj(), fontsize=size)
    tw.write_text(page, color=color)

def _measure(s, size):
    return font_obj().text_length(s, fontsize=size)

def _wrap(s, width, size):
    words, lines, cur = s.split(" "), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if _measure(t, size) > width and cur:
            lines.append(cur); cur = w
        else: cur = t
    if cur: lines.append(cur)
    return lines or [""]

def _para(page, x, y, width, s, size, color):
    for line in _wrap(s, width, size):
        _text(page, (x, y + size), line, size, color)
        y += size * 1.45
    return y
