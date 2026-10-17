/* Floor plan: draw your walls, place your devices, and see where something weakens the Wi-Fi signal.
   Orbit saves the plan on its own server, so every window and the Mac app show the same one. It never writes to the dish or router. */
import { html, useState, useEffect, useRef, useMemo, Fragment, clamp, enterKey, useSize, plural, Icon, Seg, typeIcon } from './lib.js';
import { ICONS } from './icons.js';
import { getJSON, send } from './data.js';

/* ---------- the model: the same numbers as the Mac app ---------- */
export const MATS = {
  drywall: { name: 'Plasterboard', db: [3, 4], w: 3, col: 'var(--sky-ink-2)' },
  glass: { name: 'Glass', db: [2, 3], w: 3, col: 'var(--sky-accent)', dash: '6 4' },
  brick: { name: 'Brick', db: [7, 10], w: 5, col: '#d9915c' },
  concrete: { name: 'Concrete', db: [11, 15], w: 6, col: '#e5675f' },
  metal: { name: 'Metal or mirror', db: [12, 16], w: 4, col: '#f0c24d', dash: '2 3' },
};
const MAT_ORDER = ['drywall', 'glass', 'brick', 'concrete', 'metal'];
const P1 = { '2.4': -38, '5': -44 };  /* Orbit's first guess for the signal 1 m from the router; it tunes this from your devices */
const MIN_TUNE = 3;                   /* devices needed before Orbit trusts its tuning */

/* Do the segments p-q and a-b cross each other? Touching an end doesn't count. */
export function segCross(p, q, a, b) {
  const cr = (o, u, v) => (u[0] - o[0]) * (v[1] - o[1]) - (u[1] - o[1]) * (v[0] - o[0]);
  const d1 = cr(p, q, a), d2 = cr(p, q, b), d3 = cr(a, b, p), d4 = cr(a, b, q);
  return d1 * d2 < 0 && d3 * d4 < 0;
}
const wallDb = (w, band) => (MATS[w.mat] || MATS.drywall).db[band === '2.4' ? 0 : 1];
export const wallsBetween = (p, q, walls) => walls.filter(w => segCross(p, q, w.a, w.b));
/* The signal (dBm) the plan expects at point p: distance from the router, minus every wall in the way. */
export function predict(p, router, band, walls, extraDb = 0) {
  const d = Math.max(1, Math.hypot(p[0] - router.x, p[1] - router.y));
  let loss = 0;
  for (const w of walls) if (segCross([router.x, router.y], p, w.a, w.b)) loss += wallDb(w, band);
  return P1[band] + extraDb - 20 * Math.log10(d) - loss;
}
/* How far the guess is off, typically, across the devices that are on the plan. Needs at least 3. */
export function tuneOffset(placed, router, walls) {
  if (placed.length < MIN_TUNE) return 0;
  const raw = placed.map(d => d.measured - predict([d.x, d.y], router, d.band, walls, 0)).sort((a, b) => a - b);
  return raw[Math.floor(raw.length / 2)];
}
export function gapVerdict(g) {
  if (g >= 5) return { tone: 'accent', word: 'Stronger than the plan says', icon: 'arrow-up' };
  if (g >= -5) return { tone: 'good', word: 'Matches the plan', icon: 'circle-check' };
  if (g >= -10) return { tone: 'warn', word: 'A little weak', icon: 'circle-alert' };
  return { tone: 'crit', word: 'Much weaker than the plan says', icon: 'triangle-alert' };
}

/* ---------- small helpers ---------- */
const MIN_SIZE = 4, MAX_SIZE = 40, DEF_W = 12, DEF_H = 8;
const snap = (v, g) => Math.round((Math.round(v / g) * g) * 100) / 100;
const newId = pre => pre + Math.random().toString(36).slice(2, 7) + Date.now().toString(36).slice(-4);
const shortName = (n, max = 17) => (n.length > max ? n.slice(0, max - 1) + '…' : n);
const fmtDb = v => { const r = Math.round(v); return (r > 0 ? '+' : r < 0 ? '−' : '') + Math.abs(r); };
const dBm = v => { const r = Math.round(v); return (r < 0 ? '−' : '') + Math.abs(r); };
const lenOf = w => Math.hypot(w.b[0] - w.a[0], w.b[1] - w.a[1]);
const matOf = w => MATS[w.mat] || MATS.drywall;
const noteStyle = { fontSize: '13px', marginTop: '10px' };

/* A new plan: four outer brick walls with the router in the middle, or nothing drawn yet. */
function startPlan(w, h, outline) {
  const i = 0.5;
  const wall = (a, b) => ({ id: newId('w'), a, b, mat: 'brick' });
  return {
    w, h, router: { x: snap(w / 2, 0.1), y: snap(h / 2, 0.1) }, rooms: [], devices: {},
    walls: outline ? [wall([i, i], [w - i, i]), wall([w - i, i], [w - i, h - i]), wall([w - i, h - i], [i, h - i]), wall([i, h - i], [i, i])] : [],
  };
}
/* The same plan at another size. Whatever would fall outside is pulled back in, and walls that shrink to nothing go. */
function resized(plan, w, h) {
  const pin = (v, max) => Math.round(clamp(v, 0.2, max - 0.2) * 100) / 100;
  const edge = (v, max) => Math.round(Math.min(v, max) * 100) / 100;
  const devices = {};
  for (const id of Object.keys(plan.devices)) devices[id] = { x: pin(plan.devices[id].x, w), y: pin(plan.devices[id].y, h) };
  return {
    ...plan, w, h, devices,
    router: { x: pin(plan.router.x, w), y: pin(plan.router.y, h) },
    rooms: plan.rooms.map(r => ({ ...r, x: pin(r.x, w), y: pin(r.y, h) })),
    walls: plan.walls.map(x => ({ ...x, a: [edge(x.a[0], w), edge(x.a[1], h)], b: [edge(x.b[0], w), edge(x.b[1], h)] })).filter(x => lenOf(x) >= 0.05),
  };
}

/* ---------- loading and saving the plan ---------- */
let inflight = Promise.resolve();  /* a save that is still on its way; coming back to this page waits for it */

/* Keeps the plan in sync with the server. It saves ~0.8 s after an edit (not on every move of a drag), also when you leave the page,
   and it never saves before the first load has come back, so a blank plan can't overwrite a real one. */
function usePlanStore(s, ui) {
  const [status, setStatus] = useState('loading');  /* loading | ready | failed */
  const [plan, setPlan] = useState(null);
  const [saveState, setSaveState] = useState('idle');  /* idle | saving | saved | failed */
  const r = useRef(null);
  if (!r.current) r.current = { plan: null, rev: 0, dirty: false, saving: false, failed: false, ready: false, dragging: false, wantSync: false, timer: 0, alive: true, ui, last: s.plan_rev };
  r.current.ui = ui;

  const api = useMemo(() => {
    const m = r.current;
    const load = () => {
      setStatus('loading');
      return inflight.then(() => getJSON('/api/plan')).then(res => {
        if (!m.alive) return;
        m.rev = res.rev; m.plan = res.plan; m.ready = true; m.dirty = false; m.wantSync = false;
        setPlan(res.plan); setStatus('ready');
      }, () => { if (m.alive) setStatus('failed'); });
    };
    const save = () => {
      clearTimeout(m.timer);
      m.timer = 0;
      if (!m.ready || !m.dirty || !m.plan) return inflight;
      if (m.saving) return inflight;  /* when this one finishes, it saves again if there is more */
      m.saving = true; m.dirty = false;
      setSaveState('saving');
      inflight = send('POST', '/api/plan', { v: 1, ...m.plan }).then(res => {
        m.rev = res.rev; m.wantSync = false; m.saving = false;
        if (m.dirty) return save();
        setSaveState('saved');
        return null;
      }, e => {
        m.saving = false; m.dirty = true; m.failed = true;
        m.ui.toast({ icon: 'info', text: 'Your plan didn’t save', sub: e.message });
        setSaveState('failed');
        return null;
      });
      return inflight;
    };
    const schedule = () => {
      m.dirty = true; m.failed = false;
      clearTimeout(m.timer);
      m.timer = setTimeout(save, 800);
      setSaveState('saving');
    };
    /* Another window saved: fetch its plan, unless we have edits of our own that are about to overwrite it. */
    const sync = () => {
      if (!m.wantSync || !m.ready || m.dirty || m.saving || m.dragging) return;
      m.wantSync = false;
      getJSON('/api/plan').then(res => {
        if (!m.alive) return;
        if (m.dirty || m.saving || m.dragging) { m.wantSync = true; return; }
        if (res.rev === m.rev) return;
        m.rev = res.rev; m.plan = res.plan;
        setPlan(res.plan);
      }, () => { /* the next change tries again */ });
    };
    return {
      load, save, sync,
      /* Change the plan. live: part of a drag, so don't start the save timer until the pointer lets go. */
      update(fn, live) {
        if (!m.ready) return;
        const next = fn(m.plan);
        if (!next || next === m.plan) return;
        m.plan = next;
        setPlan(next);
        if (live) { m.dirty = true; m.failed = false; setSaveState('saving'); } else schedule();
      },
      dragging(on) {
        m.dragging = on;
        if (!on) { if (m.dirty) schedule(); sync(); }
      },
      retry() { m.failed = false; m.dirty = true; save(); },
      /* Leaving the page: send what hasn't gone yet. */
      flush() { if (m.dirty && !m.failed) save(); },
      hide() {
        if (!m.dirty || m.failed || !m.ready || !m.plan) return;
        m.dirty = false;
        try { fetch('/api/plan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ v: 1, ...m.plan }), keepalive: true }); } catch (e) { m.dirty = true; }
      },
      /* The live state carries a plan revision that changes whenever any window saves. */
      seen(rev) {
        if (rev === undefined || rev === m.last) return;
        m.last = rev;
        if (rev !== m.rev) { m.wantSync = true; sync(); }
      },
    };
  }, []);

  useEffect(() => {
    const m = r.current;
    api.load();
    const away = () => { if (document.visibilityState === 'hidden') api.flush(); };
    window.addEventListener('pagehide', api.hide);
    document.addEventListener('visibilitychange', away);
    return () => {
      m.alive = false;
      clearTimeout(m.timer);
      window.removeEventListener('pagehide', api.hide);
      document.removeEventListener('visibilitychange', away);
      api.flush();
    };
  }, []);
  useEffect(() => { api.seen(s.plan_rev); }, [s.plan_rev]);

  return { status, plan, saveState, ...api };
}

/* ---------- pieces ---------- */
function PlanHead({ children }) {
  return html`<div className="page-head"><div><h1 className="page-title">Floor plan</h1>
    <p className="page-sub">Draw your walls and place your devices. Orbit compares each device’s Wi-Fi signal with what your plan predicts, and points out the ones with something in the way.</p></div>${children || null}</div>`;
}

function SaveNote({ st }) {
  const bad = st.saveState === 'failed', busy = st.saveState === 'saving';
  return html`<span className=${'plan-save' + (bad ? ' is-bad' : '')} role="status">
    ${bad ? html`<${Icon} name="info" size=${14} />Not saved<button type="button" className="link-btn" onClick=${st.retry}>Try again</button>`
      : busy ? html`<${Icon} name="refresh-cw" size=${14} className="spin" />Saving…` : html`<${Icon} name="check" size=${14} />Saved`}
  </span>`;
}

/* A size in whole metres, with a button each way. */
function Stepper({ label, value, onChange }) {
  const set = v => onChange(clamp(v, MIN_SIZE, MAX_SIZE));
  return html`<div className="stepper" role="group" aria-label=${label}>
    <span className="stepper-label">${label}</span>
    <button type="button" className="btn btn-sm btn-icon" aria-label=${`Make the ${label.toLowerCase()} smaller`} disabled=${value <= MIN_SIZE} onClick=${() => set(Math.ceil(value) - 1)}><${Icon} name="minus" size=${14} /></button>
    <span className="stepper-val tnum">${+value.toFixed(1)} m</span>
    <button type="button" className="btn btn-sm btn-icon" aria-label=${`Make the ${label.toLowerCase()} bigger`} disabled=${value >= MAX_SIZE} onClick=${() => set(Math.floor(value) + 1)}><${Icon} name="plus" size=${14} /></button>
  </div>`;
}

/* The first time: no plan yet, so ask how big the home is and offer an outline. */
function PlanStart({ onStart }) {
  const [w, setW] = useState(DEF_W), [h, setH] = useState(DEF_H);
  return html`<div className="view"><${PlanHead} />
    <section className="card plan-start" aria-label="Start your floor plan">
      <div className="plan-preview" aria-hidden="true" style=${{ '--ar': w / h }} />
      <div><h2 className="card-title" style=${{ fontSize: '19px' }}>Draw your home so Orbit can tell where walls weaken the signal</h2>
        <p className="ink2" style=${{ marginTop: '6px' }}>Say roughly how big your home is. A guess is fine, you can change it later. Orbit draws an outline with the router in the middle, then you move the router, add walls and place your devices.</p></div>
      <div className="row wrap" style=${{ justifyContent: 'center', gap: '10px 22px' }}>
        <${Stepper} label="Width" value=${w} onChange=${setW} /><${Stepper} label="Depth" value=${h} onChange=${setH} />
      </div>
      <div className="row wrap" style=${{ justifyContent: 'center' }}>
        <button type="button" className="btn btn-primary" onClick=${() => onStart(startPlan(w, h, true))}><${Icon} name="house" size=${16} />Start with an outline</button>
        <button type="button" className="btn" onClick=${() => onStart(startPlan(w, h, false))}>Start empty</button>
      </div>
      <p className="muted" style=${{ fontSize: '13px' }}>Your plan is saved by Orbit, so it looks the same in every window.</p>
    </section></div>`;
}

/* Type a short name for a spot you just tapped. */
function RoomNamer({ onSave, onCancel }) {
  const [v, setV] = useState('');
  const ok = v.trim().length > 0;
  return html`<form onSubmit=${e => { e.preventDefault(); if (ok) onSave(v.trim()); }}>
    <div className="card-head" style=${{ marginBottom: '10px' }}><div><h2 className="card-title">Name this spot</h2><div className="card-sub">A short name, like Kitchen or Bedroom 1</div></div></div>
    <input className="input" value=${v} maxLength=${30} placeholder="Kitchen" aria-label="Room name" autoComplete="off" autoFocus=${true} data-autofocus="true"
      onChange=${e => setV(e.target.value)} onKeyDown=${e => { if (e.key === 'Escape') { e.preventDefault(); onCancel(); } }} />
    <div className="row wrap" style=${{ marginTop: '10px' }}>
      <button type="submit" className="btn btn-sm btn-primary" disabled=${!ok}>Add name</button>
      <button type="button" className="btn btn-sm btn-ghost" onClick=${onCancel}>Cancel</button>
    </div>
  </form>`;
}
/* Change or remove a room name that is already on the plan. */
function RoomEdit({ room, onRename, onRemove, onClose }) {
  const [v, setV] = useState(room.name);
  useEffect(() => { setV(room.name); }, [room.id]);
  const change = e => { setV(e.target.value); if (e.target.value.trim()) onRename(e.target.value.trim()); };
  return html`<div className="card-head"><div><h2 className="card-title">Room name</h2><div className="card-sub">Drag it on the plan to move it</div></div>
      <button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label="Clear selection" onClick=${onClose}><${Icon} name="x" size=${15} /></button></div>
    <input className="input" value=${v} maxLength=${30} aria-label="Room name" autoComplete="off" onChange=${change} onBlur=${() => setV(room.name)} />
    <button type="button" className="btn btn-sm btn-danger" style=${{ alignSelf: 'flex-start', marginTop: '10px' }} onClick=${onRemove}><${Icon} name="trash-2" size=${14} />Remove this name</button>`;
}

/* A device that isn't on the plan yet. Tap it, then tap its spot. With a mouse you can also drag it onto the plan. */
function TrayChip({ d, on, onPick, onDrop }) {
  const [ghost, setGhost] = useState(null);
  const press = useRef(null);
  const quiet = useRef(false);
  const down = e => {
    if (e.pointerType !== 'mouse' || e.button !== 0) return;
    press.current = { x: e.clientX, y: e.clientY, moved: false };
    const move = ev => {
      const p = press.current;
      if (!p) return;
      if (!p.moved && Math.hypot(ev.clientX - p.x, ev.clientY - p.y) < 6) return;
      p.moved = true;
      setGhost({ x: ev.clientX, y: ev.clientY });
    };
    const up = ev => {
      window.removeEventListener('pointermove', move);
      window.removeEventListener('pointerup', up);
      const p = press.current;
      press.current = null;
      setGhost(null);
      if (p && p.moved) { quiet.current = true; setTimeout(() => { quiet.current = false; }, 0); onDrop(d.id, ev.clientX, ev.clientY); }
    };
    window.addEventListener('pointermove', move);
    window.addEventListener('pointerup', up);
  };
  return html`<${Fragment}>
    <button type="button" className=${'chip plan-dev' + (on ? ' chip-accent' : '')} aria-pressed=${on ? 'true' : 'false'} onPointerDown=${down} onClick=${() => { if (!quiet.current) onPick(d.id); }}>
      <${Icon} name=${typeIcon(d)} size=${14} />${d.name}</button>
    ${ghost ? html`<span className="chip plan-dev plan-ghost" style=${{ left: ghost.x + 'px', top: ghost.y + 'px' }}><${Icon} name=${typeIcon(d)} size=${14} />${d.name}</span>` : null}
  <//>`;
}

/* ---------- the editor ---------- */
function PlanEditor({ s, ui, st }) {
  const { plan, update } = st;
  const { w, h, router, walls, rooms } = plan;
  const [sel, setSel] = useState(null);           /* null | {kind: 'dev' | 'wall' | 'room' | 'router', id} */
  const [mode, setMode] = useState(null);         /* null | 'wall' | 'room' | {place: deviceId} */
  const [draft, setDraft] = useState(null);       /* where the wall being drawn starts */
  const [hover, setHover] = useState(null);       /* where it would end */
  const [roomAt, setRoomAt] = useState(null);     /* the spot waiting for a room name */
  const [view, setView] = useState('devices');
  const [covBand, setCovBand] = useState('5');
  const drag = useRef(null);
  const svgRef = useRef(null), stageRef = useRef(null);
  const { w: sw } = useSize(stageRef);
  const PS = sw > 0 ? sw / w : 40;                /* pixels per metre; 1 drawing unit is 1 pixel, so dots keep their size on any plan */
  const sh = sw * h / w;
  const px = v => (v * PS).toFixed(1);
  const stars = useMemo(() => {
    let a = 5;
    const rnd = () => { a = (a * 16807) % 2147483647; return a / 2147483647; };
    return Array.from({ length: 50 }, () => ({ x: rnd(), y: rnd(), r: 0.4 + rnd() * 0.9, o: 0.12 + rnd() * 0.4 }));
  }, []);

  /* Online Wi-Fi devices with a real signal reading; wired ones and ones without a reading can't be compared. */
  const devs = s.devices.filter(d => d.online && !d.hidden && (d.band === '2.4' || d.band === '5') && d.signal != null);
  const placed = devs.filter(d => plan.devices[d.id]).map(d => ({ id: d.id, name: d.name, type: d.type, band: d.band, x: plan.devices[d.id].x, y: plan.devices[d.id].y, measured: d.signal }));
  const unplaced = devs.filter(d => !plan.devices[d.id]);
  const tuned = placed.length >= MIN_TUNE;
  const offset = tuneOffset(placed, router, walls);
  const rows = placed.map(d => {
    const expected = tuned ? predict([d.x, d.y], router, d.band, walls, offset) : null;
    const gap = tuned ? d.measured - expected : null;
    return { ...d, crossed: wallsBetween([router.x, router.y], [d.x, d.y], walls), expected, gap, v: tuned ? gapVerdict(gap) : null, dist: Math.hypot(d.x - router.x, d.y - router.y) };
  });
  const problems = rows.filter(x => x.gap != null && x.gap < -5).sort((a, b) => a.gap - b.gap);
  const stronger = rows.filter(x => x.gap != null && x.gap >= 5).length;
  const selDev = sel && sel.kind === 'dev' ? rows.find(x => x.id === sel.id) : null;
  const selWall = sel && sel.kind === 'wall' ? walls.find(x => x.id === sel.id) : null;
  const selRoom = sel && sel.kind === 'room' ? rooms.find(x => x.id === sel.id) : null;
  const hiW = selDev ? new Set(selDev.crossed.map(x => x.id)) : new Set();
  const noWalls = walls.length === 0;

  /* The coverage picture: what the plan says the signal is, spot by spot, in runs of equal strength. Built once per change. */
  const covOff = Math.round(offset * 2) / 2;
  const coverage = useMemo(() => {
    if (view !== 'coverage') return null;
    const cell = 0.5, nx = Math.ceil(w / cell), ny = Math.ceil(h / cell), runs = [];
    for (let j = 0; j < ny; j++) {
      let run = null;
      for (let i = 0; i < nx; i++) {
        const v = predict([Math.min(w, (i + 0.5) * cell), Math.min(h, (j + 0.5) * cell)], { x: router.x, y: router.y }, covBand, walls, covOff);
        const lv = v >= -55 ? 3 : v >= -63 ? 2 : v >= -70 ? 1 : 0;
        if (run && run.lv === lv) run.n++;
        else { run = { i, j, n: 1, lv }; runs.push(run); }
      }
    }
    return html`<g aria-hidden="true" style=${{ pointerEvents: 'none' }}>${runs.map(q => html`<rect key=${q.j + '-' + q.i} className=${'plan-cov l' + q.lv} x=${px(q.i * 0.5)} y=${px(q.j * 0.5)} width=${px(Math.min(q.n * 0.5, w - q.i * 0.5))} height=${px(0.5)} />`)}</g>`;
  }, [view, covBand, w, h, router.x, router.y, walls, covOff, PS]);

  const toPlan = e => {
    const b = svgRef.current.getBoundingClientRect();
    return [clamp(((e.clientX - b.left) / b.width) * w, 0, w), clamp(((e.clientY - b.top) / b.height) * h, 0, h)];
  };
  const inside = (v, max) => clamp(v, 0.2, max - 0.2);
  /* Move the router, a device or a room name. live: a drag is still going. */
  const move = (kind, id, q, live) => update(p => (kind === 'router' ? { ...p, router: { x: q[0], y: q[1] } }
    : kind === 'dev' ? { ...p, devices: { ...p.devices, [id]: { x: q[0], y: q[1] } } }
    : { ...p, rooms: p.rooms.map(z => (z.id === id ? { ...z, x: q[0], y: q[1] } : z)) }), live);
  const spot = e => { const p = toPlan(e); return [snap(inside(p[0], w), 0.1), snap(inside(p[1], h), 0.1)]; };
  const placeDevice = (id, q) => { update(p => ({ ...p, devices: { ...p.devices, [id]: { x: q[0], y: q[1] } } })); setSel({ kind: 'dev', id }); setMode(null); };

  const onMove = e => {
    const d = drag.current;
    if (d) {
      if (!d.moved && Math.hypot(e.clientX - d.from[0], e.clientY - d.from[1]) < 3) return;
      d.moved = true;
      const p = toPlan(e);
      move(d.kind, d.id, [snap(inside(p[0] + d.off[0], w), 0.1), snap(inside(p[1] + d.off[1], h), 0.1)], true);
    } else if (mode === 'wall' && draft) {
      const p = toPlan(e);
      setHover([snap(p[0], 0.25), snap(p[1], 0.25)]);
    }
  };
  const endDrag = () => { if (!drag.current) return; drag.current = null; st.dragging(false); };
  /* Taps on the empty plan: place a device, draw a wall, name a spot, or just let go of the selection. */
  const onCanvas = e => {
    const p = toPlan(e);
    if (mode && mode.place) { placeDevice(mode.place, [snap(inside(p[0], w), 0.1), snap(inside(p[1], h), 0.1)]); return; }
    if (mode === 'wall') {
      const q = [snap(p[0], 0.25), snap(p[1], 0.25)];
      if (!draft) { setDraft(q); setHover(q); return; }
      if (Math.hypot(q[0] - draft[0], q[1] - draft[1]) < 0.3) { setDraft(null); return; }
      const id = newId('w');
      update(pl => ({ ...pl, walls: [...pl.walls, { id, a: draft, b: q, mat: 'drywall' }] }));
      setSel({ kind: 'wall', id }); setDraft(null); setHover(null); setMode(null);
      return;
    }
    if (mode === 'room') { setRoomAt([snap(inside(p[0], w), 0.25), snap(inside(p[1], h), 0.25)]); setSel(null); return; }
    setSel(null);
  };
  const startDrag = (e, kind, id, x, y) => {
    if (mode || (e.button != null && e.button !== 0)) return;  /* while drawing or placing, taps belong to the plan */
    const p = toPlan(e);
    drag.current = { kind, id, off: [x - p[0], y - p[1]], from: [e.clientX, e.clientY], moved: false };
    st.dragging(true);
    try { e.currentTarget.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    setSel({ kind, id });
  };
  const pick = (e, kind, id) => { if (mode) return; e.stopPropagation(); setSel({ kind, id }); };
  const nudge = (e, kind, id, x, y) => {
    const k = e.key, step = e.shiftKey ? 0.5 : 0.1;
    const d = k === 'ArrowLeft' ? [-step, 0] : k === 'ArrowRight' ? [step, 0] : k === 'ArrowUp' ? [0, -step] : k === 'ArrowDown' ? [0, step] : null;
    if (!d) return false;
    e.preventDefault();
    move(kind, id, [snap(inside(x + d[0], w), 0.1), snap(inside(y + d[1], h), 0.1)]);
    setSel({ kind, id });
    return true;
  };
  const nodeKey = (e, kind, id, x, y) => { if (e.target !== e.currentTarget) return; if (!nudge(e, kind, id, x, y)) enterKey(() => setSel({ kind, id }))(e); };

  const setMat = (id, mat) => update(p => ({ ...p, walls: p.walls.map(x => (x.id === id ? { ...x, mat } : x)) }));
  const removeWall = id => {
    const was = walls.find(x => x.id === id);
    if (!was) return;
    update(p => ({ ...p, walls: p.walls.filter(x => x.id !== id) }));
    setSel(null);
    ui.toast({ icon: 'trash-2', text: 'Removed the wall', ttl: 5000, undo: () => update(p => ({ ...p, walls: [...p.walls, was] })) });
  };
  const removeRoom = id => {
    const was = rooms.find(x => x.id === id);
    if (!was) return;
    update(p => ({ ...p, rooms: p.rooms.filter(x => x.id !== id) }));
    setSel(null);
    ui.toast({ icon: 'trash-2', text: `Removed “${was.name}”`, ttl: 5000, undo: () => update(p => ({ ...p, rooms: [...p.rooms, was] })) });
  };
  const takeOff = id => {
    const was = plan.devices[id];
    const d = s.devices.find(x => x.id === id);
    update(p => { const next = { ...p.devices }; delete next[id]; return { ...p, devices: next }; });
    setSel(null);
    ui.toast({ icon: 'map-pin', text: `${d ? d.name : 'The device'} is off the plan`, ttl: 5000, undo: () => update(p => ({ ...p, devices: { ...p.devices, [id]: was } })) });
  };
  const addRoom = name => {
    const id = newId('r');
    update(p => ({ ...p, rooms: [...p.rooms, { id, name, x: roomAt[0], y: roomAt[1] }] }));
    setRoomAt(null); setMode(null); setSel({ kind: 'room', id });
  };
  const rename = (id, name) => update(p => ({ ...p, rooms: p.rooms.map(x => (x.id === id ? { ...x, name } : x)) }));
  const cancel = () => { setMode(null); setDraft(null); setHover(null); setRoomAt(null); };
  const toggleMode = m => { setSel(null); setDraft(null); setHover(null); setRoomAt(null); setMode(cur => (cur === m ? null : m)); };
  const dropOn = (id, x, y) => {
    const b = svgRef.current.getBoundingClientRect();
    if (x < b.left || x > b.right || y < b.top || y > b.bottom) return;
    const p = toPlan({ clientX: x, clientY: y });
    placeDevice(id, [snap(inside(p[0], w), 0.1), snap(inside(p[1], h), 0.1)]);
  };

  /* Delete removes the selected wall or room name; Escape lets go of whatever you were doing. */
  useEffect(() => {
    const k = e => {
      if (document.querySelector('.modal-wrap, .drawer')) return;
      const tag = (document.activeElement && document.activeElement.tagName) || '';
      if (/INPUT|TEXTAREA|SELECT/.test(tag)) return;
      if ((e.key === 'Delete' || e.key === 'Backspace') && sel && (sel.kind === 'wall' || sel.kind === 'room')) { e.preventDefault(); if (sel.kind === 'wall') removeWall(sel.id); else removeRoom(sel.id); }
      else if (e.key === 'Escape' && (mode || sel || roomAt)) { cancel(); setSel(null); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [sel, mode, roomAt, plan]);
  /* On a touch screen the page scrolls when you touch empty space. While you draw or place something, touching the plan must not. */
  useEffect(() => {
    const el = svgRef.current;
    if (!el) return undefined;
    const block = e => { if ((drag.current || mode) && e.cancelable) e.preventDefault(); };
    el.addEventListener('touchmove', block, { passive: false });
    return () => el.removeEventListener('touchmove', block);
  }, [mode]);
  /* A device you were placing that goes offline (or gets placed in another window) can't be placed any more. */
  useEffect(() => { if (mode && mode.place && !unplaced.some(d => d.id === mode.place)) setMode(null); }, [unplaced.map(d => d.id).join(',')]);

  const sub = mode === 'wall' ? (draft ? 'Tap where the wall ends.' : 'Tap where the wall starts.') : mode === 'room' ? 'Tap where the name should go.'
    : mode && mode.place ? 'Tap the plan to place it.'
    : selDev ? `${selDev.name}: ${dBm(selDev.measured)} dBm measured${selDev.v ? `, the plan predicts ${dBm(selDev.expected)}. ${selDev.v.word}.` : '.'}`
    : 'Drag the router or a device to move it. Tap one to see its signal.';
  const gridStep = PS >= 20 ? 1 : 2;
  const gx = [], gy = [];
  for (let i = 0; i <= w; i += gridStep) gx.push(i);
  for (let i = 0; i <= h; i += gridStep) gy.push(i);

  const banner = !tuned
    ? html`<div className="banner"><span className="banner-ic" style=${{ color: 'var(--accent)' }}><${Icon} name="info" size=${18} /></span>
        <div className="grow"><div className="banner-title">Place at least 3 devices so Orbit can tune its guess</div>
          <div className="banner-body">${devs.length < MIN_TUNE ? `${devs.length === 0 ? 'No devices with a Wi-Fi signal are' : plural(devs.length, 'device') + ' with a Wi-Fi signal ' + (devs.length === 1 ? 'is' : 'are')} online right now. Orbit needs 3 to compare, so come back when more are connected.`
            : `${placed.length ? plural(placed.length, 'device') + ' placed so far. ' : ''}Tap a device under “Not on the plan yet”, then tap its spot on the plan.`}${noWalls ? ' You haven’t drawn any walls yet, so for now the prediction is distance only.' : ''}</div></div></div>`
    : problems.length ? html`<div className="banner warn"><span className="banner-ic"><${Icon} name="triangle-alert" size=${18} /></span>
        <div className="grow"><div className="banner-title">${problems.length === 1 ? problems[0].name + ' is weaker than your plan predicts' : problems.length + ' devices are weaker than your plan predicts'}</div>
          <div className="banner-body">${problems[0].name} measures ${dBm(problems[0].measured)} dBm, but ${noWalls ? 'going by distance alone' : 'with the walls you drew'} it should be about ${dBm(problems[0].expected)} dBm. ${noWalls ? 'You haven’t drawn any walls yet. A wall, a metal cabinet, a mirror or a fish tank in the way would weaken it like this.' : 'Something that isn’t on the plan is in the way, such as a metal cabinet, a mirror, a fish tank or a thick wall.'}</div>
          <div className="row wrap" style=${{ marginTop: '10px' }}><button type="button" className="btn btn-sm" onClick=${() => { setView('devices'); cancel(); setMode('wall'); setSel({ kind: 'dev', id: problems[0].id }); }}><${Icon} name="pencil" size=${14} />Draw what’s in the way</button>
            <button type="button" className="btn btn-sm" onClick=${() => { setView('devices'); setSel({ kind: 'dev', id: problems[0].id }); }}>Show on the plan</button></div></div></div>`
    : html`<div className="banner"><span className="banner-ic" style=${{ color: 'var(--good-ink)' }}><${Icon} name="circle-check" size=${18} /></span>
        <div className="grow"><div className="banner-title">${stronger ? 'No device is weaker than your plan predicts' : 'Every device matches your plan'}</div>
          <div className="banner-body">Orbit tuned its guess using ${placed.length} devices. Nothing unexpected is in the way.${noWalls ? ' You haven’t drawn any walls yet, so the prediction is distance only.' : ''}</div></div></div>`;

  const sideCard = roomAt ? html`<${RoomNamer} onSave=${addRoom} onCancel=${cancel} />`
    : selDev ? html`<${Fragment}><div className="card-head"><div><h2 className="card-title">${selDev.name}</h2><div className="card-sub">${selDev.band} GHz · ${selDev.dist.toFixed(1)} m from the router</div></div>
          <button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label="Clear selection" onClick=${() => setSel(null)}><${Icon} name="x" size=${15} /></button></div>
        ${selDev.v ? html`<div className="plan-nums"><div><small>Measured</small><b className="tnum">${dBm(selDev.measured)}<span className="stat-unit">dBm</span></b></div><div><small>Plan predicts</small><b className="tnum">${dBm(selDev.expected)}<span className="stat-unit">dBm</span></b></div><div><small>Gap</small><b className="tnum">${fmtDb(selDev.gap)}<span className="stat-unit">dB</span></b></div></div>
          <span className=${'chip chip-' + selDev.v.tone} style=${{ alignSelf: 'flex-start', marginTop: '10px' }}><${Icon} name=${selDev.v.icon} size=${12} sw=${2.6} />${selDev.v.word}</span>`
          : html`<div className="plan-nums one"><div><small>Measured</small><b className="tnum">${dBm(selDev.measured)}<span className="stat-unit">dBm</span></b></div></div>
            <p className="muted" style=${noteStyle}>Place at least 3 devices so Orbit can tune its guess. Then it can say whether this signal matches your plan.</p>`}
        <div className="setting-title" style=${{ marginTop: '12px' }}>${selDev.crossed.length ? 'Walls between it and the router' : 'A clear line to the router'}</div>
        ${selDev.crossed.length ? html`<div className="chips" style=${{ marginTop: '6px' }}>${selDev.crossed.map(x => html`<button type="button" key=${x.id} className="chip" onClick=${() => setSel({ kind: 'wall', id: x.id })}>${matOf(x).name} · −${wallDb(x, selDev.band)} dB</button>`)}</div>` : html`<div className="muted" style=${{ fontSize: '13.5px' }}>No walls are drawn between them.</div>`}
        ${selDev.v ? html`<p className="ink2" style=${{ fontSize: '14px', marginTop: '12px' }}>${selDev.gap < -10 ? 'Much weaker than the walls explain. Something not on the plan is probably in the way: a metal cabinet, a mirror, a fish tank, or a thicker wall than you drew. Draw it, or move the device a little to test.'
          : selDev.gap < -5 ? 'A bit weaker than expected. Furniture or a closed door could be the cause.'
          : selDev.gap >= 5 ? 'Stronger than expected. A door may be open, or a wall on the plan may be thinner than you set.' : 'About what the plan predicts. The signal is explained by the distance and walls.'}</p>` : null}
        ${noWalls ? html`<p className="muted" style=${noteStyle}>No walls are drawn yet, so this prediction is distance only.</p>` : null}
        <button type="button" className="btn btn-sm btn-ghost" style=${{ alignSelf: 'flex-start', marginTop: '10px' }} onClick=${() => takeOff(selDev.id)}><${Icon} name="map-pin" size=${14} />Take it off the plan</button><//>`
    : selWall ? html`<${Fragment}><div className="card-head"><div><h2 className="card-title">${matOf(selWall).name} wall</h2><div className="card-sub">${lenOf(selWall).toFixed(1)} m long · takes ${matOf(selWall).db[0]} dB off 2.4 GHz and ${matOf(selWall).db[1]} dB off 5 GHz</div></div>
          <button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label="Clear selection" onClick=${() => setSel(null)}><${Icon} name="x" size=${15} /></button></div>
        <div className="setting-title">What is it made of?</div>
        <div className="chips" style=${{ marginTop: '6px' }}>${MAT_ORDER.map(k => html`<button type="button" key=${k} className=${'chip' + (selWall.mat === k ? ' chip-accent' : '')} aria-pressed=${selWall.mat === k ? 'true' : 'false'} onClick=${() => setMat(selWall.id, k)}>${MATS[k].name}</button>`)}</div>
        <p className="muted" style=${noteStyle}>Thicker, denser walls take more signal. 5 GHz loses more through a wall than 2.4 GHz does.</p>
        <button type="button" className="btn btn-sm btn-danger" style=${{ alignSelf: 'flex-start', marginTop: '10px' }} onClick=${() => removeWall(selWall.id)}><${Icon} name="trash-2" size=${14} />Remove this wall</button><//>`
    : selRoom ? html`<${RoomEdit} room=${selRoom} onRename=${name => rename(selRoom.id, name)} onRemove=${() => removeRoom(selRoom.id)} onClose=${() => setSel(null)} />`
    : sel && sel.kind === 'router' ? html`<${Fragment}><div className="card-head"><div><h2 className="card-title">Your router</h2><div className="card-sub">${router.x.toFixed(1)} m across, ${router.y.toFixed(1)} m down</div></div>
          <button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label="Clear selection" onClick=${() => setSel(null)}><${Icon} name="x" size=${15} /></button></div>
        <p className="ink2" style=${{ fontSize: '14px' }}>Drag it to where it really sits. Orbit predicts every signal from this spot. The arrow keys move it in small steps.</p><//>`
    : html`<div className="row" style=${{ gap: '12px', alignItems: 'flex-start' }}><span className="net-ic"><${Icon} name="crosshair" size=${17} /></span><div><div className="card-title">Pick a device or a wall</div><div className="card-sub">Tap one on the plan to see its signal, or change what a wall is made of.</div></div></div>`;

  return html`<div className="view"><${PlanHead}><${SaveNote} st=${st} /><//>
    ${banner}
    <div className="grid">
      <div className="s-8"><section className="sky plan-wrap" aria-label="Floor plan">
        <div className="orbit-head"><div><h2 className="sky-title">Your home</h2><div className="sky-sub">${sub}</div></div>
          <div className="plan-tools"><${Seg} label="What to show" value=${view} onChange=${setView} options=${[{ value: 'devices', label: 'Devices' }, { value: 'coverage', label: 'Coverage' }]} />
            ${view === 'coverage' ? html`<${Seg} label="Wi-Fi band" value=${covBand} onChange=${setCovBand} options=${[{ value: '2.4', label: '2.4 GHz' }, { value: '5', label: '5 GHz' }]} />` : null}</div></div>
        <div className="plan-stage" ref=${stageRef} style=${{ '--ar': w / h }}>
          <svg ref=${svgRef} className=${mode ? 'is-busy' : ''} viewBox=${`0 0 ${sw || 100} ${sw ? sh : 100 * h / w}`} role="group" aria-label="Floor plan with walls, the router and devices"
            onPointerMove=${onMove} onPointerUp=${endDrag} onPointerCancel=${endDrag} onClick=${onCanvas} style=${{ cursor: mode ? 'crosshair' : 'default' }}>
            <g aria-hidden="true" style=${{ pointerEvents: 'none' }}>
              ${stars.map((q, i) => html`<circle key=${i} className="o-star" cx=${(q.x * w * PS).toFixed(1)} cy=${(q.y * h * PS).toFixed(1)} r=${q.r.toFixed(2)} style=${{ opacity: q.o }} />`)}
              ${gx.map(i => html`<line key=${'gx' + i} className="plan-grid" x1=${px(i)} y1="0" x2=${px(i)} y2=${px(h)} />`)}
              ${gy.map(i => html`<line key=${'gy' + i} className="plan-grid" x1="0" y1=${px(i)} x2=${px(w)} y2=${px(i)} />`)}
            </g>
            ${coverage}
            ${rooms.map(z => { const on = selRoom && selRoom.id === z.id, bw = Math.max(40, z.name.length * 7.4 + 14);
              return html`<g key=${z.id} className=${'plan-node plan-roomtag' + (on ? ' is-sel' : '')} transform=${`translate(${px(z.x)} ${px(z.y)})`} tabIndex="0" role="button" aria-pressed=${on ? 'true' : 'false'} aria-label=${`Room name: ${z.name}. Press Delete to remove it.`}
                  onPointerDown=${e => startDrag(e, 'room', z.id, z.x, z.y)} onClick=${e => pick(e, 'room', z.id)} onKeyDown=${e => nodeKey(e, 'room', z.id, z.x, z.y)}>
                <rect className="plan-room-box" x=${-bw / 2} y="-12" width=${bw} height="24" rx="6" />
                <text className="plan-room" y="4" textAnchor="middle">${z.name}</text></g>`; })}
            ${roomAt ? html`<g transform=${`translate(${px(roomAt[0])} ${px(roomAt[1])})`} style=${{ pointerEvents: 'none' }}><circle className="plan-spot" r="9" /><circle fill="var(--sky-accent)" r="2.5" /></g>` : null}
            ${walls.map(x => { const m = matOf(x), on = selWall && selWall.id === x.id, hot = hiW.has(x.id);
              const ln = { x1: px(x.a[0]), y1: px(x.a[1]), x2: px(x.b[0]), y2: px(x.b[1]) };
              return html`<g key=${x.id}>
                ${hot ? html`<line ...${ln} className="plan-hot" style=${{ pointerEvents: 'none' }} />` : null}
                <line ...${ln} stroke=${m.col} strokeWidth=${m.w} strokeLinecap="round" strokeDasharray=${m.dash || undefined} style=${{ pointerEvents: 'none' }} />
                ${on ? html`<line ...${ln} className="plan-pick" style=${{ pointerEvents: 'none' }} />` : null}
                <line ...${ln} className="plan-wall-hit" onClick=${e => pick(e, 'wall', x.id)} tabIndex="0" role="button" aria-pressed=${on ? 'true' : 'false'} aria-label=${`${m.name} wall, ${lenOf(x).toFixed(1)} metres. Press Delete to remove it.`} onKeyDown=${e => { if (e.key === 'Delete' || e.key === 'Backspace') { e.preventDefault(); removeWall(x.id); } else enterKey(() => setSel({ kind: 'wall', id: x.id }))(e); }} />
              </g>`; })}
            ${draft && hover ? html`<line x1=${px(draft[0])} y1=${px(draft[1])} x2=${px(hover[0])} y2=${px(hover[1])} className="plan-draft" style=${{ pointerEvents: 'none' }} />` : null}
            ${draft ? html`<circle cx=${px(draft[0])} cy=${px(draft[1])} r="4" fill="var(--sky-accent)" style=${{ pointerEvents: 'none' }} />` : null}
            ${selDev ? html`<line x1=${px(router.x)} y1=${px(router.y)} x2=${px(selDev.x)} y2=${px(selDev.y)} className=${'plan-link' + (selDev.v ? ' ' + selDev.v.tone : '')} style=${{ pointerEvents: 'none' }} />` : null}
            <g className=${'plan-node' + (sel && sel.kind === 'router' ? ' is-sel' : '')} transform=${`translate(${px(router.x)} ${px(router.y)})`} onPointerDown=${e => startDrag(e, 'router', 'router', router.x, router.y)} onClick=${e => pick(e, 'router', 'router')}
                tabIndex="0" role="button" aria-label="Router. Drag it, or use the arrow keys, to move it." onKeyDown=${e => nodeKey(e, 'router', 'router', router.x, router.y)}>
              <circle fill="transparent" r="24" />
              <circle className="pulse-ring" r="18" /><circle className="o-router" r="18" />
              <svg x="-9" y="-9" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)', pointerEvents: 'none' }} dangerouslySetInnerHTML=${{ __html: ICONS.router }} />
            </g>
            ${rows.map(x => { const bad = x.gap != null && x.gap < -5, col = x.v && x.v.tone === 'crit' ? 'var(--crit)' : 'var(--warn)', on = selDev && selDev.id === x.id;
              /* the name sits under the dot, or above it near the bottom edge, and leans inward near the sides */
              const lx = x.x * PS, edge = { a: lx < 60 ? 'start' : lx > sw - 60 ? 'end' : 'middle', x: lx < 60 ? -12 : lx > sw - 60 ? 12 : 0, y: x.y * PS > sh - 42 ? -22 : 28 };
              return html`<g key=${x.id} className=${'plan-node' + (on ? ' is-sel' : '')} transform=${`translate(${px(x.x)} ${px(x.y)})`} onPointerDown=${e => startDrag(e, 'dev', x.id, x.x, x.y)} onClick=${e => pick(e, 'dev', x.id)}
                  tabIndex="0" role="button" aria-pressed=${on ? 'true' : 'false'} aria-label=${`${x.name}, ${dBm(x.measured)} dBm${x.v ? ', ' + x.v.word : ''}. Drag it, or use the arrow keys, to move it.`} onKeyDown=${e => nodeKey(e, 'dev', x.id, x.x, x.y)}>
                <title>${x.name}, ${dBm(x.measured)} dBm</title>
                <circle fill="transparent" r="20" />
                ${bad ? html`<circle className="o-halo" r="15" style=${{ stroke: col }} />` : null}
                <circle className="o-body" r="13" style=${{ stroke: bad ? col : 'var(--sky-accent)' }} />
                <svg x="-7" y="-7" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)', pointerEvents: 'none' }} dangerouslySetInnerHTML=${{ __html: ICONS[typeIcon(x)] }} />
                ${on || bad ? html`<text className="o-label" x=${edge.x} y=${edge.y} textAnchor=${edge.a}>${shortName(x.name)}${bad ? ' ' + fmtDb(x.gap) : ''}</text>` : null}
              </g>`; })}
          </svg>
        </div>
        <div className="plan-bar">
          <button type="button" className=${'btn btn-sm' + (mode === 'wall' ? ' btn-accent' : '')} aria-pressed=${mode === 'wall' ? 'true' : 'false'} onClick=${() => toggleMode('wall')}><${Icon} name="pencil" size=${14} />${mode === 'wall' ? 'Cancel' : 'Add a wall'}</button>
          <button type="button" className=${'btn btn-sm' + (mode === 'room' ? ' btn-accent' : '')} aria-pressed=${mode === 'room' ? 'true' : 'false'} onClick=${() => toggleMode('room')}><${Icon} name="tag" size=${14} />${mode === 'room' ? 'Cancel' : 'Add a room name'}</button>
          <span className="plan-scale"><i style=${{ width: Math.round(PS) + 'px' }} />1 m</span>
        </div>
        <div className="plan-bar plan-size"><span className="plan-size-title">House size</span>
          <${Stepper} label="Width" value=${w} onChange=${v => update(p => resized(p, v, p.h))} /><${Stepper} label="Depth" value=${h} onChange=${v => update(p => resized(p, p.w, v))} /></div>
        <div className="sec-keys">
          ${view === 'coverage' ? html`<${Fragment}><span><i className="plan-sw" style=${{ '--k': 'var(--good)' }} />Strong</span><span><i className="plan-sw" style=${{ '--k': 'var(--warn)' }} />Fair</span><span><i className="plan-sw" style=${{ '--k': 'var(--crit)' }} />Weak</span>
              <span>${noWalls ? 'Predicted signal, from distance only' : 'Predicted signal, from the walls you drew'}</span>${tuned ? null : html`<span>Orbit’s first guess: place at least 3 devices so it can tune this</span>`}<//>`
            : html`<${Fragment}>${MAT_ORDER.map(k => html`<span key=${k}><i className="sec-key-line solid" style=${{ '--k': MATS[k].col }} />${MATS[k].name}</span>`)}<//>`}
        </div>
      </section></div>
      <div className="s-4"><div className="stack">
        <section className="card" style=${{ display: 'flex', flexDirection: 'column' }}>${sideCard}</section>
        <section className="card plan-tray">
          <div className="card-head"><div><h2 className="card-title">Not on the plan yet</h2><div className="card-sub">${unplaced.length ? 'Tap one, then tap its spot on the plan. With a mouse you can drag it too.' : devs.length ? 'Every device is placed' : 'No devices with a Wi-Fi signal are online'}</div></div></div>
          ${unplaced.length ? html`<div className="chips">${unplaced.map(d => html`<${TrayChip} key=${d.id} d=${d} on=${!!(mode && mode.place === d.id)} onDrop=${dropOn}
            onPick=${id => { setDraft(null); setHover(null); setRoomAt(null); setSel(null); setMode(mode && mode.place === id ? null : { place: id }); }} />`)}</div>`
            : html`<div className="muted" style=${{ fontSize: '13.5px' }}>${devs.length ? 'Orbit uses every placed device to tune its guess.' : 'Devices that are online show up here. Wired devices can’t be compared, and neither can ones without a signal reading.'}</div>`}
        </section>
        <section className="card">
          <div className="card-head"><div><h2 className="card-title">How this works</h2></div></div>
          <div className="see-row"><${Icon} name="circle-alert" size=${17} className="see-part" /><div className="ink2" style=${{ fontSize: '14px' }}>Your router can’t see walls. It only reports how strong each device’s signal is.</div></div>
          <div className="see-row"><${Icon} name="circle-check" size=${17} className="see-yes" /><div className="ink2" style=${{ fontSize: '14px' }}>Orbit works out what each device should get from the distance and the walls you draw, then tunes that guess using all your devices (${tuned ? `${offset >= 0 ? '+' : '−'}${Math.abs(Math.round(offset))} dB so far` : 'it starts once 3 are placed'}).</div></div>
          ${noWalls ? html`<div className="see-row"><${Icon} name="circle-alert" size=${17} className="see-part" /><div className="ink2" style=${{ fontSize: '14px' }}>You haven’t drawn any walls, so the prediction is distance only. Add walls to make it sharper.</div></div>` : null}
          <div className="see-row"><${Icon} name="circle-alert" size=${17} className="see-part" /><div className="ink2" style=${{ fontSize: '14px' }}>It’s an estimate, good to about 6 dB. Use it to spot odd cases, not to measure.</div></div>
        </section>
      </div></div>
    </div>
  </div>`;
}

export function PlanView({ s, ui }) {
  const st = usePlanStore(s, ui);
  if (st.status === 'loading' && !st.plan) return html`<div className="view"><${PlanHead} /><section className="card"><div className="empty">Loading your plan…</div></section></div>`;
  if (st.status === 'failed') return html`<div className="view"><${PlanHead} /><section className="card"><div className="empty">Orbit couldn’t load your plan.<div style=${{ marginTop: '12px' }}><button type="button" className="btn btn-sm" onClick=${st.load}>Try again</button></div></div></section></div>`;
  if (!st.plan) return html`<${PlanStart} onStart=${plan => st.update(() => plan)} />`;
  return html`<${PlanEditor} s=${s} ui=${ui} st=${st} />`;
}
