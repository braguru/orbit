/* Talks to the Orbit server: one live stream of the whole picture, plus a few requests. */
import { useState, useEffect, useRef, useCallback } from './lib.js';

/* Thrown when this device needs to sign in with the access code (Orbit running with --lan). */
export class LoginNeeded extends Error {}

async function check(r) {
  const data = await r.json().catch(() => ({}));
  if (r.status === 401) throw new LoginNeeded(data.error || 'Sign in');
  if (!r.ok) throw new Error(data.error || r.statusText);
  return data;
}

export async function getJSON(url) {
  return check(await fetch(url, { cache: 'no-store' }));
}

export async function send(method, url, body) {
  return check(await fetch(url, {
    method,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body || {}),
  }));
}

const KEEP_POINTS = 120;  // seconds of whole-home history for the live chart
const KEEP_DEVICE = 60;   // readings per device for its sparkline

/* The live state, refreshed every second over Server-Sent Events. conn: connecting | live | lost | login */
export function useLive() {
  const [s, setS] = useState(null);
  const [conn, setConn] = useState('connecting');
  const [session, setSession] = useState(null);
  const [attempt, setAttempt] = useState(0);
  const points = useRef([]);
  const devHist = useRef({});
  const lastMsg = useRef(0);

  const merge = useCallback(list => {
    const byT = new Map(points.current.map(p => [p.t, p]));
    for (const p of list) byT.set(p.t, p);
    points.current = [...byT.values()].sort((a, b) => a.t - b.t).slice(-KEEP_POINTS);
  }, []);

  const apply = useCallback(next => {
    merge(next.points || []);
    for (const d of next.devices) {
      const h = devHist.current[d.id] || (devHist.current[d.id] = []);
      h.push(d.online ? d.down_mbps + d.up_mbps : null);
      if (h.length > KEEP_DEVICE) h.shift();
    }
    lastMsg.current = Date.now();
    setS(next);
  }, [merge]);

  const refresh = useCallback(() => getJSON('/api/state').then(apply).catch(e => { if (e instanceof LoginNeeded) setConn('login'); }), [apply]);

  useEffect(() => {
    let alive = true, es = null, watch = null;
    getJSON('/api/session').then(sess => {
      if (!alive) return;
      setSession(sess);
      if (sess.required && !sess.signed_in) { setConn('login'); return; }
      getJSON('/api/live').then(merge).catch(() => {});
      refresh();
      lastMsg.current = Date.now();
      es = new EventSource('/api/stream');
      es.onmessage = e => {
        try { apply(JSON.parse(e.data)); setConn('live'); } catch (err) { /* skip a bad message */ }
      };
      watch = setInterval(() => {
        if (Date.now() - lastMsg.current < 6000) return;
        // Quiet for 6 seconds: the server is down, or this device was signed out.
        getJSON('/api/session').then(se => setConn(se.required && !se.signed_in ? 'login' : 'lost'), () => setConn('lost'));
      }, 2000);
    }, () => {
      if (!alive) return;
      setConn('lost');
      setTimeout(() => { if (alive) setAttempt(a => a + 1); }, 3000);  // the server isn't up yet: keep trying
    });
    return () => { alive = false; if (es) es.close(); if (watch) clearInterval(watch); };
  }, [attempt, apply, merge, refresh]);

  const signedIn = useCallback(() => { setConn('connecting'); setAttempt(a => a + 1); }, []);
  return { s, conn, session, points: points.current, devHist: devHist.current, refresh, signedIn };
}

/* Fetch JSON now and again every `every` ms while the component is shown. */
export function usePoll(url, every = 60000) {
  const [data, setData] = useState(null);
  const [error, setError] = useState(null);
  const urlRef = useRef(url);
  urlRef.current = url;
  useEffect(() => {
    let alive = true;
    const load = () => getJSON(url).then(d => { if (alive && urlRef.current === url) { setData(d); setError(null); } }, e => { if (alive) setError(e.message); });
    setData(null);
    load();
    const t = setInterval(load, every);
    return () => { alive = false; clearInterval(t); };
  }, [url, every]);
  return { data, error };
}
