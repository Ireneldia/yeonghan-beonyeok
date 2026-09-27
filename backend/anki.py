import hashlib, os, re
import genanki

MODEL = genanki.Model(
    1607392319, "영한번역 단어",
    fields=[{"name": "Word"}, {"name": "Meaning"}, {"name": "Context"}, {"name": "Subject"}],
    templates=[{
        "name": "Card 1",
        "qfmt": '<div style="font-size:34px;text-align:center;margin-top:40px">{{Word}}</div>'
                '<div style="font-size:13px;color:#888;text-align:center;margin-top:12px">{{Subject}}</div>',
        "afmt": '{{FrontSide}}<hr id="answer">'
                '<div style="font-size:26px;color:#c22;text-align:center">{{Meaning}}</div>'
                '<div style="font-size:14px;color:#555;text-align:center;margin-top:16px;line-height:1.5">{{Context}}</div>',
    }],
    css=".card{font-family:-apple-system,Pretendard,sans-serif;}",
)

def build(words: list[dict], out_dir: str) -> list[str]:
    """words: {word, meaning, context, subject}. 과목별 .apkg 생성, 경로 목록 반환."""
    by_subject: dict[str, dict[str, dict]] = {}
    for w in words:
        key = re.sub(r"[^a-z0-9]+", "", w["word"].lower())
        if not key: continue
        subj = w.get("subject") or "기타"
        by_subject.setdefault(subj, {})
        if key not in by_subject[subj]:
            by_subject[subj][key] = w
    paths = []
    for subj, items in by_subject.items():
        deck_id = int(hashlib.md5(("영한번역::" + subj).encode()).hexdigest()[:8], 16)
        deck = genanki.Deck(deck_id, f"영한번역::{subj}")
        for key, w in items.items():
            guid = genanki.guid_for(subj, key)
            deck.add_note(genanki.Note(model=MODEL, fields=[w["word"], w["meaning"], w.get("context", ""), subj], guid=guid))
        safe = re.sub(r"[^\w가-힣]+", "_", subj)
        p = os.path.join(out_dir, f"{safe}.apkg")
        genanki.Package(deck).write_to_file(p)
        paths.append(p)
    return paths
