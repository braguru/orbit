/* Overview: the health headline, the live orbit map, who's using the internet, and today at a glance. */
import {
  html, useState, useMemo, useRef, Fragment, clamp, sum, enterKey, DAY, MIN, readPref, writePref,
  fmtMbps, fmtBytes, fmtDur, fmtAgo, fmtSecs, fmtClock, plural, Icon, Glyph, Spark, Stat, AssignMenu, LineChart, HBars,
  OutageStrip, useSize, personOf, pcol, devColor, devSky, ownerLabel, signalInfo, bandLabel, netLabel,
  statusOf, isWired, isActive, typeIcon,
} from './lib.js';
import { ICONS } from './icons.js';

/* Everything derived from the live state that more than one view needs. */
export function derive(s) {
  const conn = s.devices.filter(d => d.online);
  const active = conn.filter(isActive);
  const dish = s.dish;
  // "How full is the pipe" is measured against the last speed test from the past 2 weeks, else the fastest reading seen.
  const test = s.tests.find(t => !t.error && t.down && s.now - t.ts < 14 * 86400e3);
  const capDown = Math.max(50, Math.round(test ? test.down : dish.fastest_mbps || 0));
  const capLabel = test ? 'your last speed test' : 'the fastest seen this week';
  const util = (dish.down_mbps || 0) / capDown;
  const unknown = s.devices.filter(d => d.is_new);
  const hog = [...conn].sort((a, b) => b.down_mbps - a.down_mbps)[0];
  const dropSecs = sum(s.outages, o => o.duration_s);
  let health;
  if (dish.reachable === false) health = { tone: 'crit', title: 'Orbit can’t reach your dish.', sub: 'It may be restarting, or a cable may be unplugged. Devices at home can still reach each other over Wi-Fi.' };
  else if (dish.online === false) health = { tone: 'crit', title: 'Starlink is offline right now.', sub: `${dish.outage ? dish.outage.text + '. ' : ''}It usually comes back by itself within a minute.` };
  else if (s.router.reachable === false) health = { tone: 'warn', title: 'Orbit can’t reach your router.', sub: 'The device list may be out of date until the router answers again.' };
  else if (dish.reachable == null) health = { tone: 'muted', title: 'Connecting to Starlink…', sub: 'Orbit is asking your dish and router how things are going.' };
  else if (s.speedtest && s.speedtest.running) health = { tone: 'accent', title: 'Testing your internet speed…', sub: 'The router is measuring download, then upload. It takes about 30 seconds, and things may feel slow until it’s done.' };
  else if (util > 0.85 && hog && hog.down_mbps > 1) health = { tone: 'warn', title: 'Your internet is busy right now.', sub: `${hog.name} is using ${fmtMbps(hog.down_mbps)} Mbps, close to ${capLabel}.` };
  else if (dish.latency_ms > 80) health = { tone: 'warn', title: 'Your internet is responding slowly.', sub: `Latency is ${Math.round(dish.latency_ms)} ms right now. Under 40 ms is normal for Starlink.` };
  else health = {
    tone: 'good', title: unknown.length ? 'Your internet is running smoothly.' : 'Everything’s running smoothly.',
    sub: `${plural(conn.length, 'device')} connected, ${active.length} using the internet right now.${dish.online_since ? ` Starlink has been online for ${fmtDur(s.now - dish.online_since)}.` : ''}`,
  };
  return { conn, active, capDown, capLabel, util, unknown, hog, health, dropSecs, test };
}

/* ---------- hero ---------- */
function Hero({ s, x, points, api, ui }) {
  const now = new Date(s.now);
  const h = now.getHours();
  const me = s.people.find(p => p.id === 'me');
  const greet = h < 5 ? 'Hello' : h < 12 ? 'Good morning' : h < 17 ? 'Good afternoon' : 'Good evening';
  const date = now.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });
  const d = s.dish, lat = d.latency_ms;
  const today = s.home.down + s.home.up;
  const drops = s.outages.length;
  return html`<div className="hero-text">
    <div className="greet"><span>${greet}${me ? ', ' + me.name : ''}</span><span aria-hidden="true">·</span><span>${date}</span></div>
    <h1 className="headline">${x.health.title}</h1>
    <p className="hero-sub">${x.health.sub}</p>
    ${d.alerts.filter(a => a.tone !== 'info').map(a => html`<div key=${a.key} className=${'banner ' + (a.tone === 'crit' ? 'crit' : 'warn')} role="status">
      <span className="banner-ic"><${Icon} name="triangle-alert" size=${17} /></span>
      <div className="grow"><div className="banner-title">${a.text}</div><div className="banner-body">Reported by your dish. The Starlink app has more help for this.</div></div>
    </div>`)}
    <div className="readouts">
      <${Stat} icon="timer" label="Latency" live=${lat != null} value=${lat == null ? '–' : Math.round(lat)} unit=${lat == null ? '' : 'ms'}
        note=${lat == null ? 'No connection right now' : lat < 40 ? 'Great for gaming and calls' : lat < 80 ? 'Fine for most things' : 'Responses feel slow'}
        spark=${html`<${Spark} values=${points.slice(-40).map(p => p.lat)} w=${76} h=${30} max=${80} />`} />
      <${Stat} icon="activity" label="In use now" live=${d.online === true} value=${fmtMbps(d.down_mbps)} unit="Mbps"
        note=${`of ~${x.capDown} Mbps, ${x.capLabel} · ${x.util < 0.5 ? 'plenty of room' : x.util < 0.8 ? 'some room left' : 'nearly full'}`}>
        <div className="meter" aria-hidden="true"><span style=${{ width: clamp(x.util * 100, 1, 100) + '%' }} /></div>
      <//>
      <${Stat} icon="arrow-down-up" label="Data used today" value=${fmtBytes(today).split(' ')[0]} unit=${fmtBytes(today).split(' ')[1]}
        note=${`↓ ${fmtBytes(s.home.down)} down · ↑ ${fmtBytes(s.home.up)} up`} />
      <${Stat} icon="triangle-alert" label="Dropouts, 24 h" value=${drops} note=${drops ? `${fmtSecs(x.dropSecs)} offline in total${s.outages.every(o => o.duration_s < 10) ? ', all short' : ''}` : 'Not one in the last 24 hours'} />
    </div>
    ${x.unknown.length ? html`<${Attention} list=${x.unknown} s=${s} api=${api} ui=${ui} />` : null}
    <div className="hero-actions">
      <button type="button" className="btn btn-primary" onClick=${() => ui.openModal({ type: 'speed' })}><${Icon} name="gauge" size=${16} />${s.speedtest.running ? 'Speed test running…' : 'Run a speed test'}</button>
      <button type="button" className="btn" onClick=${() => ui.go('usage')}><${Icon} name="chart-no-axes-column" size=${16} />See usage history</button>
    </div>
  </div>`;
}

function Attention({ list, s, api, ui }) {
  const weak = list.some(d => d.signal != null && d.signal < -72);
  return html`<div className="banner warn" role="status">
    <span className="banner-ic"><${Icon} name="shield-alert" size=${18} /></span>
    <div className="grow" style=${{ minWidth: 0 }}>
      <div className="banner-title">${list.length === 1 ? 'A device you may not know joined' : `${list.length} devices you may not know joined`}</div>
      <div className="banner-body">${weak ? 'A weak signal means it’s far from your router, maybe outside your home. ' : ''}If nobody at home recognizes it, change your Wi-Fi password in the Starlink app.</div>
      ${list.slice(0, 2).map(d => html`<div className="attn-dev" key=${d.id}>
        <${Glyph} d=${d} people=${s.people} size="sm" />
        <div className="grow clickable" role="button" tabIndex="0" onClick=${() => ui.openDevice(d.id)} onKeyDown=${enterKey(() => ui.openDevice(d.id))}>
          <div className="urow-name">${d.name}</div>
          <div className="urow-meta">${netLabel(d)} · ${bandLabel(d)} · joined ${fmtAgo(d.first_seen, s.now)}</div>
        </div>
        <div className="row">
          <${AssignMenu} people=${s.people} onPick=${pid => api.assign(d.id, pid)} label="It’s ours" align="right" />
          <button type="button" className="btn btn-sm" onClick=${() => api.acknowledge(d.id)}>Dismiss</button>
        </div>
      </div>`)}
    </div>
  </div>`;
}

/* ---------- the orbit map ---------- */
const ZONES = [[272, 'Weak'], [234, 'Fair'], [202, 'Good'], [165, 'Excellent']];
const orbitR = d => (isWired(d) ? 66 : d.signal == null ? 200 : clamp(96 + (-d.signal - 40) * 4.6, 96, 272));
const sigVal = d => (isWired(d) ? 0 : d.signal == null ? -99 : d.signal);
const shortName = n => (n.length > 17 ? n.slice(0, 16) + '…' : n);
function KeyGlyph({ kind }) {
  const st = { stroke: 'var(--sky-ink-2)', strokeWidth: 1.4, fill: 'none' };
  if (kind === 'rings') return html`<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="7.5" style=${st} /><circle cx="9" cy="9" r="4" style=${st} /><circle cx="9" cy="9" r="1.3" style=${{ fill: 'var(--sky-ink-2)' }} /></svg>`;
  if (kind === 'size') return html`<svg width="22" height="18" viewBox="0 0 22 18" aria-hidden="true"><circle cx="5" cy="11" r="3" style=${st} /><circle cx="15" cy="9" r="6" style=${st} /></svg>`;
  return html`<svg width="22" height="18" viewBox="0 0 22 18" aria-hidden="true"><line x1="1" y1="9" x2="21" y2="9" style=${{ ...st, strokeDasharray: '2.5 3.5', strokeLinecap: 'round' }} /></svg>`;
}
function OrbitMap({ s, ui }) {
  const stageRef = useRef(null);
  const { w } = useSize(stageRef);
  const [tip, setTip] = useState(null);
  const stars = useMemo(() => {
    let a = 7;
    const r = () => { a = (a * 16807) % 2147483647; return a / 2147483647; };
    return Array.from({ length: 90 }, (_, i) => ({ x: r() * 600, y: r() * 600, r: 0.4 + r() * 1.1, o: 0.15 + r() * 0.55, tw: i % 6 === 0, delay: (r() * 4).toFixed(2) }));
  }, []);
  const vis = s.devices.filter(d => d.online);
  const order = [...s.people.map(p => p.id), null];
  const groups = order.map(pid => vis.filter(d => (d.owner || null) === pid).sort((a, b) => sigVal(b) - sigVal(a))).filter(g => g.length);
  const GAP = 9;
  const per = (360 - GAP * groups.length) / Math.max(1, vis.length);
  let ang = -90 + GAP / 2;
  const layout = [];
  groups.forEach(g => { g.forEach((d, i) => layout.push({ d, a: ang + per * (i + 0.5) })); ang += per * g.length + GAP; });
  const top = new Set(vis.filter(d => d.down_mbps > 2).sort((a, b) => b.down_mbps - a.down_mbps).slice(0, 2).map(d => d.id));
  const showLabels = w >= 430;
  const activeN = vis.filter(isActive).length;
  const showTip = (d, el) => {
    const st = stageRef.current;
    if (!st || !el) return;
    const a = st.getBoundingClientRect(), b = el.getBoundingClientRect();
    const below = b.top - a.top < 100;
    setTip({ id: d.id, x: clamp(b.left + b.width / 2 - a.left, 90, a.width - 90), y: below ? b.bottom - a.top : b.top - a.top, below });
  };
  const td = tip && s.devices.find(d => d.id === tip.id);
  const tp = td && personOf(s.people, td.owner);
  const counts = order.map(pid => ({ pid, p: personOf(s.people, pid), n: vis.filter(d => (d.owner || null) === pid).length })).filter(c => c.n);
  const nodeR = d => 12 + 10 * Math.sqrt(Math.min(1, d.down_mbps / 45));
  return html`<section className="sky orbit" aria-label="Map of connected devices">
    <div className="orbit-head">
      <div><h2 className="sky-title">Your network right now</h2><div className="sky-sub">${plural(vis.length, 'device')} connected · ${activeN} using the internet</div></div>
      <span className="live-pill"><span className="live-dot" />Live</span>
    </div>
    <div className=${'orbit-stage' + (tip ? ' is-held' : '')} ref=${stageRef}>
      <svg viewBox="0 0 600 600" role="group" aria-label=${`${plural(vis.length, 'device')} around your router. Closer to the middle means a stronger Wi-Fi signal.`}>
        <g aria-hidden="true">
          ${stars.map((st, i) => html`<circle key=${i} className=${'o-star' + (st.tw ? ' twinkle' : '')} cx=${st.x.toFixed(1)} cy=${st.y.toFixed(1)} r=${st.r.toFixed(2)} style=${{ opacity: st.o, animationDelay: st.tw ? st.delay + 's' : undefined }} />`)}
          <g className="sat-train">${[0, 1, 2, 3, 4].map(i => html`<circle key=${i} cx=${-i * 13} cy=${i * 3.4} r="1.5" style=${{ fill: 'var(--sky-ink)', opacity: 0.85 - i * 0.12 }} />`)}</g>
          ${ZONES.map(([r, l], i) => html`<circle key=${l} className="o-zone" cx="300" cy="300" r=${r} style=${{ fillOpacity: 0.016 + i * 0.012 }} />`)}
          <circle className="o-zone" cx="300" cy="300" r="66" style=${{ fillOpacity: 0, strokeDasharray: '2 4' }} />
          <text className="o-zone-label" x="300" y=${300 - 253 + 3} textAnchor="middle">Weak</text>
          <text className="o-zone-label" x="300" y=${300 - 218 + 3} textAnchor="middle">Fair</text>
          <text className="o-zone-label" x="300" y=${300 - 183 + 3} textAnchor="middle">Good</text>
          <text className="o-zone-label" x="300" y=${300 - 140} textAnchor="middle">Excellent</text>
          <text className="o-zone-label" x="300" y=${300 - 46} textAnchor="middle">Wired</text>
          <g transform="translate(300 300)">
            <circle className="pulse-ring" r="30" />
            <circle className="pulse-ring" r="30" style=${{ animationDelay: '1.6s' }} />
            <circle className="o-router" r="30" />
            <svg x="-13" y="-13" width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)' }} dangerouslySetInnerHTML=${{ __html: ICONS.router }} />
          </g>
          <text className="o-router-label" x="300" y="350" textAnchor="middle">Router</text>
        </g>
        <g className="constellation">
          ${layout.map(({ d, a }) => {
            const p = personOf(s.people, d.owner);
            const r = orbitR(d), nr = nodeR(d);
            const hot = d.down_mbps + d.up_mbps > 0.4;
            const flow = d.down_mbps > 25 ? '.55s' : d.down_mbps > 6 ? '.9s' : '1.5s';
            return html`<line key=${'l' + d.id} className=${'o-link' + (hot ? ' is-hot' : '')} x1="36" y1="0" x2=${Math.max(40, r - nr - 4).toFixed(1)} y2="0" style=${{ '--a': a.toFixed(2) + 'deg', '--flow': flow, stroke: hot ? devSky(d, p) : undefined }} />`;
          })}
          ${layout.map(({ d, a }) => {
            const p = personOf(s.people, d.owner);
            const col = devSky(d, p);
            const r = orbitR(d), nr = nodeR(d);
            const hot = d.down_mbps + d.up_mbps > 0.4;
            const label = showLabels && (top.has(d.id) || d.is_new);
            const open = () => ui.openDevice(d.id);
            return html`<g key=${d.id} className="o-node" style=${{ '--a': a.toFixed(2) + 'deg', '--r': r.toFixed(1) + 'px' }}
                tabIndex="0" role="button" aria-label=${`${d.name}, ${ownerLabel(d, p)}, ${statusOf(d).label}, ${fmtMbps(d.down_mbps)} megabits per second`}
                onPointerEnter=${e => showTip(d, e.currentTarget)} onPointerLeave=${() => setTip(null)} onFocus=${e => showTip(d, e.currentTarget)} onBlur=${() => setTip(null)}
                onClick=${open} onKeyDown=${enterKey(open)}>
              <circle className="o-hit" r=${Math.max(nr + 7, 20).toFixed(1)} />
              ${hot ? html`<circle className="o-glow" r=${(nr + 5).toFixed(1)} style=${{ fill: col }} />` : null}
              ${d.is_new ? html`<circle className="o-halo" r=${(nr + 3).toFixed(1)} />` : null}
              <circle className="o-body" r=${nr.toFixed(1)} style=${{ stroke: col, strokeDasharray: p ? undefined : '3 3' }} />
              <svg x="-8" y="-8" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)', pointerEvents: 'none' }} dangerouslySetInnerHTML=${{ __html: ICONS[typeIcon(d)] }} />
              ${label ? html`<text className="o-label" y=${(nr + 15).toFixed(1)} textAnchor="middle">${shortName(d.name)}</text>` : null}
            </g>`;
          })}
        </g>
      </svg>
      ${td ? html`<div className=${'tip' + (tip.below ? ' below' : '')} style=${{ left: tip.x + 'px', top: tip.y + 'px' }}>
        <div className="tip-title">${td.name}</div>
        <div className="tip-row"><span className=${'pdot' + (tp ? '' : ' is-none')} style=${{ '--pc': devColor(td, tp) }} />${ownerLabel(td, tp)} · ${statusOf(td).label}</div>
        <div className="tip-row tnum"><span className="tip-val">↓ ${fmtMbps(td.down_mbps)}</span><span className="tip-val">↑ ${fmtMbps(td.up_mbps)}</span> Mbps</div>
        <div className="tip-row">${isWired(td) ? 'Wired connection' : `${signalInfo(td.signal).word} signal (${td.signal} dBm) · ${bandLabel(td)}`}</div>
      </div>` : null}
    </div>
    <div className="orbit-legend">${counts.map(c => html`<span key=${c.pid || 'none'}><span className=${'pdot' + (c.p ? '' : ' is-none')} style=${{ '--pc': c.p ? `var(--s-${c.p.color})` : 'var(--s-none)' }} />${c.p ? c.p.name : 'No owner yet'} <b style=${{ color: 'var(--sky-ink)' }}>${c.n}</b></span>`)}</div>
    <div className="orbit-keys">
      <span><${KeyGlyph} kind="rings" />Closer to the router = stronger Wi-Fi</span>
      <span><${KeyGlyph} kind="size" />Bigger = using more internet</span>
      <span><${KeyGlyph} kind="flow" />Moving dots = data flowing</span>
    </div>
  </section>`;
}

/* ---------- who's using it ---------- */
function TopUsers({ s, x, ui }) {
  const top = s.devices.filter(d => d.online && d.down_mbps + d.up_mbps > 0.05).sort((a, b) => b.down_mbps + b.up_mbps - (a.down_mbps + a.up_mbps)).slice(0, 5);
  return html`<section className="card">
    <div className="card-head">
      <div><h2 className="card-title">Using the most right now</h2><div className="card-sub">Share of ~${x.capDown} Mbps, ${x.capLabel}</div></div>
      <button type="button" className="link-btn" onClick=${() => ui.go('devices')}>All devices<${Icon} name="chevron-right" size=${15} /></button>
    </div>
    <div className="ulist">
      ${top.map(d => {
        const p = personOf(s.people, d.owner);
        const share = d.down_mbps / x.capDown;
        return html`<div className="urow" key=${d.id}>
          <div className="clickable row grow" role="button" tabIndex="0" onClick=${() => ui.openDevice(d.id)} onKeyDown=${enterKey(() => ui.openDevice(d.id))}>
            <${Glyph} d=${d} people=${s.people} />
            <div className="urow-main">
              <div className="row"><span className="urow-name grow">${d.name}</span><span className="urow-val tnum">${fmtMbps(d.down_mbps)} <span className="muted" style=${{ fontWeight: 600 }}>Mbps</span></span></div>
              <div className="share" style=${{ '--pc': devColor(d, p) }}><span style=${{ width: clamp(share * 100, 1, 100) + '%' }} /></div>
              <div className="urow-meta"><span className=${'pdot' + (p ? '' : ' is-none')} style=${{ '--pc': devColor(d, p) }} /><span>${ownerLabel(d, p)}</span><span aria-hidden="true">·</span><span className="tnum">${share >= 0.005 ? Math.round(share * 100) + '% of your internet' : 'a sliver of your internet'}</span></div>
            </div>
          </div>
          <${Icon} name="chevron-right" size=${16} className="muted" />
        </div>`;
      })}
      ${top.length === 0 ? html`<div className="empty">Nothing is using the internet right now.</div>` : null}
    </div>
  </section>`;
}

function TrafficTable({ s, devHist }) {
  const rows = s.devices.filter(d => devHist[d.id] && devHist[d.id].some(v => v)).map(d => {
    const vals = devHist[d.id].filter(v => v != null);
    return { d, now: d.down_mbps + d.up_mbps, avg: sum(vals, v => v) / Math.max(1, vals.length), peak: Math.max(0, ...vals) };
  }).sort((a, b) => b.avg - a.avg).slice(0, 10);
  return html`<div style=${{ overflowX: 'auto', marginTop: '14px' }}><table className="table-view">
    <thead><tr><th>Device</th><th>Now</th><th>Average</th><th>Peak</th></tr></thead>
    <tbody>${rows.map(r => html`<tr key=${r.d.id}><td>${r.d.name}</td><td>${fmtMbps(r.now)} Mbps</td><td>${fmtMbps(r.avg)} Mbps</td><td>${fmtMbps(r.peak)} Mbps</td></tr>`)}</tbody>
  </table><p className="muted" style=${{ fontSize: '12.5px', marginTop: '8px' }}>Download and upload together, over the last minute.</p></div>`;
}
export function liveLabels(points) {
  const n = points.length;
  if (n < 2) return [];
  const span = Math.round((points[n - 1].t - points[0].t) / 1000);
  const ago = sec => (sec >= 90 ? `${Math.round(sec / 60)} min ago` : `${sec} s ago`);
  return [{ i: 0, text: ago(span) }, { i: Math.floor((n - 1) / 2), text: ago(Math.round(span / 2)) }, { i: n - 1, text: 'Now' }];
}
function LiveTraffic({ s, x, points, devHist }) {
  const [table, setTable] = useState(false);
  const segs = [...s.people.map(p => ({ id: p.id, p })), { id: 'none', p: null }]
    .map(z => ({ ...z, v: sum(s.devices.filter(d => d.online && (d.owner || 'none') === z.id), d => d.down_mbps) }))
    .filter(z => z.v > 0.05);
  const segColor = z => (z.p ? pcol(z.p) : 'var(--p-none)');
  const last = points[points.length - 1];
  return html`<section className="card">
    <div className="card-head">
      <div><h2 className="card-title">Live traffic</h2><div className="card-sub">Last 2 minutes · updates every second</div></div>
      <button type="button" className="link-btn" onClick=${() => setTable(t => !t)}>${table ? 'Show chart' : 'Show as table'}</button>
    </div>
    <div className="stack" style=${{ gap: '9px' }}>
      <div className="row" style=${{ justifyContent: 'space-between', alignItems: 'baseline' }}><span className="eyebrow">Right now, by person</span><span className="tnum ink2" style=${{ fontSize: '13px' }}><b style=${{ color: 'var(--ink)' }}>${fmtMbps(sum(segs, z => z.v))}</b> of ~${x.capDown} Mbps</span></div>
      <div className="stackbar" role="img" aria-label=${segs.map(z => `${z.p ? z.p.name : 'No owner yet'} ${fmtMbps(z.v)} Mbps`).join(', ') || 'Nothing in use'}>
        ${segs.map(z => html`<span key=${z.id} style=${{ width: (z.v / x.capDown) * 100 + '%', '--pc': segColor(z) }} />`)}
      </div>
      <div className="legend">${segs.map(z => html`<span key=${z.id}><span className=${'pdot' + (z.p ? '' : ' is-none')} style=${{ '--pc': segColor(z) }} />${z.p ? z.p.name : 'No owner yet'} <b className="tnum" style=${{ color: 'var(--ink)' }}>${fmtMbps(z.v)}</b></span>`)}</div>
    </div>
    ${table ? html`<${TrafficTable} s=${s} devHist=${devHist} />` : html`<div style=${{ marginTop: '16px' }}><${LineChart} points=${points} xLabels=${liveLabels(points)}
      label=${last ? `Whole-home internet use over the last 2 minutes. Now ${fmtMbps(last.down)} Mbps down and ${fmtMbps(last.up)} Mbps up.` : 'Waiting for readings'}
      timeLabel=${(p, l) => (l.t - p.t < 1000 ? 'Now' : `${Math.round((l.t - p.t) / 1000)} seconds ago`)} /></div>`}
  </section>`;
}

/* ---------- today ---------- */
export function personRows(s, valueOf) {
  return [...s.people.map(p => ({ id: p.id, label: p.name, color: pcol(p), match: d => d.owner === p.id })),
    { id: 'none', label: 'No owner yet', color: 'var(--p-none)', hollow: true, match: d => !d.owner }]
    .map(r => ({ ...r, value: valueOf(r.match) }))
    .filter(r => r.value >= 1e6)
    .sort((a, b) => b.value - a.value);
}
function DataToday({ s, ui }) {
  const rows = personRows(s, match => sum(s.devices.filter(match), d => d.today_down + d.today_up));
  return html`<section className="card">
    <div className="card-head">
      <div><h2 className="card-title">Data used today, by person</h2><div className="card-sub">${fmtBytes(s.home.down + s.home.up)} for the whole home since midnight</div></div>
      <button type="button" className="link-btn" onClick=${() => ui.go('usage')}>History<${Icon} name="chevron-right" size=${15} /></button>
    </div>
    ${rows.length ? html`<${HBars} rows=${rows} />` : html`<div className="empty">Nothing measured yet today. Usage per device appears as Orbit watches your router.</div>`}
  </section>`;
}

/* ---------- suggestions ---------- */
function buildInsights(s, x) {
  const out = [];
  const conn = x.conn;
  const weak = conn.filter(d => d.signal != null && d.signal < -72).sort((a, b) => a.signal - b.signal)[0];
  if (weak) out.push({
    id: 'weak-' + weak.id, icon: 'wifi', tone: 'warn', title: `${weak.name} has a weak Wi-Fi signal`,
    body: `It’s on ${bandLabel(weak)} at ${weak.signal} dBm, so pages can load slowly and calls can break up. Moving it closer to the router, or the router somewhere more central, should help.${weak.band === '5' ? ' 2.4 GHz reaches further through walls, if the device lets you pick.' : ''}`,
    acts: [{ label: 'Details', fn: (api, ui) => ui.openDevice(weak.id) }],
  });
  for (const a of s.dish.alerts.filter(a => a.tone === 'info')) out.push({ id: 'alert-' + a.key, icon: 'info', title: a.text, body: 'Reported by your dish. Nothing for you to do.', acts: [] });
  if (s.dish.dl_limit && s.dish.dl_limit !== 'NO_LIMIT') out.push({
    id: 'limited', icon: 'gauge', tone: 'warn', title: 'Starlink is limiting your download speed',
    body: `The dish reports “${s.dish.dl_limit.replace(/_/g, ' ').toLowerCase()}”. This usually comes from your plan. The Starlink app shows the details.`, acts: [],
  });
  const long = s.outages.filter(o => o.duration_s >= 10 && o.cause !== 'BOOTING');
  const restarts = s.outages.filter(o => o.cause === 'BOOTING');
  if (long.length) out.push({
    id: 'drops-' + long[long.length - 1].start, icon: 'satellite-dish', tone: long.length > 2 ? 'warn' : undefined,
    title: `Starlink dropped ${plural(long.length, 'time')} for 10 seconds or more in the last 24 hours`,
    body: `The latest was at ${fmtClock(long[long.length - 1].start)}: ${long[long.length - 1].text}. Short dropouts rarely matter except on calls and in games.`,
    acts: [{ label: 'See dropouts', fn: (api, ui) => ui.go('starlink') }],
  });
  if (restarts.length) out.push({
    id: 'restart-' + restarts[restarts.length - 1].start, icon: 'rotate-cw',
    title: restarts.length === 1 ? `Starlink restarted at ${fmtClock(restarts[0].start)}` : `Starlink restarted ${plural(restarts.length, 'time')} in the last 24 hours`,
    body: `It was offline for ${fmtSecs(restarts[restarts.length - 1].duration_s)} while it started up. Software updates and power cuts are the usual reasons.`,
    acts: [{ label: 'See dropouts', fn: (api, ui) => ui.go('starlink') }],
  });
  if (s.dish.obstructed > 0.005) out.push({
    id: 'obstruction', icon: 'eye-off', tone: 'warn', title: 'Something blocks part of the dish’s view',
    body: `The view is blocked ${(s.dish.obstructed * 100).toFixed(1)}% of the time. Trimming branches or moving the dish a little can fix it.`,
    acts: [{ label: 'See what the dish sees', fn: (api, ui) => ui.go('starlink') }],
  });
  const big = [...s.devices].sort((a, b) => b.today_down - a.today_down)[0];
  if (big && big.today_down > 5e9) out.push({
    id: 'big-' + big.id + '-' + s.home.day, icon: 'arrow-down', title: `${big.name} has downloaded ${fmtBytes(big.today_down)} today`,
    body: 'That’s the most of any device today. Big app, game or system updates are the usual reason.', acts: [{ label: 'Details', fn: (api, ui) => ui.openDevice(big.id) }],
  });
  const unnamed = s.devices.filter(d => !d.custom_name && !d.router_name && !d.hostname);
  if (unnamed.length) out.push({
    id: 'unnamed', icon: 'tag', title: `${plural(unnamed.length, 'device has', 'devices have')} no name`,
    body: 'Give each one a name, so you can tell what it is at a glance. Usage helps: the busiest unnamed device is often a TV or computer.',
    acts: [{ label: 'Name it', primary: true, fn: (api, ui) => ui.openDevice(unnamed.sort((a, b) => b.today_down - a.today_down)[0].id) }],
  });
  const unowned = s.devices.filter(d => !d.owner && !d.is_new);
  if (unowned.length >= 2) out.push({
    id: 'owners', icon: 'users-round', title: `Tell Orbit whose devices these are`,
    body: `${plural(unowned.length, 'device has', 'devices have')} no owner yet. Once each one has an owner, you can see who uses the most data.`,
    acts: [{ label: 'Go to People', fn: (api, ui) => ui.go('people') }],
  });
  if (!x.test && !s.speedtest.running) out.push({
    id: 'speedtest', icon: 'gauge', title: 'Find out your real speed',
    body: 'Orbit compares what your home uses with your last speed test. Run one to set the baseline. It takes about 30 seconds.',
    acts: [{ label: 'Run a speed test', primary: true, fn: (api, ui) => ui.openModal({ type: 'speed' }) }],
  });
  const blocked = s.devices.filter(d => d.blocked);
  if (blocked.length) out.push({
    id: 'blocked-' + blocked.map(d => d.id).join('-'), icon: 'ban', title: `${plural(blocked.length, 'device has', 'devices have')} no internet access`,
    body: `${blocked.map(d => d.name).join(', ')} ${blocked.length === 1 ? 'is' : 'are'} blocked from the Starlink app, paused or on a schedule. Change it there.`,
    acts: [{ label: 'Details', fn: (api, ui) => ui.openDevice(blocked[0].id) }],
  });
  if (s.now - (s.watching_since || s.started) < 6 * 3600e3) out.push({
    id: 'learning', icon: 'history', title: 'Orbit is still building your history',
    body: 'Usage and speed history fill in as Orbit runs. Keep it running, and the Usage page shows days and weeks.', acts: [],
  });
  return out;
}
function Insights({ s, x, api, ui }) {
  const [all, setAll] = useState(false);
  const [dismissed, setDismissed] = useState(() => readPref('dismissed', {}));
  const dismiss = id => { const next = { ...dismissed, [id]: Date.now() }; setDismissed(next); writePref('dismissed', next); };
  const list = buildInsights(s, x).filter(i => !dismissed[i.id]);
  const shown = all ? list : list.slice(0, 3);
  return html`<section className="card">
    <div className="card-head"><div><h2 className="card-title">Suggestions</h2><div className="card-sub">Things Orbit noticed on your network</div></div><${Icon} name="sparkles" size=${18} style=${{ color: 'var(--accent)' }} /></div>
    <div>
      ${shown.map(i => html`<div className="insight" key=${i.id}>
        <span className=${'insight-ic' + (i.tone === 'warn' ? ' warn' : '')}><${Icon} name=${i.icon} size=${17} /></span>
        <div className="grow">
          <div className="row" style=${{ alignItems: 'flex-start' }}><div className="insight-title grow">${i.title}</div>
            <button type="button" className="btn btn-sm btn-icon btn-ghost" style=${{ marginTop: '-6px', marginRight: '-8px' }} aria-label="Dismiss suggestion" onClick=${() => dismiss(i.id)}><${Icon} name="x" size=${15} /></button></div>
          <div className="insight-body">${i.body}</div>
          ${i.acts.length ? html`<div className="insight-acts">${i.acts.map(a => html`<button key=${a.label} type="button" className=${'btn btn-sm' + (a.primary ? ' btn-primary' : '')} onClick=${() => a.fn(api, ui)}>${a.label}</button>`)}</div>` : null}
        </div>
      </div>`)}
      ${list.length === 0 ? html`<div className="empty">All clear. Nothing needs your attention.</div>` : null}
      ${list.length > 3 ? html`<button type="button" className="link-btn" style=${{ marginTop: '8px' }} onClick=${() => setAll(a => !a)}>${all ? 'Show fewer' : `Show ${list.length - 3} more`}</button>` : null}
    </div>
  </section>`;
}

/* ---------- activity and Starlink at a glance ---------- */
export const actCls = e => (e.tone === 'good' ? 'good' : e.cat === 'security' ? 'security' : e.tone === 'warn' || e.tone === 'crit' ? 'warn' : e.cat);
function RecentActivity({ s, ui }) {
  return html`<section className="card">
    <div className="card-head"><div><h2 className="card-title">Recent activity</h2><div className="card-sub">What happened on your network</div></div>
      <button type="button" className="link-btn" onClick=${() => ui.go('activity')}>See all<${Icon} name="chevron-right" size=${15} /></button></div>
    <div>${s.events.slice(0, 6).map(e => html`<div className="act-row" key=${e.id}>
      <span className=${'act-ic ' + actCls(e)}><${Icon} name=${e.icon} size=${15} /></span>
      <div className="grow" style=${{ minWidth: 0 }}><div className="act-title">${e.title}</div>${e.detail ? html`<div className="act-detail">${e.detail}</div>` : null}</div>
      <span className="act-time">${fmtAgo(e.ts, s.now)}</span>
    </div>`)}
    ${s.events.length === 0 ? html`<div className="empty">Nothing yet.</div>` : null}</div>
  </section>`;
}
export function DishChip({ dish }) {
  if (dish.reachable === false) return html`<span className="chip chip-crit"><${Icon} name="satellite-dish" size=${12} />Can’t reach it</span>`;
  if (dish.online === false) return html`<span className="chip chip-crit"><${Icon} name="wifi-off" size=${12} />Offline</span>`;
  if (dish.online) return html`<span className="chip chip-good"><span className="dot" />Online</span>`;
  return html`<span className="chip chip-muted"><span className="dot" />Connecting</span>`;
}
function StarlinkGlance({ s, ui }) {
  const d = s.dish;
  return html`<section className="card">
    <div className="card-head"><div><h2 className="card-title">Starlink</h2><div className="card-sub">Dish, sky view and dropouts</div></div>
      <button type="button" className="link-btn" onClick=${() => ui.go('starlink')}>Details<${Icon} name="chevron-right" size=${15} /></button></div>
    <div className="kv">
      <div>Status</div><div><${DishChip} dish=${d} /></div>
      <div>Online for</div><div>${d.online_since ? fmtDur(s.now - d.online_since) : '–'}</div>
      <div>Sky view</div><div>${d.obstructed > 0.0005 ? `${(d.obstructed * 100).toFixed(2)}% blocked` : 'Clear, nothing blocking it'}</div>
      <div>Dropouts, 24 h</div><div className="tnum">${s.outages.length ? `${s.outages.length}, ${fmtSecs(sum(s.outages, o => o.duration_s))} in total` : 'None'}</div>
    </div>
    <div style=${{ marginTop: '14px' }}><${OutageStrip} outages=${s.outages} now=${s.now} knownSince=${s.known_since} /></div>
  </section>`;
}

export function Overview({ s, x, points, devHist, api, ui }) {
  return html`<div className="view">
    <div className="hero">
      <${Hero} s=${s} x=${x} points=${points} api=${api} ui=${ui} />
      <${OrbitMap} s=${s} ui=${ui} />
    </div>
    <div className="grid">
      <div className="s-5"><${TopUsers} s=${s} x=${x} ui=${ui} /></div>
      <div className="s-7"><${LiveTraffic} s=${s} x=${x} points=${points} devHist=${devHist} /></div>
      <div className="s-7"><${Insights} s=${s} x=${x} api=${api} ui=${ui} /></div>
      <div className="s-5"><${RecentActivity} s=${s} ui=${ui} /></div>
      <div className="s-7"><${DataToday} s=${s} ui=${ui} /></div>
      <div className="s-5"><${StarlinkGlance} s=${s} ui=${ui} /></div>
    </div>
  </div>`;
}
