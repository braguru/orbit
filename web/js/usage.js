/* Usage: how much data your home used, and how the connection behaved, over a day, a week or a month. */
import {
  html, useState, sum, readPref, writePref, fmtMbps, fmtBytes, fmtDur, fmtSecs, fmtClock, fmtShortDate, fmtWeekday,
  plural, Icon, Seg, Stat, LineChart, UsageBars, HBars, Glyph, personOf, devColor, ownerLabel,
} from './lib.js';
import { usePoll } from './data.js';
import { personRows } from './overview.js';

const RANGES = [{ value: '24h', label: '24 hours' }, { value: '7d', label: '7 days' }, { value: '30d', label: '30 days' }];
const LONG = { '24h': 'the last 24 hours', '7d': 'the last 7 days', '30d': 'the last 30 days' };
const LATENCY = [{ key: 'lat', name: 'latency', label: 'Latency', color: 'var(--accent)', area: true }];
const fmtMs = v => String(Math.round(v));
const longDay = t => new Date(t).toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });

function barLabels(range, bars) {
  const n = bars.length;
  if (range === '24h') return (b, i) => (i % 4 === 0 ? new Date(b.t).toLocaleTimeString([], { hour: 'numeric' }) : '');
  if (range === '7d') return (b, i) => (i === n - 1 ? 'Today' : fmtWeekday(b.t));
  return (b, i) => (i === n - 1 ? 'Today' : (n - 1 - i) % 7 === 0 ? fmtShortDate(b.t) : '');
}
function seriesLabels(range, pts) {
  const n = pts.length;
  if (n < 2) return [];
  const fmt = range === '24h' ? fmtClock : range === '7d' ? fmtWeekday : fmtShortDate;
  return [{ i: 0, text: fmt(pts[0].t) }, { i: Math.floor((n - 1) / 2), text: fmt(pts[Math.floor((n - 1) / 2)].t) }, { i: n - 1, text: 'Now' }];
}

export function UsageView({ s, ui }) {
  const [range, setRange] = useState(() => readPref('usage-range', '7d'));
  const pick = r => { setRange(r); writePref('usage-range', r); };
  const { data, error } = usePoll(`/api/usage?range=${range}`, 60000);
  const head = html`<div className="page-head"><div><h1 className="page-title">Usage</h1>
      <p className="page-sub">How much data your home used, and how the connection held up. Orbit saves a reading every second while it runs.</p></div>
    <${Seg} label="Time range" value=${range} onChange=${pick} options=${RANGES} /></div>`;
  if (!data) return html`<div className="view">${head}<section className="card"><div className="empty">${error ? 'Couldn’t load usage: ' + error : 'Loading…'}</div></section></div>`;

  const per = range === '24h' ? 'hour' : 'day';
  const total = data.total.down + data.total.up;
  const busiest = data.bars.reduce((m, b) => (b.down + b.up > (m ? m.down + m.up : 0) ? b : m), null);
  const peak = Math.max(0, ...data.speed.map(p => p.down_max || 0));
  const coverage = data.range_s ? data.recorded_s / data.range_s : 1;
  const speed = data.speed.map(p => ({ t: p.t, down: p.down, up: p.up, lat: p.lat }));
  const bucketWords = data.bucket_s >= 21600 ? '6-hour' : data.bucket_s >= 3600 ? 'hourly' : '15-minute';
  const when = p => (range === '24h' ? `${fmtClock(p.t)} – ${fmtClock(p.t + data.bucket_s * 1000)}` : `${longDay(p.t)}, from ${fmtClock(p.t)}`);
  const whenBar = b => (range === '24h' ? `${fmtClock(b.t)} – ${fmtClock(b.t + 3600e3)}` : longDay(b.t));
  const people = personRows({ ...s, devices: data.devices.map(d => ({ ...d, owner: (s.devices.find(x => x.id === d.id) || d).owner })) }, m => sum(data.devices.filter(m), d => d.down + d.up));
  const devTotal = sum(data.devices, d => d.down + d.up);
  return html`<div className="view">
    ${head}
    ${coverage < 0.95 ? html`<div className="banner" role="note"><span className="banner-ic" style=${{ color: 'var(--accent)' }}><${Icon} name="history" size=${17} /></span>
      <div className="grow"><div className="banner-title">Orbit has recorded ${fmtDur(data.recorded_s * 1000)} of ${LONG[range]}</div>
      <div className="banner-body">Totals only cover the time Orbit was running. Leave it running, ideally on a computer that stays on, and this fills in.</div></div></div>` : null}
    <div className="tiles">
      <${Stat} icon="arrow-down" label="Downloaded" value=${fmtBytes(data.total.down).split(' ')[0]} unit=${fmtBytes(data.total.down).split(' ')[1]} note=${`Whole home, ${LONG[range]}`} />
      <${Stat} icon="arrow-up" label="Uploaded" value=${fmtBytes(data.total.up).split(' ')[0]} unit=${fmtBytes(data.total.up).split(' ')[1]} note=${total ? `${Math.round((data.total.up / total) * 100)}% of all traffic` : 'Nothing yet'} />
      <${Stat} icon="calendar" label=${'Busiest ' + per} value=${busiest ? fmtBytes(busiest.down + busiest.up).split(' ')[0] : '–'} unit=${busiest ? fmtBytes(busiest.down + busiest.up).split(' ')[1] : ''} note=${busiest ? whenBar(busiest) : 'Nothing yet'} />
      <${Stat} icon="gauge" label="Fastest download" value=${fmtMbps(peak)} unit="Mbps" note="The highest one-second reading. Not a speed test." />
      <${Stat} icon="triangle-alert" label="Dropouts" value=${data.outages.count} note=${data.outages.count ? `${fmtSecs(data.outages.seconds)} offline in total` : 'None recorded'} />
      <${Stat} icon="monitor-smartphone" label="Devices that used data" value=${data.devices.length} note=${data.devices[0] ? `Most: ${data.devices[0].name}` : 'None yet'} />
    </div>
    <div className="grid">
      <div className="s-12"><section className="card">
        <div className="card-head"><div><h2 className="card-title">Data used per ${per}</h2><div className="card-sub">${fmtBytes(total)} in ${LONG[range]}, measured at the dish</div></div></div>
        <${UsageBars} bars=${data.bars} tall=${true} dense=${data.bars.length > 14} labelOf=${barLabels(range, data.bars)} tipOf=${whenBar} />
      </section></div>
      <div className="s-7"><section className="card">
        <div className="card-head"><div><h2 className="card-title">Internet use over time</h2><div className="card-sub">Average download and upload, in ${bucketWords} steps. Gaps are times Orbit wasn’t recording.</div></div></div>
        <${LineChart} points=${speed} xLabels=${seriesLabels(range, speed)} label=${`Average internet use over ${LONG[range]}`} timeLabel=${when} />
      </section></div>
      <div className="s-5"><section className="card">
        <div className="card-head"><div><h2 className="card-title">Latency over time</h2><div className="card-sub">How quickly the internet responds. Under 40 ms is great.</div></div></div>
        <${LineChart} points=${speed} series=${LATENCY} unit="ms" fmt=${fmtMs} minMax=${50} height=${160} xLabels=${seriesLabels(range, speed)} label=${`Latency over ${LONG[range]}`} timeLabel=${when} />
      </section></div>
      <div className="s-5"><section className="card">
        <div className="card-head"><div><h2 className="card-title">By person</h2><div className="card-sub">${LONG[range].replace(/^the l/, 'L')}</div></div>
          <button type="button" className="link-btn" onClick=${() => ui.go('people')}>People<${Icon} name="chevron-right" size=${15} /></button></div>
        ${people.length ? html`<${HBars} rows=${people} />` : html`<div className="empty">No device usage recorded yet.</div>`}
      </section></div>
      <div className="s-7"><section className="card">
        <div className="card-head"><div><h2 className="card-title">By device</h2><div className="card-sub">Download and upload together</div></div></div>
        <div className="ulist">
          ${data.devices.slice(0, 12).map(d => {
            const live = s.devices.find(x => x.id === d.id) || { ...d, online: false, is_new: false };
            const p = personOf(s.people, live.owner);
            const share = devTotal ? (d.down + d.up) / devTotal : 0;
            return html`<div className="urow" key=${d.id}>
              <button type="button" className="clickable row grow link-plain" onClick=${() => s.devices.some(x => x.id === d.id) && ui.openDevice(d.id)}>
                <${Glyph} d=${live} people=${s.people} />
                <div className="urow-main">
                  <div className="row"><span className="urow-name grow">${d.name}</span><span className="urow-val tnum">${fmtBytes(d.down + d.up)}</span></div>
                  <div className="share" style=${{ '--pc': devColor(live, p) }}><span style=${{ width: Math.max(1, share * 100) + '%' }} /></div>
                  <div className="urow-meta"><span className=${'pdot' + (p ? '' : ' is-none')} style=${{ '--pc': devColor(live, p) }} /><span>${ownerLabel(live, p)}</span><span aria-hidden="true">·</span><span className="tnum">↓ ${fmtBytes(d.down)} · ↑ ${fmtBytes(d.up)}</span></div>
                </div>
              </button>
            </div>`;
          })}
          ${data.devices.length === 0 ? html`<div className="empty">No device usage recorded yet.</div>` : null}
          ${data.devices.length > 12 ? html`<p className="muted" style=${{ fontSize: '13px', paddingTop: '8px' }}>And ${plural(data.devices.length - 12, 'more device')}.</p>` : null}
        </div>
      </section></div>
    </div>
    <p className="muted fine">The whole-home numbers come from your dish. Per-device numbers come from your router and count everything a device sends over Wi-Fi, including traffic that stays inside your home, like casting to a TV. That’s why they can add up to more than the whole-home total.</p>
  </div>`;
}
