# 영한번역 — 영어 교안 예습 도구

아침에 영어 교안을 읽으면서 모르는 단어·문장을 클릭하거나 소리 내어 읽으면 한국어 뜻이 교안 위에 붙고, 끝나면 갤럭시 탭용 PDF로 내보낸다. 기획·평가는 `01-기획-평가.md`.

## 실행
```bash
./run.sh
```
브라우저(Chrome)에서 http://localhost:8766 열기. 음성 인식은 Chrome에서만 된다.

처음 한 번:
```bash
python3 -m pip install fastapi "uvicorn[standard]" rapidfuzz genanki python-multipart pymupdf faster-whisper
```
번역은 `claude -p`(Claude Code 헤드리스, 구독 사용)로 한다. API 키 불필요. 단어·문장 번역 모델은 `YH_MODEL`(기본 haiku), 질문 교정 모델은 `YH_FIX_MODEL`(기본 sonnet).
질문 받아쓰기는 로컬 Whisper(`faster-whisper`). 모델은 `data/models/faster-whisper-large-v3-turbo/`에 있어야 한다. 없으면 `./data/models/download.sh`로 받는다(1.6GB, Hugging Face 자동 다운로드는 자주 멈춰서 미러 이어받기 스크립트를 쓴다). 🎤 읽기는 Chrome 내장 인식 그대로.

## 아침 루틴
1. 홈 → PDF 불러오기(과목명 입력) → "요약 프롬프트 복사" → 클로드 조교에 붙여 요약 받기.
2. 리더에서 읽기. **단어 클릭** = 뜻. **드래그** = 문장 번역(오른쪽 패널). **Alt+클릭** = 그 단어가 든 문장 번역. **🎤 읽기** = 영어로 단어/문장을 소리 내어 읽으면 페이지에서 찾아 같은 처리.
3. **탭용 PDF 내보내기** → `data/exports/<교안>_번역.pdf`. 밑줄+한글이 페이지에 그려지고, 문장 번역은 슬라이드 아래에 붙는다.
4. 2회독하며 **🎤 질문**을 누르고 한국어로 말한 뒤 **다시 눌러 끄면**, 녹음 전체를 로컬 Whisper가 받아쓰고(오디오는 밖으로 안 나감) Sonnet이 교안 용어·LaTeX 수식으로 정리해 질문 하나로 쌓는다. 중간에 쉬어도 안 끊김. **전체 복사(프롬프트)** → 클로드 조교/whisper-note 예습 질문란.
5. 홈 → **Anki 덱 만들기** → `data/exports/<과목>.apkg` → 노트북 Anki에 가져오기 → AnkiWeb 동기화 → 아이폰 Safari로 복습.

## 구조
```
backend/app.py     FastAPI 라우트, 번역 큐(백그라운드 2개)
backend/llm.py     claude -p 호출 (단어 뜻·문장 번역·질문 교정)
backend/pdfx.py    PyMuPDF: 단어 좌표·문장 분리·렌더링·내보내기
backend/match.py   음성 인식 결과 ↔ 페이지 단어/문장 매칭
backend/anki.py    genanki 덱 생성
backend/db.py      SQLite (data/yh.sqlite)
frontend/          index.html, app.js, style.css (빌드 없음)
prompts/           요약·예습질문 프롬프트 템플릿 (홈 복사 버튼이 읽음)
data/              업로드 PDF, 페이지 캐시, 내보낸 파일 (git 제외)
```

## 알아둘 것
- 교재처럼 줄 간격이 빽빽한 본문은 뜻을 줄 밑이 아니라 **오른쪽 여백**에 "단어 뜻" 형태로 쓴다(화면·PDF 모두). 슬라이드는 단어 밑에.
- 줄 끝 하이픈 단어("rep-" / "resent")는 클릭 한 번으로 이어서 조회된다.
- 문장 분리: 슬라이드는 줄 단위(구두점 없이 끝나고 다음 줄이 소문자로 시작하면 이어붙임), 본문은 마침표 단위.
- 한글 폰트는 TTF만 쓴다(AppleGothic / NanumGothic). Pretendard 같은 OTF는 PyMuPDF에서 글리프가 깨진다.
- 8765 포트는 다른 프로젝트 서버가 써서 8766을 쓴다.
- 교안을 다시 올리면 새 문서로 취급된다(변경 병합은 아직 없음).

## 바로가기
바탕화면의 `영한번역.command`를 더블클릭하면 서버를 띄우고 Chrome을 연다(이미 떠 있으면 Chrome만). 터미널 창을 닫으면 서버가 꺼진다. 실체는 `start.sh`.
