/* Devices: the full list with search and filters, and the details drawer for one device. */
import {
  html, useState, useEffect, useRef, Fragment, sum, enterKey, fmtMbps, fmtBytes, fmtDur, fmtAgo, fmtClock, fmtDate,
  fmtWeekday, plural, Icon, Glyph, Bars, StatusChip, Spark, Seg, AssignMenu, CopyBtn, UsageBars, trapTab,
  personOf, devColor, ownerLabel, signalInfo, bandLabel, netLabel, connLabel, statusDetail, isWired, isActive, TYPES,
} from './lib.js';
import { usePoll } from './data.js';

const sigVal = d => (isWired(d) ? 0 : d.signal == null ? -99 : d.signal);

function DeviceRow({ d, s, ui }) {
  const p = personOf(s.people, d.owner);
  const open = () => ui.openDevice(d.id);
  return html`<div className="dev-row" role="button" tabIndex="0" onClick=${open} onKeyDown=${e => { if (e.target === e.currentTarget) enterKey(open)(e); }} aria-label=${`${d.name}, ${d.online ? 'online' : 'offline'}. Open details`}>
    <div className="dev-main"><${Glyph} d=${d} people=${s.people} />
      <div style=${{ minWidth: 0 }}>
        <div className="row" style=${{ gap: '6px' }}><span className="dev-name">${d.name}</span>${d.is_new ? html`<span className="new-tag">New</span>` : null}</div>
        <div className="dev-meta"><span className=${'pdot' + (p ? '' : ' is-none')} style=${{ '--pc': devColor(d, p) }} /><span>${ownerLabel(d, p)} · ${netLabel(d)}</span></div>
      </div>
    </div>
    <div className="dev-status"><${StatusChip} d=${d} /><small>${statusDetail(d, s.now)}</small></div>
    <div className="dev-conn">${d.online ? html`<${Bars} d=${d} /><span>${connLabel(d)}</span>` : html`<span className="muted">${d.ip ? 'Last at ' + d.ip : 'Not connected'}</span>`}</div>
    <div className="dev-now">${d.online ? html`<span className="speeds tnum"><span><span className="u">↓ </span>${fmtMbps(d.down_mbps)}</span><span><span className="u">↑ </span>${fmtMbps(d.up_mbps)}</span><span className="u">Mbps</span></span>` : html`<span className="muted">No traffic</span>`}</div>
    <div className="dev-today tnum">${fmtBytes(d.today_down + d.today_up)}<span className="sr-only"> today</span></div>
    <div className="dev-acts"><${Icon} name="chevron-right" size=${16} className="muted" /></div>
  </div>`;
}

export function DevicesView({ s, x, ui }) {
  const [q, setQ] = useState('');
  const [st, setSt] = useState('all');
  const [who, setWho] = useState('all');
  const [sort, setSort] = useState('usage');
  const match = { all: () => true, online: d => d.online, offline: d => !d.online, new: d => d.is_new, blocked: d => d.blocked };
  const count = k => s.devices.filter(match[k]).length;
  const ql = q.trim().toLowerCase();
  const list = s.devices.filter(d => match[st](d) && (who === 'all' || (who === 'none' ? !d.owner : d.owner === who)) &&
    (!ql || [d.name, d.router_name, d.hostname, d.ip, d.mac, (personOf(s.people, d.owner) || {}).name, (TYPES[d.type] || {}).label].join(' ').toLowerCase().includes(ql)));
  const rank = d => (d.online ? 0 : 1);
  list.sort((a, b) => sort === 'name' ? a.name.localeCompare(b.name)
    : sort === 'signal' ? rank(a) - rank(b) || sigVal(b) - sigVal(a)
    : sort === 'today' ? (b.today_down + b.today_up) - (a.today_down + a.today_up)
    : rank(a) - rank(b) || (b.down_mbps + b.up_mbps) - (a.down_mbps + a.up_mbps) || (b.today_down - a.today_down));
  const filters = [{ value: 'all', label: 'All', count: count('all') }, { value: 'online', label: 'Online', count: count('online') },
    { value: 'offline', label: 'Offline', count: count('offline') }];
  if (count('new')) filters.push({ value: 'new', label: 'New', count: count('new') });
  if (count('blocked')) filters.push({ value: 'blocked', label: 'Blocked', count: count('blocked') });
  return html`<div className="view">
    <div className="page-head"><div><h1 className="page-title">Devices</h1>
      <p className="page-sub">${x.conn.length} connected, ${x.active.length} using the internet${count('offline') ? `, ${count('offline')} offline` : ''}. Tap a device to name it, say whose it is, or see how much it uses.</p></div></div>
    <div className="filters">
      <div className="search-in"><${Icon} name="search" size=${16} /><input id="dev-search" className="input" type="search" placeholder="Search name, IP address or owner" value=${q} onChange=${e => setQ(e.target.value)} aria-label="Search devices" /></div>
      <${Seg} label="Filter by status" value=${st} onChange=${setSt} options=${filters} />
      <select id="dev-person" className="select" value=${who} onChange=${e => setWho(e.target.value)} aria-label="Filter by person">
        <option value="all">Everyone</option>${s.people.map(p => html`<option key=${p.id} value=${p.id}>${p.name}</option>`)}<option value="none">No owner yet</option>
      </select>
      <select id="dev-sort" className="select" value=${sort} onChange=${e => setSort(e.target.value)} aria-label="Sort devices">
        <option value="usage">Using the most</option><option value="today">Most data today</option><option value="signal">Strongest signal</option><option value="name">Name</option>
      </select>
    </div>
    <section className="card dev-list" aria-label="Device list">
      <div className="dev-row head" aria-hidden="true"><span>Device</span><span>Status</span><span>Connection</span><span>Right now</span><span style=${{ textAlign: 'right' }}>Today</span><span /></div>
      ${list.map(d => html`<${DeviceRow} key=${d.id} d=${d} s=${s} ui=${ui} />`)}
      ${list.length === 0 ? html`<div className="empty">${s.devices.length ? 'No devices match. Clear the search or pick another filter.' : 'No devices yet. They appear as soon as Orbit hears from your router.'}</div>` : null}
    </section>
  </div>`;
}

/* ---------- the drawer ---------- */
function WeekBars({ id, p, d }) {
  const { data } = usePoll(`/api/devices/${id}/usage`, 60000);
  if (!data) return html`<div className="cols" aria-busy="true" />`;
  const bars = data.days.map((x, i) => (i === data.days.length - 1 ? { ...x, down: d.today_down, up: d.today_up } : x));
  return html`<div className="drawer-sec"><h3>Data used</h3>
    <div className="row" style=${{ gap: '20px' }}>
      <div><div className="muted" style=${{ fontSize: '12px', fontWeight: 650 }}>Today</div><b>${fmtBytes(d.today_down + d.today_up)}</b> <span className="muted" style=${{ fontSize: '12.5px' }}>↓ ${fmtBytes(d.today_down)} · ↑ ${fmtBytes(d.today_up)}</span></div>
      <div><div className="muted" style=${{ fontSize: '12px', fontWeight: 650 }}>Last 7 days</div><b>${fmtBytes(sum(bars, b => b.down + b.up))}</b></div>
    </div>
    <${UsageBars} bars=${bars} color=${devColor(d, p)} labelOf=${(b, i) => (i === bars.length - 1 ? 'Today' : fmtWeekday(b.t))} tipOf=${b => new Date(b.t).toLocaleDateString([], { weekday: 'long' })} />
  </div>`;
}

export function DeviceDrawer({ id, s, devHist, api, ui }) {
  const d = s.devices.find(z => z.id === id);
  const [name, setName] = useState(d ? d.name : '');
  const closeRef = useRef(null);
  useEffect(() => {
    if (d) setName(d.custom_name || d.name);
    const back = document.activeElement;
    if (closeRef.current) closeRef.current.focus();
    return () => { if (back && back.focus) back.focus(); };
  }, [id]);
  if (!d) return null;
  const p = personOf(s.people, d.owner);
  const sig = signalInfo(d.signal);
  const t = TYPES[d.type] || TYPES.unknown;
  const commit = () => {
    const v = name.trim();
    if (v === (d.custom_name || d.name)) return;
    if (!v && !d.custom_name) { setName(d.name); return; }
    api.rename(d.id, v);
  };
  const routerName = d.router_name || d.hostname;
  return html`<${Fragment}>
    <div className="scrim" onClick=${ui.closeDevice} />
    <aside className="drawer" role="dialog" aria-modal="true" aria-label=${d.name + ' details'} onKeyDown=${trapTab}>
      <div className="drawer-top"><span className="eyebrow">${t.label}</span><button ref=${closeRef} type="button" className="btn btn-icon btn-ghost" aria-label="Close" onClick=${ui.closeDevice}><${Icon} name="x" size=${18} /></button></div>
      <div className="drawer-body">
        <div className="row" style=${{ gap: '14px', alignItems: 'flex-start' }}>
          <${Glyph} d=${d} people=${s.people} size="lg" />
          <div className="grow">
            <input id="device-name" className="name-in" value=${name} aria-label="Device name" maxLength=${40} placeholder=${d.router_name || d.hostname || 'Name this device'}
              onChange=${e => setName(e.target.value)} onBlur=${commit}
              onKeyDown=${e => { if (e.key === 'Enter') e.currentTarget.blur(); if (e.key === 'Escape') { setName(d.custom_name || d.name); e.stopPropagation(); } }} />
            <div className="row wrap" style=${{ gap: '6px', marginTop: '4px' }}><${StatusChip} d=${d} /><span className="muted" style=${{ fontSize: '13px' }}>${statusDetail(d, s.now)}</span></div>
            <div className="row wrap" style=${{ marginTop: '10px', gap: '8px' }}>
              <${AssignMenu} people=${s.people} current=${d.owner} onPick=${pid => api.assign(d.id, pid)} btnClass="btn btn-sm"
                label=${html`<span className=${'pdot' + (p ? '' : ' is-none')} style=${{ '--pc': devColor(d, p) }} />${p ? p.name : 'Choose an owner'}`} />
              <select className="select" style=${{ height: '32px', fontSize: '13px' }} value=${d.type} aria-label="Kind of device" onChange=${e => api.setType(d.id, e.target.value)}>
                ${Object.entries(TYPES).map(([k, v]) => html`<option key=${k} value=${k}>${v.label}</option>`)}
              </select>
            </div>
          </div>
        </div>
        ${d.is_new ? html`<div className="banner warn"><span className="banner-ic"><${Icon} name="shield-alert" size=${17} /></span>
          <div className="grow"><div className="banner-title">Do you recognize this device?</div>
            <div className="banner-body">It first joined ${fmtAgo(d.first_seen, s.now)}, on ${netLabel(d).toLowerCase()}. ${d.signal != null && d.signal < -72 ? 'Its weak signal suggests it’s far away, maybe outside your home. ' : ''}If nobody knows it, change your Wi-Fi password in the Starlink app.</div>
            <div className="row wrap" style=${{ marginTop: '10px' }}><${AssignMenu} people=${s.people} onPick=${pid => api.assign(d.id, pid)} label="It’s ours" /><button type="button" className="btn btn-sm" onClick=${() => api.acknowledge(d.id)}>It’s fine</button></div></div></div>` : null}
        ${d.blocked ? html`<div className="banner crit"><span className="banner-ic"><${Icon} name="ban" size=${17} /></span>
          <div className="grow"><div className="banner-title">No internet access right now</div>
            <div className="banner-body">It’s blocked from the Starlink app, either paused or inside a schedule. It stays on your Wi-Fi. To change it, use the Starlink app.</div></div></div>` : null}
        ${d.online ? html`<div className="live-box">
          <div><div className="muted" style=${{ fontSize: '12px', fontWeight: 650 }}>Download</div><b className="tnum">${fmtMbps(d.down_mbps)}</b> <span className="muted">Mbps</span></div>
          <div><div className="muted" style=${{ fontSize: '12px', fontWeight: 650 }}>Upload</div><b className="tnum">${fmtMbps(d.up_mbps)}</b> <span className="muted">Mbps</span></div>
          <div className="grow" style=${{ display: 'flex', justifyContent: 'flex-end' }}><${Spark} values=${devHist[d.id] || []} w=${120} h=${40} color=${devColor(d, p)} /></div>
        </div>` : null}
        <p className="muted" style=${{ fontSize: '12.5px', marginTop: '-8px' }}>Live speeds are measured from your router over the last few seconds. ${d.schedules
          ? `It has ${d.schedules === 1 ? 'a block schedule' : d.schedules + ' block times'} set in the Starlink app. `
          : ''}To pause a device or give it a schedule, use the Starlink app: your router only accepts changes from there. Orbit shows what you set.</p>
        <div className="drawer-sec"><h3>Connection</h3>
          <div className="kv">
            <div>Network</div><div>${netLabel(d)}${d.ssid ? html` <span className="muted">· ${d.ssid}</span>` : null}</div>
            ${!isWired(d) && d.online ? html`<${Fragment}><div>Band</div><div>${bandLabel(d)}${d.upper_band ? ' · upper channels' : ''}${d.width ? ` · ${d.width} MHz wide` : ''}</div>
              <div>Signal</div><div><span className="row" style=${{ gap: '8px' }}><${Bars} d=${d} />${sig.word} <span className="muted tnum">(${d.signal} dBm)</span></span>
                ${sig.level <= 2 ? html`<div className="muted" style=${{ fontSize: '13px', marginTop: '4px' }}>${d.band === '5' ? 'Move it closer to the router. 2.4 GHz reaches further through walls, if the device lets you pick.' : 'Move it closer to the router for a steadier connection.'}</div>` : null}</div><//>` : null}
            ${d.online && (d.rate_down || d.rate_up) ? html`<${Fragment}><div>Link speed</div><div className="tnum">↓ ${Math.round(d.rate_down || 0)} · ↑ ${Math.round(d.rate_up || 0)} Mbps <span className="muted">right now</span></div><//>` : null}
            <div>${d.online ? 'Connected' : 'Last seen'}</div><div>${d.online ? (d.since ? `${fmtDur(s.now - d.since)} (since ${fmtClock(d.since)})` : 'Yes') : fmtAgo(d.last_seen || s.now, s.now)}</div>
          </div>
        </div>
        <${WeekBars} id=${d.id} p=${p} d=${d} />
        <div className="drawer-sec"><h3>Device</h3>
          <div className="kv">
            ${routerName ? html`<${Fragment}><div>Router calls it</div><div>${d.router_name || d.hostname}${d.router_name && d.hostname && d.hostname !== d.router_name ? html` <span className="muted">(${d.hostname})</span>` : null}</div><//>` : null}
            <div>IP address</div><div className="row" style=${{ gap: '4px' }}>${d.ip ? html`<span className="mono">${d.ip}</span><${CopyBtn} text=${d.ip} ui=${ui} label="Copy IP address" />` : '–'}</div>
            <div>MAC address</div><div><span className="mono">${d.mac || '–'}</span>
              <div className="muted" style=${{ fontSize: '12.5px' }}>${d.private_mac ? 'A private address the device made up for your network. ' : ''}Your router hides the second half.</div></div>
            <div>First seen</div><div>${fmtDate(d.first_seen)}</div>
          </div>
        </div>
        ${!d.online ? html`<button type="button" className="btn btn-ghost btn-danger" style=${{ alignSelf: 'flex-start' }} onClick=${() => ui.openModal({ type: 'confirm', title: `Forget ${d.name}?`, body: 'Orbit removes its name and owner. If it connects again, it shows up as a new device. Its usage history stays in your totals.', label: 'Forget device', danger: true, fn: () => api.forget(d.id) })}><${Icon} name="trash-2" size=${16} />Forget this device</button>` : null}
      </div>
    </aside>
  <//>`;
}
