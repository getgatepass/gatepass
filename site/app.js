import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';
import { RectAreaLightUniformsLib } from 'three/addons/lights/RectAreaLightUniformsLib.js';

const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
const clamp = (v, a = 0, b = 1) => Math.min(b, Math.max(a, v));
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = t => t * t * (3 - 2 * t);
const easeOut = t => 1 - Math.pow(1 - t, 3);
const easeInOut = t => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const bump = (u, c, w = 1.3) => clamp(1 - Math.abs(u - c) * w);

/* ---------- accents per scene (hero uses the app's emerald) ---------- */
const ACCENTS = ['#22cc8f', '#2fd4c0', '#34d27b', '#3d8bff', '#22cc8f', '#dfe4ec', '#22cc8f'];
const hex2rgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const rgb2hex = c => '#' + c.map(v => Math.round(v).toString(16).padStart(2, '0')).join('');
const mixHex = (a, b, t) => { const A = hex2rgb(a), B = hex2rgb(b); return rgb2hex(A.map((v, i) => lerp(v, B[i], t))); };
const rgba = (h, a) => { const [r, g, b] = hex2rgb(h); return `rgba(${r},${g},${b},${a})`; };

/* ---------- scroll state ---------- */
const scenes = [...document.querySelectorAll('[data-scene]')];
let tops = [], heights = [];
function measure() {
  tops = scenes.map(s => s.getBoundingClientRect().top + scrollY);
  heights = scenes.map(s => s.offsetHeight);
}
const localOf = (k, y) => (y - tops[k]) / heights[k];
function scrollState() {
  const y = scrollY + innerHeight * 0.5;
  let i = 0;
  for (let k = 0; k < scenes.length; k++) if (tops[k] <= y) i = k;
  const local = clamp(localOf(i, y));
  return { i, local, t: i + local, y };
}

/* ---------- reveal + counters ---------- */
const io = new IntersectionObserver(es => es.forEach(e => { if (e.isIntersecting) e.target.classList.add('in'); }), { threshold: 0.15 });
document.querySelectorAll('.reveal').forEach(el => (reduce ? el.classList.add('in') : io.observe(el)));
const counters = [...document.querySelectorAll('[data-count]')].map(el => ({ el, k: scenes.indexOf(el.closest('[data-scene]')), from: +el.dataset.from, to: +el.dataset.to, last: null }));
const daysEl = document.querySelector('[data-days]');
const daysScene = scenes.indexOf(daysEl.closest('[data-scene]'));
const progressBar = document.querySelector('.progress');

// shared timeline for scene 2 so the page copy and the screen agree
const daysAt = p => (p > 0.72 ? 7 : 7 - Math.round(clamp(p / 0.68) * 6));

function updateDom(st) {
  for (const c of counters) {
    const p = reduce ? 1 : easeOut(clamp((localOf(c.k, st.y) + 0.05) / 0.45));
    const v = Math.round(lerp(c.from, c.to, p));
    if (v !== c.last) { c.el.textContent = v; c.last = v; }
  }
  const dp = clamp(localOf(daysScene, st.y));
  daysEl.textContent = daysAt(dp);
  daysEl.closest('.inner').classList.toggle('renewed', dp > 0.72);
  const max = document.documentElement.scrollHeight - innerHeight;
  progressBar.style.transform = `scaleX(${max > 0 ? scrollY / max : 0})`;
}

/* =====================================================================
   Screen: a faithful redraw of the GatePass window (demo data only)
   ===================================================================== */
const SW = 1600, SH = 1053;                // screen canvas (MacBook panel aspect ≈ 1.52)
const K = SW / 2048;                       // draw in a 2048-wide desktop space
const sc = document.createElement('canvas'); sc.width = SW; sc.height = SH;
const g = sc.getContext('2d');
const appIcon = new Image(); appIcon.src = 'icon.png';

const SYS = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter Tight", system-ui, sans-serif';
const RND = 'ui-rounded, "SF Pro Rounded", -apple-system, BlinkMacSystemFont, "Inter Tight", system-ui, sans-serif';
const F = (w, s, fam = SYS) => { g.font = `${w} ${s}px ${fam}`; };
const T = (txt, x, y, color = '#fff', align = 'left') => { g.fillStyle = color; g.textAlign = align; g.fillText(txt, x, y); };
const RR = (x, y, w, h, r, fill) => { g.beginPath(); g.roundRect(x, y, w, h, r); g.fillStyle = fill; g.fill(); };
const SR = (x, y, w, h, r, stroke, lw = 1) => { g.beginPath(); g.roundRect(x, y, w, h, r); g.strokeStyle = stroke; g.lineWidth = lw; g.stroke(); };
const brand = (x, y, w, h) => { const gr = g.createLinearGradient(x, y, x + w, y + h); gr.addColorStop(0, '#21cc8f'); gr.addColorStop(1, '#0891b3'); return gr; };
const SEC = 'rgba(235,235,245,.6)', TER = 'rgba(235,235,245,.35)', CARD = 'rgba(255,255,255,.055)';
const GREEN = '#5bd47d';

function tile(x, y, s, letter) {
  RR(x, y, s, s, s * 0.225, brand(x, y, s, s));
  F(700, s * 0.42, RND); T(letter, x + s / 2, y + s * 0.65, '#fff', 'center');
}
function dayRing(cx, cy, days, color) {
  g.lineCap = 'round'; g.lineWidth = 3.5;
  g.strokeStyle = 'rgba(255,255,255,.12)'; g.beginPath(); g.arc(cx, cy, 20, 0, Math.PI * 2); g.stroke();
  g.strokeStyle = color; g.beginPath(); g.arc(cx, cy, 20, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * clamp(days / 7)); g.stroke();
  F(700, 12, RND); T(`${days}d`, cx, cy + 4.5, color, 'center');
}
function check(x, y, s, color, lw = 2.4) {
  g.strokeStyle = color; g.lineWidth = lw; g.lineCap = 'round'; g.lineJoin = 'round';
  g.beginPath(); g.moveTo(x - s * 0.35, y); g.lineTo(x - s * 0.08, y + s * 0.28); g.lineTo(x + s * 0.4, y - s * 0.3); g.stroke();
}
function wifi(x, y, s, color) {
  g.strokeStyle = color; g.lineWidth = s * 0.14; g.lineCap = 'round';
  for (let k = 0; k < 3; k++) { g.beginPath(); g.arc(x, y, s * (0.25 + k * 0.28), -Math.PI * 0.75, -Math.PI * 0.25); g.stroke(); }
  g.fillStyle = color; g.beginPath(); g.arc(x, y, s * 0.09, 0, Math.PI * 2); g.fill();
}
function toggle(x, y, on) {
  RR(x, y, 36, 20, 10, on ? '#30d158' : 'rgba(255,255,255,.18)');
  g.fillStyle = '#fff'; g.beginPath(); g.arc(on ? x + 26 : x + 10, y + 10, 8, 0, Math.PI * 2); g.fill();
}
function trafficLights(x, y) {
  ['#ff5f57', '#febc2e', '#28c840'].forEach((c, k) => { g.fillStyle = c; g.beginPath(); g.arc(x + k * 20, y, 6, 0, Math.PI * 2); g.fill(); });
}
function deviceIcon(kind, x, y, color) {
  g.strokeStyle = color; g.fillStyle = color; g.lineWidth = 1.8;
  if (kind === 'phone') { g.beginPath(); g.roundRect(x - 7, y - 12, 14, 24, 3.5); g.stroke(); RR(x - 3, y + 7.5, 6, 1.6, 1, color); }
  else if (kind === 'pad') { g.beginPath(); g.roundRect(x - 10, y - 13, 20, 26, 3.5); g.stroke(); }
  else { RR(x - 13, y - 13, 26, 26, 6, '#fff'); F(700, 10); T('tv', x + 2, y + 4, '#111', 'center'); }
}
function cursor(x, y) {
  g.save(); g.translate(x, y);
  g.beginPath(); g.moveTo(0, 0); g.lineTo(0, 22); g.lineTo(5.5, 17); g.lineTo(9.5, 26); g.lineTo(13, 24.5); g.lineTo(9, 16); g.lineTo(16, 16); g.closePath();
  g.fillStyle = '#000'; g.fill(); g.strokeStyle = '#fff'; g.lineWidth = 1.6; g.stroke();
  g.restore();
}
function ipaFile(x, y, s, label = true) {
  g.save(); g.translate(x, y);
  g.shadowColor = 'rgba(0,0,0,.45)'; g.shadowBlur = 12; g.shadowOffsetY = 4;
  g.beginPath(); g.moveTo(0, 0); g.lineTo(s * 0.62, 0); g.lineTo(s * 0.8, s * 0.18); g.lineTo(s * 0.8, s); g.lineTo(0, s); g.closePath();
  g.fillStyle = '#f2f2f5'; g.fill(); g.shadowColor = 'transparent';
  g.beginPath(); g.moveTo(s * 0.62, 0); g.lineTo(s * 0.62, s * 0.18); g.lineTo(s * 0.8, s * 0.18); g.fillStyle = '#c9c9cf'; g.fill();
  RR(s * 0.14, s * 0.36, s * 0.52, s * 0.36, s * 0.09, brand(0, 0, s, s));
  F(800, s * 0.17, RND); T('.ipa', s * 0.4, s * 0.6, '#fff', 'center');
  if (label) { RR(-s * 0.32, s * 1.08, s * 1.44, s * 0.3, s * 0.08, 'rgba(10,132,255,.85)'); F(600, s * 0.16); T('RetroArcade.ipa', s * 0.4, s * 1.28, '#fff', 'center'); }
  g.restore();
}

/* main window, drawn in the app's own point space (980×660) */
const WIN = { x: 289, y: 190, s: 1.5 };
function drawMainWindow(st) {
  g.save(); g.translate(WIN.x, WIN.y); g.scale(WIN.s, WIN.s);
  g.shadowColor = 'rgba(0,0,0,.6)'; g.shadowBlur = 50; g.shadowOffsetY = 18;
  RR(0, 0, 980, 660, 12, '#1e1e20'); g.shadowColor = 'transparent';
  SR(0.5, 0.5, 979, 659, 12, 'rgba(255,255,255,.12)');
  trafficLights(20, 20);

  // header
  if (appIcon.complete && appIcon.naturalWidth) { g.save(); g.beginPath(); g.roundRect(26, 62, 34, 34, 8); g.clip(); g.drawImage(appIcon, 26, 62, 34, 34); g.restore(); }
  F(700, 20, RND); T('GatePass', 72, 86);
  RR(612, 67, 34, 34, 17, 'rgba(255,255,255,.08)');
  g.strokeStyle = SEC; g.lineWidth = 2; g.beginPath(); g.arc(629, 84, 6, 0, Math.PI * 2); g.stroke();
  for (let k = 0; k < 8; k++) { const a = k * Math.PI / 4; g.beginPath(); g.moveTo(629 + Math.cos(a) * 7.5, 84 + Math.sin(a) * 7.5); g.lineTo(629 + Math.cos(a) * 10, 84 + Math.sin(a) * 10); g.stroke(); }
  RR(658, 62, 298, 44, 22, 'rgba(255,255,255,.07)');
  g.fillStyle = brand(666, 68, 32, 32); g.beginPath(); g.arc(682, 84, 16, 0, Math.PI * 2); g.fill();
  F(700, 14, RND); T('A', 682, 89, '#fff', 'center');
  F(700, 13); T('Alex', 708, 80); F(400, 11); T('Free account', 708, 96, SEC);
  RR(872, 70, 74, 28, 14, brand(872, 70, 74, 28)); F(700, 12, RND); T(`${st.sigs}/10`, 909, 89, '#fff', 'center');

  // device chips
  st.devices.forEach((d, k) => {
    const x = 24 + k * 181, sel = k === st.selected, a = d.alpha ?? 1;
    g.globalAlpha = a;
    RR(x, 125, 173, 57, 12, sel ? brand(x, 125, 173, 57) : 'rgba(255,255,255,.06)');
    deviceIcon(d.kind, x + 28, 153.5, sel ? '#fff' : 'rgba(255,255,255,.85)');
    F(600, 13); T(d.name, x + 52, 149, '#fff');
    wifi(x + 57, 170, 9, sel ? 'rgba(255,255,255,.85)' : SEC);
    F(400, 11); T(d.sub, x + 66, 169, sel ? 'rgba(255,255,255,.85)' : SEC);
    g.globalAlpha = 1;
  });

  // drop zone / activity
  const dz = { x: 24, y: 198, w: 582, h: 166 };
  if (st.activity) {
    RR(dz.x, dz.y, dz.w, dz.h, 14, CARD);
    const a = st.activity, cy = dz.y + dz.h / 2;
    g.strokeStyle = 'rgba(255,255,255,.75)'; g.lineWidth = 2.2; g.lineCap = 'round';
    g.beginPath(); g.arc(dz.x + 40, cy - 6, 8, st.time * 6, st.time * 6 + 4.4); g.stroke();
    F(600, 13); T(a.title, dz.x + 66, cy - 20);
    F(500, 12, RND); T(`${Math.round(a.pct)}%`, dz.x + dz.w - 72, cy - 20, SEC, 'right');
    RR(dz.x + 66, cy - 8, dz.w - 140, 5, 3, 'rgba(255,255,255,.12)');
    RR(dz.x + 66, cy - 8, Math.max(5, (dz.w - 140) * a.pct / 100), 5, 3, '#10ba82');
    F(400, 11); T(a.stage, dz.x + 66, cy + 16, SEC);
    RR(dz.x + dz.w - 50, cy - 19, 26, 26, 13, 'rgba(255,255,255,.08)');
    RR(dz.x + dz.w - 41, cy - 10, 8, 8, 1.5, 'rgba(255,255,255,.7)');
    if (a.done) { RR(dz.x + 30, cy - 18, 20, 20, 10, '#10ba82'); check(dz.x + 40, cy - 8, 11, '#fff', 2); }
  } else {
    if (st.hover) RR(dz.x, dz.y, dz.w, dz.h, 14, 'rgba(16,186,130,.12)');
    g.setLineDash([6, 5]); SR(dz.x + 0.5, dz.y + 0.5, dz.w - 1, dz.h - 1, 14, st.hover ? '#10ba82' : 'rgba(255,255,255,.22)', st.hover ? 2 : 1.2); g.setLineDash([]);
    const cx = dz.x + dz.w / 2;
    g.beginPath(); g.moveTo(cx - 11, 230); g.lineTo(cx + 5, 230); g.lineTo(cx + 12, 237); g.lineTo(cx + 12, 258); g.lineTo(cx - 11, 258); g.closePath(); g.fillStyle = brand(cx - 11, 230, 23, 28); g.fill();
    g.strokeStyle = '#1e1e20'; g.lineWidth = 2; g.lineCap = 'round'; g.beginPath(); g.moveTo(cx, 239); g.lineTo(cx, 251); g.moveTo(cx - 4, 247); g.lineTo(cx, 251); g.lineTo(cx + 4, 247); g.stroke();
    F(600, 15); T(st.hover ? 'Release to install' : 'Drop IPA files here', cx, 286, '#fff', 'center');
    F(400, 12); T('or click to choose · several at once is fine', cx, 310, SEC, 'center');
  }

  // library card
  RR(24, 372, 582, 265, 14, CARD);
  RR(45, 380, 163, 24, 7, 'rgba(255,255,255,.07)'); RR(127, 382, 79, 20, 5, 'rgba(255,255,255,.16)');
  F(500, 12); T('Recent', 86, 396, '#fff', 'center'); T('My Folder', 166, 396, '#fff', 'center');
  T('ipa', 515, 396, SEC, 'right'); T('Change', 523, 396, '#0a84ff');
  g.strokeStyle = SEC; g.lineWidth = 1.5; g.beginPath(); g.arc(584, 392, 5.5, -Math.PI * 0.2, Math.PI * 1.5); g.stroke();
  const lib = [['Retro Arcade', 'RetroArcade.ipa', 'v2.1.0 · 48.2 MB', 'R'], ['Pocket Code', 'PocketCode.ipa', 'v1.4.2 · 22.7 MB', 'P']];
  lib.forEach(([n, f, m, l], k) => {
    const y = 423 + k * 69;
    tile(46, y, 34, l);
    F(700, 13); T(n, 92, y + 12); F(400, 11); T(f, 92, y + 26, SEC); T(m, 92, y + 39, TER);
    RR(494, y + 5, 60, 25, 12.5, brand(494, y + 5, 60, 25)); F(700, 12); T('Install', 524, y + 22, '#fff', 'center');
    g.fillStyle = 'rgba(255,255,255,.25)'; g.beginPath(); g.arc(574, y + 17, 7, 0, Math.PI * 2); g.fill();
    g.strokeStyle = '#1e1e20'; g.lineWidth = 1.6; g.beginPath(); g.moveTo(571, y + 14); g.lineTo(577, y + 20); g.moveTo(577, y + 14); g.lineTo(571, y + 20); g.stroke();
  });

  // my apps
  RR(624, 198, 332, 439, 14, CARD);
  F(700, 15); T('My Apps', 645, 228);
  st.apps.forEach((a, k) => {
    const y = 250 + k * 84;
    g.globalAlpha = a.alpha ?? 1;
    if (a.flash) RR(634, y - 8, 312, 68, 12, rgba('#10ba82', 0.16 * a.flash));
    tile(645, y, 52, a.letter);
    F(700, 14); T(a.name, 711, y + 22); F(400, 12); T(a.sub ?? 'iPhone', 711, y + 40, SEC);
    dayRing(915, y + 26, a.days, a.days <= 1 ? '#ff9f0a' : GREEN);
    g.globalAlpha = 1;
  });
  g.fillStyle = GREEN; g.beginPath(); g.arc(649, 607, 3.5, 0, Math.PI * 2); g.fill();
  F(400, 12); T('Auto-refresh is on', 660, 611, SEC);

  if (st.spotlight) {   // dim everything but My Apps
    g.fillStyle = `rgba(0,0,0,${0.5 * st.spotlight})`;
    g.beginPath(); g.rect(0, 0, 980, 660); g.roundRect(624, 198, 332, 439, 14); g.fill('evenodd');
    SR(624, 198, 332, 439, 14, rgba('#22cc8f', 0.8 * st.spotlight), 2);
  }
  g.restore();
}

function drawSettings(a) {
  const s = 1.5, x = 1010, y = 300 + (1 - a) * 30;
  g.save(); g.globalAlpha = a; g.translate(x, y); g.scale(s, s);
  g.shadowColor = 'rgba(0,0,0,.65)'; g.shadowBlur = 40; g.shadowOffsetY = 14;
  RR(0, 0, 480, 450, 12, '#232326'); g.shadowColor = 'transparent';
  SR(0.5, 0.5, 479, 449, 12, 'rgba(255,255,255,.12)');
  trafficLights(20, 20);
  F(600, 13); T('General', 240, 24, 'rgba(255,255,255,.7)', 'center');
  [['General', 180, true], ['Advanced', 240, false], ['About', 300, false]].forEach(([n, cx, sel]) => {
    if (sel) RR(cx - 28, 34, 56, 54, 8, 'rgba(255,255,255,.08)');
    g.strokeStyle = sel ? '#fff' : SEC; g.lineWidth = 1.8; g.beginPath(); g.arc(cx, 56, 8, 0, Math.PI * 2); g.stroke();
    F(500, 11); T(n, cx, 80, sel ? '#fff' : SEC, 'center');
  });
  RR(16, 100, 448, 110, 10, 'rgba(255,255,255,.05)');
  F(400, 11); T('When a device shows up (USB or Wi‑Fi), GatePass refreshes apps that', 28, 120, SEC);
  T('expire within 2 days.', 28, 135, SEC);
  F(400, 13); T('Notifications', 28, 165); toggle(414, 152, true);
  g.fillStyle = 'rgba(255,255,255,.08)'; g.fillRect(28, 178, 424, 1);
  T('Open GatePass at login', 28, 200); toggle(414, 188, true);
  F(700, 13); T('Security', 28, 244);
  RR(16, 258, 448, 108, 10, 'rgba(255,255,255,.05)');
  F(400, 13); T('Store sign-in in Keychain', 28, 290); toggle(414, 278, false);
  F(400, 11);
  ['Your Apple session token is kept in a file only your Mac user account can', 'read. No password prompts. Your Apple ID password is never saved', 'either way.'].forEach((l, k) => T(l, 28, 316 + k * 15, SEC));
  RR(16, 378, 448, 46, 10, 'rgba(255,255,255,.05)');
  RR(28, 389, 140, 24, 6, 'rgba(255,255,255,.12)'); F(500, 12); T('Show Welcome Again', 98, 405, '#fff', 'center');
  g.restore();
}

function drawNotification(a) {
  if (a <= 0) return;
  const w = 600, h = 120, x = 2048 - w - 36 + (1 - easeOut(a)) * 680, y = 68;
  g.save();
  g.shadowColor = 'rgba(0,0,0,.5)'; g.shadowBlur = 30; g.shadowOffsetY = 10;
  RR(x, y, w, h, 26, 'rgba(44,44,48,.94)'); g.shadowColor = 'transparent';
  SR(x + 0.5, y + 0.5, w - 1, h - 1, 26, 'rgba(255,255,255,.1)');
  if (appIcon.complete && appIcon.naturalWidth) { g.save(); g.beginPath(); g.roundRect(x + 22, y + 26, 68, 68, 16); g.clip(); g.drawImage(appIcon, x + 22, y + 26, 68, 68); g.restore(); }
  F(700, 26); T('GatePass', x + 110, y + 50);
  F(400, 22); T('now', x + w - 28, y + 50, SEC, 'right');
  F(400, 24); T('Renewed 3 apps on iPhone · next in 7 days', x + 110, y + 86, 'rgba(255,255,255,.85)');
  g.restore();
}

function drawDesktop(acc, st) {
  g.setTransform(K, 0, 0, K, 0, 0);
  g.fillStyle = '#071012'; g.fillRect(0, 0, 2048, 1348);
  const blob = (x, y, r, c, a) => { const gr = g.createRadialGradient(x, y, 0, x, y, r); gr.addColorStop(0, rgba(c, a)); gr.addColorStop(1, rgba(c, 0)); g.fillStyle = gr; g.fillRect(0, 0, 2048, 1348); };
  blob(420, 1180, 1300, '#10b981', 0.55);
  blob(1750, 180, 1100, '#0891b3', 0.5);
  blob(1100, 1348, 900, acc, 0.35);
  // menu bar
  g.fillStyle = 'rgba(0,0,0,.32)'; g.fillRect(0, 0, 2048, 44);
  F(700, 24); T('GatePass', 40, 31);
  F(400, 24); ['File', 'Edit', 'View', 'Window', 'Help'].forEach((m, k) => T(m, 175 + k * 92, 31, 'rgba(255,255,255,.9)'));
  F(500, 24); T('Tue 9:41', 2008, 31, '#fff', 'right');
  RR(1810, 14, 38, 18, 5, 'transparent'); SR(1810, 13, 38, 18, 5, 'rgba(255,255,255,.9)', 2); RR(1814, 17, 28, 10, 2, '#fff');
  wifi(1885, 32, 26, '#fff');
  // GatePass status item
  const pulse = st.statusPulse || 0;
  if (pulse) RR(1714, 6, 52, 32, 8, `rgba(255,255,255,${0.22 * pulse})`);
  g.strokeStyle = '#fff'; g.lineWidth = 2.6; g.lineCap = 'round';
  g.beginPath(); g.moveTo(1726, 32); g.lineTo(1726, 18); g.moveTo(1754, 32); g.lineTo(1754, 18); g.moveTo(1722, 24); g.lineTo(1758, 24); g.stroke();
  g.fillStyle = '#fff'; g.beginPath(); g.arc(1745, 13, 3.4, 0, Math.PI * 2); g.fill();
}

const BASE_APPS = () => [
  { name: 'Field Notes', letter: 'F', days: 6 },
  { name: 'Pocket Code', letter: 'P', days: 4 },
];
const DEVS = [
  { kind: 'phone', name: 'iPhone', sub: 'iOS 26 · USB' },
  { kind: 'pad', name: 'iPad', sub: 'iPadOS 26 · Wi‑Fi' },
  { kind: 'tv', name: 'Living Room', sub: 'tvOS 26 · Wi‑Fi' },
];

/* outro screen: a small macOS window whose one job is the download button */
const GET = { x: 348, y: 176, s: 2.6, bx: 110, by: 262, bw: 300, bh: 54 };
const GET_BTN = { x: GET.x + GET.bx * GET.s, y: GET.y + GET.by * GET.s, w: GET.bw * GET.s, h: GET.bh * GET.s };   // desktop space
function drawGet(p, hover) {
  const a = smooth(clamp((p - 0.3) / 0.3));
  if (a <= 0) return;
  g.save(); g.globalAlpha = a;
  g.translate(GET.x, GET.y + (1 - a) * 36); g.scale(GET.s, GET.s);
  g.shadowColor = 'rgba(0,0,0,.6)'; g.shadowBlur = 50; g.shadowOffsetY = 18;
  RR(0, 0, 520, 400, 16, '#1c1c1f'); g.shadowColor = 'transparent';
  const sheen = g.createLinearGradient(0, 0, 0, 400); sheen.addColorStop(0, 'rgba(255,255,255,.06)'); sheen.addColorStop(0.5, 'rgba(255,255,255,0)');
  RR(0, 0, 520, 400, 16, sheen);
  SR(0.5, 0.5, 519, 399, 16, 'rgba(255,255,255,.14)');
  trafficLights(22, 22);
  if (appIcon.complete && appIcon.naturalWidth) g.drawImage(appIcon, 212, 58, 96, 96);
  F(700, 32, RND); T('GatePass', 260, 200, '#fff', 'center');
  F(400, 15); T('Sideload apps. Forget the 7‑day limit.', 260, 226, SEC, 'center');
  // the button: macOS push-button proportions in the site's emerald
  const { bx, by, bw, bh } = GET;
  g.shadowColor = `rgba(33,204,143,${hover ? 0.6 : 0.38})`; g.shadowBlur = hover ? 34 : 24; g.shadowOffsetY = 8;
  const bg = g.createLinearGradient(0, by, 0, by + bh); bg.addColorStop(0, hover ? '#3ff0b0' : '#2fe3a2'); bg.addColorStop(1, hover ? '#1fc98b' : '#17b57c');
  RR(bx, by, bw, bh, 14, bg); g.shadowColor = 'transparent';
  const hi = g.createLinearGradient(0, by, 0, by + bh); hi.addColorStop(0, 'rgba(255,255,255,.55)'); hi.addColorStop(0.35, 'rgba(255,255,255,0)');
  SR(bx + 0.75, by + 0.75, bw - 1.5, bh - 1.5, 13.5, hi, 1.5);
  F(650, 19); const label = 'Get GatePass for Mac', tw = g.measureText(label).width, x0 = bx + (bw - tw - 30) / 2, cy = by + bh / 2;
  g.strokeStyle = '#04110c'; g.lineWidth = 2.4; g.lineCap = 'round'; g.lineJoin = 'round';
  g.beginPath(); g.moveTo(x0 + 9, cy - 9); g.lineTo(x0 + 9, cy + 3); g.moveTo(x0 + 3.5, cy - 2); g.lineTo(x0 + 9, cy + 3.5); g.lineTo(x0 + 14.5, cy - 2); g.moveTo(x0 + 2, cy + 9); g.lineTo(x0 + 16, cy + 9); g.stroke();
  T(label, x0 + 30, cy + 6.5, '#04110c');
  F(400, 12.5); T('Free · Open source · macOS 14 or later', 260, 352, TER, 'center');
  g.restore();
}

function drawScreen(mode, p, acc, time, hover) {
  const st = { time, sigs: 7, devices: [DEVS[0], DEVS[2]], selected: 0, apps: BASE_APPS(), activity: null, hover: false, spotlight: 0, statusPulse: 0 };
  let drag = null, notif = 0, settings = 0;

  if (mode === 1) {
    // drag .ipa from the desktop into the drop zone, then install
    const dragP = clamp(p / 0.4);
    if (p < 0.46) {
      const e = easeInOut(dragP);
      drag = { x: lerp(120, 640, e), y: lerp(1150, 560, e) - Math.sin(e * Math.PI) * 120 };
      st.hover = dragP > 0.82;
    } else {
      const ip = clamp((p - 0.46) / 0.46);
      const stages = ['Reading package', 'Signing with your Apple ID', 'Sending to iPhone', 'Installing'];
      st.activity = { title: ip >= 1 ? 'Installed Retro Arcade' : 'Installing Retro Arcade', pct: ip * 100, stage: ip >= 1 ? 'Done · expires in 7 days' : `${stages[Math.min(3, Math.floor(ip * 4))]} · don't stop now`, done: ip >= 1 };
      st.sigs = ip > 0.3 ? 6 : 7;
      if (ip >= 1) st.apps.push({ name: 'Retro Arcade', letter: 'R', days: 7, flash: 1 });
    }
  } else if (mode >= 2) {
    st.sigs = 6;
    st.apps.push({ name: 'Retro Arcade', letter: 'R', days: 7 });
  }

  if (mode === 2) {
    const renewed = p > 0.72;
    const d = daysAt(p);
    st.apps = [
      { name: 'Field Notes', letter: 'F', days: renewed ? 7 : Math.max(1, d - 1), flash: renewed ? 1 : 0 },
      { name: 'Pocket Code', letter: 'P', days: renewed ? 7 : Math.max(1, d - 2), flash: renewed ? 1 : 0 },
      { name: 'Retro Arcade', letter: 'R', days: d, flash: renewed ? 1 : 0 },
    ];
    notif = clamp((p - 0.72) / 0.12);
    st.statusPulse = renewed ? 0 : 0.5 + 0.5 * Math.sin(time * 5);
  }
  if (mode === 3) {
    const found = 1 + (p > 0.3) + (p > 0.55);
    st.devices = DEVS.slice(0, found).map((d, k) => ({ ...d, alpha: k === found - 1 ? clamp((p - [0, 0.3, 0.55][k]) / 0.08) || 1 : 1 }));
    st.selected = found - 1;
  }
  if (mode === 4) {
    st.devices = DEVS; st.selected = 0;
    st.spotlight = smooth(clamp(p / 0.25));
    const renewed = p > 0.6;
    st.apps = [
      { name: 'Field Notes', letter: 'F', days: 6 },
      { name: 'Pocket Code', letter: 'P', days: renewed ? 7 : 1, flash: renewed ? 1 : 0 },
      { name: 'Retro Arcade', letter: 'R', days: 5 },
    ];
  }
  if (mode === 5) { st.devices = DEVS; settings = smooth(clamp(p / 0.25)); }
  if (mode >= 6) st.devices = DEVS;

  drawDesktop(acc, st);
  if (mode === 7) { drawGet(p, hover); g.setTransform(1, 0, 0, 1, 0, 0); return; }
  drawMainWindow(st);
  if (settings) drawSettings(settings);
  drawNotification(notif);
  if (drag) { ipaFile(drag.x, drag.y, 120); cursor(drag.x + 70, drag.y + 70); }
  g.setTransform(1, 0, 0, 1, 0, 0);
}

/* =====================================================================
   3D scene
   ===================================================================== */
const canvas = document.getElementById('gl');
const root = document.documentElement;
const preBar = document.querySelector('.pre-bar span'), preN = document.querySelector('.pre-n');
let pctTarget = 0, pct = 0, isReady = false;
function ready() {
  if (isReady) return; isReady = true; pctTarget = 1;
  setTimeout(() => root.classList.add('ready'), reduce ? 0 : 450);
}
setTimeout(ready, 9000);   // never trap the visitor behind the loader
let renderer = null;
try {
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true, powerPreference: 'high-performance' });
} catch (e) { document.documentElement.classList.add('no-webgl'); canvas.style.display = 'none'; ready(); }

const scene = new THREE.Scene();
const camera = new THREE.PerspectiveCamera(32, innerWidth / innerHeight, 0.1, 100);
camera.position.set(0, 0.35, 6);
camera.lookAt(0, 0, 0);

let rig = null, lid = null, LID_OPEN = -1.92, screenTex = null, ring, waves = [], rim, key, screenLight = null, modelScale = 1, screenKey = '';
let loaded = false, loadedAt = 0;
let spot = null, screenMesh = null, screenQuad = null, outroHover = false, lidT = 0;
const outroEl = document.querySelector('.outro'), beamEl = document.querySelector('.beam'), hitEl = document.querySelector('.outro-hit');
hitEl.addEventListener('pointerenter', () => { outroHover = true; });
hitEl.addEventListener('pointerleave', () => { outroHover = false; });
hitEl.addEventListener('focus', () => { outroHover = true; });
hitEl.addEventListener('blur', () => { outroHover = false; });

/* local-space corners of the display panel, read from its UVs, so a point on the
   screen canvas can be projected to the page (used to put a real link over the drawn button) */
function readScreenQuad(mesh) {
  const pos = mesh.geometry.attributes.position, uv = mesh.geometry.attributes.uv;
  let u0 = Infinity, u1 = -Infinity, v0 = Infinity, v1 = -Infinity;
  for (let i = 0; i < uv.count; i++) { u0 = Math.min(u0, uv.getX(i)); u1 = Math.max(u1, uv.getX(i)); v0 = Math.min(v0, uv.getY(i)); v1 = Math.max(v1, uv.getY(i)); }
  const near = (u, v) => { let best = 0, bd = Infinity; for (let i = 0; i < uv.count; i++) { const d = Math.hypot(uv.getX(i) - u, uv.getY(i) - v); if (d < bd) { bd = d; best = i; } } return new THREE.Vector3().fromBufferAttribute(pos, best); };
  return { u0, u1, v0, v1, p00: near(u0, v0), p10: near(u1, v0), p01: near(u0, v1), p11: near(u1, v1) };
}
const _a = new THREE.Vector3(), _b = new THREE.Vector3();
function screenToPage(fx, fy) {     // fx, fy: 0..1 across the screen canvas
  const q = screenQuad, x = (fx - q.u0) / (q.u1 - q.u0), y = (fy - q.v0) / (q.v1 - q.v0);
  _a.copy(q.p00).lerp(q.p10, x); _b.copy(q.p01).lerp(q.p11, x); _a.lerp(_b, y);
  screenMesh.localToWorld(_a).project(camera);
  return [(_a.x * 0.5 + 0.5) * innerWidth, (-_a.y * 0.5 + 0.5) * innerHeight];
}
const glowEl = document.querySelector('.glow3d');

/* photo-studio environment: dark room, a big overhead softbox and two strip lights.
   This is what gives brushed aluminium its long, soft highlights instead of a flat grey. */
function studioEnvironment(renderer) {
  const env = new THREE.Scene();
  env.background = new THREE.Color(0x050506);
  const panel = (w, h, intensity, pos, look, tint = 0xffffff) => {
    const m = new THREE.Mesh(new THREE.PlaneGeometry(w, h), new THREE.MeshBasicMaterial({ color: new THREE.Color(tint).multiplyScalar(intensity), side: THREE.DoubleSide }));
    m.position.set(...pos); m.lookAt(...look); env.add(m);
  };
  panel(8, 5, 2.6, [0, 7, 1.5], [0, 0, 0]);            // overhead softbox
  panel(1.4, 7, 3.2, [-6, 2.5, 3], [0, 0, 0]);         // key strip, front-left
  panel(1.2, 6, 1.8, [6.5, 2, -1.5], [0, 0, 0]);       // rim strip, back-right
  panel(10, 1.2, 0.5, [0, -0.6, 7], [0, 0.5, 0], 0xdfe7ff); // low front bounce
  const floor = new THREE.Mesh(new THREE.PlaneGeometry(40, 40), new THREE.MeshBasicMaterial({ color: 0x0b0b0d }));
  floor.rotation.x = -Math.PI / 2; floor.position.y = -1.5; env.add(floor);
  const pmrem = new THREE.PMREMGenerator(renderer);
  const tex = pmrem.fromScene(env, 0.02).texture;
  pmrem.dispose();
  return tex;
}

if (renderer) {
  renderer.setClearColor(0x000000, 0);
  renderer.toneMapping = THREE.NeutralToneMapping;
  renderer.toneMappingExposure = 0.95;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.VSMShadowMap;
  RectAreaLightUniformsLib.init();
  scene.environment = studioEnvironment(renderer);
  scene.environmentIntensity = 1.2;

  key = new THREE.DirectionalLight(0xfff6ee, 1.6);
  key.position.set(-2.5, 6, 3.5);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  Object.assign(key.shadow.camera, { left: -3, right: 3, top: 3, bottom: -3, near: 1, far: 15 });
  key.shadow.radius = 10; key.shadow.blurSamples = 16; key.shadow.bias = -0.0004;
  scene.add(key, key.target);
  rim = new THREE.PointLight(0x22cc8f, 14, 12, 1.8); rim.position.set(2.5, 2.2, -2.5); scene.add(rim);
  spot = new THREE.SpotLight(0xffffff, 0, 16, 0.42, 0.85, 1); scene.add(spot, spot.target);

  screenTex = new THREE.CanvasTexture(sc);
  screenTex.colorSpace = THREE.SRGBColorSpace;
  screenTex.flipY = false;                      // glTF UV convention
  screenTex.anisotropy = renderer.capabilities.getMaxAnisotropy();

  // soft gaussian sprite for glow + contact shadow
  const gc = document.createElement('canvas'); gc.width = gc.height = 256;
  const gg = gc.getContext('2d'); const img = gg.createImageData(256, 256);
  for (let y = 0; y < 256; y++) for (let x = 0; x < 256; x++) {
    const r = Math.hypot(x - 127.5, y - 127.5) / 128, o = (y * 256 + x) * 4;
    const a = r >= 1 ? 0 : Math.exp(-r * r * 5) * (1 - r * r);
    img.data[o] = img.data[o + 1] = img.data[o + 2] = 255; img.data[o + 3] = Math.round(a * 255);
  }
  gg.putImageData(img, 0, 0);
  const softTex = new THREE.CanvasTexture(gc);

  // particle ring (scene 2) and Wi‑Fi waves (scene 3)
  const N = 1100, pts = new Float32Array(N * 3);
  for (let k = 0; k < N; k++) {
    const a = Math.random() * Math.PI * 2, r = 1.75 + (Math.random() - 0.5) * 0.16 + (k % 3 === 0 ? 0.25 : 0);
    pts[k * 3] = Math.cos(a) * r; pts[k * 3 + 1] = Math.sin(a) * r * 0.62; pts[k * 3 + 2] = (Math.random() - 0.5) * 0.2;
  }
  const pg = new THREE.BufferGeometry(); pg.setAttribute('position', new THREE.BufferAttribute(pts, 3));
  ring = new THREE.Points(pg, new THREE.PointsMaterial({ color: 0x34d27b, size: 0.024, transparent: true, opacity: 0, depthWrite: false }));
  scene.add(ring);
  for (let k = 0; k < 4; k++) {
    const m = new THREE.Mesh(new THREE.TorusGeometry(1, 0.008, 8, 180), new THREE.MeshBasicMaterial({ color: 0x3d8bff, transparent: true, opacity: 0, depthWrite: false }));
    waves.push(m); scene.add(m);
  }

  const manager = new THREE.LoadingManager();
  const gl = new GLTFLoader(manager);
  gl.load('models/macbook.glb', gltf => {
    const model = gltf.scene;
    lid = model.getObjectByName('Lid');
    if (lid) LID_OPEN = lid.rotation.x;
    model.traverse(o => {
      if (!o.isMesh) return;
      o.castShadow = true;
      const n = o.material && o.material.name;
      // the model's screen normals point backwards, so render both sides; the logo decal is
      // double-sided in the file and would otherwise show through on the screen side
      if (n === 'OLED') { o.material = new THREE.MeshBasicMaterial({ map: screenTex, toneMapped: false, side: THREE.DoubleSide }); screenMesh = o; screenQuad = readScreenQuad(o); }
      else if (n === 'Apple logo') o.material.side = THREE.FrontSide;
      else if (n === 'Display glass nanotexture') o.visible = false;
      else if (n === 'Display glass') { o.material.opacity = 0.08; o.material.roughness = 0.05; }
    });
    // normalise: ~2.2 units wide, pivot at the centre of the base
    const box = new THREE.Box3().setFromObject(model), size = box.getSize(new THREE.Vector3());
    const k = 2.2 / size.x;
    model.scale.setScalar(k);
    const b2 = new THREE.Box3().setFromObject(model), c = b2.getCenter(new THREE.Vector3());
    model.position.set(-c.x, -b2.min.y, -c.z * 0.4);
    modelScale = k;
    rig = new THREE.Group();
    rig.add(model);

    // light spilling from the display onto the keyboard and palm rest
    if (lid) {
      screenLight = new THREE.RectAreaLight(0x3ccfae, 5, 1, 1);
      screenLight.position.set(0, 0.0035, 0.11);     // lid space: centre of the panel
      screenLight.rotation.x = -Math.PI / 2;          // emit out of the screen side
      lid.add(screenLight);
    }

    // grounding: a real cast shadow plus two soft contact layers
    const ground = new THREE.Mesh(new THREE.PlaneGeometry(9, 7), new THREE.ShadowMaterial({ opacity: 0.5 }));
    ground.rotation.x = -Math.PI / 2; ground.position.y = 0.001; ground.receiveShadow = true; rig.add(ground);
    const contact = (w, d, o, y) => {
      const m = new THREE.Mesh(new THREE.PlaneGeometry(w, d), new THREE.MeshBasicMaterial({ map: softTex, color: 0x000000, transparent: true, opacity: o, depthWrite: false }));
      m.rotation.x = -Math.PI / 2; m.position.y = y; rig.add(m);
    };
    contact(2.9, 2.1, 0.9, 0.002);
    contact(5.2, 3.8, 0.45, 0.0015);
    scene.add(rig);
    root.classList.add('gl');
    loaded = true; loadedAt = performance.now() + (reduce ? 0 : 700);
    ready();
    measure();
  }, e => { pctTarget = Math.max(pctTarget, Math.min(0.96, e.loaded / (e.total || 6177536))); }, () => {
    document.documentElement.classList.add('no-webgl'); canvas.style.display = 'none'; ready();
  });
}

/* ---------- choreography: [x, y, z, rx, ry, rz, scale, lidOpen] ---------- */
const POSES_DESK = [
  [-0.2, -0.56, 0, 0.2, -0.32, 0, 0.86, 0.22],   // hero: lid mostly shut so the GATEPASS word reads
  [1.35, -0.68, 0.2, 0.1, -0.38, 0, 1.15, 1],
  [-1.35, -0.68, 0.2, 0.1, 0.4, 0, 1.15, 1],
  [1.3, -0.62, 0, 0.2, -0.5, 0, 1.1, 1],
  [-1.25, -0.72, 0.7, 0.06, 0.28, 0, 1.1, 1],
  [1.35, -0.68, 0.2, 0.1, -0.3, 0, 1.15, 1],
  [0, 1.1, -0.6, 0.35, -0.15, 0, 0.8, 0],
];
const POSES_MOB = [
  [0, 0.62, 0, 0.16, -0.4, 0, 0.64, 0.27],
  [0, 0.38, 0, 0.12, -0.3, 0, 0.66, 1],
  [0, 0.38, 0, 0.12, 0.3, 0, 0.66, 1],
  [0, 0.38, 0, 0.2, -0.4, 0, 0.64, 1],
  [0, 0.34, 0.3, 0.06, 0.15, 0, 0.66, 1],
  [0, 0.38, 0, 0.12, -0.25, 0, 0.66, 1],
  [0, 1.5, -0.6, 0.35, -0.15, 0, 0.6, 0],
];
let mobile = innerWidth < 820;
function poseAt(u) {
  const P = mobile ? POSES_MOB : POSES_DESK;
  const a = clamp(Math.floor(u), 0, P.length - 1), b = clamp(a + 1, 0, P.length - 1), f = smooth(clamp(u - a));
  const out = P[a].map((v, k) => lerp(v, P[b][k], f));
  if (!mobile) {
    const halfW = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * camera.position.z * camera.aspect;
    // poses are authored for 16:9 (halfW ≈ 3.06); keep the laptop inside its half on other shapes
    out[0] *= halfW / 3.06;
    out[6] *= clamp(halfW / 3.06, 0.6, 1.15);
  }
  return out;
}

// outro: front and centre, lid driven by scroll
function outroPose(lid) {
  if (mobile) return [0, 0.05, 0, 0.14, 0, 0, 0.74, lid];
  const halfW = Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * camera.position.z * camera.aspect;
  return [0, -0.6, 0.6, 0.13, 0, 0, 1.12 * clamp(halfW / 3.06, 0.6, 1.1), lid];
}

let cur = null;
const mouse = { x: 0, y: 0, tx: 0, ty: 0 };
addEventListener('pointermove', e => {
  if (e.pointerType !== 'mouse') return;
  mouse.tx = (e.clientX / innerWidth - 0.5) * 2; mouse.ty = (e.clientY / innerHeight - 0.5) * 2;
}, { passive: true });

function resize() {
  mobile = innerWidth < 820;
  measure();
  if (!renderer) return;
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize(innerWidth, innerHeight, false);
  camera.aspect = innerWidth / innerHeight;
  camera.fov = mobile ? 40 : 32;
  camera.updateProjectionMatrix();
}
addEventListener('resize', resize);
resize();
addEventListener('load', measure);
appIcon.onload = () => { screenKey = ''; };
document.fonts && document.fonts.ready.then(() => { measure(); screenKey = ''; });

let lastAccent = '', railIdx = -1, lenis = null;
const railLinks = [...document.querySelectorAll('.rail a')];
const clock = new THREE.Clock();
function frame() {
  const dt = Math.min(clock.getDelta(), 0.05), time = clock.elapsedTime;
  if (lenis) lenis.raf(performance.now());
  const st = scrollState();
  updateDom(st);
  if (pct < 1) {
    pct = Math.min(1, pct + Math.max(0.004, (pctTarget - pct) * 0.12));
    if (pct > pctTarget && pctTarget < 1) pct = pctTarget;
    preBar.style.transform = `scaleX(${pct})`; preN.textContent = `${Math.round(pct * 100)}%`;
  }

  const u = clamp(st.t - 0.5, 0, 6);
  const ai = clamp(Math.floor(u), 0, 5);
  const accent = mixHex(ACCENTS[ai], ACCENTS[ai + 1], smooth(clamp(u - ai)));
  if (accent !== lastAccent) { lastAccent = accent; root.style.setProperty('--accent', accent); }
  root.classList.toggle('scrolled', scrollY > 40);
  root.classList.toggle('rail-on', u > 0.55 && u < 5.45);
  const ri = clamp(Math.round(u), 1, 5) - 1;
  if (ri !== railIdx) { railIdx = ri; railLinks.forEach((a, k) => a.classList.toggle('on', k === ri)); }

  // outro progress: oe = entering the viewport, op = through the pinned stretch
  const or = outroEl.getBoundingClientRect(), pinLen = Math.max(1, or.height - innerHeight);
  const oe = clamp(1 - or.top / innerHeight), op = clamp(-or.top / pinLen), exitPx = Math.max(0, -or.top - pinLen);
  const outroOn = oe > 0 && !!rig;
  const oFade = !outroOn ? 0 : reduce ? 1 : smooth(clamp((oe - 0.5) / 0.5));
  // the lid opens on its own once the scene is in view: a slow, timed open rather than one tied to scroll
  const lidGo = outroOn && oe > 0.92, lidBack = oFade < 0.05;
  if (reduce) lidT = lidGo ? 1 : 0;
  else if (lidGo) lidT = Math.min(1, lidT + dt / 2.8);
  else if (lidBack) lidT = Math.max(0, lidT - dt / 0.6);
  const oLid = easeInOut(lidT);

  if (renderer) {
    if (rig) {
      const intro = reduce ? 1 : clamp((performance.now() - loadedAt) / 2200);
      const target = outroOn ? outroPose(oLid) : poseAt(u);
      if (!cur || (outroOn && oFade < 0.02)) cur = target.slice();   // arrive in the dark, not mid-flight
      const k = reduce ? 1 : 1 - Math.pow(0.0009, dt);
      for (let j = 0; j < 8; j++) cur[j] = lerp(cur[j], target[j], k);
      mouse.x = lerp(mouse.x, mouse.tx, k * 0.6); mouse.y = lerp(mouse.y, mouse.ty, k * 0.6);

      const heroW = clamp(1 - u * 1.4);
      const idle = reduce ? 0 : Math.sin(time * 0.35) * 0.12 * heroW;
      const float = reduce ? 0 : Math.sin(time * 0.9) * 0.025;
      const ie = easeOut(clamp(intro * 1.4));
      rig.position.set(cur[0], cur[1] + float - (1 - ie) * 0.5, cur[2]);
      rig.rotation.set(cur[3] + mouse.y * 0.04, cur[4] + idle + mouse.x * 0.1 - (1 - ie) * 0.6, cur[5]);
      rig.scale.setScalar(cur[6] * (0.9 + 0.1 * ie));
      if (lid) lid.rotation.x = LID_OPEN * cur[7] * easeInOut(clamp((intro - 0.15) / 0.85));

      if (outroOn) {   // once the pin releases, ride away with the page
        const worldH = 2 * Math.tan(THREE.MathUtils.degToRad(camera.fov / 2)) * (camera.position.z - rig.position.z);
        rig.position.y += (exitPx / innerHeight) * worldH;
      }
      spot.position.set(rig.position.x, rig.position.y + 4.8, rig.position.z + 1.0);
      spot.target.position.set(rig.position.x, rig.position.y + 0.3, rig.position.z);
      spot.intensity = oFade * 22;
      scene.environmentIntensity = lerp(1.2, 0.55, oFade);
      key.intensity = lerp(1.6, 0.5, oFade);
      beamEl.style.opacity = String(oFade * 0.6);
      const open = outroOn && cur[7] > 0.8;
      outroEl.classList.toggle('open', open);
      if (open && screenQuad) {
        const c = [[GET_BTN.x, GET_BTN.y], [GET_BTN.x + GET_BTN.w, GET_BTN.y], [GET_BTN.x, GET_BTN.y + GET_BTN.h], [GET_BTN.x + GET_BTN.w, GET_BTN.y + GET_BTN.h]].map(([x, y]) => screenToPage(x / 2048, y / 1348));
        const xs = c.map(v => v[0]), ys = c.map(v => v[1]), x = Math.min(...xs), y = Math.min(...ys);
        hitEl.style.transform = `translate(${x.toFixed(1)}px, ${y.toFixed(1)}px)`;
        hitEl.style.width = `${(Math.max(...xs) - x).toFixed(1)}px`; hitEl.style.height = `${(Math.max(...ys) - y).toFixed(1)}px`;
      }

      const col = new THREE.Color(accent);
      rim.color.copy(col);
      key.position.set(rig.position.x - 2.5, rig.position.y + 6, rig.position.z + 3.5);
      key.target.position.copy(rig.position);
      if (screenLight) {
        const s = modelScale * rig.scale.x;
        screenLight.width = 0.3 * s; screenLight.height = 0.19 * s;
        screenLight.intensity = 0.35 * cur[7];
      }

      const centre = new THREE.Vector3(rig.position.x, rig.position.y + 0.85 * cur[6], rig.position.z - 0.5);
      // CSS glow follows the laptop on screen
      const sp = centre.clone().project(camera);
      glowEl.style.transform = `translate(${(sp.x * 0.5 + 0.5) * innerWidth}px, ${(-sp.y * 0.5 + 0.5) * innerHeight}px) scale(${0.75 + 0.35 * cur[6]})`;
      glowEl.style.opacity = String(ie * Math.max(1 - smooth(clamp((u - 5.3) / 0.5)), oFade * 0.35));
      const w2 = bump(u, 2, 1.25);
      ring.visible = w2 > 0.01;
      ring.material.opacity = w2 * 0.85; ring.material.color.copy(col);
      ring.position.copy(centre);
      ring.rotation.z += dt * (reduce ? 0 : 0.25);
      ring.scale.setScalar(cur[6] * (1.2 - w2 * 0.2));

      const w3 = bump(u, 3, 1.25);
      waves.forEach((m, j) => {
        m.visible = w3 > 0.01;
        const ph = reduce ? (j + 1) / 5 : ((time * 0.3 + j / waves.length) % 1);
        m.position.copy(centre);
        m.scale.set(cur[6] * (1.0 + ph * 2.6), cur[6] * (0.65 + ph * 1.7), 1);
        m.material.opacity = w3 * (1 - ph) * 0.8; m.material.color.copy(col);
      });

      const mode = outroOn ? 7 : clamp(Math.round(u), 0, 6);
      const mp = outroOn ? lidT : mode === st.i ? st.local : mode < st.i ? 1 : 0;
      const animated = (mode === 1 && mp > 0.46 && mp < 0.92) || (mode === 2 && mp < 0.72);
      const sk = `${mode}|${Math.round(mp * 300)}|${accent}|${animated ? Math.floor(time * 24) : 0}|${outroHover ? 1 : 0}`;
      if (sk !== screenKey) { screenKey = sk; drawScreen(mode, mp, accent, time, outroHover); screenTex.needsUpdate = true; }
    }
    canvas.style.opacity = String(Math.max(1 - smooth(clamp((u - 5.3) / 0.5)), oFade));
    renderer.render(scene, camera);
  }
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);

/* =====================================================================
   Page polish: smooth scroll, anchors, magnetic buttons, card spotlight
   ===================================================================== */
document.querySelectorAll('[data-ticks]').forEach(el => {
  const n = +el.dataset.ticks;
  for (let k = 0; k < 10; k++) { const i = document.createElement('i'); if (k < n) i.className = 'f'; i.style.setProperty('--i', k); el.append(i); }
});

const fine = matchMedia('(hover: hover) and (pointer: fine)').matches;
if (fine && !reduce) {
  import('https://cdn.jsdelivr.net/npm/lenis@1.1.14/dist/lenis.mjs')
    .then(m => { lenis = new m.default({ lerp: 0.115, wheelMultiplier: 0.95 }); })
    .catch(() => {});

  document.querySelectorAll('[data-magnetic]').forEach(el => {
    let raf = 0, x = 0, y = 0, tx = 0, ty = 0;
    const tick = () => {
      x = lerp(x, tx, 0.18); y = lerp(y, ty, 0.18);
      el.style.transform = `translate(${x.toFixed(2)}px, ${y.toFixed(2)}px)`;
      raf = Math.abs(x - tx) + Math.abs(y - ty) > 0.05 ? requestAnimationFrame(tick) : 0;
    };
    const go = () => { if (!raf) raf = requestAnimationFrame(tick); };
    el.addEventListener('pointermove', e => {
      const r = el.getBoundingClientRect();
      tx = (e.clientX - r.left - r.width / 2) * 0.22; ty = (e.clientY - r.top - r.height / 2) * 0.3; go();
    });
    el.addEventListener('pointerleave', () => { tx = ty = 0; go(); });
  });

  document.querySelectorAll('.card').forEach(el => el.addEventListener('pointermove', e => {
    const r = el.getBoundingClientRect();
    el.style.setProperty('--mx', `${e.clientX - r.left}px`); el.style.setProperty('--my', `${e.clientY - r.top}px`);
  }, { passive: true }));
}

document.addEventListener('click', e => {
  const a = e.target.closest('a[href^="#"]');
  if (!a) return;
  const target = document.querySelector(a.getAttribute('href'));
  if (!target) return;
  e.preventDefault();
  const scene = target.classList.contains('scene');
  // story scenes read best a little way in, once the copy has settled
  const y = target.id === 'top' ? 0 : target.getBoundingClientRect().top + scrollY + (scene ? innerHeight * 0.3 : -90);
  if (lenis) lenis.scrollTo(y, { duration: 1.4 });
  else scrollTo({ top: y, behavior: reduce ? 'auto' : 'smooth' });
  history.replaceState(null, '', a.getAttribute('href'));
});
