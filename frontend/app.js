const $ = s => document.querySelector(s);
const api = async (url, opt = {}) => {
  const r = await fetch(url, { headers: opt.body && !(opt.body instanceof FormData) ? { 'Content-Type': 'application/json' } : {}, ...opt });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).detail || r.statusText);
  return r.json();
};
const toast = (m, ms = 1800) => { const t = $('#toast'); t.textContent = m; t.classList.remove('hidden'); clearTimeout(t._t); t._t = setTimeout(() => t.classList.add('hidden'), ms); };
const copy = async (text, msg = '복사됨') => { await navigator.clipboard.writeText(text); toast(msg); };

// ---------- 상태 ----------
const S = { doc: null, page: 0, meta: null, lookups: [], questions: [], poll: null, drag: null, zoom: 0 }; // zoom 0 = 폭 맞춤

// ---------- 라우팅 ----------
function route() {
  const m = location.hash.match(/^#\/doc\/([^/]+)(?:\/(\d+))?/);
  if (m) openDoc(m[1], m[2] ? parseInt(m[2]) - 1 : 0); else showHome();
}
window.addEventListener('hashchange', route);

// ---------- 홈 ----------
async function showHome() {
  $('#home').classList.remove('hidden'); $('#reader').classList.add('hidden');
  $('#doc-title').textContent = ''; S.doc = null; stopPoll();
  const docs = await api('/api/docs');
  $('#doc-list').innerHTML = docs.map(d => `<li><a href="#/doc/${d.id}">${esc(d.name)}</a> <span class="muted">${esc(d.subject || '')} · ${d.pages}p</span></li>`).join('') || '<li class="muted">아직 없음</li>';
  $('#summary-prompt').textContent = (await api('/api/prompts/summary')).prompt;
  const v = await api('/api/vocab');
  $('#vocab-count').textContent = v.length;
  $('#vocab-table').innerHTML = '<tr><th>단어</th><th>뜻</th><th>과목</th><th>교안</th></tr>' + v.map(x => `<tr><td>${esc(x.word)}</td><td>${esc(x.meaning)}</td><td>${esc(x.subject)}</td><td>${esc(x.doc)} p.${x.page}</td></tr>`).join('');
}
$('#upload-form').onsubmit = async e => {
  e.preventDefault();
  const fd = new FormData(); fd.append('file', $('#file').files[0]); fd.append('subject', $('#subject').value);
  const d = await api('/api/docs', { method: 'POST', body: fd });
  location.hash = `#/doc/${d.id}`;
};
$('#copy-summary').onclick = () => copy($('#summary-prompt').textContent, '요약 프롬프트 복사됨');
$('#anki-export').onclick = async () => {
  const r = await api('/api/anki', { method: 'POST' });
  $('#anki-result').textContent = `${r.count}개 → ${r.files.map(f => f.split('/').pop()).join(', ')} (data/exports)`;
};

// ---------- 리더 ----------
async function openDoc(id, page) {
  $('#home').classList.add('hidden'); $('#reader').classList.remove('hidden');
  if (!S.doc || S.doc.id !== id) {
    S.doc = await api(`/api/docs/${id}`);
    S.lookups = await api(`/api/docs/${id}/lookups`);
    S.questions = await api(`/api/docs/${id}/questions`);
    renderQuestions();
  }
  $('#doc-title').textContent = S.doc.name + (S.doc.subject ? ` · ${S.doc.subject}` : '');
  $('#page-count').textContent = S.doc.pages;
  await gotoPage(Math.max(0, Math.min(page, S.doc.pages - 1)));
  startPoll();
}
async function gotoPage(p) {
  S.page = p; $('#page-input').value = p + 1;
  const img = $('#page-img');
  img.src = `/api/docs/${S.doc.id}/page/${p}.png?scale=${S.zoom > 1.3 ? 3 : 2}`;
  S.meta = await api(`/api/docs/${S.doc.id}/page/${p}/meta`);
  applyZoom();
  if (img.complete) renderOverlay(); else img.onload = renderOverlay;
  history.replaceState(null, '', `#/doc/${S.doc.id}/${p + 1}`);
}
$('#prev').onclick = () => S.page > 0 && gotoPage(S.page - 1);
$('#next').onclick = () => S.page < S.doc.pages - 1 && gotoPage(S.page + 1);
$('#page-input').onchange = e => gotoPage(Math.max(0, Math.min(parseInt(e.target.value) - 1 || 0, S.doc.pages - 1)));
document.addEventListener('keydown', e => {
  if (!S.doc) return;
  if (e.metaKey || e.ctrlKey) {            // ⌘+ / ⌘− / ⌘0 → 브라우저 줌 대신 페이지 줌
    if (e.key === '=' || e.key === '+') { e.preventDefault(); setZoom((S.zoom || 1) * 1.15); }
    else if (e.key === '-') { e.preventDefault(); setZoom((S.zoom || 1) / 1.15); }
    else if (e.key === '0') { e.preventDefault(); setZoom(0); }
    return;
  }
  if (e.target.tagName === 'INPUT') return;
  if (e.key === 'ArrowRight' || e.key === 'PageDown') $('#next').click();
  if (e.key === 'ArrowLeft' || e.key === 'PageUp') $('#prev').click();
});

// ---------- 확대·축소 (페이지만) ----------
function setZoom(z) {
  const wasHi = S.zoom > 1.3;
  S.zoom = z ? Math.max(0.4, Math.min(4, z)) : 0;
  if (S.doc && (S.zoom > 1.3) !== wasHi) { $('#page-img').src = `/api/docs/${S.doc.id}/page/${S.page}.png?scale=${S.zoom > 1.3 ? 3 : 2}`; }
  applyZoom(); renderOverlay();
}
function applyZoom() {
  const img = $('#page-img'), wrap = $('#stage-wrap');
  $('#zoom-label').textContent = S.zoom ? Math.round(S.zoom * 100) + '%' : '맞춤';
  if (!S.zoom) { img.classList.remove('zoomed'); img.style.width = ''; return; }
  img.classList.add('zoomed');
  img.style.width = Math.round((wrap.clientWidth - 2) * S.zoom) + 'px';
}
$('#zoom-in').onclick = () => setZoom((S.zoom || 1) * 1.15);
$('#zoom-out').onclick = () => setZoom((S.zoom || 1) / 1.15);
$('#zoom-fit').onclick = () => setZoom(0);

function pageLookups() { return S.lookups.filter(l => l.page === S.page); }

function renderOverlay() {
  const ov = $('#overlay'), img = $('#page-img'); ov.innerHTML = '';
  if (!S.meta) return;
  const sx = img.clientWidth / S.meta.w, sy = img.clientHeight / S.meta.h;
  const wordAnn = {}, sentWords = new Set(), pendingWords = new Set();
  for (const l of pageLookups()) {
    if (l.kind === 'word') { for (const i of l.word_ids) { if (l.status === 'done') wordAnn[i] = l; else pendingWords.add(i); } }
    else for (const i of l.word_ids) sentWords.add(i);
  }
  for (const w of S.meta.words) {
    const d = document.createElement('div');
    d.className = 'w' + (sentWords.has(w.i) ? ' sent' : '') + (pendingWords.has(w.i) ? ' pending' : '');
    d.dataset.i = w.i;
    Object.assign(d.style, { left: w.x0 * sx + 'px', top: w.y0 * sy + 'px', width: (w.x1 - w.x0) * sx + 'px', height: (w.y1 - w.y0) * sy + 'px' });
    d.title = w.t;
    ov.appendChild(d);
  }
  // 단어 주석: 밑줄 + 작은 한글 (여러 단어 묶음이면 첫 단어부터)
  const drawn = new Set(); const marginRows = {};
  for (const l of pageLookups()) {
    if (l.kind !== 'word' || l.status !== 'done' || drawn.has(l.id)) continue;
    drawn.add(l.id);
    const ws = l.word_ids.map(i => S.meta.words[i]).filter(Boolean); if (!ws.length) continue;
    const rows = {}; for (const w of ws) (rows[Math.round(w.y1)] ||= []).push(w);
    for (const r of Object.values(rows)) {
      const ul = document.createElement('div'); ul.className = 'ul';
      const rx0 = Math.min(...r.map(w => w.x0)), rx1 = Math.max(...r.map(w => w.x1)), ry1 = Math.max(...r.map(w => w.y1));
      Object.assign(ul.style, { left: rx0 * sx + 'px', top: (ry1 + 0.5) * sy + 'px', width: (rx1 - rx0) * sx + 'px' });
      ov.appendChild(ul);
    }
    const first = ws.reduce((a, b) => (b.y0 < a.y0 || (b.y0 === a.y0 && b.x0 < a.x0)) ? b : a);
    const x0 = first.x0, y0 = first.y0, y1 = first.y1;
    const gap = Math.min(...ws.map(w => w.gap ?? 99));
    const t = document.createElement('div'); t.className = 'ann';
    const marginOk = (S.meta.w - (S.meta.right ?? S.meta.w)) >= 40;
    if (gap < 4 && marginOk) {   // 빽빽한 본문: 오른쪽 여백에
      const key = Math.round(y1); const prev = marginRows[key];
      const label = l.text + ' ' + l.result.meaning;
      if (prev) { prev.textContent += ' · ' + label; continue; }
      t.textContent = label; marginRows[key] = t;
      Object.assign(t.style, { left: ((S.meta.right ?? S.meta.w) + 6) * sx + 'px', top: (y1 - 7) * sy + 'px', fontSize: Math.max(8, 6.5 * sy) + 'px' });
    } else {
      t.textContent = l.result.meaning;
      const fs = Math.max(7, Math.min(13, (y1 - y0) * sy * 0.5, (gap - 1) * sy * 0.9));
      Object.assign(t.style, { left: x0 * sx + 'px', top: (y1 + 1) * sy + 'px', fontSize: fs + 'px' });
    }
    ov.appendChild(t);
  }
  renderSide();
}
window.addEventListener('resize', () => { applyZoom(); renderOverlay(); });

// 클릭 = 단어, 드래그 = 문장(선택 범위)
const ov = $('#overlay');
ov.addEventListener('mousedown', e => { const w = e.target.closest('.w'); if (!w) return; S.drag = { a: +w.dataset.i, b: +w.dataset.i }; markSel(); e.preventDefault(); });
ov.addEventListener('mousemove', e => { if (!S.drag) return; const w = e.target.closest('.w'); if (w) { S.drag.b = +w.dataset.i; markSel(); } });
document.addEventListener('mouseup', async e => {
  if (!S.drag) return;
  const { a, b } = S.drag; S.drag = null;
  ov.querySelectorAll('.sel').forEach(x => x.classList.remove('sel'));
  if (a === b) {
    if (e.altKey) { const w = S.meta.words[a]; if (w.s != null) return lookupSentence(S.meta.sentences[w.s].w); }
    return lookupWord([a]);
  }
  const ids = range(a, b);
  const text = ids.map(i => S.meta.words[i].t).join(' ');
  if (ids.length <= 2) return lookupWord(ids); // 두 단어짜리 용어
  lookupSentence(ids, text);
});
function range(a, b) { const [lo, hi] = a < b ? [a, b] : [b, a]; return Array.from({ length: hi - lo + 1 }, (_, k) => lo + k); }
function markSel() { const ids = new Set(range(S.drag.a, S.drag.b)); ov.querySelectorAll('.w').forEach(x => x.classList.toggle('sel', ids.has(+x.dataset.i))); }

async function lookupWord(ids) {
  if (ids.length === 1 && S.meta.words[ids[0]].join != null) ids = [ids[0], S.meta.words[ids[0]].join];
  const text = ids.map(i => S.meta.words[i].t).join(' ');
  await enqueue({ page: S.page, kind: 'word', text, word_ids: ids });
}
async function lookupSentence(ids, text) {
  text = text || ids.map(i => S.meta.words[i].t).join(' ');
  await enqueue({ page: S.page, kind: 'sentence', text, word_ids: ids });
}
async function enqueue(body) {
  const l = await api(`/api/docs/${S.doc.id}/lookup`, { method: 'POST', body: JSON.stringify(body) });
  if (!S.lookups.find(x => x.id === l.id)) S.lookups.push(l);
  renderOverlay(); startPoll();
}

// ---------- 큐 폴링 ----------
function startPoll() { if (S.poll) return; S.poll = setInterval(pollOnce, 1500); }
function stopPoll() { clearInterval(S.poll); S.poll = null; }
async function pollOnce() {
  if (!S.doc) return stopPoll();
  const pending = S.lookups.filter(l => l.status === 'pending').length;
  $('#queue-status').textContent = pending ? `번역 중 ${pending}건` : '';
  if (!pending) return stopPoll();
  const fresh = await api(`/api/docs/${S.doc.id}/lookups`);
  const changed = fresh.some(f => { const o = S.lookups.find(x => x.id === f.id); return !o || o.status !== f.status; });
  S.lookups = fresh; if (changed) renderOverlay();
}

// ---------- 사이드 ----------
function renderSide() {
  const sents = pageLookups().filter(l => l.kind === 'sentence');
  $('#sent-count').textContent = sents.length ? `(${sents.length})` : '';
  $('#sent-list').innerHTML = sents.map(l => `<li data-id="${l.id}">
      <span class="li-tools"><button data-act="del">✕</button>${l.status === 'error' ? '<button data-act="retry">재시도</button>' : ''}</span>
      <div class="sent-en">${esc(l.text)}</div>
      ${l.status === 'done' ? `<div class="sent-ko">${esc(l.result.translation)}</div>${l.result.note ? `<div class="sent-note">${esc(l.result.note)}</div>` : ''}`
        : l.status === 'error' ? `<div class="err">실패: ${esc(l.error || '')}</div>` : '<div class="muted">번역 중…</div>'}
    </li>`).join('') || '<li class="muted">단어를 드래그하거나 🎤 읽기로 문장을 읽으면 여기 쌓임. (Alt+클릭 = 그 단어가 든 문장)</li>';
  const words = pageLookups().filter(l => l.kind === 'word');
  $('#word-count').textContent = words.length ? `(${words.length})` : '';
  $('#word-list').innerHTML = words.map(l => `<li data-id="${l.id}"><span class="li-tools"><button data-act="del">✕</button>${l.status === 'error' ? '<button data-act="retry">재시도</button>' : ''}</span>
      <b>${esc(l.text)}</b> — ${l.status === 'done' ? `<span class="sent-ko" style="display:inline">${esc(l.result.meaning)}</span>${l.result.note ? `<div class="sent-note">${esc(l.result.note)}</div>` : ''}` : l.status === 'error' ? `<span class="err">실패</span>` : '<span class="muted">…</span>'}</li>`).join('') || '<li class="muted">없음</li>';
}
$('#side').addEventListener('click', async e => {
  const b = e.target.closest('button[data-act]'); if (!b) return;
  const li = b.closest('li'); const id = +li.dataset.id;
  if (li.closest('#q-list')) return; // 질문은 아래에서
  if (b.dataset.act === 'del') { await api(`/api/lookups/${id}`, { method: 'DELETE' }); S.lookups = S.lookups.filter(x => x.id !== id); renderOverlay(); }
  if (b.dataset.act === 'retry') { await api(`/api/lookups/${id}/retry`, { method: 'POST' }); const l = S.lookups.find(x => x.id === id); if (l) l.status = 'pending'; renderOverlay(); startPoll(); }
});

// ---------- 질문 ----------
function renderQuestions() {
  $('#q-count').textContent = S.questions.length ? `(${S.questions.length})` : '';
  $('#q-list').innerHTML = S.questions.map(q => q.fixing
    ? `<li class="fixing"><span class="q-text"><span class="spin"></span> ${esc(q.stage || '용어 정리 중… (8~15초)')}</span>${q.raw ? `<span class="q-raw">${esc(q.raw)}</span>` : ''}</li>`
    : `<li data-id="${q.id}"><span class="li-tools"><button data-act="qedit">수정</button><button data-act="qdel">✕</button></span>
      <span class="q-text">${esc(q.text)}</span>${q.raw && q.raw !== q.text ? `<span class="q-raw">원문: ${esc(q.raw)}</span>` : ''}</li>`).join('')
    || '<li class="muted">🎤 질문 버튼으로 말하거나 타자로 추가</li>';
}
async function addQuestion(raw, fix = true) {
  $('#side details:nth-of-type(3)').open = true;
  const tmp = { fixing: fix, raw, text: raw, id: -Date.now() };
  S.questions.push(tmp); renderQuestions();
  if (fix) $('#mic-status').textContent = '✍️ 용어 정리 중…';
  try {
    const q = await api(`/api/docs/${S.doc.id}/questions`, { method: 'POST', body: JSON.stringify({ raw, fix }) });
    Object.assign(tmp, q, { fixing: false });
  } catch (e) {
    S.questions = S.questions.filter(x => x !== tmp); toast('질문 저장 실패: ' + e.message, 3000);
  }
  renderQuestions();
  if (fix && !rec) $('#mic-status').textContent = '';
}
$('#q-add').onclick = () => { const v = $('#q-input').value.trim(); if (v) { addQuestion(v, false); $('#q-input').value = ''; } };
$('#q-input').onkeydown = e => { if (e.key === 'Enter') $('#q-add').click(); };
$('#q-copy').onclick = async () => { const r = await api(`/api/docs/${S.doc.id}/questions/prompt`); copy(r.prompt, '질문 프롬프트 복사됨'); };
$('#q-list').addEventListener('click', async e => {
  const b = e.target.closest('button[data-act]'); if (!b) return;
  const id = +b.closest('li').dataset.id; const q = S.questions.find(x => x.id === id);
  if (b.dataset.act === 'qdel') { await api(`/api/questions/${id}`, { method: 'DELETE' }); S.questions = S.questions.filter(x => x.id !== id); renderQuestions(); }
  if (b.dataset.act === 'qedit') { const t = prompt('질문 수정', q.text); if (t != null) { await api(`/api/questions/${id}`, { method: 'PUT', body: JSON.stringify({ text: t }) }); q.text = t; renderQuestions(); } }
});

// ---------- 음성 ----------
const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
let rec = null, recMode = null, askBuf = [], userStopped = false, askInterim = '';
function micToggle(mode) {
  if (mode === 'ask') return askToggle();
  if (!SR) return toast('이 브라우저는 음성 인식을 지원하지 않아요. Chrome을 쓰세요.', 3000);
  if (rec) { userStopped = true; rec.stop(); return; }   // 다시 누르면 종료
  recMode = mode; askBuf = []; askInterim = ''; userStopped = false;
  startRec();
}

// ---------- 질문: 누르고 → 말하고 → 다시 눌러 끄면 통째로 Whisper 받아쓰기 → sonnet 교정 ----------
let recorder = null, recTimer = null, recStart = 0;
async function askToggle() {
  if (recorder) { recorder.stop(); return; }
  let stream;
  try { stream = await navigator.mediaDevices.getUserMedia({ audio: true }); }
  catch (e) { return toast('마이크를 쓸 수 없어요: ' + e.message, 3000); }
  const chunks = [];
  recorder = new MediaRecorder(stream, { mimeType: MediaRecorder.isTypeSupported('audio/webm;codecs=opus') ? 'audio/webm;codecs=opus' : 'audio/webm' });
  recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data); };
  recorder.onstop = () => {
    stream.getTracks().forEach(t => t.stop()); clearInterval(recTimer); recorder = null;
    $('#mic-ask').classList.remove('on'); $('#mic-status').textContent = '';
    askFlow(new Blob(chunks, { type: 'audio/webm' }));
  };
  recorder.start(250); recStart = Date.now();
  $('#mic-ask').classList.add('on');
  const tick = () => { const s = Math.floor((Date.now() - recStart) / 1000); $('#mic-status').textContent = `● 녹음 중 ${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')} — 다 말했으면 다시 눌러`; };
  tick(); recTimer = setInterval(tick, 500);
}
async function askFlow(blob) {
  $('#side details:nth-of-type(3)').open = true;
  const tmp = { fixing: true, stage: '받아쓰는 중… (Whisper, 몇 초)', raw: '', text: '', id: -Date.now() };
  S.questions.push(tmp); renderQuestions();
  $('#mic-status').textContent = '✍️ 받아쓰는 중…';
  try {
    const fd = new FormData(); fd.append('file', blob, 'q.webm');
    const r = await api(`/api/docs/${S.doc.id}/questions/audio`, { method: 'POST', body: fd });
    tmp.raw = r.raw; tmp.stage = '용어·수식 정리 중… (sonnet, 10~20초)'; renderQuestions();
    $('#mic-status').textContent = '✍️ 용어·수식 정리 중…';
    const q = await api(`/api/docs/${S.doc.id}/questions`, { method: 'POST', body: JSON.stringify({ raw: r.raw, fix: true }) });
    Object.assign(tmp, q, { fixing: false });
  } catch (e) {
    S.questions = S.questions.filter(x => x !== tmp); toast('질문 실패: ' + e.message, 4000);
  }
  renderQuestions(); $('#mic-status').textContent = '';
}
function startRec() {
  rec = new SR();
  rec.lang = recMode === 'read' ? 'en-US' : 'ko-KR'; rec.continuous = true; rec.interimResults = true;
  const btn = $(recMode === 'read' ? '#mic-read' : '#mic-ask'); btn.classList.add('on');
  $('#mic-status').textContent = recMode === 'read' ? '듣는 중 (영어: 단어 또는 문장)' : '질문 듣는 중… 다 말했으면 버튼을 다시 눌러';
  rec.onresult = e => {
    let interim = '';
    for (let i = e.resultIndex; i < e.results.length; i++) {
      const r = e.results[i]; const text = r[0].transcript.trim();
      if (recMode === 'read') {
        $('#mic-status').textContent = (r.isFinal ? '✓ ' : '… ') + text;
        if (r.isFinal && text) onRead(text);
      } else {
        if (r.isFinal) { if (text) askBuf.push(text); askInterim = ''; } else { interim += (interim ? ' ' : '') + text; }
      }
    }
    if (recMode === 'ask') { askInterim = interim; $('#mic-status').textContent = '🎙 ' + [...askBuf, interim].filter(Boolean).join(' '); }
  };
  rec.onerror = e => { if (e.error !== 'no-speech' && e.error !== 'aborted') toast('음성 오류: ' + e.error); };
  rec.onend = () => {
    // 세션이 끊길 때 아직 확정 안 된 구절(interim)도 버리지 않고 챙긴다
    if (recMode === 'ask' && askInterim) { askBuf.push(askInterim); askInterim = ''; }
    // 질문 모드: 브라우저가 침묵 때문에 스스로 끊으면 계속 듣고, 내가 끈 것이면 한 질문으로 제출
    if (recMode === 'ask' && !userStopped) { try { startRec(); return; } catch (_) {} }
    btn.classList.remove('on'); rec = null; $('#mic-status').textContent = '';
    if (recMode === 'ask') {
      const q = askBuf.join(' ').trim(); askBuf = [];
      if (q) addQuestion(q, true); else toast('들린 말이 없어요');
    }
    recMode = null;
  };
  rec.start();
}
$('#mic-read').onclick = () => micToggle('read');
$('#mic-ask').onclick = () => micToggle('ask');
async function onRead(text) {
  const m = await api(`/api/docs/${S.doc.id}/match`, { method: 'POST', body: JSON.stringify({ page: S.page, transcript: text }) });
  if (!m.kind) return toast(`이 페이지에서 못 찾음: "${text}"`, 2500);
  flash(m.word_ids);
  if (m.kind === 'word') lookupWord(m.word_ids); else lookupSentence(m.word_ids, m.text);
}
function flash(ids) { const set = new Set(ids); ov.querySelectorAll('.w').forEach(x => { if (set.has(+x.dataset.i)) { x.classList.add('flash'); setTimeout(() => x.classList.remove('flash'), 1200); } }); }

// ---------- 내보내기 ----------
$('#export').onclick = async () => {
  const pending = S.lookups.filter(l => l.status === 'pending').length;
  if (pending && !confirm(`아직 번역 중인 항목이 ${pending}건 있어요. 그래도 내보낼까요?`)) return;
  $('#export').disabled = true; $('#export').textContent = '만드는 중…';
  try {
    const r = await api(`/api/docs/${S.doc.id}/export`, { method: 'POST' });
    toast(`완료: 단어 ${r.words}, 문장 ${r.sentences}`);
    const a = $('#export-dl'); a.href = `/api/docs/${S.doc.id}/export/download`; a.classList.remove('hidden');
  } catch (e) { toast('실패: ' + e.message, 3000); }
  $('#export').disabled = false; $('#export').textContent = '탭용 PDF 내보내기';
};

function esc(s) { return String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c])); }
route();
