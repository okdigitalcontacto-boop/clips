// Clips para Windows · © 2026 OK Digital. Todos los derechos reservados.
'use strict';

// MARK: - Iconos (trazos propios, sin archivos)
const P = {
  link: '<path d="M10 13a5 5 0 0 0 7.1 0l3-3a5 5 0 0 0-7.1-7.1l-1.2 1.2"/><path d="M14 11a5 5 0 0 0-7.1 0l-3 3a5 5 0 0 0 7.1 7.1l1.2-1.2"/>',
  drop: '<circle cx="12" cy="12" r="9.5"/><path d="M12 7v9M8 12.5l4 4 4-4"/>',
  scissors: '<circle cx="6" cy="6" r="3"/><circle cx="6" cy="18" r="3"/><path d="M20 4 8.1 15.9M14.5 14.5 20 20M8.1 8.1 12 12"/>',
  stop: '<rect x="6" y="6" width="12" height="12" rx="2" class="f"/>',
  x: '<circle cx="12" cy="12" r="10" class="f"/><path d="m9 9 6 6m0-6-6 6" style="stroke:var(--bg);stroke-width:2.2"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  minus: '<path d="M5 12h14" style="stroke-width:3"/>', plus: '<path d="M12 5v14M5 12h14" style="stroke-width:3"/>',
  captions: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M7 15h4m3 0h3M7 11h2m3 0h5"/>',
  bubble: '<path d="M21 12a8 8 0 0 1-11.6 7.1L4 20.5l1.4-4.7A8 8 0 1 1 21 12z"/><path d="M8.5 10.5h7m-7 3h4"/>',
  music: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  info: '<circle cx="12" cy="12" r="9.5"/><path d="M12 11v5.5M12 7.6v.1"/>',
  warn: '<path d="M10.3 3.9 1.8 18.4A2 2 0 0 0 3.5 21.4h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z" class="f"/><path d="M12 9v4.5M12 17.2v.1" style="stroke:#fff;stroke-width:2.4"/>',
  play: '<path d="M7 4.5v15l12.5-7.5z" class="f"/>',
  playc: '<circle cx="12" cy="12" r="11" style="fill:rgba(0,0,0,.35);stroke:none"/><path d="M9.6 7.4v9.2l7.4-4.6z" style="fill:#fff;stroke:none"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2.5"/><path d="M5 15H4.5A1.5 1.5 0 0 1 3 13.5v-9A1.5 1.5 0 0 1 4.5 3h9A1.5 1.5 0 0 1 15 4.5V5"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5" style="stroke-width:2.6"/>',
  folder: '<path d="M3 7.5A2.5 2.5 0 0 1 5.5 5H9l2 2.5h7.5A2.5 2.5 0 0 1 21 10v7.5a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 17.5z"/>',
  upload: '<path d="M12 15V3m-4.5 4.5L12 3l4.5 4.5"/><path d="M8 10H6a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-7a2 2 0 0 0-2-2h-2"/>',
  clock: '<circle cx="12" cy="12" r="9.5"/><path d="M12 7v5l3 2"/>',
  retry: '<path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/>',
  back: '<path d="M4 12a8 8 0 1 0 2.3-5.7"/><path d="M4 3.5V9h5.5"/>',
  fwd: '<path d="M20 12a8 8 0 1 1-2.3-5.7"/><path d="M20 3.5V9h-5.5"/>',
  land: '<rect x="3" y="6.5" width="18" height="11" rx="2.5"/>', port: '<rect x="6.5" y="3" width="11" height="18" rx="2.5"/>',
  video: '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M10 9.5v5l4.5-2.5z" class="f"/>',
  quote: '<path d="M4 7h16M4 12h16M4 17h10"/>',
  sparkles: '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8z"/><path d="M19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z"/>',
  key: '<rect x="2.5" y="6" width="19" height="12" rx="2.5"/><path d="M6.5 10h1m3 0h1m3 0h1m3 0h.1M8 14h8"/>',
};
const ic = (n, cls = '') => `<svg class="i ${cls}" viewBox="0 0 24 24">${P[n].replace(/class="f"/g, 'style="fill:currentColor;stroke:none"')}</svg>`;
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function fmt(s, tenths = false) {
  const t = Math.max(0, s || 0), w = Math.floor(t), h = Math.floor(w / 3600), m = Math.floor((w % 3600) / 60), sec = w % 60;
  let r = h > 0 ? `${h}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}` : `${m}:${String(sec).padStart(2, '0')}`;
  if (tenths) r += '.' + Math.floor((t - w) * 10);
  return r;
}

// MARK: - Puente con Python (o datos de muestra si se abre en un navegador)
let api = null;
const call = (name, ...a) => api && api[name] ? api[name](...a) : Promise.resolve(Demo.call(name, ...a));

let S = { clips: [], done: [], curve: [] };   // estado que manda Python
let O = { count: 5, durIdx: 1, vertical: true, subtitles: true, focus: 'Automático', music: true, mood: 'Calma', hook: true,
  durations: [[15, 30], [30, 60], [60, 90]], focuses: ['Automático', 'Tensión', 'Humor', 'Aprendizaje', 'Emoción', 'Polémica'],
  moods: ['Calma', 'Energía'], platforms: {}, outputLabel: 'Vídeos › Clips' };
let hovered = null;

function setOpt(k, v) { O[k] = v; call('set_option', k, v); renderOptions(); }

// MARK: - Barra del enlace
const urlIn = $('url');
function looksInvalid() { const v = urlIn.value.trim(); return v && !/(^|\s|\/\/|\.)(youtube\.com|youtu\.be)/i.test(v); }
function renderInput() {
  const run = !!S.running;
  urlIn.disabled = run;
  if (document.activeElement !== urlIn && S.url && run) urlIn.value = S.url;
  const empty = !urlIn.value.trim();
  $('lead').innerHTML = ic($('bar').classList.contains('drop') ? 'drop' : 'link');
  $('clear').classList.toggle('hidden', empty || run);
  $('paste').classList.toggle('hidden', !empty || run);
  const go = $('go');
  go.className = 'primary' + (run ? ' grey' : '');
  go.innerHTML = run ? `${ic('stop')}Cancelar` : `${ic('scissors')}Sacar clips`;
  go.disabled = !run && empty;
  go.title = run ? 'Cancelar (Esc)' : 'Sacar clips (Ctrl+Intro)';
  const bad = !run && looksInvalid();
  $('bar').classList.toggle('invalid', bad);
  $('invalid').classList.toggle('hidden', !bad);
}
function start() {
  if (S.running || !urlIn.value.trim()) return;
  Sound.play('start');
  S.error = null; renderError();
  call('start', urlIn.value, $('notes').value);
}
function receive(text) {
  if (S.running || !text) return;
  call('is_link', text).then(link => { urlIn.value = link || text.trim(); renderInput(); Sound.play('tick'); });
}
urlIn.addEventListener('input', renderInput);
urlIn.addEventListener('keydown', e => { if (e.key === 'Enter') start(); });
$('go').onclick = () => S.running ? (call('cancel'), Sound.play('tick')) : start();
$('clear').innerHTML = ic('x');
$('clear').onclick = () => { urlIn.value = ''; renderInput(); urlIn.focus(); Sound.play('tick'); };
$('paste').onclick = () => call('clipboard_text').then(receive);
$('gear').innerHTML = ic('gear');
$('gear').onclick = openSettings;

// Arrastrar un enlace desde el navegador a la ventana.
let dragDepth = 0;
document.addEventListener('dragenter', e => { e.preventDefault(); if (++dragDepth === 1 && !S.running) { $('bar').classList.add('drop'); renderInput(); } });
document.addEventListener('dragleave', e => { if (--dragDepth <= 0) { dragDepth = 0; $('bar').classList.remove('drop'); renderInput(); } });
document.addEventListener('dragover', e => e.preventDefault());
document.addEventListener('drop', e => {
  e.preventDefault(); dragDepth = 0; $('bar').classList.remove('drop');
  const d = e.dataTransfer;
  receive(d.getData('text/uri-list') || d.getData('text/plain') || d.getData('URL'));
  renderInput();
});
// Al volver a la ventana, si hay un enlace de YouTube copiado, se pega solo.
function pasteIfYouTube() { if (!S.running && !urlIn.value.trim()) call('clipboard_link').then(l => { if (l && !urlIn.value.trim()) { urlIn.value = l; renderInput(); } }); }
window.addEventListener('focus', pasteIfYouTube);

// MARK: - Opciones
function pills(el, items, value, onPick) {
  if (el.dataset.built !== JSON.stringify(items.map(i => i[1]))) {
    el.innerHTML = '<span class="knob"></span>' + items.map((it, k) => `<button data-k="${k}">${it[2] ? ic(it[2]) : ''}${esc(it[1])}</button>`).join('');
    el.dataset.built = JSON.stringify(items.map(i => i[1]));
    el.querySelectorAll('button').forEach(b => b.onclick = () => {
      const it = items[+b.dataset.k];
      if (it[0] === el._value) return;
      Sound.play('tick'); onPick(it[0]);
    });
  }
  el._value = value;
  const btns = [...el.querySelectorAll('button')];
  const on = btns[items.findIndex(i => i[0] === value)];
  btns.forEach(b => b.classList.toggle('on', b === on));
  const knob = el.querySelector('.knob');
  if (on) requestAnimationFrame(() => { knob.style.width = on.offsetWidth + 'px'; knob.style.transform = `translateX(${on.offsetLeft}px)`; });
}
function chip(el, icon, label, on, key) {
  el.className = 'chip' + (on ? ' on' : '');
  el.innerHTML = ic(icon) + label;
  el.onclick = () => { Sound.play('tick'); setOpt(key, !O[key]); };
}
function renderOptions() {
  const c = $('count');
  c.innerHTML = `<button id="cm" ${O.count <= 1 ? 'disabled' : ''}>${ic('minus')}</button><span class="val"><b>${O.count}</b>${O.count === 1 ? 'clip' : 'clips'}</span><button id="cp" ${O.count >= 10 ? 'disabled' : ''}>${ic('plus')}</button>`;
  $('cm').onclick = () => { Sound.play('tick'); setOpt('count', Math.max(1, O.count - 1)); };
  $('cp').onclick = () => { Sound.play('tick'); setOpt('count', Math.min(10, O.count + 1)); };
  pills($('dur'), O.durations.map((d, i) => [i, `${d[0]}–${d[1]} s`]), O.durIdx, v => setOpt('durIdx', v));
  pills($('orient'), [[false, 'Horizontal', 'land'], [true, 'Vertical', 'port']], O.vertical, v => setOpt('vertical', v));
  chip($('subs'), 'captions', 'Subtítulos', O.subtitles, 'subtitles');
  chip($('hook'), 'bubble', 'Título al inicio', O.hook, 'hook');
  chip($('music'), 'music', 'Música', O.music, 'music');
  $('mood').classList.toggle('hidden', !O.music);
  $('mood').title = O.ownMusic ? 'Usando tu carpeta de música (Ajustes)' : 'Estilo de la música que compone Clips';
  pills($('mood'), O.moods.map(m => [m, m]), O.mood, v => setOpt('mood', v));
  pills($('focus'), O.focuses.map(f => [f, f]), O.focus, v => setOpt('focus', v));
  $('options').classList.toggle('busy', !!S.running);
}
const notes = $('notes');
function fitNotes() { notes.style.height = '18px'; notes.style.height = Math.min(76, notes.scrollHeight) + 'px'; $('notes-clear').classList.toggle('hidden', !notes.value || S.running); }
notes.addEventListener('input', fitNotes);
notes.addEventListener('keydown', e => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); start(); } });
$('notes-clear').innerHTML = ic('x');
$('notes-clear').onclick = () => { notes.value = ''; fitNotes(); Sound.play('tick'); };

// MARK: - Avisos y error
function renderNotice() {
  const n = $('notice');
  n.classList.toggle('hidden', !S.notice || !!S.error);
  if (S.notice) n.innerHTML = ic('info') + esc(S.notice);
}
let lastError = null;
function renderError() {
  const box = $('error'), e = S.error;
  if (!e) { box.innerHTML = ''; lastError = null; return; }
  const key = e.message + S.updatingTools;
  if (key === lastError) return;
  const shake = !lastError || !lastError.startsWith(e.message);
  lastError = key;
  box.innerHTML = `<div class="error">${ic('warn')}<div class="msg">${esc(e.message)}</div><div class="btns">
    ${e.canUpdateTools ? (S.updatingTools ? '<span class="spinner"></span><small style="color:var(--fg2)">Actualizando…</small>' : '<button class="btn" id="upd">Actualizar yt-dlp</button>') : ''}
    ${e.opensSettings ? '<button class="btn" id="eset">Abrir Ajustes</button>' : `<button class="btn" id="eretry" ${S.updatingTools ? 'disabled' : ''}>Reintentar</button>`}
  </div></div>`;
  if (!shake) box.firstChild.style.animation = 'none';
  if ($('upd')) $('upd').onclick = () => call('update_tools');
  if ($('eset')) $('eset').onclick = openSettings;
  if ($('eretry')) $('eretry').onclick = () => { call('dismiss_error'); start(); };
}

// MARK: - Panel del trabajo: vídeo, línea de tiempo y pasos
const STAGES = [['video', 'Vídeo', 'video'], ['text', 'Texto', 'quote'], ['moments', 'Momentos', 'sparkles'], ['clips', 'Clips', 'scissors']];
function stageState(s) {
  if (S.done.includes(s)) return 'done';
  if (S.stage === s) return S.error ? 'failed' : (S.running ? 'active' : 'pending');
  return 'pending';
}
function curvePath(values, closed) {
  if (values.length < 2) return '';
  const W = 1000, H = 66, top = 8, usable = H - 12;
  const pts = values.map((v, i) => [W * i / (values.length - 1), top + usable * (1 - Math.max(0, Math.min(1, v)))]);
  let d = closed ? `M0 ${H} L${pts[0][0]} ${pts[0][1]}` : `M${pts[0][0]} ${pts[0][1]}`;
  for (let i = 1; i < pts.length; i++) {
    const mx = (pts[i - 1][0] + pts[i][0]) / 2, my = (pts[i - 1][1] + pts[i][1]) / 2;
    d += ` Q${pts[i - 1][0]} ${pts[i - 1][1]} ${mx} ${my}`;
  }
  d += ` L${pts[pts.length - 1][0]} ${pts[pts.length - 1][1]}`;
  if (closed) d += ` L${W} ${H} Z`;
  return d;
}
function renderJob() {
  const box = $('job');
  if (!(S.running || S.info)) { box.innerHTML = ''; return; }
  if (!box.firstChild) {
    box.innerHTML = `<div class="job"><div class="head"><div class="thumb shimmer" id="jthumb" style="position:relative;overflow:hidden"></div>
      <div><div class="title" id="jtitle"></div><div class="sub" id="jsub"></div></div></div>
      <div><div class="timeline" id="tl"><svg class="curve" viewBox="0 0 1000 66" preserveAspectRatio="none">
        <defs><linearGradient id="hf" x1="0" x2="1"><stop offset="0" stop-color="#6E6BF0" stop-opacity=".32"/><stop offset="1" stop-color="#FF5C36" stop-opacity=".32"/></linearGradient></defs>
        <path id="cfill" fill="url(#hf)"/><path id="cline" fill="none" stroke="url(#heat)" stroke-width="1.6" vector-effect="non-scaling-stroke" stroke-linecap="round"/></svg>
        <div class="sweep hidden" id="sweep"></div><div id="marks"></div></div>
        <div class="tl-foot"><span id="clabel"></span><span id="ctotal"></span></div></div>
      <div class="stages"><div class="dots" id="dots"></div><div class="detail" id="jdetail"></div><button class="btn hidden" id="openf">${ic('folder')}Abrir carpeta</button></div></div>`;
    $('openf').onclick = () => { call('open_folder'); Sound.play('tick'); };
  }
  const i = S.info;
  const th = $('jthumb');
  if (i && i.thumbnail && th.dataset.src !== i.thumbnail) { th.dataset.src = i.thumbnail; th.style.backgroundImage = `url("${i.thumbnail}")`; th.classList.remove('shimmer'); }
  if (!i) { th.style.backgroundImage = ''; th.dataset.src = ''; th.classList.add('shimmer'); }
  $('jtitle').textContent = i ? i.title : 'Leyendo el vídeo…';
  $('jsub').textContent = i ? [i.channel, fmt(i.duration)].filter(Boolean).join(' · ') : '';
  const key = (S.curve || []).join(',');
  if ($('tl').dataset.curve !== key) {
    $('tl').dataset.curve = key;
    $('cfill').setAttribute('d', curvePath(S.curve || [], true));
    $('cline').setAttribute('d', curvePath(S.curve || [], false));
  }
  $('sweep').classList.toggle('hidden', !S.analyzing);
  const total = Math.max(i ? i.duration : 0, S.words || 0, 1);
  const marks = $('marks'), have = new Set();
  for (const c of S.clips) {
    have.add(c.id);
    let m = marks.querySelector(`[data-id="${c.id}"]`);
    if (!m) {
      m = document.createElement('div'); m.className = 'mark'; m.dataset.id = c.id; marks.appendChild(m);
      m.onmouseenter = () => setHover(c.id); m.onmouseleave = () => setHover(null);
      m.onclick = () => { const cc = S.clips.find(x => x.id === c.id); if (cc && cc.state === 'ready') openDetail(c.id); };
    }
    m.style.left = (c.start / total * 100) + '%';
    m.style.width = `max(5px, ${(c.end - c.start) / total * 100}%)`;
    m.title = c.title;
    m.textContent = m.offsetWidth > 15 || (c.end - c.start) / total * $('tl').offsetWidth > 15 ? c.rank : '';
    m.classList.toggle('hot', hovered === c.id);
  }
  marks.querySelectorAll('.mark').forEach(m => { if (!have.has(m.dataset.id)) m.remove(); });
  $('clabel').textContent = S.curve && S.curve.length ? (S.curveIsHeat ? 'Curva: lo que más repiten los espectadores' : 'Curva: cuánto se habla en cada tramo') : '';
  $('ctotal').textContent = i && i.duration > 0 ? fmt(i.duration) : '';
  $('dots').innerHTML = STAGES.map(([s, label, icon], k) => {
    const st = stageState(s);
    const sym = st === 'done' ? 'check' : st === 'failed' ? 'info' : icon;
    return `<div class="dot ${st}"><span class="c">${ic(sym)}</span><span>${label}</span></div>` +
      (k < STAGES.length - 1 ? `<span class="bar ${S.done.includes(s) ? 'done' : ''}"></span>` : '');
  }).join('');
  $('jdetail').textContent = S.detail || '';
  $('openf').classList.toggle('hidden', !!S.running || !S.readyCount || !S.outDir);
}

// MARK: - Clips
function setHover(id) {
  hovered = id;
  document.querySelectorAll('.mark').forEach(m => m.classList.toggle('hot', m.dataset.id === id));
  document.querySelectorAll('.card').forEach(c => c.classList.toggle('hl', c.dataset.id === id));
}
function ring(score) {
  const r = 13.5, L = 2 * Math.PI * r;
  return `<div class="ring" title="Potencial viral según la IA: ${score} de 100"><svg viewBox="0 0 30 30"><circle class="bg" cx="15" cy="15" r="${r}"/>
    <circle class="fg" cx="15" cy="15" r="${r}" stroke-dasharray="${L}" stroke-dashoffset="${L}" data-to="${L * (1 - score / 100)}"/></svg><b>${score}</b></div>`;
}
function animateRings(root) {
  requestAnimationFrame(() => requestAnimationFrame(() => root.querySelectorAll('.ring .fg[data-to]').forEach(c => { c.style.strokeDashoffset = c.dataset.to; c.removeAttribute('data-to'); })));
}
let openMenu = null;
function closeMenu() { if (openMenu) { openMenu.remove(); document.querySelectorAll('.upload.open').forEach(b => b.classList.remove('open')); openMenu = null; } }
document.addEventListener('pointerdown', e => { if (openMenu && !e.target.closest('.menu') && !e.target.closest('.upload')) closeMenu(); });
function publishMenu(btn, id) {
  if (openMenu) { closeMenu(); return; }
  const m = document.createElement('div');
  m.className = 'menu';
  m.innerHTML = '<div class="cap">El texto se copia y el clip aparece en el Explorador para arrastrarlo</div>' +
    Object.keys(O.platforms).map(p => `<button data-p="${p}" title="${esc(O.platforms[p])}">${p}</button>`).join('');
  m.querySelectorAll('button').forEach(b => b.onclick = () => { call('publish', id, b.dataset.p); Sound.play('copy'); closeMenu(); });
  btn.parentElement.appendChild(m);
  btn.classList.add('open');
  openMenu = m;
}
function copied(btn) {
  btn.innerHTML = ic('check'); btn.classList.add('ok'); Sound.play('copy');
  setTimeout(() => { btn.innerHTML = ic('copy'); btn.classList.remove('ok'); }, 1400);
}
function cardHTML(c) {
  let state = '';
  if (c.state === 'queued') state = `<div class="state">${ic('clock')}En cola</div>`;
  else if (c.state === 'downloading') state = `<div class="state"><div class="progress"><i style="width:${Math.round(c.progress * 100)}%"></i></div>Descargando ${Math.round(c.progress * 100)} %</div>`;
  else if (c.state === 'rendering') state = `<div class="state ${c.thumb ? 'glass' : ''}"><span class="spinner"></span>${c.thumb ? 'Volviendo a montar…' : 'Montando…'}</div>`;
  else if (c.state === 'failed') state = `<div class="state"><span class="warn">${ic('warn')}</span>${esc(c.error)}</div>`;
  const busy = ['queued', 'downloading', 'rendering'].includes(c.state);
  const media = c.thumb
    ? `<div class="blur" style="background-image:url('${c.thumb}')"></div><img src="${c.thumb}" alt="">`
    : `<div class="${busy ? 'shimmer' : ''}" style="position:absolute;inset:0;overflow:hidden"></div>`;
  let actions = '<span style="height:26px"></span>';
  if (c.state === 'ready') {
    actions = `<button class="icon-btn" data-a="play" title="Ver el clip">${ic('play')}</button>
      <button class="icon-btn" data-a="copy" title="Copiar título y texto para redes">${ic('copy')}</button>
      <button class="icon-btn" data-a="reveal" title="Mostrar en el Explorador">${ic('folder')}</button>
      <span class="spacer"></span><div class="menu-wrap"><button class="upload" data-a="upload" title="Subir a YouTube, Instagram o TikTok">${ic('upload')}Subir</button></div>`;
  } else if (c.state === 'failed' && (c.error !== 'Cancelado' || !S.running)) {
    actions = `<button class="btn" data-a="retry" ${S.running && c.error !== 'Cancelado' ? 'disabled' : ''}>${ic('retry')}Reintentar</button>`;
  }
  return `<div class="media">${media}${state}${c.state === 'ready' ? `<span class="play">${ic('playc')}</span>` : ''}
      <span class="rank">${c.rank}</span><span class="len">${Math.round(c.end - c.start)} s</span></div>
    <div class="body"><div class="top"><h4>${esc(c.title)}</h4>${ring(c.score)}</div>
      <div class="times">${fmt(c.start, true)} → ${fmt(c.end, true)}</div>
      <div class="reason">${esc(c.reason)}</div><div class="actions">${actions}</div></div>`;
}
function renderClips() {
  const sec = $('clips');
  sec.classList.toggle('hidden', !S.clips.length);
  $('clips-title').textContent = S.finished ? 'Tus clips' : 'Clips elegidos';
  $('clips-sub').textContent = S.chronological ? 'en el orden del vídeo' : 'ordenados por potencial';
  const all = $('copy-all');
  all.classList.toggle('hidden', !S.readyCount);
  all.innerHTML = ic('copy') + 'Copiar todos los textos';
  all.onclick = () => { call('copy_all'); Sound.play('copy'); };
  const grid = $('grid'), have = new Set();
  S.clips.forEach((c, idx) => {
    have.add(c.id);
    let el = grid.querySelector(`.card[data-id="${c.id}"]`);
    const sig = [c.state, Math.round(c.progress * 100), c.thumb, c.title, c.reason, c.error, c.start, c.end, S.running].join('|');
    if (!el) {
      el = document.createElement('div'); el.className = 'card'; el.dataset.id = c.id;
      el.style.animationDelay = Math.min(idx, 6) * 40 + 'ms';
      el.onmouseenter = () => setHover(c.id); el.onmouseleave = () => setHover(null);
      grid.appendChild(el);
    }
    if (el.dataset.sig !== sig) {
      const keepMenu = openMenu && el.contains(openMenu);
      if (!keepMenu) {
        el.dataset.sig = sig;
        el.innerHTML = cardHTML(c);
        animateRings(el);
        el.querySelector('.media').onclick = () => { if (c.state === 'ready') openDetail(c.id); };
        el.querySelectorAll('[data-a]').forEach(b => b.onclick = ev => {
          ev.stopPropagation();
          const a = b.dataset.a;
          if (a === 'play') openDetail(c.id);
          if (a === 'copy') { call('copy_caption', c.id); copied(b); }
          if (a === 'reveal') { call('reveal', c.id); Sound.play('tick'); }
          if (a === 'upload') publishMenu(b, c.id);
          if (a === 'retry') { call('retry', c.id); Sound.play('tick'); }
        });
      }
    }
    el.classList.toggle('hl', hovered === c.id);
    if (grid.children[idx] !== el) grid.insertBefore(el, grid.children[idx]);
  });
  grid.querySelectorAll('.card').forEach(el => { if (!have.has(el.dataset.id)) el.remove(); });
}
function renderEmpty() {
  const show = !S.clips.length && !S.running && !S.info && !S.error;
  const e = $('empty');
  e.classList.toggle('hidden', !show);
  if (show && !e.firstChild) {
    let holes = '';
    for (let i = 0; i < 18; i++) { const x = (i + 0.5) * 260 / 18 - 3; holes += `<rect x="${x}" y="5" width="6" height="5" rx="1.5"/><rect x="${x}" y="44" width="6" height="5" rx="1.5"/>`; }
    e.innerHTML = `<svg width="260" height="54" style="opacity:.55"><rect width="260" height="54" rx="8" fill="currentColor" opacity=".12"/>
      <g fill="currentColor" opacity=".22">${holes}</g><rect x="145.6" width="52" height="54" rx="6" fill="#FF5C36" opacity=".85"/></svg>
      <div><h3>Pega un enlace y elige cuántos clips quieres.</h3><p>Clips lee lo que se dice, encuentra los momentos con más gancho y te los da montados.</p></div>
      <div class="tips"><span>${ic('drop')}Arrastra un enlace a la ventana</span><span>${ic('key')}Ctrl+Intro para empezar</span><span id="outlabel"></span></div>`;
  }
  if ($('outlabel')) $('outlabel').innerHTML = ic('folder') + 'Se guardan en ' + esc(O.outputLabel);
}

// MARK: - Detalle de un clip: verlo y retocarlo
let detail = null;
function closeSheet() {
  const s = $('sheet').firstChild;
  if (!s) return;
  const v = s.querySelector('video');
  if (v) { v.pause(); v.removeAttribute('src'); v.load(); }
  s.classList.add('closing');
  setTimeout(() => { $('sheet').innerHTML = ''; detail = null; }, 190);
}
function sheet(html, cls = '') {
  $('sheet').innerHTML = `<div class="scrim"><div class="sheet ${cls}">${html}</div></div>`;
  $('sheet').firstChild.addEventListener('pointerdown', e => { if (e.target.classList.contains('scrim')) closeSheet(); });
  return $('sheet').firstChild.firstChild;
}
function openDetail(id) {
  const c = S.clips.find(x => x.id === id);
  if (!c) return;
  Sound.play('tick');
  detail = { id, start: c.start, end: c.end, version: -1 };
  const el = sheet(`<div class="player"><video controls playsinline></video><div class="busy hidden"><span class="spinner"></span>Volviendo a montar…</div></div>
    <div class="d-head"><div style="flex:1"><h3 id="dtitle"></h3><p id="dreason"></p></div><span id="dring"></span></div>
    <div class="caption-box" id="dcap"><div class="sel" id="dcaptext"></div><button class="icon-btn" id="dcopy" title="Copiar texto para redes">${ic('copy')}</button></div>
    <div class="trim-row">
      <div class="trim">Inicio <span class="box"><button data-t="s-" title="Medio segundo antes">${ic('back')}</button><span id="ds"></span><button data-t="s+" title="Medio segundo después">${ic('fwd')}</button></span></div>
      <div class="trim">Final <span class="box"><button data-t="e-" title="Medio segundo antes">${ic('back')}</button><span id="de"></span><button data-t="e+" title="Medio segundo después">${ic('fwd')}</button></span></div>
      <span class="secs" id="dlen"></span><span class="spacer"></span>
      <button class="btn hidden" id="dundo">Deshacer</button>
      <button class="primary hidden" id="dredo">${ic('scissors')}Volver a montar</button>
    </div>
    <div class="d-foot"><button class="btn" id="dreveal">${ic('folder')}Mostrar en el Explorador</button><span class="spacer"></span>
      <span id="dpub" style="display:flex;gap:8px"></span><span style="width:6px"></span><button class="btn" id="dclose">Cerrar</button></div>`);
  el.querySelectorAll('[data-t]').forEach(b => b.onclick = () => {
    const cc = S.clips.find(x => x.id === id), total = S.info && S.info.duration > 0 ? S.info.duration : detail.end + 60;
    const t = b.dataset.t, d = t.endsWith('+') ? 0.5 : -0.5;
    let v;
    if (t[0] === 's') { v = Math.min(detail.end - 1, Math.max(Math.max(0, detail.end - 180), detail.start + d)); if (v === detail.start) return; detail.start = v; }
    else { v = Math.min(total, Math.max(detail.start + 1, detail.end + d)); if (v === detail.end) return; detail.end = v; }
    Sound.play('tick'); renderDetail();
  });
  $('dundo').onclick = () => { const cc = S.clips.find(x => x.id === id); detail.start = cc.start; detail.end = cc.end; renderDetail(); };
  $('dredo').onclick = () => {
    const v = el.querySelector('video'); v.pause(); v.removeAttribute('src'); v.load();  // suelta el archivo para poder sustituirlo
    call('retrim', id, detail.start, detail.end); Sound.play('tick');
  };
  $('dcopy').onclick = () => { call('copy_caption', id); copied($('dcopy')); };
  $('dreveal').onclick = () => call('reveal', id);
  $('dclose').onclick = closeSheet;
  renderDetail();
}
function renderDetail() {
  if (!detail) return;
  const c = S.clips.find(x => x.id === detail.id);
  if (!c) { closeSheet(); return; }
  const el = $('sheet').firstChild.firstChild;
  if (c.version !== detail.version) {
    detail.start = c.start; detail.end = c.end;
    if (c.state === 'ready' && c.file) { const v = el.querySelector('video'); v.src = c.file; v.play().catch(() => {}); detail.version = c.version; }
  }
  el.querySelector('.busy').classList.toggle('hidden', !['queued', 'downloading', 'rendering'].includes(c.state));
  $('dtitle').textContent = c.title; $('dreason').textContent = c.reason;
  if ($('dring').dataset.s !== String(c.score)) { $('dring').dataset.s = c.score; $('dring').innerHTML = ring(c.score); animateRings($('dring')); }
  $('dcap').classList.toggle('hidden', !c.caption); $('dcaptext').textContent = c.caption;
  $('ds').textContent = fmt(detail.start, true); $('de').textContent = fmt(detail.end, true);
  $('dlen').textContent = Math.round(detail.end - detail.start) + ' s';
  const changed = Math.abs(c.start - detail.start) > 0.01 || Math.abs(c.end - detail.end) > 0.01;
  $('dundo').classList.toggle('hidden', !changed); $('dredo').classList.toggle('hidden', !changed);
  $('dredo').disabled = ['queued', 'downloading', 'rendering'].includes(c.state);
  const pub = $('dpub');
  if (c.state === 'ready' && !pub.firstChild) {
    pub.innerHTML = Object.keys(O.platforms).map(p => `<button class="btn" data-p="${p}" title="${esc(O.platforms[p])}">${p}</button>`).join('');
    pub.querySelectorAll('button').forEach(b => b.onclick = () => { call('publish', detail.id, b.dataset.p); Sound.play('copy'); });
  } else if (c.state !== 'ready') pub.innerHTML = '';
}

// MARK: - Ajustes
async function openSettings() {
  Sound.play('tick');
  const st = await call('settings');
  const el = sheet(`
    <h3>Clave de Gemini</h3>
    <div class="group"><div class="line"><input type="password" id="skey" placeholder="Pega aquí tu clave" spellcheck="false">
      <button class="btn" id="stest">Probar</button><span id="sres"></span></div>
      <div class="steps"><b>Cómo conseguirla gratis:</b><br>1. Abre Google AI Studio e inicia sesión con tu cuenta de Google.<br>
      2. Pulsa «Create API key» y copia la clave.<br>3. Pégala arriba y pulsa «Probar».<br><a id="sstudio">Abrir Google AI Studio</a></div></div>
    <h3>Dónde se guardan los clips</h3>
    <div class="group"><div class="line"><span class="path" id="sout"></span><button class="btn" id="soutc">Cambiar…</button><button class="btn hidden" id="soutr">Restablecer</button></div></div>
    <h3>Música de fondo</h3>
    <div class="group"><div class="line"><span class="path" id="smus"></span><button class="btn" id="smusc">Elegir carpeta…</button><button class="btn hidden" id="smusr">Quitar</button></div>
      <div class="steps">Si eliges una carpeta con tus canciones (mp3, m4a, wav), Clips usa esas en vez de componer una.</div></div>
    <h3>&nbsp;</h3>
    <div class="group"><div class="line"><span style="flex:1">Sonidos</span><button class="switch" id="ssnd"></button></div></div>
    <div class="about">Clips ${esc(st.version)} para Windows · ${esc(st.copyright)}</div>
    <button class="btn sheet-close" id="sclose">Listo</button>`, 'settings');
  const key = $('skey'), res = $('sres');
  key.value = st.key;
  let t;
  key.oninput = () => { res.innerHTML = ''; clearTimeout(t); t = setTimeout(() => call('set_key', key.value), 200); updTest(); };
  const updTest = () => { $('stest').disabled = !key.value.trim(); };
  updTest();
  $('stest').onclick = async () => {
    await call('set_key', key.value);
    $('stest').textContent = 'Probando…'; $('stest').disabled = true;
    const ok = await call('test_key');
    $('stest').textContent = 'Probar'; updTest();
    res.innerHTML = ok ? `<span class="ok-mark">${ic('check')}</span>` : `<span class="bad-mark">${ic('x')}</span>`;
    Sound.play(ok ? 'success' : 'error');
  };
  $('sstudio').onclick = () => call('open_url', 'https://aistudio.google.com/apikey');
  const paths = s => {
    $('sout').textContent = s.outputDir || s.outputDefault; $('sout').title = s.outputDir || s.outputDefault;
    $('soutr').classList.toggle('hidden', !s.outputDir);
    $('smus').textContent = s.musicDir || 'La compone Clips para cada vídeo'; $('smus').title = s.musicDir || '';
    $('smusr').classList.toggle('hidden', !s.musicDir);
  };
  paths(st);
  const refresh = async () => { paths(await call('settings')); O = { ...O, ...(await call('options')) }; renderOptions(); renderEmpty(); };
  $('soutc').onclick = async () => { await call('choose_folder', 'output'); refresh(); };
  $('soutr').onclick = async () => { await call('clear_folder', 'output'); refresh(); };
  $('smusc').onclick = async () => { await call('choose_folder', 'music'); refresh(); };
  $('smusr').onclick = async () => { await call('clear_folder', 'music'); refresh(); };
  const snd = $('ssnd');
  snd.classList.toggle('on', st.sounds);
  snd.onclick = () => { const on = !snd.classList.contains('on'); snd.classList.toggle('on', on); Sound.enabled = on; call('set_option', 'sounds', on); if (on) Sound.play('pop'); };
  $('sclose').onclick = closeSheet;
  if (!st.key) key.focus();
}

// MARK: - Teclado
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') { if (openMenu) closeMenu(); else if ($('sheet').firstChild) closeSheet(); else if (S.running) call('cancel'); }
  if (e.key === 'Enter' && e.ctrlKey && !$('sheet').firstChild) { e.preventDefault(); start(); }
  if (e.key === ',' && e.ctrlKey) { e.preventDefault(); openSettings(); }
});

// MARK: - Estado que llega de Python
let prev = { ready: 0, finished: false, error: null, clips: 0 };
function update(state) {
  S = state;
  const ready = S.readyCount || 0;
  if (ready > prev.ready && S.clips.length) Sound.play('pop');
  if (S.finished && !prev.finished) setTimeout(() => Sound.play('success'), 180);
  if (S.error && (!prev.error || prev.error !== S.error.message)) Sound.play('error');
  prev = { ready, finished: S.finished, error: S.error && S.error.message };
  document.title = S.running && S.stage === 'clips' && S.clips.length ? `Clips — ${ready}/${S.clips.length}` : 'Clips';
  renderInput(); renderOptions(); fitNotes(); renderNotice(); renderError(); renderJob(); renderClips(); renderEmpty(); renderDetail();
}
window.app = { update };

async function boot() {
  O = { ...O, ...(await call('options')) };
  Sound.enabled = O.sounds !== false;
  update(await call('state'));
  pasteIfYouTube();
  if (!urlIn.value) urlIn.focus();
}

// MARK: - Datos de muestra (solo al abrir la página fuera de la app, para revisar el diseño)
const Demo = {
  call(name) {
    if (name === 'state') return Demo.state();
    if (name === 'options') return { platforms: { YouTube: '', Instagram: '', TikTok: '' } };
    if (name === 'settings') return { key: '', outputDir: '', outputDefault: 'C:\\Users\\Omar\\Videos\\Clips', musicDir: '', sounds: true, version: '1.0.0', copyright: '© 2026 OK Digital. Todos los derechos reservados.' };
    return null;
  },
  state() {
    const q = new URLSearchParams(location.search);
    if (!q.has('demo')) return { clips: [], done: [], curve: [] };
    const running = q.get('demo') === 'running';
    const curve = [...Array(100)].map((_, i) => 0.25 + 0.2 * Math.sin(i / 6) + (i > 28 && i < 33 ? 0.45 : 0) + (i > 70 && i < 74 ? 0.35 : 0));
    const ms = [[350.5, 391.7, 'We Get Educated Out of Creativity', 'La tesis central de la charla, rematada con la cita de Picasso sobre el miedo a equivocarse.', 98],
      [1005.2, 1064.6, "She Wasn't Sick, She Was a Dancer", 'La historia de Gillian Lynne: casi la mediquen y acabó siendo una gran coreógrafa.', 95],
      [740.3, 786.8, 'The Trap of Academic Inflation', 'Explica con humor por qué los títulos ya no garantizan trabajo.', 91],
      [520.6, 576.1, "Why Schools Don't Teach Dance", 'La jerarquía de asignaturas, con el chiste de educar de cintura para arriba.', 88]];
    const thumb = q.get('thumb');
    return {
      url: 'https://www.youtube.com/watch?v=iG9CE55wbtY', running, stage: 'clips', done: running ? ['video', 'text', 'moments'] : ['video', 'text', 'moments', 'clips'],
      detail: running ? 'Descargando y montando 4 clips…' : '4 clips listos', error: null,
      info: { title: 'Do schools kill creativity? | Sir Ken Robinson | TED', channel: 'TED', duration: 1203, thumbnail: null },
      curve, curveIsHeat: true, analyzing: false, finished: !running, notice: null, chronological: false, outDir: 'x',
      readyCount: running ? 2 : 4, words: 1203,
      clips: ms.map((m, i) => ({ id: 'c' + i, rank: i + 1, start: m[0], end: m[1], title: m[2], reason: m[3], score: m[4], caption: '#ted',
        state: !running || i < 2 ? 'ready' : i === 2 ? 'downloading' : 'queued', progress: 0.42, error: '', version: 1,
        thumb: (!running || i < 2) && thumb ? thumb : null, file: null })),
    };
  },
};

if (window.pywebview && window.pywebview.api) { api = window.pywebview.api; boot(); }
else {
  let booted = false;
  window.addEventListener('pywebviewready', () => { if (booted) return; booted = true; api = window.pywebview.api; boot(); });
  setTimeout(() => { if (!booted && !window.pywebview) { booted = true; boot(); } }, 600);
}
