/* The speed test: the router measures download, then upload, for about 30 seconds. */
import { html, Fragment, clamp, fmtAgo, fmtClock, Icon, Modal } from './lib.js';

function Gauge({ v, max }) {
  const cx = 150, cy = 140, r = 112;
  const ang = f => Math.PI * (1 - clamp(f, 0, 1));
  const at = f => [cx + r * Math.cos(ang(f)), cy - r * Math.sin(ang(f))];
  const [ex, ey] = at(v / max);
  const ticks = [0, 0.2, 0.4, 0.6, 0.8, 1].map(f => Math.round(f * max));
  return html`<svg viewBox="0 0 300 176" className="gauge" aria-hidden="true">
    <path className="gauge-track" d=${`M${cx - r},${cy} A${r},${r} 0 0 1 ${cx + r},${cy}`} />
    ${v > max * 0.004 ? html`<path className="gauge-val" d=${`M${cx - r},${cy} A${r},${r} 0 0 1 ${ex.toFixed(1)},${ey.toFixed(1)}`} />` : null}
    ${ticks.map(t => { const a = ang(t / max); return html`<text key=${t} className="gauge-tick" x=${(cx + (r - 26) * Math.cos(a)).toFixed(1)} y=${(cy - (r - 26) * Math.sin(a) + 4).toFixed(1)} textAnchor="middle">${t}</text>`; })}
    <text className="gauge-num" x=${cx} y=${cy - 14} textAnchor="middle">${v < 10 ? v.toFixed(1) : Math.round(v)}</text>
    <text className="gauge-unit" x=${cx} y=${cy + 8} textAnchor="middle">Mbps</text>
  </svg>`;
}

export function verdict(down, up) {
  const streams = Math.floor(down / 25);
  const d = down >= 150 ? `Fast. About ${streams} people can stream in 4K at the same time.`
    : down >= 50 ? 'Good for streaming and calls. Big downloads take a little while.'
    : 'Slower than usual for Starlink. Restarting the dish, or checking what blocks its view, can help.';
  const u = up >= 10 ? ' Uploads and video calls will be smooth.' : up >= 5 ? ' Uploads are fine for video calls.' : ' Uploads and video calls may struggle.';
  return d + u;
}

const PHASE = { starting: 'Starting the test…', down: 'Testing download…', up: 'Testing upload…' };

export function SpeedModal({ s, api, ui }) {
  const t = s.speedtest, last = s.tests[0];
  const result = !t.running && t.result && s.now - t.result.ts < 15 * 60e3 ? t.result : null;
  const wait = last ? Math.max(0, Math.ceil((60e3 - (s.now - last.ts)) / 1000)) : 0;
  const offline = s.dish.online !== true;
  const startBtn = label => html`<button type="button" className="btn btn-primary" data-autofocus="true" disabled=${offline || wait > 0} onClick=${() => api.speedtest()}>
    <${Icon} name="gauge" size=${16} />${wait > 0 ? `${label} in ${wait} s` : label}</button>`;
  let body;
  if (t.running) {
    const up = t.phase === 'up';
    body = html`<div><${Gauge} v=${(up ? t.up_now : t.down_now) || 0} max=${up ? 50 : 500} />
      <div className="muted" style=${{ textAlign: 'center', fontWeight: 650, marginTop: '-4px' }} aria-live="polite">${PHASE[t.phase] || PHASE.starting}</div></div>
      <p className="muted" style=${{ fontSize: '13.5px', textAlign: 'center' }}>Your router is measuring the link to the internet. This takes about 30 seconds.</p>`;
  } else if (result && result.error) {
    body = html`<div className="banner warn"><span className="banner-ic"><${Icon} name="triangle-alert" size=${17} /></span>
      <div className="grow"><div className="banner-title">The test didn’t finish</div><div className="banner-body">${result.error_text}</div></div></div>
      <div className="row">${startBtn('Try again')}</div>`;
  } else if (result) {
    body = html`<${Fragment}>
      <div className="results">
        <div><small>Download</small><b className="tnum">${Math.round(result.down)} Mbps</b></div>
        <div><small>Upload</small><b className="tnum">${Math.round(result.up || 0)} Mbps</b></div>
        <div><small>Latency</small><b className="tnum">${result.latency ? Math.round(result.latency) + ' ms' : '–'}</b></div>
      </div>
      <p className="ink2">${verdict(result.down, result.up || 0)}</p>
      <p className="muted" style=${{ fontSize: '13px' }}>These are the typical speeds during the test. The fastest moments reached ${Math.round(result.down_peak || 0)} Mbps down and ${Math.round(result.up_peak || 0)} Mbps up.</p>
      <div className="row">${startBtn('Test again')}</div><//>`;
  } else {
    body = html`<${Fragment}>
      <p className="ink2">Your router measures the speed between your home and the internet. It takes about 30 seconds and uses a few hundred MB of data, and streams in the house may stutter while it runs.</p>
      ${last && !last.error ? html`<p className="muted" style=${{ fontSize: '13.5px' }}>Last test, ${fmtAgo(last.ts, s.now)} at ${fmtClock(last.ts)}: ${Math.round(last.down)} Mbps down, ${Math.round(last.up || 0)} Mbps up.</p>` : null}
      ${offline ? html`<p className="muted">Starlink is offline right now, so there’s nothing to test.</p>` : null}
      <div className="row">${startBtn('Start the test')}</div><//>`;
  }
  return html`<${Modal} onClose=${ui.closeModal} title="Speed test">${body}<//>`;
}
