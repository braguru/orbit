/* Activity: everything Orbit noticed, newest first. */
import { html, useState, useEffect, Fragment, DAY, fmtClock, Icon, Seg } from './lib.js';
import { getJSON } from './data.js';
import { actCls } from './overview.js';

const FILTERS = [{ value: 'all', label: 'All' }, { value: 'security', label: 'Security', icon: 'shield-alert' }, { value: 'devices', label: 'Devices' },
  { value: 'network', label: 'Starlink' }, { value: 'you', label: 'Your changes' }];

export function ActivityView({ s, ui }) {
  const [f, setF] = useState('all');
  const [events, setEvents] = useState(null);
  const newest = s.events[0] ? s.events[0].id : 0;
  useEffect(() => {
    let alive = true;
    getJSON('/api/events?limit=300' + (f === 'all' ? '' : '&cat=' + f)).then(list => { if (alive) setEvents(list); }, () => { if (alive) setEvents(null); });
    return () => { alive = false; };
  }, [f, newest]);
  const list = events || s.events.filter(e => f === 'all' || e.cat === f);
  const today = new Date(s.now).toDateString(), yest = new Date(s.now - DAY).toDateString();
  const groups = [];
  list.forEach(e => {
    const ds = new Date(e.ts).toDateString();
    const label = ds === today ? 'Today' : ds === yest ? 'Yesterday' : new Date(e.ts).toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });
    let g = groups[groups.length - 1];
    if (!g || g.label !== label) { g = { label, items: [] }; groups.push(g); }
    g.items.push(e);
  });
  return html`<div className="view">
    <div className="page-head"><div><h1 className="page-title">Activity</h1><p className="page-sub">New devices, devices coming and going, Starlink dropouts and updates, and the changes you made, newest first.</p></div></div>
    <${Seg} label="Filter activity" value=${f} onChange=${setF} options=${FILTERS} />
    <section className="card">
      ${groups.map(g => html`<${Fragment} key=${g.label}><div className="tl-day">${g.label}</div>
        ${g.items.map(e => html`<div className="tl-item" key=${e.id}>
          <span className="tl-time">${fmtClock(e.ts)}</span>
          <span className=${'act-ic ' + actCls(e)}><${Icon} name=${e.icon} size=${15} /></span>
          <div style=${{ minWidth: 0 }}><div className="tl-title">${e.title}</div>${e.detail ? html`<div className="tl-detail">${e.detail}</div>` : null}
            ${e.device && s.devices.some(d => d.id === e.device) ? html`<button type="button" className="link-btn" style=${{ marginTop: '4px' }} onClick=${() => ui.openDevice(e.device)}>Open device<${Icon} name="chevron-right" size=${14} /></button>` : null}</div>
        </div>`)}<//>`)}
      ${list.length === 0 ? html`<div className="empty">Nothing here yet.</div>` : null}
    </section>
  </div>`;
}
