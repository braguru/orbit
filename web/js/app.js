/* Orbit: the app shell. Navigation, search, toasts and changes all go through here. */
import {
  html, useState, useEffect, useRef, useMemo, useCallback, Fragment, uid, clamp, IS_MAC, fmtShortDate, fmtDur, fmtLimit,
  Icon, BrandMark, Glyph, Modal, statusOf, personOf, PERIOD,
} from './lib.js';
import { useLive, send } from './data.js';
import { Overview, derive } from './overview.js';
import { SpeedModal } from './speedtest.js';
import { DevicesView, DeviceDrawer, MergeModal } from './devices.js';
import { PeopleView, PersonModal, AllowanceModal } from './people.js';
import { UsageView } from './usage.js';
import { StarlinkView } from './starlink.js';
import { ActivityView } from './activity.js';

const FONTS = 'https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@62..125,500..800&family=Atkinson+Hyperlegible+Mono:wght@400;500&family=Atkinson+Hyperlegible+Next:wght@400;500;600;700&display=swap';
const VIEWS = [
  { id: 'overview', label: 'Overview', icon: 'house' },
  { id: 'devices', label: 'Devices', icon: 'monitor-smartphone' },
  { id: 'people', label: 'People', icon: 'users-round' },
  { id: 'usage', label: 'Usage', icon: 'chart-no-axes-column' },
  { id: 'starlink', label: 'Starlink', icon: 'satellite-dish' },
  { id: 'activity', label: 'Activity', icon: 'activity' },
];

/* Fonts load in the background. Without internet the page uses system fonts, and still works. */
function loadFonts() {
  const l = document.createElement('link');
  l.rel = 'stylesheet';
  l.href = FONTS;
  document.head.appendChild(l);
}

/* ---------- changes, each with a toast and, where it makes sense, undo ---------- */
function makeApi(getS, refresh, ui) {
  const dev = id => getS().devices.find(d => d.id === id);
  const post = (url, body) => send('POST', url, body).then(r => { refresh(); return r; });
  const fail = e => ui.toast({ icon: 'info', text: 'That didn’t work', sub: e.message });
  const api = {
    rename(id, name) {
      const d = dev(id);
      if (!d) return;
      const prev = d.custom_name || '';
      post(`/api/devices/${id}`, { name }).then(r => ui.toast({ icon: 'pencil', text: name ? `Renamed to ${r.name}` : `Back to the router’s name, ${r.name}`, undo: () => api.rename(id, prev) }), fail);
    },
    assign(id, owner) {
      const d = dev(id);
      if (!d) return;
      const prev = d.owner || null;
      post(`/api/devices/${id}`, { owner }).then(() => {
        const p = personOf(getS().people, owner);
        ui.toast({ icon: 'tag', text: p ? `${d.name} now belongs to ${p.name}` : `${d.name} has no owner now`, undo: () => post(`/api/devices/${id}`, { owner: prev }).catch(fail) });
      }, fail);
    },
    setType(id, type) {
      const d = dev(id);
      if (!d) return;
      const prev = d.type_set ? d.type : null;
      post(`/api/devices/${id}`, { type }).then(() => ui.toast({ icon: 'tag', text: 'Device type saved', ttl: 3000, undo: () => post(`/api/devices/${id}`, { type: prev }).catch(fail) }), fail);
    },
    acknowledge(id) {
      const d = dev(id);
      post(`/api/devices/${id}`, { acknowledged: true }).then(() => ui.toast({ icon: 'shield-check', text: `${d ? d.name : 'Device'} is marked as known`, sub: 'Give it an owner any time from People.', ttl: 4000 }), fail);
    },
    forget(id) {
      const d = dev(id);
      ui.closeDevice();
      send('DELETE', `/api/devices/${id}`).then(() => { refresh(); ui.toast({ icon: 'trash-2', text: `Forgot ${d ? d.name : 'the device'}`, sub: 'If it connects again, it shows up as new.' }); }, fail);
    },
    setNotes(id, notes) {
      post(`/api/devices/${id}`, { notes }).then(() => ui.toast({ icon: 'pencil', text: notes ? 'Note saved' : 'Note removed', ttl: 2500 }), fail);
    },
    setHidden(id, hidden) {
      const d = dev(id);
      if (!d) return;
      post(`/api/devices/${id}`, { hidden }).then(() => ui.toast({
        icon: hidden ? 'eye-off' : 'eye', text: hidden ? `Hid ${d.name}` : `${d.name} is back in your lists`,
        sub: hidden ? 'It’s under Hidden on the Devices page. Orbit still records what it uses.' : null,
        undo: () => post(`/api/devices/${id}`, { hidden: !hidden }).catch(fail),
      }), fail);
    },
    setAllowance(id, allowance) {
      const d = dev(id);
      if (!d) return;
      const prev = d.allowance ? { bytes: d.allowance.bytes, period: d.allowance.period } : null;
      post(`/api/devices/${id}`, { allowance }).then(() => ui.toast({
        icon: 'bell-ring', text: allowance ? `${d.name}: ${fmtLimit(allowance.bytes)} ${PERIOD[allowance.period].per}` : `Removed ${d.name}’s allowance`,
        sub: allowance ? 'Orbit tells you when it’s nearly used up, and when it’s used up.' : null,
        undo: () => post(`/api/devices/${id}`, { allowance: prev }).catch(fail),
      }), fail);
    },
    setPersonAllowance(pid, allowance) {
      const p = personOf(getS().people, pid);
      if (!p) return;
      const prev = p.allowance ? { bytes: p.allowance.bytes, period: p.allowance.period } : null;
      post(`/api/people/${pid}`, { allowance }).then(() => ui.toast({
        icon: 'bell-ring', text: allowance ? `${p.name}: ${fmtLimit(allowance.bytes)} ${PERIOD[allowance.period].per}` : `Removed ${p.name}’s allowance`,
        sub: allowance ? `It counts all of ${p.name}’s devices together.` : null,
        undo: () => post(`/api/people/${pid}`, { allowance: prev }).catch(fail),
      }), fail);
    },
    /* One change to several devices: changes is [{id, owner | type | hidden | acknowledged}]. */
    bulk(changes, text, icon = 'tag') {
      const before = changes.map(c => {
        const d = dev(c.id) || {};
        const b = { id: c.id };
        if ('owner' in c) b.owner = d.owner || null;
        if ('type' in c) b.type = d.type_set ? d.type : null;
        if ('hidden' in c) b.hidden = !!d.hidden;
        return b;
      }).filter(b => Object.keys(b).length > 1);
      return post('/api/devices/bulk', { changes }).then(() => ui.toast({
        icon, text, undo: before.length ? () => post('/api/devices/bulk', { changes: before }).catch(fail) : null,
      }), fail);
    },
    forgetMany(ids) {
      const names = ids.map(id => (dev(id) || {}).name).filter(Boolean);
      ui.closeDevice();
      return post('/api/devices/forget', { ids }).then(() => ui.toast({
        icon: 'trash-2', text: ids.length === 1 ? `Forgot ${names[0] || 'the device'}` : `Forgot ${ids.length} devices`,
        sub: ids.length === 1 ? 'If it connects again, it shows up as new.' : 'If they connect again, they show up as new.',
      }), fail);
    },
    merge(id, other) {
      post(`/api/devices/${id}/merge`, { other }).then(r => {
        ui.openDevice(r.id);
        ui.toast({ icon: 'link', text: `Merged into ${r.name}`, sub: 'One device now, with both histories.' });
      }, fail);
    },
    separate(id, cid, name) {
      send('DELETE', `/api/devices/${id}/aliases/${cid}`).then(() => {
        refresh();
        ui.toast({ icon: 'unlink', text: `${name || 'That connection'} is its own device again`, sub: 'What it used so far stays where it was.' });
      }, fail);
    },
    addPerson(name, devices) {
      post('/api/people', { name, devices }).then(() => { ui.toast({ icon: 'user-plus', text: `Added ${name}`, sub: devices.length ? `${devices.length} device${devices.length === 1 ? '' : 's'} moved to ${name}.` : 'Open a device and choose them as its owner.' }); ui.go('people'); }, fail);
    },
    renamePerson(id, name) {
      post(`/api/people/${id}`, { name }).then(() => ui.toast({ icon: 'pencil', text: `Renamed to ${name}`, ttl: 3000 }), fail);
    },
    removePerson(id) {
      const p = personOf(getS().people, id);
      send('DELETE', `/api/people/${id}`).then(() => { refresh(); ui.toast({ icon: 'user', text: `Removed ${p ? p.name : 'that person'}`, sub: 'Their devices have no owner now.' }); }, fail);
    },
    speedtest() {
      post('/api/speedtest', {}).catch(fail);
    },
    signOut() {
      send('POST', '/api/logout', {}).then(() => location.reload(), fail);
    },
  };
  return api;
}

/* ---------- theme ---------- */
function readTheme() {
  const a = document.documentElement.getAttribute('data-theme');
  if (a === 'dark' || a === 'light') return a;
  return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}
function useTheme() {
  const [theme, setTheme] = useState(readTheme);
  useEffect(() => {
    const on = () => setTheme(readTheme());
    const mq = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
    if (mq && mq.addEventListener) mq.addEventListener('change', on);
    return () => { if (mq && mq.removeEventListener) mq.removeEventListener('change', on); };
  }, []);
  const toggle = useCallback(() => {
    const next = readTheme() === 'dark' ? 'light' : 'dark';
    document.documentElement.setAttribute('data-theme', next);
    try { localStorage.setItem('orbit-theme', next); } catch (e) { /* ignore */ }
    setTheme(next);
  }, []);
  return [theme, toggle];
}

/* ---------- sign-in, for other devices when Orbit runs with --lan ---------- */
function LoginScreen({ onDone }) {
  const [code, setCode] = useState('');
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const digits = code.replace(/\D/g, '');
  const submit = e => {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    send('POST', '/api/login', { code }).then(onDone, er => { setErr(er.message); setBusy(false); });
  };
  return html`<div className="boot"><form className="login" onSubmit=${submit}>
    <${BrandMark} size=${34} />
    <h1 className="modal-title">Sign in to Orbit</h1>
    <p className="muted">Enter the access code shown in the terminal on the computer that runs Orbit. You only need to do this once on this device.</p>
    <input className="input login-code" inputMode="numeric" autoComplete="one-time-code" autoFocus placeholder="1234-5678" maxLength=${12}
      value=${code} onChange=${e => setCode(e.target.value)} aria-label="Access code" aria-invalid=${err ? 'true' : 'false'} />
    ${err ? html`<p className="login-err" role="alert">${err}</p>` : null}
    <button type="submit" className="btn btn-primary" disabled=${busy || digits.length !== 8}>${busy ? 'Checking…' : 'Sign in'}</button>
  </form></div>`;
}

/* ---------- search palette ---------- */
function Palette({ s, api, ui, theme, toggleTheme, session }) {
  const [q, setQ] = useState('');
  const [i, setI] = useState(0);
  const listRef = useRef(null);
  const items = [];
  const add = (group, label, icon, run, extra) => items.push({ key: group + ':' + (extra && extra.device ? extra.device.id : label), group, label, icon, run, ...(extra || {}) });
  VIEWS.forEach(v => add('Go to', v.label, v.icon, () => ui.go(v.id)));
  add('Actions', 'Run a speed test', 'gauge', () => ui.openModal({ type: 'speed' }));
  add('Actions', 'Add a person', 'user-plus', () => ui.openModal({ type: 'person' }));
  add('Actions', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme', theme === 'dark' ? 'sun' : 'moon', toggleTheme);
  if (session && session.required && !session.local) add('Actions', 'Sign out of this device', 'unlink', () => api.signOut());
  s.devices.forEach(d => add('Devices', d.name, null, () => ui.openDevice(d.id), { device: d, hint: statusOf(d).label + (d.hidden ? ' · Hidden' : '') + (d.ip ? ' · ' + d.ip : '') }));
  s.people.forEach(p => add('People', p.name, 'user', () => ui.go('people')));
  const words = q.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const shown = items.filter(it => words.every(w => (it.label + ' ' + (it.hint || '') + ' ' + it.group).toLowerCase().includes(w)));
  const idx = clamp(i, 0, Math.max(0, shown.length - 1));
  const run = it => { ui.closeModal(); it.run(); };
  useEffect(() => { const el = listRef.current && listRef.current.querySelector('.is-active'); if (el) el.scrollIntoView({ block: 'nearest' }); }, [idx, q]);
  const onKey = e => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setI(idx + 1 >= shown.length ? 0 : idx + 1); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setI(idx - 1 < 0 ? shown.length - 1 : idx - 1); }
    else if (e.key === 'Enter' && shown[idx]) { e.preventDefault(); run(shown[idx]); }
  };
  let lastGroup = null;
  return html`<${Modal} onClose=${ui.closeModal} top=${true} className="palette" label="Search devices and pages">
    <div className="palette-in"><${Icon} name="search" size=${18} style=${{ color: 'var(--muted)' }} />
      <input id="palette-q" data-autofocus="true" value=${q} placeholder="Search devices, people, pages…" onChange=${e => { setQ(e.target.value); setI(0); }} onKeyDown=${onKey} aria-label="Search" autoComplete="off" />
      <button type="button" className="btn btn-sm btn-ghost" onClick=${ui.closeModal}>Esc</button></div>
    <div className="palette-list" ref=${listRef} role="listbox">
      ${shown.map((it, k) => { const head = it.group !== lastGroup ? it.group : null; lastGroup = it.group; return html`<${Fragment} key=${it.key}>
        ${head ? html`<div className="palette-group">${head}</div>` : null}
        <button type="button" role="option" aria-selected=${k === idx ? 'true' : 'false'} className=${'palette-item' + (k === idx ? ' is-active' : '')} onMouseMove=${() => k !== idx && setI(k)} onClick=${() => run(it)}>
          ${it.device ? html`<${Glyph} d=${it.device} people=${s.people} size="sm" />` : html`<${Icon} name=${it.icon} size=${17} />`}<span>${it.label}</span>${it.hint ? html`<span className="hint">${it.hint}</span>` : null}
        </button><//>`; })}
      ${shown.length === 0 ? html`<div className="empty">Nothing matches “${q}”.</div>` : null}
    </div>
    <div className="palette-foot"><span>↑ ↓ to move</span><span>Enter to open</span><span>${IS_MAC ? '⌘K' : 'Ctrl K'} to toggle</span></div>
  <//>`;
}

function ConfirmModal({ m, ui }) {
  return html`<${Modal} onClose=${ui.closeModal} title=${m.title}>
    <p className="ink2">${m.body}</p>
    <div className="row" style=${{ justifyContent: 'flex-end' }}><button type="button" className="btn btn-ghost" onClick=${ui.closeModal}>Cancel</button>
      <button type="button" data-autofocus="true" className=${'btn ' + (m.danger ? 'btn-danger' : 'btn-primary')} onClick=${() => { ui.closeModal(); m.fn(); }}>${m.label}</button></div>
  <//>`;
}

function Toasts({ toasts, close }) {
  return html`<div className="toasts" role="status" aria-live="polite">${toasts.map(t => html`<div className="toast" key=${t.id}>
    ${t.icon ? html`<${Icon} name=${t.icon} size=${17} />` : null}
    <div className="toast-text">${t.text}${t.sub ? html`<small>${t.sub}</small>` : null}</div>
    ${t.undo ? html`<button type="button" className="toast-btn" onClick=${() => { t.undo(); close(t.id); }}>Undo</button>` : null}
    ${(t.actions || []).map(a => html`<button type="button" key=${a.label} className="toast-btn" onClick=${() => { close(t.id); a.fn(); }}>${a.label}</button>`)}
    <button type="button" className="toast-btn" aria-label="Dismiss" onClick=${() => close(t.id)}><${Icon} name="x" size=${15} /></button>
  </div>`)}</div>`;
}

/* ---------- the shell ---------- */
function App() {
  const { s, conn, session, points, devHist, refresh, signedIn } = useLive();
  const sRef = useRef(s);
  sRef.current = s;
  const [view, setView] = useState(() => { const h = (location.hash || '').slice(1); return VIEWS.some(v => v.id === h) ? h : 'overview'; });
  const [drawer, setDrawer] = useState(null);
  const [modal, setModal] = useState(null);
  const [toasts, setToasts] = useState([]);
  const [theme, toggleTheme] = useTheme();
  const closeToast = useCallback(id => setToasts(ts => ts.filter(t => t.id !== id)), []);
  const toast = useCallback(t => { const id = uid(); setToasts(ts => [...ts.slice(-2), { id, ...t }]); setTimeout(() => closeToast(id), t.ttl || 6500); }, [closeToast]);
  const ui = useMemo(() => ({
    toast, openDevice: id => { setModal(null); setDrawer(id); }, closeDevice: () => setDrawer(null),
    go: v => { setView(v); setDrawer(null); setModal(null); window.scrollTo(0, 0); }, openModal: m => setModal(m), closeModal: () => setModal(null),
  }), [toast]);
  const api = useMemo(() => makeApi(() => sRef.current, refresh, ui), [refresh, ui]);

  // A toast when a new device joins while the page is open.
  const seen = useRef(null);
  useEffect(() => {
    if (!s) return;
    if (seen.current === null) { seen.current = new Set(s.events.map(e => e.id)); return; }
    for (const e of s.events) {
      if (seen.current.has(e.id)) continue;
      seen.current.add(e.id);
      if (e.cat === 'security' && e.device) toast({ icon: 'shield-alert', text: e.title, sub: e.detail, ttl: 15000, actions: [{ label: 'Review', fn: () => ui.openDevice(e.device) }] });
      else if (e.icon === 'gauge' && e.cat === 'network') toast({ icon: 'gauge', text: e.title, sub: e.detail, ttl: 9000, actions: [{ label: 'Details', fn: () => ui.openModal({ type: 'speed' }) }] });
      else if (e.cat === 'usage') toast({ icon: 'bell-ring', text: e.title, sub: e.detail, ttl: 15000, actions: [e.device ? { label: 'Details', fn: () => ui.openDevice(e.device) } : { label: 'People', fn: () => ui.go('people') }] });
    }
  }, [s && s.events[0] && s.events[0].id]);

  useEffect(() => {
    const k = e => {
      const tag = (document.activeElement && document.activeElement.tagName) || '';
      const typing = /INPUT|TEXTAREA|SELECT/.test(tag);
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') { e.preventDefault(); setModal(m => (m && m.type === 'palette' ? null : { type: 'palette' })); }
      else if (e.key === '/' && !typing && !modal) { e.preventDefault(); setModal({ type: 'palette' }); }
      else if (e.key === 'Escape') { if (modal) setModal(null); else if (drawer) setDrawer(null); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [modal, drawer]);
  useEffect(() => { document.body.style.overflow = drawer || modal ? 'hidden' : ''; }, [drawer, modal]);
  useEffect(() => { try { history.replaceState(null, '', '#' + view); } catch (e) { /* ignore */ } }, [view]);

  if (conn === 'login') return html`<${LoginScreen} onDone=${signedIn} />`;
  if (!s) {
    return html`<div className="boot"><div><${BrandMark} size=${34} /><p style=${{ marginTop: '12px', fontWeight: 650 }}>${conn === 'lost' ? 'Orbit’s server isn’t answering.' : 'Connecting to Orbit…'}</p>
      ${conn === 'lost' ? html`<p className="muted" style=${{ marginTop: '6px', maxWidth: '40ch' }}>Start it on the computer it runs on with <span className="mono">.venv/bin/python -m orbit</span>, then reload this page.</p>` : null}</div></div>`;
  }
  const x = derive(s);
  const badge = id => (id === 'devices' && x.unknown.length ? html`<span className="nav-count" aria-label=${x.unknown.length + ' new'}>${x.unknown.length}</span>` : null);
  const props = { s, x, points, devHist, api, ui };
  const viewEl = view === 'devices' ? html`<${DevicesView} ...${props} />` : view === 'people' ? html`<${PeopleView} ...${props} />`
    : view === 'usage' ? html`<${UsageView} ...${props} />` : view === 'starlink' ? html`<${StarlinkView} ...${props} />`
    : view === 'activity' ? html`<${ActivityView} ...${props} />` : html`<${Overview} ...${props} />`;
  let modalEl = null;
  if (modal) {
    if (modal.type === 'person') modalEl = html`<${PersonModal} s=${s} api=${api} ui=${ui} person=${modal.person} />`;
    else if (modal.type === 'confirm') modalEl = html`<${ConfirmModal} m=${modal} ui=${ui} />`;
    else if (modal.type === 'palette') modalEl = html`<${Palette} s=${s} api=${api} ui=${ui} theme=${theme} toggleTheme=${toggleTheme} session=${session} />`;
    else if (modal.type === 'speed') modalEl = html`<${SpeedModal} s=${s} api=${api} ui=${ui} />`;
    else if (modal.type === 'merge') modalEl = html`<${MergeModal} s=${s} api=${api} ui=${ui} id=${modal.id} other=${modal.other} />`;
    else if (modal.type === 'allowance') modalEl = html`<${AllowanceModal} s=${s} api=${api} ui=${ui} person=${modal.person} />`;
  }
  const d = s.dish;
  const netPill = d.reachable === false ? html`<span className="net-pill"><${Icon} name="satellite-dish" size=${14} />Can’t reach dish</span>`
    : d.online === false ? html`<span className="net-pill"><span className="live-dot" style=${{ background: 'var(--crit)', animation: 'none' }} />Starlink offline</span>`
    : html`<span className="net-pill"><span className="live-dot" />Starlink online<span className="muted tnum">${d.latency_ms == null ? '' : Math.round(d.latency_ms) + ' ms'}</span></span>`;
  return html`<div className="app">
    <aside className="rail" aria-label="Main navigation">
      <div className="brand"><${BrandMark} /><span className="brand-name">orbit</span></div>
      <nav className="nav">${VIEWS.map(v => html`<button key=${v.id} type="button" className="nav-item" aria-current=${view === v.id ? 'page' : undefined} title=${v.label} onClick=${() => ui.go(v.id)}><${Icon} name=${v.icon} size=${19} /><span className="nav-label">${v.label}</span>${badge(v.id)}</button>`)}</nav>
      <div className="rail-foot">
        <div className="rail-card">
          <div className="rail-card-row"><span className="live-dot" />Recording</div>
          <div className="muted">A reading every second${s.watching_since ? `, since ${fmtShortDate(s.watching_since)}` : ''}. Running for ${fmtDur(s.now - s.started)}.</div>
        </div>
      </div>
    </aside>
    <div className="main">
      <header className="topbar">
        <div className="topbar-brand"><${BrandMark} size=${24} /><span className="brand-name">orbit</span></div>
        <button type="button" className="search-btn" onClick=${() => ui.openModal({ type: 'palette' })} aria-label="Search devices and pages"><${Icon} name="search" size=${17} /><span>Search devices, people, pages…</span><span className="kbd">${IS_MAC ? '⌘K' : 'Ctrl K'}</span></button>
        <div className="topbar-right">
          ${netPill}
          <button type="button" className="btn btn-icon btn-ghost" aria-label=${theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme'} title=${theme === 'dark' ? 'Light theme' : 'Dark theme'} onClick=${toggleTheme}><${Icon} name=${theme === 'dark' ? 'sun' : 'moon'} size=${18} /></button>
        </div>
      </header>
      <main className="content" id="main">
        ${conn === 'lost' ? html`<div className="banner crit conn-banner" role="alert"><span className="banner-ic"><${Icon} name="unlink" size=${17} /></span>
          <div className="grow"><div className="banner-title">Orbit’s server isn’t answering</div><div className="banner-body">These numbers stopped updating. Check Orbit is still running on the computer it runs on. This page reconnects by itself.</div></div></div>` : null}
        ${viewEl}
      </main>
    </div>
    <nav className="tabbar" aria-label="Main navigation">${VIEWS.map(v => html`<button key=${v.id} type="button" className="tab" aria-current=${view === v.id ? 'page' : undefined} onClick=${() => ui.go(v.id)}><${Icon} name=${v.icon} size=${21} />${v.label}${badge(v.id)}</button>`)}</nav>
    ${drawer ? html`<${DeviceDrawer} id=${drawer} s=${s} devHist=${devHist} api=${api} ui=${ui} />` : null}
    ${modalEl}
    <${Toasts} toasts=${toasts} close=${closeToast} />
  </div>`;
}

class Boundary extends React.Component {
  constructor(p) { super(p); this.state = { err: null }; }
  static getDerivedStateFromError(err) { return { err }; }
  componentDidCatch(err) { console.error('Orbit error', err); }
  render() {
    if (this.state.err) return html`<div className="boot"><div><p style=${{ fontWeight: 700, fontSize: '18px' }}>Something went wrong on this page.</p><p className="muted" style=${{ marginTop: '6px' }}>Reload to try again. Your history is safe on the server.</p></div></div>`;
    return this.props.children;
  }
}

loadFonts();
ReactDOM.createRoot(document.getElementById('root')).render(html`<${Boundary}><${App} /><//>`);
