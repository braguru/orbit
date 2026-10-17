/* Security: who can reach whom on your Wi-Fi, and who is knocking on this Mac. */
import { html, useState, useMemo, Fragment, enterKey, sum, fmtAgo, fmtClock, plural, Icon, Glyph, Switch, personOf, scol, typeIcon, HOUR } from './lib.js';
import { ICONS } from './icons.js';
import { actCls } from './overview.js';

const ACTIVE_MS = HOUR;
const shortName = (n, max = 17) => (n.length > max ? n.slice(0, max - 1) + '…' : n);
const polar = (a, r) => [300 + r * Math.cos((a * Math.PI) / 180), 300 + r * Math.sin((a * Math.PI) / 180)];
const f1 = v => v.toFixed(1);
function wedgePath(a0, a1, r0, r1) {
  const [x1, y1] = polar(a0, r1), [x2, y2] = polar(a1, r1), [x3, y3] = polar(a1, r0), [x4, y4] = polar(a0, r0);
  return `M${f1(x1)},${f1(y1)} A${r1},${r1} 0 0 1 ${f1(x2)},${f1(y2)} L${f1(x3)},${f1(y3)} A${r0},${r0} 0 0 0 ${f1(x4)},${f1(y4)} Z`;
}
function rng(seed) {
  let t = seed;
  return () => { t += 0x6d2b79f5; let r = Math.imul(t ^ (t >>> 15), 1 | t); r ^= r + Math.imul(r ^ (r >>> 7), 61 | r); return ((r ^ (r >>> 14)) >>> 0) / 4294967296; };
}

/* Probes seen in the last hour. Used by the page and the navigation badge. */
export function activeProbes(s) {
  const sec = s && s.security;
  return sec && sec.probes ? sec.probes.filter(p => !p.known && s.now - p.last < ACTIVE_MS) : [];
}

/* Known devices on your main Wi-Fi are allowed to talk to this Mac. Seen in the last hour, they get a calm line on the map. */
export function friendlyProbes(s) {
  const sec = s && s.security;
  return sec && sec.probes ? sec.probes.filter(p => p.known && s.now - p.last < ACTIVE_MS) : [];
}

/* The networks, each with the slice of the circle it owns. Non-guest networks share the top half, guests the bottom half. */
function layoutNets(s) {
  let list = ((s.router && s.router.networks) || []).map(n => ({ ...n, name: Object.values(n.ssids || {})[0] || (n.guest ? 'Guest Wi-Fi' : 'Wi-Fi') }));
  if (!list.length) list = [{ domain: 'lan', guest: false, isolated: false, open: false, enabled: true, ssids: {}, name: 'Your Wi-Fi' }];
  if (!list.some(n => !n.guest)) list[0].guest = false;
  const top = list.filter(n => !n.guest), bottom = list.filter(n => n.guest).slice(0, 4);
  const place = (arr, base) => arr.forEach((n, i) => { const w = 180 / arr.length; n.a0 = base + w * i; n.a1 = base + w * (i + 1); n.groupSize = arr.length; });
  place(top, 180);
  place(bottom, 0);
  return { nets: [...top, ...bottom], main: top[0] };
}

function layoutNodes(s, nets, main) {
  const byDomain = new Map(nets.map(n => [n.domain, n]));
  const groups = new Map(nets.map(n => [n.domain, []]));
  s.devices.filter(d => d.online && !d.hidden).forEach(d => {
    const net = byDomain.get(d.domain || main.domain) || main;
    groups.get(net.domain).push(d);
  });
  const out = [];
  nets.forEach(net => {
    const g = groups.get(net.domain), n = g.length;
    const a0 = net.a0 + 10, a1 = net.a1 - 10;
    const cap = Math.max(2, Math.min(6, Math.floor(((a1 - a0) * Math.PI / 180 * 175) / 38)));
    const rings = n <= cap ? [175] : n <= cap * 2 ? [160, 222] : [140, 185, 230];
    g.forEach((d, i) => {
      const a = a0 + ((a1 - a0) * (i + 0.5)) / n;
      const [x, y] = polar(a, rings[i % rings.length]);
      out.push({ id: d.id, name: d.name, d, net, a, x, y });
    });
  });
  return out;
}

const GHOST_ANGLES = [215, 325, 240, 300, 205, 335];
const where = p => (p.network === 'main' ? 'on your main Wi-Fi' : p.network === 'guest' ? 'on a guest Wi-Fi' : 'from outside your Wi-Fi');
const probeName = (p, s) => { const d = p.device && s.devices.find(x => x.id === p.device); return (d && d.name) || p.name || p.ip; };
const doorText = x => `Door ${x.port}${x.label && !/^Port /.test(x.label) ? ' · ' + x.label : ''}`;
const probeLine = p => (p.scan
  ? 'It knocked on many doors on this Mac in quick succession, which is how scanners look for a way in.'
  : 'Doors are how programs talk to a computer. Knocking on one nobody asked for is how strangers look for a way in.');

/* Wi-Fi protection types as the router reports them: the label, and whether it is the strong kind. */
const SEC_TYPE = { wpa3: ['WPA3', true], wpa2: ['WPA2', true], wpa: ['WPA (old)', false], wep: ['WEP (old)', false] };

/* One settings row: what it is, a plain line about it, and a small verdict chip on the right. */
function SettingRow({ title, sub, tone, children }) {
  return html`<div className="setting"><div className="setting-text"><div className="setting-title">${title}</div>${sub ? html`<div className="setting-sub">${sub}</div>` : null}</div>
    ${children ? html`<span className=${'chip ' + (tone ? 'chip-' + tone : '')}>${children}</span>` : null}</div>`;
}

/* The router's own settings, read-only. Orbit never changes them. */
function RouterSettings({ s }) {
  const r = s.router || {}, st = r.settings;
  const nets = (r.networks || []).filter(n => n.enabled !== false);
  if (!st) return html`<section className="card"><div className="card-head"><div><h2 className="card-title">Router settings</h2><div className="card-sub">Read from your router</div></div></div><div className="empty">Waiting for the router’s settings…</div></section>`;
  const dns = st.dns || {}, ch = st.channels || {}, wd = st.widths || {};
  const auto = !ch['2.4'] && !ch['5'] && !ch['5_upper'] && !wd['5'] && !wd['5_upper'];
  const chan = v => (v ? 'channel ' + v : 'automatic');
  const width = v => (v ? v + ' MHz' : 'automatic');
  const netName = n => Object.values(n.ssids || {})[0] || (n.guest ? 'Guest Wi-Fi' : 'Wi-Fi');
  return html`<section className="card">
    <div className="card-head"><div><h2 className="card-title">Router settings</h2><div className="card-sub">What your router is set to right now</div></div></div>
    ${nets.map(n => {
      const t = SEC_TYPE[n.security];
      return html`<${SettingRow} key=${n.domain} title=${`${n.guest ? 'Guest' : 'Main'} Wi-Fi protection`}
        sub=${n.open ? `${netName(n)}: anyone nearby can join without a password.` : `${netName(n)}${n.hidden ? '. Its name is hidden, which hides it from the list but is not real protection' : ''}`}
        tone=${n.open ? 'crit' : t && t[1] ? 'good' : 'warn'}>${n.open ? 'No password' : t ? t[0] : 'Password'}<//>`;
    })}
    <${SettingRow} title="DNS" sub="DNS decides where website names lead. Only change it if you know why." tone=${dns.custom ? 'warn' : ''}>${dns.custom ? 'Custom: ' + (dns.servers || []).join(', ') : 'Router default'}<//>
    <${SettingRow} title="Secure DNS" sub=${dns.secure ? 'Website lookups are scrambled so others on the way can’t read or change them.' : 'Website lookups are sent as plain text. That is how most homes work.'} tone=${dns.secure ? 'good' : ''}>${dns.secure ? 'On' : 'Off'}<//>
    <${SettingRow} title=${st.ap_mode ? 'Access point mode' : 'Bypass mode'} sub=${st.bypass || st.ap_mode ? 'Another router runs your network, so Orbit can’t see the devices behind it.' : 'Your Starlink router runs your network, so Orbit can see every device.'} tone=${st.bypass || st.ap_mode ? 'warn' : 'good'}>${st.bypass || st.ap_mode ? 'On' : 'Off'}<//>
    ${st.repeater ? html`<${SettingRow} title="Repeater" sub="The router is extending another Wi-Fi network." tone="warn">On<//>` : null}
    <${SettingRow} title="Adding mesh routers" sub=${st.mesh_onboarding ? 'The router is open to pairing a new Starlink mesh router right now.' : 'The router isn’t looking for new mesh routers.'}>${st.mesh_onboarding ? 'Open' : 'Closed'}<//>
    <${SettingRow} title="Wi-Fi channels" sub=${`Channels are lanes on the radio. Automatic lets the router pick the quietest. Now: 2.4 GHz ${chan(ch['2.4'])}, 5 GHz ${chan(ch['5'])}, upper 5 GHz ${chan(ch['5_upper'])}. Width is how wide a lane is, wider is faster: 5 GHz ${width(wd['5'])}, upper ${width(wd['5_upper'])}.`}>${auto ? 'Automatic' : 'Set by hand'}<//>
    <${SettingRow} title="DFS channels" sub="Extra 5 GHz lanes shared with weather radar. They’re often quieter, but the router must hop off if radar shows up.">${st.dfs ? 'On' : 'Off'}<//>
    <${SettingRow} title="Country" sub="Sets which Wi-Fi channels and power levels are legal.">${st.country || '–'}<//>
    <${SettingRow} title="Automatic speed tests" sub="The router tests your speed now and then on its own.">${st.auto_speedtests ? 'On' : 'Off'}<//>
    <p className="muted" style=${{ fontSize: '13px', marginTop: '12px' }}>Orbit shows what your router is set to. Change it in the Starlink app.</p>
  </section>`;
}

function netInfo(n, hasGuest) {
  const off = n.enabled === false;
  const chips = [n.open ? ['chip-crit', 'lock-open', 'No password'] : ['chip-good', 'lock', n.security && SEC_TYPE[n.security] ? SEC_TYPE[n.security][0] : 'Password']];
  if (n.hidden) chips.push(['chip-muted', 'eye-off', 'Name hidden']);
  if (n.guest) chips.push(n.isolated ? ['chip-good', 'shield-check', 'Client isolation on'] : ['chip-crit', 'shield-x', 'Client isolation OFF']);
  else chips.push(n.isolated ? ['chip-good', 'shield-check', 'Client isolation on'] : ['chip-warn', 'unlink', 'Devices can reach each other']);
  if (n.guest) chips.push(['chip-good', 'shield-check', 'Can’t reach main Wi-Fi']);
  else if (hasGuest) chips.push(['chip-good', 'shield-check', 'Guests can’t reach it']);
  if (off) chips.unshift(['chip-muted', 'power', 'Off']);
  let note;
  if (off) note = 'This network is switched off, so nothing can join it right now.';
  else if (n.guest && n.open && !n.isolated) note = 'Anyone can join without a password, and they can reach each other. Any traffic they send can be read by the others. Turn isolation back on in the Starlink app.';
  else if (n.guest && !n.isolated) note = 'Guests can reach each other. That is not what a guest network is for. Turn isolation back on in the Starlink app.';
  else if (n.guest && n.open) note = 'Anyone can join, but isolation keeps each visitor in their own room. Orbit checks this setting and warns you if it ever turns off.';
  else if (n.guest) note = 'Each guest gets the internet and nothing else. They can’t see each other or your devices.';
  else if (n.open) note = 'Anyone nearby can join without a password, and then reach every device on it. Set a Wi-Fi password in the Starlink app.';
  else if (n.isolated) note = 'Isolation keeps each device in its own room, so none of them can reach the others.';
  else note = 'Normal for a home network. It means any device that gets in can see the rest, so strangers must not get in.';
  const tone = off ? '' : (n.guest && !n.isolated) || n.open ? 'crit' : n.guest ? 'good' : 'warn';
  return { chips, note, tone, ic: n.guest ? 'qr-code' : n.open ? 'radar' : 'house-wifi' };
}

function zoneStyle(n) {
  const dim = n.enabled === false ? 0.45 : 1;
  if (n.guest) {
    const bad = !n.isolated || n.open;
    return { fill: bad ? 'var(--crit)' : 'var(--sky-ink)', fillOpacity: !n.isolated ? 0.16 : n.open ? 0.07 : 0.035, stroke: bad ? 'var(--crit)' : 'var(--sky-line-2)', strokeOpacity: bad ? 0.55 : 1, strokeDasharray: n.open ? '5 4' : undefined, opacity: dim };
  }
  return { fill: n.open ? 'var(--crit)' : 'var(--sky-accent)', fillOpacity: 0.07, stroke: n.open ? 'var(--crit)' : 'var(--sky-accent)', strokeOpacity: 0.4, opacity: dim };
}

export function SecurityView({ s, api, ui }) {
  const [sel, setSel] = useState(null);
  const sec = s.security || { tripwire: { on: false, listening: [], busy: [] }, probes: [] };
  const tw = sec.tripwire || {};
  const { nets, main } = useMemo(() => layoutNets(s), [s.router]);
  const nodes = useMemo(() => layoutNodes(s, nets, main), [s.devices, nets]);
  const stars = useMemo(() => { const r = rng(11); return Array.from({ length: 70 }, (_, i) => ({ x: r() * 600, y: r() * 600, r: 0.4 + r() * 1.1, o: 0.15 + r() * 0.5, tw: i % 7 === 0, delay: (r() * 4).toFixed(2) })); }, []);

  const active = activeProbes(s);
  const byDevId = id => nodes.find(n => n.id === id);
  /* One map point per source: a device on the map, or a ghost at the edge of the main sector. */
  const sources = [];
  active.forEach(p => {
    const real = p.device ? byDevId(p.device) : null;
    const key = real ? real.id : 'ghost:' + p.ip;
    let src = sources.find(x => x.key === key);
    if (!src) { src = { key, node: real, probes: [] }; sources.push(src); }
    src.probes.push(p);
  });
  const ghosts = sources.filter(x => !x.node).map((x, i) => {
    const a = GHOST_ANGLES[i % GHOST_ANGLES.length], [px, py] = polar(a, i >= GHOST_ANGLES.length ? 246 : 268);
    x.node = { id: x.key, name: x.probes[0].ip, ghost: true, probe: x.probes[0], net: main, a, x: px, y: py };
    return x.node;
  });
  const host = tw.host_device ? byDevId(tw.host_device) : null;
  const friends = host ? friendlyProbes(s).map(p => ({ p, node: p.device ? byDevId(p.device) : null })).filter(x => x.node && x.node.id !== host.id) : [];
  const arcs = host ? sources.filter(x => x.node.id !== host.id) : [];
  const allNodes = [...nodes, ...ghosts];
  const hotIds = new Set(sources.map(x => x.node.id));
  if (host && sources.length) hotIds.add(host.id);

  const reach = (a, b) => !a.ghost && !b.ghost && a.id !== b.id && a.net.domain === b.net.domain && (!a.net.guest || !a.net.isolated);
  const selN = sel ? allNodes.find(n => n.id === sel) : null;
  const reachable = selN ? nodes.filter(n => reach(selN, n)) : [];
  const meshOf = net => nodes.filter(n => n.net.domain === net.domain).sort((a, b) => a.a - b.a).map(n => f1(n.x) + ',' + f1(n.y)).join(' ');
  const countOn = net => nodes.filter(n => n.net.domain === net.domain).length;
  const hasGuest = nets.some(n => n.guest);
  const clear = () => setSel(null);

  /* A wall stands wherever two networks meet. */
  const walls = [...new Set(nets.flatMap(n => [n.a0 % 360, n.a1 % 360]))].filter(a => nets.filter(n => n.a0 % 360 === a || n.a1 % 360 === a).length >= 2);

  const tries = sum(active, p => p.tries);
  const doorSet = new Set();
  active.forEach(p => (p.ports || []).forEach(x => doorSet.add(x.port)));
  const names = sources.map(x => probeName(x.probes[0], s));
  const anyScan = active.some(p => p.scan);
  const firstReal = sources.find(x => x.probes[0].device && s.devices.some(d => d.id === x.probes[0].device));
  const toggleTw = on => api.setTripwire(on);
  const allProbes = sec.probes || [];
  const secEvents = s.events.filter(e => e.cat === 'security').slice(0, 5);
  const port0 = (tw.listening || [])[0];
  const verb = anyScan ? 'scanning' : 'probing';

  return html`<div className="view">
    <div className="page-head"><div><h1 className="page-title">Security</h1>
      <p className="page-sub">See which devices can talk to each other, and who is knocking on this Mac. Each Wi-Fi network is its own part of the map.</p></div></div>
    ${active.length ? html`<div className="banner crit" role="status"><span className="banner-ic"><${Icon} name="shield-alert" size=${18} /></span>
      <div className="grow"><div className="banner-title">${sources.length === 1 ? `${names[0]} is ${verb} your Mac` : `${sources.length} devices are ${verb} your Mac`}</div>
        <div className="banner-body">${plural(tries, 'try', 'tries')}${doorSet.size ? ` on ${plural(doorSet.size, 'door')}` : ''}, the latest ${fmtAgo(Math.max(...active.map(p => p.last)), s.now)}. If you don’t recognise ${sources.length === 1 ? 'it' : 'them'}, block ${sources.length === 1 ? 'it' : 'them'} in the Starlink app and change your Wi-Fi password.</div>
        ${firstReal ? html`<div className="row wrap" style=${{ marginTop: '10px' }}><button type="button" className="btn btn-sm" onClick=${() => ui.openDevice(firstReal.probes[0].device)}>Open device</button></div>` : null}</div></div>`
      : tw.on ? html`<div className="banner" role="status"><span className="banner-ic" style=${{ color: 'var(--good-ink)' }}><${Icon} name="shield-check" size=${18} /></span>
        <div className="grow"><div className="banner-title">No one is probing your Mac</div><div className="banner-body">The tripwire has seen nothing in the last hour.</div></div></div>`
      : html`<div className="banner" role="status"><span className="banner-ic"><${Icon} name="shield-x" size=${18} /></span>
        <div className="grow"><div className="banner-title">The tripwire is off</div><div className="banner-body">Without it, Orbit can’t tell you when something knocks on this Mac.</div>
          <div className="row wrap" style=${{ marginTop: '10px' }}><button type="button" className="btn btn-sm btn-primary" onClick=${() => toggleTw(true)}>Turn it on</button></div></div></div>`}
    <div className="grid">
      <div className="s-7"><section className="sky sec-wrap" aria-label="Map of who can reach whom">
        <div className="orbit-head"><div><h2 className="sky-title">Who can reach whom</h2><div className="sky-sub">${plural(nets.length, 'Wi-Fi network')} around your router. Tap a device to see what it can reach.</div></div>
          <span className="live-pill"><span className="live-dot" />${active.length ? 'Watching' : tw.on ? 'All quiet' : 'Tripwire off'}</span></div>
        <div className="sec-stage">
          <svg viewBox="0 0 600 600" role="group" aria-label="Your devices grouped by Wi-Fi network. Walls separate the networks.">
            <rect width="600" height="600" fill="transparent" onClick=${clear} />
            <g aria-hidden="true" style=${{ pointerEvents: 'none' }}>
              ${stars.map((st, i) => html`<circle key=${i} className=${'o-star' + (st.tw ? ' twinkle' : '')} cx=${f1(st.x)} cy=${f1(st.y)} r=${st.r.toFixed(2)} style=${{ opacity: st.o, animationDelay: st.tw ? st.delay + 's' : undefined }} />`)}
              ${nets.map(n => html`<path key=${'z' + n.domain} className="sec-zone" d=${wedgePath(n.a0 + 4, n.a1 - 4, 46, 292)} style=${zoneStyle(n)} />`)}
              ${walls.map(a => { const [x1, y1] = polar(a, 46), [x2, y2] = polar(a, 296), [bx, by] = polar(a, 150); return html`<${Fragment} key=${'w' + a}>
                <line className="sec-wall" x1=${f1(x1)} y1=${f1(y1)} x2=${f1(x2)} y2=${f1(y2)} />
                <circle className="sec-wall-badge" cx=${f1(bx)} cy=${f1(by)} r="13" />
                <svg x=${f1(bx - 7)} y=${f1(by - 7)} width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)' }} dangerouslySetInnerHTML=${{ __html: ICONS['shield-check'] }} /><//>`; })}
              ${nets.map(n => { const [lx, ly] = polar((n.a0 + n.a1) / 2, 268), off = n.enabled === false;
                const sub = off ? 'Switched off' : n.guest ? (n.isolated ? 'Each guest in their own room' : 'Isolation off: guests can reach each other') : (n.isolated ? 'Each device in its own room' : 'One big room: everything can reach everything');
                const label = shortName(n.name, n.groupSize > 2 ? 12 : 20) + (n.guest ? '' : ' · main') + (off ? ' · Off' : '');
                return html`<${Fragment} key=${'l' + n.domain}>
                  <text className="sec-zone-label" x=${f1(lx)} y=${f1(ly)} textAnchor="middle" style=${{ fill: n.guest ? (!n.isolated || n.open ? '#ffb4b4' : 'var(--sky-ink-2)') : 'var(--sky-accent)' }}>${label}</text>
                  ${n.groupSize <= 2 ? html`<text className="sec-sub-label" x=${f1(lx)} y=${f1(ly + 14)} textAnchor="middle">${sub}</text>` : null}<//>`; })}
              ${nets.filter(n => !n.guest || !n.isolated).map(n => html`<polyline key=${'m' + n.domain} className="sec-mesh" points=${meshOf(n)} style=${n.guest ? { stroke: 'var(--crit)', opacity: 0.6 } : undefined} />`)}
              <g transform="translate(300 300)"><circle className="pulse-ring" r="30" /><circle className="pulse-ring" r="30" style=${{ animationDelay: '1.6s' }} /><circle className="o-router" r="30" />
                <svg x="-13" y="-13" width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)' }} dangerouslySetInnerHTML=${{ __html: ICONS.router }} /></g>
              <text className="o-router-label" x="300" y="350" textAnchor="middle">Router</text>
            </g>
            ${selN ? reachable.map(n => html`<line key=${'r' + n.id} className="sec-reach" x1=${f1(selN.x)} y1=${f1(selN.y)} x2=${f1(n.x)} y2=${f1(n.y)} style=${{ pointerEvents: 'none' }} />`) : null}
            ${arcs.map(({ node: f, probes }, i) => { const o = host, cx = (f.x + o.x) / 2 + (300 - (f.x + o.x) / 2) * 0.35, cy = (f.y + o.y) / 2 + (300 - (f.y + o.y) / 2) * 0.35;
              const doors = [...new Set(probes.flatMap(p => (p.ports || []).map(x => x.port)))];
              const tx = 0.25 * f.x + 0.5 * cx + 0.25 * o.x, ty = 0.25 * f.y + 0.5 * cy + 0.25 * o.y;
              const tag = probes.some(p => p.scan) ? 'Scanning' : doors.length ? 'Probing ' + (doors.length === 1 ? 'door ' : 'doors ') + doors.slice(0, 3).join(', ') + (doors.length > 3 ? '…' : '') : 'Probing';
              return html`<${Fragment} key=${'a' + f.id}>
                <path className="sec-atk" d=${`M${f1(f.x)},${f1(f.y)} Q${f1(cx)},${f1(cy)} ${f1(o.x)},${f1(o.y)}`} style=${{ pointerEvents: 'none', animationDelay: i % 2 ? '-.4s' : undefined }} />
                <text className="sec-atk-tag" x=${f1(tx)} y=${f1(ty - 8)} textAnchor="middle" style=${{ pointerEvents: 'none' }}>${tag}</text><//>`; })}
            ${friends.map(({ p, node: f }) => { const o = host, cx = (f.x + o.x) / 2 + (300 - (f.x + o.x) / 2) * 0.2, cy = (f.y + o.y) / 2 + (300 - (f.y + o.y) / 2) * 0.2;
              return html`<path key=${'f' + f.id} className="sec-ok" d=${`M${f1(f.x)},${f1(f.y)} Q${f1(cx)},${f1(cy)} ${f1(o.x)},${f1(o.y)}`} style=${{ pointerEvents: 'none' }}><title>${f.name} is talking to this Mac. Allowed: it's a known device.</title></path>`; })}
            ${allNodes.map(n => {
              const p = n.ghost ? null : personOf(s.people, n.d.owner);
              const col = n.ghost ? 'var(--crit)' : p ? scol(p) : 'var(--warn)';
              const dim = selN && n.id !== selN.id && !reach(selN, n);
              const hot = hotIds.has(n.id);
              const unknown = !n.ghost && (!n.d.owner || n.d.is_new);
              const iso = !n.ghost && n.net.guest && n.net.isolated;
              const off = n.net.enabled === false;
              const lab = n.id === sel || n.ghost || unknown || hot;
              const pick = () => setSel(n.id === sel ? null : n.id);
              const isHost = host && n.id === host.id;
              return html`<g key=${n.id} className=${'sec-node o-node-s' + (dim || off ? ' is-dim' : '') + (n.id === sel ? ' is-sel' : '')} transform=${`translate(${f1(n.x)} ${f1(n.y)})`} tabIndex="0" role="button" aria-pressed=${n.id === sel ? 'true' : 'false'}
                  aria-label=${n.ghost ? `Unknown source ${n.name}, ${where(n.probe)}, probing this Mac` : `${n.name}, ${n.net.name}${isHost ? ', this Mac' : ''}${hot && !isHost ? ', probing this Mac' : ''}`} onClick=${pick} onKeyDown=${enterKey(pick)}>
                <circle fill="transparent" r="22" />
                ${iso ? html`<circle className="sec-cell" r="21" />` : null}
                <circle className="sec-sel-ring" r="23" />
                ${hot ? html`<circle className="o-halo" r="17" style=${{ stroke: 'var(--crit)' }} />` : unknown && !n.net.guest ? html`<circle className="o-halo" r="17" />` : null}
                <circle className="o-body" r="15" style=${{ stroke: hot ? 'var(--crit)' : col, strokeDasharray: n.ghost || !p ? '3 3' : undefined }} />
                <svg x="-8" y="-8" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style=${{ color: 'var(--sky-ink)', pointerEvents: 'none' }} dangerouslySetInnerHTML=${{ __html: ICONS[n.ghost ? 'circle-help' : typeIcon(n.d)] }} />
                ${lab ? html`<text className="o-label" y="31" textAnchor="middle">${shortName(n.name)}</text>` : null}
              </g>`;
            })}
          </svg>
        </div>
        <div className="sec-keys">
          <span><i className="sec-key-line" style=${{ '--k': 'var(--good)' }} />Can reach each other</span>
          <span><i className="sec-key-line solid" style=${{ '--k': 'var(--sky-ink-2)' }} />Wall: can’t cross</span>
          <span><i className="sec-key-line dash" style=${{ '--k': 'var(--crit)' }} />Contact attempt</span>
          <span><i className="sec-key-line" style=${{ '--k': 'var(--sky-accent)' }} />Known device talking to this Mac</span>
          <span><svg width="20" height="20" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8" className="sec-cell" /></svg>Own private room</span>
        </div>
      </section></div>
      <div className="s-5"><div className="stack">
        <section className="card"><div className="card-head"><div><h2 className="card-title">Your Wi-Fi networks</h2><div className="card-sub">Read from your router</div></div></div>
          ${nets.map(n => { const i = netInfo(n, hasGuest); return html`<div className="net-row" key=${n.domain}>
            <div className="net-top"><span className=${'net-ic ' + i.tone}><${Icon} name=${i.ic} size=${17} /></span><div className="grow"><div className="net-name">${n.name}</div><div className="card-sub" style=${{ marginTop: 0 }}>${n.enabled === false ? 'Off' : plural(countOn(n), 'device') + ' connected'}</div></div></div>
            <div className="chips">${i.chips.map(c => html`<span key=${c[2]} className=${'chip ' + c[0]}><${Icon} name=${c[1]} size=${12} sw=${2.6} />${c[2]}</span>`)}</div>
            <div className="muted" style=${{ fontSize: '13px' }}>${i.note}</div>
          </div>`; })}
        </section>
        <section className="card" aria-live="polite">
          ${selN ? html`<div className="card-head"><div className="row" style=${{ gap: '12px' }}>${selN.ghost ? html`<span className="glyph is-unknown" style=${{ '--pc': 'var(--warn)' }}><${Icon} name="circle-help" size=${20} /></span>` : html`<${Glyph} d=${selN.d} people=${s.people} />`}
              <div><h2 className="card-title">${selN.name}</h2><div className="card-sub">${selN.ghost ? where(selN.probe) : selN.net.name}${host && selN.id === host.id ? ' · This Mac' : ''}</div></div></div>
              <button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label="Clear selection" onClick=${clear}><${Icon} name="x" size=${15} /></button></div>
            ${selN.ghost ? html`<div className="row" style=${{ gap: '10px', alignItems: 'flex-start' }}><${Icon} name="shield-alert" size=${18} style=${{ color: 'var(--crit-ink)', marginTop: '2px' }} /><div className="ink2">Orbit doesn’t know a device with this address. It knocked on this Mac ${where(selN.probe)}.</div></div>`
              : reachable.length ? html`<${Fragment}><div className="setting-title" style=${{ marginBottom: '8px' }}>Can reach ${plural(reachable.length, 'other device')}</div>
              <div className="reach-list">${reachable.map(n => html`<button key=${n.id} type="button" className="chip chip-good" onClick=${() => setSel(n.id)}>${n.name}</button>`)}</div><//>`
              : html`<div className="row" style=${{ gap: '10px', alignItems: 'flex-start' }}><${Icon} name="shield-check" size=${18} style=${{ color: 'var(--good-ink)', marginTop: '2px' }} /><div className="ink2">Can’t reach any other device. It only gets the internet.</div></div>`}
            ${selN.ghost ? null : html`<p className="muted" style=${{ fontSize: '13px', marginTop: '10px' }}>${selN.net.guest ? 'The wall around this network keeps it away from your main Wi-Fi.' : 'It can also reach your router. Nothing on a guest network can reach it.'}</p>`}
            ${selN.d ? html`<button type="button" className="link-btn" style=${{ marginTop: '10px' }} onClick=${() => ui.openDevice(selN.id)}>Open device<${Icon} name="chevron-right" size=${14} /></button>` : null}`
            : html`<div className="row" style=${{ gap: '12px', alignItems: 'flex-start' }}><span className="net-ic"><${Icon} name="crosshair" size=${17} /></span><div><div className="card-title">Pick a device</div><div className="card-sub">Tap any dot on the map to see what it can reach and what it can’t.</div></div></div>`}
        </section>
      </div></div>
      <div className="s-7"><section className="card">
        <div className="card-head"><div><h2 className="card-title">Contact attempts</h2><div className="card-sub">Seen by the tripwire on this Mac, last 24 hours</div></div><span className=${'chip ' + (active.length ? 'chip-crit' : 'chip-good')}>${active.length ? 'Active now' : 'Stopped'}</span></div>
        ${allProbes.length ? allProbes.map(p => html`<div className="atk-row" key=${p.ip + '-' + p.first}>
          <span className=${'act-ic ' + (p.known ? 'schedules' : 'security')}><${Icon} name=${p.known ? 'link' : p.scan ? 'scan-line' : 'crosshair'} size=${15} /></span>
          <div style=${{ minWidth: 0 }}><div className="act-title">${probeName(p, s)} ${p.known ? 'connected to this Mac' : p.scan ? 'scanned this Mac' : 'knocked on this Mac'}</div>
            <div className="act-detail">${p.known ? 'A known device on your main Wi-Fi. Devices there are allowed to talk to each other, so this is only a note, not an alert.' : probeLine(p)}</div>
            <div className="atk-meta">${p.known ? html`<span className="chip chip-accent"><${Icon} name="check" size=${12} sw=${2.6} />Allowed</span>` : null}${(p.ports || []).slice(0, 6).map(x => html`<span key=${x.port} className=${'chip ' + (p.known ? '' : 'chip-crit')}>${doorText(x)}${x.tries > 1 ? ' · ' + x.tries + ' tries' : ''}</span>`)}
              <span className="chip">${plural(p.tries, 'try', 'tries')}</span><span className="chip">${where(p)}</span>${p.device ? null : html`<span className="chip">${p.ip}</span>`}</div>
            ${p.device && s.devices.some(d => d.id === p.device) ? html`<button type="button" className="link-btn" style=${{ marginTop: '6px' }} onClick=${() => ui.openDevice(p.device)}>Open device<${Icon} name="chevron-right" size=${14} /></button>` : null}</div>
          <span className="act-time tnum">${fmtAgo(p.last, s.now)}</span></div>`)
          : html`<div className="empty">${tw.on ? 'Nothing to show. When something knocks on this Mac, it appears here and on the map.' : 'The tripwire is off, so Orbit isn’t listening for knocks.'}</div>`}
        ${secEvents.length ? html`<div className="eyebrow" style=${{ margin: '16px 0 4px' }}>Recent security events</div>${secEvents.map(e => html`<div className="tl-item" key=${e.id}>
          <span className="tl-time">${fmtClock(e.ts)}</span>
          <span className=${'act-ic ' + actCls(e)}><${Icon} name=${e.icon} size=${15} /></span>
          <div style=${{ minWidth: 0 }}><div className="tl-title">${e.title}</div>${e.detail ? html`<div className="tl-detail">${e.detail}</div>` : null}</div>
        </div>`)}` : null}
      </section></div>
      <div className="s-5"><div className="stack">
        <section className="card">
          <div className="card-head"><div><h2 className="card-title">Tripwire</h2><div className="card-sub">A few quiet doors on this Mac that Orbit watches</div></div>
            <span className=${'chip ' + (tw.on && tw.running ? 'chip-good' : tw.on ? 'chip-warn' : 'chip-muted')}>${tw.on ? (tw.running ? 'Listening on ' + plural((tw.listening || []).length, 'door') : 'Starting') : 'Off'}</span></div>
          <div className="setting"><div className="setting-text"><label className="setting-title" htmlFor="tripwire-switch">Watch for knocks</label>
            <div className="setting-sub">${tw.on ? 'Orbit tells you when a device tries one of these doors.' : 'Turn it on and Orbit tells you when a device tries one of these doors.'}</div></div>
            <${Switch} id="tripwire-switch" on=${!!tw.on} onChange=${toggleTw} label="Watch for knocks on this Mac" /></div>
          ${tw.on && (tw.listening || []).length ? html`<div className="chips" style=${{ marginTop: '10px' }}>${tw.listening.map(d => html`<span key=${d.port} className="chip">${doorText(d)}</span>`)}</div>` : null}
          ${(tw.busy || []).map(d => html`<p key=${d.port} className="muted" style=${{ fontSize: '13px', marginTop: '10px' }}>${d.port === 22 ? 'Remote Login is switched on, so Orbit can’t watch door 22.' : `Something on this Mac already uses door ${d.port} (${d.label}), so Orbit can’t watch it.`}</p>`)}
          ${tw.on && tw.host_ip && port0 ? html`<p className="muted" style=${{ fontSize: '13px', marginTop: '10px' }}><b style=${{ color: 'var(--ink-2)' }}>Test it.</b> From a phone on your Wi-Fi, open <span className="mono">http://${tw.host_ip}:${port0.port}</span> in a browser. It should appear here within a few seconds. Devices you’ve marked as known on your main Wi-Fi are allowed to connect, so test with one that isn’t known yet.</p>` : null}
          <p className="muted" style=${{ fontSize: '13px', marginTop: '10px' }}>It only notices connections to those doors on this Mac. It can’t see half-open scans, pings, attempts on other devices, or anything inside guest networks.</p>
        </section>
      </div></div>
      <div className="s-7"><${RouterSettings} s=${s} /></div>
      <div className="s-5"><section className="card">
        <div className="card-head"><div><h2 className="card-title">What Orbit can and can’t see</h2><div className="card-sub">So you know what this page can promise</div></div></div>
          ${[['yes', 'circle-check', 'Which network each device is on, and each network’s settings: open or password, isolation on or off.'],
            ['yes', 'circle-check', 'Who can reach whom. Worked out from those settings, so it’s as reliable as the router’s own settings.'],
            ['part', 'circle-alert', 'Attempts aimed at this Mac. Orbit runs a small tripwire here that notices connection attempts. It only covers this Mac.'],
            ['no', 'circle-x', 'Traffic between two other devices. The Starlink router doesn’t report it.'],
            ['no', 'circle-x', 'Attempts inside a guest network. Isolation drops them before anyone can see them, which is also why they can’t hurt.'],
            ['no', 'circle-x', 'The router’s firewall log. Starlink’s router refuses to share it.']].map((r, i) => html`<div className="see-row" key=${i}><${Icon} name=${r[1]} size=${17} className=${'see-' + r[0]} /><div className="ink2" style=${{ fontSize: '14px' }}>${r[2]}</div></div>`)}
        </section></div>
    </div>
  </div>`;
}
