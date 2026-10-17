/* Shared helpers and small UI pieces. React and htm are loaded as globals by index.html. */
import { ICONS } from './icons.js';

export const { useState, useEffect, useRef, useMemo, useCallback, useLayoutEffect, Fragment } = React;
export const html = htm.bind(React.createElement);

export const MIN = 60e3, HOUR = 3600e3, DAY = 86400e3;
export const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
export const sum = (arr, f) => arr.reduce((t, x) => t + (f(x) || 0), 0);
export const enterKey = fn => e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); fn(); } };
export const IS_MAC = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent || '');
let _uid = 0;
export const uid = () => 'k' + (++_uid);

/* Per-browser preferences. Storage can be blocked, so every access is guarded. */
export function readPref(key, fallback) {
  try { const v = localStorage.getItem('orbit-' + key); return v == null ? fallback : JSON.parse(v); } catch (e) { return fallback; }
}
export function writePref(key, value) {
  try { localStorage.setItem('orbit-' + key, JSON.stringify(value)); } catch (e) { /* ignore */ }
}

/* ---------- formatting ---------- */
export function fmtMbps(v) { if (!v || v < 0.05) return '0'; if (v < 10) return v.toFixed(1); return String(Math.round(v)); }
export function fmtBytes(b) {
  if (!b) return '0 MB';
  const mb = b / 1e6;
  if (mb < 1) return '<1 MB';
  if (mb < 1000) return Math.round(mb) + ' MB';
  const gb = mb / 1000;
  if (gb < 1000) return (gb < 100 ? gb.toFixed(1) : String(Math.round(gb))) + ' GB';
  return (gb / 1000).toFixed(2) + ' TB';
}
export function fmtDur(ms) {
  const m = Math.round(ms / MIN);
  if (m < 1) return 'under a minute';
  if (m < 60) return m + ' min';
  const h = Math.floor(m / 60), mm = m % 60;
  if (h < 24) return mm ? `${h} h ${mm} min` : `${h} h`;
  const d = Math.floor(h / 24), hh = h % 24;
  return d < 7 && hh ? `${d} d ${hh} h` : `${d} days`;
}
export function fmtSecs(s) {
  s = Math.round(s || 0);
  if (s < 60) return `${s} s`;
  return fmtDur(s * 1000);
}
export function fmtAgo(ts, now) {
  const d = now - ts;
  if (d < 45e3) return 'just now';
  if (d < HOUR) return Math.max(1, Math.round(d / MIN)) + ' min ago';
  if (d < DAY) return Math.floor(d / HOUR) + ' h ago';
  const days = Math.floor(d / DAY);
  return days === 1 ? 'yesterday' : days + ' days ago';
}
export const fmtClock = ts => new Date(ts).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
export const fmtDate = ts => new Date(ts).toLocaleDateString([], { day: 'numeric', month: 'short', year: 'numeric' });
export const fmtShortDate = ts => new Date(ts).toLocaleDateString([], { day: 'numeric', month: 'short' });
export const fmtWeekday = ts => new Date(ts).toLocaleDateString([], { weekday: 'short' });
export const clockOfMinutes = m => `${String(Math.floor(m / 60) % 24).padStart(2, '0')}:${String(Math.round(m % 60)).padStart(2, '0')}`;
export const plural = (n, word, many) => `${n} ${n === 1 ? word : many || word + 's'}`;
/* An amount you chose, like an allowance: "2 GB" rather than "2.0 GB". */
export const fmtLimit = b => fmtBytes(b).replace(/\.0+ /, ' ');

/* ---------- devices and people ---------- */
export const TYPES = {
  phone: { icon: 'smartphone', label: 'Phone' }, laptop: { icon: 'laptop', label: 'Laptop' }, desktop: { icon: 'monitor', label: 'Computer' },
  tablet: { icon: 'tablet', label: 'Tablet' }, watch: { icon: 'watch', label: 'Watch' }, tv: { icon: 'tv', label: 'TV' },
  console: { icon: 'gamepad-2', label: 'Game console' }, speaker: { icon: 'speaker', label: 'Smart speaker' }, camera: { icon: 'cctv', label: 'Camera' },
  thermostat: { icon: 'thermometer', label: 'Thermostat' }, lights: { icon: 'lightbulb', label: 'Lights hub' }, vacuum: { icon: 'bot', label: 'Robot vacuum' },
  plug: { icon: 'plug', label: 'Smart plug' }, ereader: { icon: 'book-open', label: 'E-reader' }, printer: { icon: 'printer', label: 'Printer' },
  unknown: { icon: 'circle-help', label: 'Unknown device' },
};
export const typeIcon = d => (TYPES[d.type] || TYPES.unknown).icon;
/* 2.4 GHz reaches farther and fades more slowly, so the same dBm is a better sign on it than on 5 GHz.
   Every judgement of a device's signal uses this adjusted level, so the labels, bars and radar rings agree. */
export const BAND_EASE_DB = 6;
export const effSignal = d => (d.signal == null ? null : d.signal + (d.band === '2.4' ? BAND_EASE_DB : 0));
export function signalInfo(dbm) {
  if (dbm == null) return { level: 4, word: 'Wired', tone: 'good' };
  if (dbm >= -55) return { level: 4, word: 'Excellent', tone: 'good' };
  if (dbm >= -63) return { level: 3, word: 'Good', tone: 'good' };
  if (dbm >= -70) return { level: 2, word: 'Fair', tone: 'warn' };
  return { level: 1, word: 'Weak', tone: 'crit' };
}
export const isWired = d => d.band === 'eth';
export const bandLabel = d => (isWired(d) ? 'Ethernet' : d.band ? d.band + ' GHz' : 'Wi-Fi');
export const netLabel = d => (isWired(d) ? 'Wired' : d.network === 'guest' ? 'Guest Wi-Fi' : 'Main Wi-Fi');
export const connLabel = d => (isWired(d) ? 'Wired · Ethernet' : `${d.network === 'guest' ? 'Guest · ' : ''}${bandLabel(d)} · ${signalInfo(effSignal(d)).word}`);
export const personOf = (people, id) => (id ? people.find(p => p.id === id) || null : null);
export const pcol = p => `var(--p-${p.color})`;
export const scol = p => `var(--s-${p.color})`;
/* Colors for a device: its owner's color, amber while it's new, grey when nobody owns it yet. */
export const devColor = (d, p) => (p ? pcol(p) : d.is_new ? 'var(--warn)' : 'var(--p-none)');
export const devSky = (d, p) => (p ? scol(p) : d.is_new ? 'var(--warn)' : 'var(--s-none)');
export const ownerLabel = (d, p) => (p ? p.name : d.is_new ? 'New device' : 'No owner yet');
export const initials = name => (name || '?').trim().split(/\s+/).map(w => w[0]).slice(0, 2).join('').toUpperCase();
export const isActive = d => d.online && d.down_mbps + d.up_mbps > 0.15;
export function statusOf(d) {
  if (!d.online) return { cls: 'chip-muted', icon: 'wifi-off', label: 'Offline' };
  if (d.blocked) return { cls: 'chip-crit', icon: 'ban', label: 'Blocked' };
  return isActive(d) ? { cls: 'chip-good', dot: true, label: 'Online' } : { cls: 'chip-muted', dot: true, label: 'Idle' };
}
export function statusDetail(d, now) {
  if (!d.online) return 'Seen ' + fmtAgo(d.last_seen || now, now);
  if (d.blocked) return 'From the Starlink app';
  return d.since ? 'For ' + fmtDur(now - d.since) : 'Connected';
}
/* What a device is called before you name it: the router's name for it, or the name it gives itself. */
export const ownName = d => d.router_name || d.hostname || null;

/* ---------- data allowances ---------- */
export const PERIOD = { day: { per: 'a day', when: 'today', adj: 'daily' }, month: { per: 'a month', when: 'this month', adj: 'monthly' } };
export const allowanceTone = a => (a.used >= a.bytes ? 'crit' : a.used >= a.bytes * 0.8 ? 'warn' : 'good');
export const allowanceText = a => `${fmtBytes(a.used)} of ${fmtLimit(a.bytes)} used ${PERIOD[a.period].when}`;

/* ---------- primitives ---------- */
export function Icon({ name, size = 18, sw = 2, className = '', style }) {
  return html`<svg className=${'ic ' + className} width=${size} height=${size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth=${sw} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style=${style} dangerouslySetInnerHTML=${{ __html: ICONS[name] || ICONS['circle-help'] }} />`;
}
export function BrandMark({ size = 26 }) {
  return html`<svg className="brand-mark ic" width=${size} height=${size} viewBox="0 0 32 32" fill="none" aria-hidden="true">
    <ellipse cx="16" cy="16" rx="13" ry="6.5" transform="rotate(-28 16 16)" style=${{ stroke: 'currentColor', strokeWidth: 2, opacity: 0.5 }} />
    <circle cx="16" cy="16" r="5" style=${{ fill: 'currentColor' }} />
    <circle cx="25.8" cy="8.3" r="2.6" style=${{ fill: 'currentColor' }} />
  </svg>`;
}
export function useSize(ref) {
  const [size, setSize] = useState({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const set = (w, h) => setSize(s => (Math.abs(s.w - w) > 0.5 || Math.abs(s.h - h) > 0.5 ? { w, h } : s));
    const r = el.getBoundingClientRect();
    set(r.width, r.height);
    if (typeof ResizeObserver === 'undefined') return undefined;
    const ro = new ResizeObserver(entries => { const c = entries[0].contentRect; set(c.width, c.height); });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  return size;
}
export function Glyph({ d, people, size = '' }) {
  const p = personOf(people, d.owner);
  const isz = size === 'lg' ? 26 : size === 'sm' ? 16 : 20;
  return html`<span className=${`glyph ${size}${d.is_new ? ' is-unknown' : ''}${d.online ? '' : ' is-dim'}`} style=${{ '--pc': devColor(d, p) }}>
    <${Icon} name=${typeIcon(d)} size=${isz} />
  </span>`;
}
export function Bars({ d }) {
  if (isWired(d)) return html`<${Icon} name="ethernet-port" size=${15} />`;
  const s = signalInfo(effSignal(d));
  return html`<span className=${'bars t-' + s.tone} aria-hidden="true">${[1, 2, 3, 4].map(i => html`<i key=${i} className=${i <= s.level ? 'on' : ''} />`)}</span>`;
}
export function StatusChip({ d }) {
  const s = statusOf(d);
  return html`<span className=${'chip ' + s.cls}>${s.dot ? html`<span className="dot" />` : html`<${Icon} name=${s.icon} size=${12} sw=${2.6} />`}${s.label}</span>`;
}
/* A small line chart. null values are gaps, so an outage shows as a break, not as zero. */
export function Spark({ values, w = 96, h = 30, color = 'var(--accent)', max }) {
  const n = values.length;
  if (n < 2) return html`<svg width=${w} height=${h} aria-hidden="true" className="ic" />`;
  const vals = values.filter(v => v != null);
  const m = max || Math.max(1, ...vals) * 1.12;
  const X = i => 2 + (i / (n - 1)) * (w - 6);
  const Y = v => h - 3 - (clamp(v, 0, m) / m) * (h - 7);
  let d = '', pen = false, last = -1;
  values.forEach((v, i) => {
    if (v == null) { pen = false; return; }
    d += (pen ? 'L' : 'M') + X(i).toFixed(1) + ',' + Y(v).toFixed(1);
    pen = true; last = i;
  });
  return html`<svg width=${w} height=${h} viewBox=${`0 0 ${w} ${h}`} aria-hidden="true" className="ic">
    <line x1="2" x2=${w - 4} y1=${h - 3} y2=${h - 3} style=${{ stroke: 'var(--line)', strokeWidth: 1 }} />
    <path d=${d} style=${{ fill: 'none', stroke: color, strokeWidth: 1.75, strokeLinejoin: 'round', strokeLinecap: 'round' }} />
    ${last === n - 1 ? html`<circle cx=${X(n - 1)} cy=${Y(values[n - 1])} r="3" style=${{ fill: color, stroke: 'var(--surface)', strokeWidth: 1.5 }} />` : null}
  </svg>`;
}
export function Seg({ options, value, onChange, label }) {
  return html`<div className="seg" role="group" aria-label=${label}>${options.map(o => html`<button key=${String(o.value)} type="button" aria-pressed=${value === o.value ? 'true' : 'false'} onClick=${() => onChange(o.value)}>${o.icon ? html`<${Icon} name=${o.icon} size=${14} />` : null}${o.label}${o.count != null ? html`<span className="count">${o.count}</span>` : null}</button>`)}</div>`;
}
export function Menu({ trigger, children, align = '', label }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
    const h = e => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    const k = e => { if (e.key === 'Escape') { e.stopPropagation(); setOpen(false); } };
    document.addEventListener('pointerdown', h);
    document.addEventListener('keydown', k, true);
    return () => { document.removeEventListener('pointerdown', h); document.removeEventListener('keydown', k, true); };
  }, [open]);
  return html`<div className="menu-wrap" ref=${ref}>
    ${trigger({ open, toggle: () => setOpen(o => !o) })}
    ${open ? html`<div className=${'menu ' + align} role="menu" aria-label=${label} onClick=${e => { e.stopPropagation(); setOpen(false); }}>${children}</div>` : null}
  </div>`;
}
export function AssignMenu({ people, onPick, label = 'Choose owner', btnClass = 'btn btn-sm btn-primary', align = '', current, noneOption, disabled }) {
  return html`<${Menu} align=${align} label="Choose who uses this device" trigger=${({ toggle, open }) => html`<button type="button" className=${btnClass} disabled=${disabled} aria-haspopup="menu" aria-expanded=${open ? 'true' : 'false'} onClick=${e => { e.stopPropagation(); toggle(); }}>${label}<${Icon} name="chevron-down" size=${14} /></button>`}>
    <div className="menu-label">Whose device is it?</div>
    ${people.map(p => html`<button key=${p.id} type="button" role="menuitem" onClick=${() => onPick(p.id)}><span className="pdot" style=${{ '--pc': pcol(p) }} />${p.name}${current === p.id ? html`<${Icon} name="check" size=${15} style=${{ marginLeft: 'auto' }} />` : null}</button>`)}
    ${current || noneOption ? html`<button type="button" role="menuitem" onClick=${() => onPick(null)}><${Icon} name="x" size=${15} />No owner</button>` : null}
  <//>`;
}
/* Pick a kind of device, for several at once. */
export function TypeMenu({ onPick, label = 'Kind', btnClass = 'btn btn-sm', align = '', disabled }) {
  return html`<${Menu} align=${align} label="Choose the kind of device" trigger=${({ toggle, open }) => html`<button type="button" className=${btnClass} disabled=${disabled} aria-haspopup="menu" aria-expanded=${open ? 'true' : 'false'} onClick=${e => { e.stopPropagation(); toggle(); }}>${label}<${Icon} name="chevron-down" size=${14} /></button>`}>
    <div className="menu-scroll">
      ${Object.entries(TYPES).map(([k, v]) => html`<button key=${k} type="button" role="menuitem" onClick=${() => onPick(k)}><${Icon} name=${v.icon} size=${16} />${v.label}</button>`)}
    </div>
  <//>`;
}
export function Switch({ on, onChange, label, id }) {
  return html`<button type="button" id=${id} role="switch" className="switch" aria-checked=${on ? 'true' : 'false'} aria-label=${label} onClick=${() => onChange(!on)} />`;
}
/* How much of a data allowance is used. compact: just the bar, for lists. */
export function AllowanceMeter({ a, compact }) {
  const tone = allowanceTone(a);
  const left = a.bytes - a.used;
  return html`<div className=${'allow' + (compact ? ' compact' : '')} title=${compact ? allowanceText(a) : undefined}>
    <div className=${'allow-bar t-' + tone} role="meter" aria-valuemin="0" aria-valuemax=${a.bytes} aria-valuenow=${Math.min(a.used, a.bytes)} aria-label=${'Allowance: ' + allowanceText(a)}>
      <span style=${{ width: clamp((a.used / a.bytes) * 100, 1, 100) + '%' }} /></div>
    ${compact ? null : html`<div className="allow-text"><span className="tnum">${allowanceText(a)}</span><span className=${'allow-left t-' + tone}>${left > 0 ? fmtBytes(left) + ' left' : 'Used up'}</span></div>`}
  </div>`;
}
/* Set, change or remove a data allowance. a: the current one, or null. onSave({bytes, period}), or onSave(null) to remove it. */
export function AllowanceEditor({ a, onSave, onCancel }) {
  const [gb, setGb] = useState(a ? String(+(a.bytes / 1e9).toFixed(2)) : '');
  const [period, setPeriod] = useState(a ? a.period : 'day');
  const v = parseFloat(String(gb).replace(',', '.'));
  const ok = isFinite(v) && v >= 0.01 && v <= 100000;
  const save = e => { e.preventDefault(); if (ok) onSave({ bytes: Math.round(v * 1e9), period }); };
  return html`<form className="allow-edit" onSubmit=${save}>
    <div className="row wrap" style=${{ gap: '8px' }}>
      <input className="input allow-gb tnum" type="number" inputMode="decimal" min="0.01" max="100000" step="any" value=${gb} placeholder="2"
        onChange=${e => setGb(e.target.value)} aria-label="Allowance in gigabytes" data-autofocus="true" autoFocus=${true} />
      <span className="ink2">GB</span>
      <select className="select" value=${period} onChange=${e => setPeriod(e.target.value)} aria-label="How often it starts again">
        <option value="day">a day</option><option value="month">a month</option>
      </select>
    </div>
    <div className="row wrap" style=${{ gap: '8px' }}>
      <button type="submit" className="btn btn-sm btn-primary" disabled=${!ok}>${a ? 'Save' : 'Set allowance'}</button>
      ${onCancel ? html`<button type="button" className="btn btn-sm btn-ghost" onClick=${onCancel}>Cancel</button>` : null}
      ${a ? html`<button type="button" className="btn btn-sm btn-ghost btn-danger" onClick=${() => onSave(null)}>Remove allowance</button>` : null}
    </div>
  </form>`;
}
export function CopyBtn({ text, ui, label = 'Copy' }) {
  const copy = e => {
    e.stopPropagation();
    const ok = () => ui.toast({ icon: 'copy', text: 'Copied to clipboard', ttl: 2500 });
    const fail = () => ui.toast({ icon: 'info', text: 'Couldn’t copy here. Select the text and copy it instead.' });
    try { navigator.clipboard.writeText(text).then(ok, fail); } catch (err) { fail(); }
  };
  return html`<button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label=${label} title=${label} onClick=${copy}><${Icon} name="copy" size=${15} /></button>`;
}
export function Stat({ icon, label, value, unit, note, live, children, spark }) {
  return html`<div className="stat">
    <div className="stat-label"><${Icon} name=${icon} size=${14} />${label}${live ? html`<span className="live"><span className="live-dot" style=${{ width: '6px', height: '6px' }} />Live</span>` : null}</div>
    <div className="stat-mid"><span className="stat-value tnum">${value}${unit ? html`<span className="stat-unit">${unit}</span>` : null}</span>${spark || null}</div>
    ${children || null}
    ${note ? html`<div className="stat-note">${note}</div>` : null}
  </div>`;
}
export function Modal({ onClose, title, children, top, className = '', label }) {
  const ref = useRef(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return undefined;
    const back = document.activeElement;
    const f = el.querySelector('[data-autofocus]') || el.querySelector('input, select, button:not(.modal-x)');
    if (f) f.focus();
    return () => { if (back && back.focus) back.focus(); };
  }, []);
  return html`<div className=${'modal-wrap' + (top ? ' top' : '')}>
    <div className="scrim" onClick=${onClose} />
    <div className=${'modal ' + className} role="dialog" aria-modal="true" aria-label=${label || title} ref=${ref} style=${{ zIndex: 61 }} onKeyDown=${trapTab}>
      ${title ? html`<h2 className="modal-title">${title}</h2>` : null}
      ${title ? html`<button type="button" className="btn btn-icon btn-ghost modal-x" aria-label="Close" onClick=${onClose}><${Icon} name="x" size=${18} /></button>` : null}
      ${children}
    </div>
  </div>`;
}
/* Keeps Tab inside an open dialog. */
export function trapTab(e) {
  if (e.key !== 'Tab') return;
  const items = [...e.currentTarget.querySelectorAll('button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])')].filter(el => !el.disabled && el.offsetParent !== null);
  if (!items.length) return;
  const first = items[0], last = items[items.length - 1];
  if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
  else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
}

/* ---------- charts ---------- */
const niceCeil = v => [10, 25, 50, 100, 150, 200, 250, 300, 400, 500, 750, 1000].find(c => c >= v) || Math.ceil(v / 500) * 500;
function niceTicks(max) {
  const step = max <= 10 ? 2.5 : max <= 25 ? 5 : max <= 100 ? 25 : max <= 300 ? 50 : 100;
  const t = [];
  for (let v = 0; v <= max + 0.01; v += step) t.push(v);
  return t;
}
const SPEED_SERIES = [
  { key: 'down', name: 'download', label: 'Download', color: 'var(--accent)', area: true },
  { key: 'up', name: 'upload', label: 'Upload', color: 'var(--muted)' },
];
/* Line chart. points: [{t, ...}]; each series reads one key. null values are gaps, so outages show as breaks. */
export function LineChart({ points, height = 196, xLabels, timeLabel, label, minMax = 10, series = SPEED_SERIES, unit = 'Mbps', fmt = fmtMbps }) {
  const ref = useRef(null);
  const { w } = useSize(ref);
  const [hi, setHi] = useState(null);
  const H = height, L = 38, R = 8, T = 10, B = 26;
  const n = points.length;
  const ymax = niceCeil(Math.max(minMax, ...points.flatMap(p => series.map(sr => p[sr.key] || 0))) * 1.12);
  const ticks = niceTicks(ymax);
  const pw = Math.max(10, w - L - R), ph = H - T - B;
  const X = i => L + (n <= 1 ? 0 : (i / (n - 1)) * pw);
  const Y = v => T + ph - (clamp(v, 0, ymax) / ymax) * ph;
  const segs = key => {
    const out = [];
    let cur = null;
    points.forEach((p, i) => {
      if (p[key] == null) { cur = null; return; }
      if (!cur) { cur = []; out.push(cur); }
      cur.push([X(i), Y(p[key])]);
    });
    return out;
  };
  const f = v => v.toFixed(1);
  const pathOf = list => list.map(sg => sg.map((pt, i) => (i ? 'L' : 'M') + f(pt[0]) + ',' + f(pt[1])).join('')).join('');
  const areaOf = list => list.filter(sg => sg.length > 1).map(sg => `M${f(sg[0][0])},${Y(0)}` + sg.map(pt => `L${f(pt[0])},${f(pt[1])}`).join('') + `L${f(sg[sg.length - 1][0])},${Y(0)}Z`).join('');
  const onMove = e => { const r = e.currentTarget.getBoundingClientRect(); setHi(clamp(Math.round(((e.clientX - r.left - L) / pw) * (n - 1)), 0, n - 1)); };
  const p = hi != null ? points[hi] : null;
  const last = points[n - 1];
  const main = series[0];
  return html`<div className="chart-wrap" ref=${ref}>
    ${w > 0 && n ? html`<svg width=${w} height=${H} role="img" aria-label=${label} onPointerMove=${onMove} onPointerLeave=${() => setHi(null)}>
      ${ticks.map(t => html`<g key=${t}><line className="c-grid" x1=${L} x2=${L + pw} y1=${Y(t)} y2=${Y(t)} /><text className="c-axis" x=${L - 8} y=${Y(t) + 4} textAnchor="end">${t}</text></g>`)}
      ${series.filter(sr => sr.area).map(sr => html`<path key=${'a' + sr.key} d=${areaOf(segs(sr.key))} style=${{ fill: sr.color, fillOpacity: 0.1 }} />`)}
      ${[...series].reverse().map(sr => html`<path key=${sr.key} d=${pathOf(segs(sr.key))} className="c-line" style=${{ stroke: sr.color }} />`)}
      ${last && last[main.key] != null ? html`<circle className="c-dot" cx=${X(n - 1)} cy=${Y(last[main.key])} r="4" style=${{ fill: main.color }} />` : null}
      ${(xLabels || []).map((x, i) => html`<text key=${i} className="c-axis" x=${X(x.i)} y=${H - 6} textAnchor=${x.i === 0 ? 'start' : x.i === n - 1 ? 'end' : 'middle'}>${x.text}</text>`)}
      ${p ? html`<g><line className="c-cross" x1=${X(hi)} x2=${X(hi)} y1=${T} y2=${T + ph} />
        ${series.filter(sr => p[sr.key] != null).map(sr => html`<circle key=${sr.key} className="c-dot" cx=${X(hi)} cy=${Y(p[sr.key])} r="4" style=${{ fill: sr.color }} />`)}</g>` : null}
      <rect x=${L} y=${T} width=${pw} height=${ph} style=${{ fill: 'transparent' }} />
    </svg>` : html`<div style=${{ height: H + 'px' }} />`}
    ${p ? html`<div className="tip below" style=${{ left: clamp(X(hi), 90, w - 90) + 'px', top: '0px', transform: 'translate(-50%, 0)' }}>
      <div className="muted" style=${{ fontSize: '12px' }}>${timeLabel(p, last)}</div>
      ${p[main.key] == null ? html`<div className="tip-row">No reading</div>`
        : series.map(sr => html`<div className="tip-row" key=${sr.key}><span className="lkey" style=${{ '--k': sr.color }} /><span className="tip-val tnum">${p[sr.key] == null ? '–' : fmt(p[sr.key])} ${unit}</span>${sr.name}</div>`)}
    </div>` : null}
    <div className="legend" style=${{ marginTop: '8px' }}>${series.map(sr => html`<span key=${sr.key}><span className="lkey" style=${{ '--k': sr.color }} />${sr.label}</span>`)}</div>
  </div>`;
}
/* Vertical bars of data used, one per hour or day. bars: [{t, down, up}] */
export function UsageBars({ bars, labelOf, tipOf, dense, tall, color = 'var(--accent)' }) {
  const [hi, setHi] = useState(null);
  const vals = bars.map(b => b.down + b.up);
  const max = Math.max(1, ...vals);
  const maxI = vals.indexOf(Math.max(...vals));
  const barMax = tall ? 150 : 62;
  return html`<div className=${'cols' + (dense ? ' dense' : '') + (tall ? ' tall' : '')} style=${{ '--pc': color }} onPointerLeave=${() => setHi(null)}>
    ${bars.map((b, i) => {
      const show = hi === i || (hi == null && i === maxI && vals[i] > 0);
      const lab = labelOf(b, i);
      return html`<div className="col" key=${i} tabIndex="0" aria-label=${`${tipOf(b)}: ${fmtBytes(vals[i])}`} onPointerEnter=${() => setHi(i)} onFocus=${() => setHi(i)} onBlur=${() => setHi(null)}>
        ${show ? html`<span className=${'col-val tnum' + (i > bars.length * 0.7 ? ' left' : i < bars.length * 0.3 ? ' right' : '')}>${fmtBytes(vals[i])}${hi === i ? html`<span className="col-when">${tipOf(b)}</span>` : null}</span>` : null}
        <div className="col-bar" style=${{ height: Math.max(2, (vals[i] / max) * barMax) + 'px', opacity: hi == null || hi === i ? 1 : 0.55 }} />
        <span className="col-day">${lab || ' '}</span>
      </div>`;
    })}
  </div>`;
}
/* Horizontal bars, one per person. rows: [{id, label, color, value}] */
export function HBars({ rows }) {
  const max = Math.max(1, ...rows.map(r => r.value));
  return html`<div className="hbars">${rows.map(r => html`<div className="hbar" key=${r.id}>
    <div className="hbar-label"><span className=${'pdot' + (r.hollow ? ' is-none' : '')} style=${{ '--pc': r.color }} /><span>${r.label}</span></div>
    <div className="hbar-track"><div className="hbar-fill" style=${{ width: `calc(${((r.value / max) * 100).toFixed(2)}% - 72px)`, '--pc': r.color }} /><span className="hbar-val tnum">${fmtBytes(r.value)}</span></div>
  </div>`)}</div>`;
}
/* 24 hours of the dish's dropouts in 15-minute slots. outages: [{start, duration_s, text}].
   Slots before knownSince (when Orbit's records begin) show as "no data" instead of "fine". */
export function OutageStrip({ outages, now, knownSince }) {
  const [hi, setHi] = useState(null);
  const ref = useRef(null);
  const { w } = useSize(ref);
  const slots = new Array(96).fill(null);
  outages.forEach(o => {
    const age = now - o.start;
    if (age >= 0 && age < DAY) { const i = 95 - Math.floor(age / (15 * MIN)); if (i >= 0) slots[i] = (slots[i] || []).concat(o); }
  });
  const slotStart = i => now - (96 - i) * 15 * MIN;
  const unknown = i => knownSince && slotStart(i) + 15 * MIN <= knownSince && !slots[i];
  const o = hi != null ? slots[hi] : null;
  return html`<div className="chart-wrap" ref=${ref} onPointerLeave=${() => setHi(null)}>
    <div className="strip" role="img" aria-label=${`Connection over the last 24 hours: ${plural(outages.length, 'dropout')}`}>
      ${slots.map((z, i) => html`<span key=${i} className=${z ? (Math.max(...z.map(q => q.duration_s)) >= 10 ? 'major' : 'minor') : unknown(i) ? 'nodata' : ''} onPointerEnter=${() => setHi(i)} />`)}
    </div>
    ${hi != null ? html`<div className="tip" style=${{ left: clamp(((hi + 0.5) / 96) * w, 100, w - 100) + 'px', top: '0px' }}>
      <div className="tip-title tnum">${fmtClock(slotStart(hi))} – ${fmtClock(slotStart(hi) + 15 * MIN)}</div>
      ${o ? o.map((q, k) => html`<div className="tip-row" key=${k}><${Icon} name="triangle-alert" size=${13} />Dropped for <span className="tip-val">${q.duration_s < 1 ? 'under a second' : fmtSecs(q.duration_s)}</span></div>`)
        : unknown(hi) ? html`<div className="tip-row"><${Icon} name="history" size=${13} />Before Orbit’s records start</div>`
        : html`<div className="tip-row"><${Icon} name="circle-check" size=${13} />No dropouts</div>`}
      ${o ? html`<div className="tip-row">${o[o.length - 1].text}</div>` : null}
    </div>` : null}
    <div className="strip-axis"><span>24 h ago</span><span>12 h ago</span><span>Now</span></div>
  </div>`;
}
