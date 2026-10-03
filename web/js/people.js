/* People: group devices by who uses them, and see each person's usage. */
import {
  html, useState, sum, fmtMbps, fmtBytes, fmtLimit, plural, Icon, Glyph, StatusChip, AssignMenu, Menu, Modal,
  AllowanceMeter, AllowanceEditor, personOf, pcol, initials, isActive, PERIOD,
} from './lib.js';

function PersonCard({ p, s, api, ui }) {
  const devs = s.devices.filter(d => d.owner === p.id);
  const conn = devs.filter(d => d.online);
  const live = sum(conn, d => d.down_mbps);
  const today = sum(devs, d => d.today_down + d.today_up);
  const chip = conn.some(isActive) ? html`<span className="chip chip-good"><span className="dot" />Active</span>` : html`<span className="chip chip-muted"><span className="dot" />Quiet</span>`;
  return html`<section className="card person" style=${{ '--pc': pcol(p) }}>
    <div className="person-top"><span className="avatar" aria-hidden="true">${initials(p.name)}</span>
      <div className="grow"><h2 className="person-name">${p.name}</h2><div className="card-sub">${plural(devs.length, 'device')} · ${conn.length} connected</div></div>
      ${chip}
      <${Menu} align="right" label=${'Options for ' + p.name} trigger=${({ toggle, open }) => html`<button type="button" className="btn btn-sm btn-icon btn-ghost" aria-label=${'Options for ' + p.name} aria-haspopup="menu" aria-expanded=${open ? 'true' : 'false'} onClick=${toggle}><${Icon} name="ellipsis" size=${16} /></button>`}>
        <button type="button" role="menuitem" onClick=${() => ui.openModal({ type: 'person', person: p })}><${Icon} name="pencil" size=${16} />Rename</button>
        <button type="button" role="menuitem" onClick=${() => ui.openModal({ type: 'allowance', person: p })}><${Icon} name="bell-ring" size=${16} />${p.allowance ? 'Change allowance' : 'Set an allowance'}</button>
        <button type="button" role="menuitem" onClick=${() => ui.openModal({ type: 'confirm', title: `Remove ${p.name}?`, body: `Their ${plural(devs.length, 'device')} stay on your network with no owner. You can give them a new owner any time.`, label: 'Remove', danger: true, fn: () => api.removePerson(p.id) })}><${Icon} name="trash-2" size=${16} />Remove</button>
      <//>
    </div>
    <div className="person-stats"><div><small>Using now</small><b className="tnum">${fmtMbps(live)}<span className="stat-unit">Mbps</span></b></div><div><small>Today</small><b>${fmtBytes(today)}</b></div></div>
    ${p.allowance ? html`<button type="button" className="person-allow link-plain" onClick=${() => ui.openModal({ type: 'allowance', person: p })} aria-label=${`Allowance: ${fmtLimit(p.allowance.bytes)} ${PERIOD[p.allowance.period].per}. Change it`}>
      <div className="allow-title">Allowance: ${fmtLimit(p.allowance.bytes)} ${PERIOD[p.allowance.period].per}</div><${AllowanceMeter} a=${p.allowance} /></button>` : null}
    <div>${devs.map(d => html`<button key=${d.id} type="button" className="mini-dev" onClick=${() => ui.openDevice(d.id)}><${Glyph} d=${d} people=${s.people} size="sm" /><span className="grow">${d.name}</span><${StatusChip} d=${d} /></button>`)}
      ${devs.length === 0 ? html`<div className="muted" style=${{ fontSize: '14px', padding: '6px 0' }}>No devices yet. Open a device and choose ${p.name} as its owner.</div>` : null}</div>
  </section>`;
}

export function PeopleView({ s, api, ui }) {
  const unowned = s.devices.filter(d => !d.owner && !d.hidden);
  return html`<div className="view">
    <div className="page-head"><div><h1 className="page-title">People</h1><p className="page-sub">Group devices by who uses them, then see how much each person uses. Names and owners are kept by Orbit on this computer.</p></div>
      <button type="button" className="btn" onClick=${() => ui.openModal({ type: 'person' })}><${Icon} name="user-plus" size=${16} />Add a person</button></div>
    <div className="people">
      ${unowned.length ? html`<section className="card person">
        <div className="person-top"><span className="avatar" style=${{ '--pc': 'var(--p-none)' }} aria-hidden="true">?</span><div className="grow"><h2 className="person-name">No owner yet</h2><div className="card-sub">Tell Orbit whose ${unowned.length === 1 ? 'this is' : 'these are'}</div></div></div>
        <div>${unowned.map(d => html`<div key=${d.id} className="mini-dev" style=${{ cursor: 'default' }}><${Glyph} d=${d} people=${s.people} size="sm" />
          <button type="button" className="grow link-plain" onClick=${() => ui.openDevice(d.id)}>${d.name}${d.is_new ? html` <span className="new-tag">New</span>` : null}</button>
          <${AssignMenu} people=${s.people} onPick=${pid => api.assign(d.id, pid)} label="Assign" btnClass="btn btn-sm" align="right" /></div>`)}</div>
      </section>` : null}
      ${s.people.map(p => html`<${PersonCard} key=${p.id} p=${p} s=${s} api=${api} ui=${ui} />`)}
      <button type="button" className="add-card" onClick=${() => ui.openModal({ type: 'person' })}><${Icon} name="user-plus" size=${22} />Add a person<span className="muted" style=${{ fontWeight: 500, fontSize: '13px' }}>Give someone their own devices and usage</span></button>
    </div>
  </div>`;
}

/* Add a person, or rename one (when `person` is given). */
export function PersonModal({ s, api, ui, person }) {
  const [name, setName] = useState(person ? person.name : '');
  const [sel, setSel] = useState({});
  const cand = s.devices.filter(d => !d.owner);
  const save = e => {
    e.preventDefault();
    const v = name.trim();
    if (!v) return;
    if (person) api.renamePerson(person.id, v);
    else api.addPerson(v, Object.keys(sel).filter(k => sel[k]));
    ui.closeModal();
  };
  return html`<${Modal} onClose=${ui.closeModal} title=${person ? 'Rename ' + person.name : 'Add a person'}>
    <form onSubmit=${save} className="stack" style=${{ gap: '14px' }}>
      <div className="field"><label htmlFor="person-name">Name</label><input id="person-name" data-autofocus="true" className="input" value=${name} maxLength=${24} onChange=${e => setName(e.target.value)} placeholder="For example, Grandma" /></div>
      ${!person && cand.length ? html`<div className="field"><label>Their devices <span className="muted" style=${{ fontWeight: 500 }}>(optional)</span></label>
        <div style=${{ maxHeight: '260px', overflowY: 'auto', border: '1px solid var(--line)', borderRadius: '12px', padding: '4px 8px' }}>
          ${cand.map(d => html`<label key=${d.id} className="mini-dev" style=${{ cursor: 'pointer' }}>
            <input type="checkbox" id=${'pick-' + d.id} checked=${!!sel[d.id]} onChange=${e => setSel(m => ({ ...m, [d.id]: e.target.checked }))} />
            <${Glyph} d=${d} people=${s.people} size="sm" /><span className="grow">${d.name}</span></label>`)}
        </div></div>` : null}
      <div className="row" style=${{ justifyContent: 'flex-end' }}><button type="button" className="btn btn-ghost" onClick=${ui.closeModal}>Cancel</button><button type="submit" className="btn btn-primary" disabled=${!name.trim()}>${person ? 'Save' : 'Add person'}</button></div>
    </form>
  <//>`;
}

/* A data allowance for everything a person owns. */
export function AllowanceModal({ s, api, ui, person }) {
  const p = s.people.find(x => x.id === person.id) || person;
  return html`<${Modal} onClose=${ui.closeModal} title=${p.allowance ? `${p.name}’s allowance` : `An allowance for ${p.name}`}>
    <p className="ink2">It counts all of ${p.name}’s devices together. Orbit tells you when it’s nearly used up, and when it’s used up.</p>
    ${p.allowance ? html`<${AllowanceMeter} a=${p.allowance} />` : null}
    <${AllowanceEditor} a=${p.allowance} onSave=${a => { api.setPersonAllowance(p.id, a); ui.closeModal(); }} onCancel=${ui.closeModal} />
    <p className="muted fine">Orbit can’t cut anyone off, because your router only takes changes from the Starlink app. To pause their devices, use the app.</p>
  <//>`;
}
