/* Roadwise for iPhone and the web.
 * Same free services as the Android app: OpenFreeMap tiles, Esri satellite imagery,
 * Valhalla routing (FOSSGIS), Photon search (Komoot) and the optional Roadwise report/live server. */
(() => {
'use strict';

const VALHALLA = 'https://valhalla1.openstreetmap.de';
const PHOTON = 'https://photon.komoot.io';
const STYLES = { day: 'https://tiles.openfreemap.org/styles/liberty', night: 'https://tiles.openfreemap.org/styles/dark' };
const SAT_TILES = 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
const APK_URL = 'https://github.com/JDavis008/Roadwise/releases/latest/download/Roadwise.apk';
const REPO_URL = 'https://github.com/JDavis008/Roadwise';

// ------------------------------------------------------------------ helpers
const $ = (s, el = document) => el.querySelector(s);
function h(tag, attrs = {}, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || v === false) continue;
    if (k === 'class') e.className = v;
    else if (k.startsWith('on') && typeof v === 'function') e.addEventListener(k.slice(2), v);
    else if (k === 'html') e.innerHTML = v;
    else e.setAttribute(k, v === true ? '' : v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) e.append(c.nodeType ? c : document.createTextNode(String(c)));
  return e;
}
const store = {
  get(k, d) { try { const v = localStorage.getItem('rw.' + k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem('rw.' + k, JSON.stringify(v)); } catch { /* private mode */ } },
};
const settings = Object.assign({
  imperial: !/^(en-GB|fr|de|es-ES|it|nl|sv|da|nb|fi|pl|pt-PT)/.test(navigator.language || 'en-US') || /US$/.test(navigator.language || ''),
  voice: true, speedAlert: true, tolerance: 5, reportAlerts: true, cameraAlerts: true,
  avoidTolls: false, avoidHighways: false, avoidFerries: false,
  theme: 'auto', satellite: false, nickname: '', server: '', mode: 'auto',
}, store.get('settings', {}));
const saveSettings = () => store.set('settings', settings);
const clientId = store.get('clientId') || (() => {
  const id = (crypto.randomUUID ? crypto.randomUUID() : Date.now().toString(36) + Math.random().toString(36).slice(2));
  store.set('clientId', id); return id;
})();
let toastTimer;
function toast(msg, ms = 2600) {
  const t = $('#toast'); t.textContent = msg; t.classList.remove('hidden');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.add('hidden'), ms);
}
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const serverUrl = () => settings.server.trim().replace(/\/+$/, '');

// ------------------------------------------------------------------ geo  (points are [lon, lat])
const R = 6371008.8, RAD = Math.PI / 180;
function dist(a, b) {
  const dLat = (b[1] - a[1]) * RAD, dLon = (b[0] - a[0]) * RAD;
  const s = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.sin(dLon / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}
function bearing(a, b) {
  const y = Math.sin((b[0] - a[0]) * RAD) * Math.cos(b[1] * RAD);
  const x = Math.cos(a[1] * RAD) * Math.sin(b[1] * RAD) - Math.sin(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.cos((b[0] - a[0]) * RAD);
  return (Math.atan2(y, x) / RAD + 360) % 360;
}
function project(p, a, b) {
  const k = Math.cos(a[1] * RAD) * R * RAD, m = R * RAD;
  const bx = (b[0] - a[0]) * k, by = (b[1] - a[1]) * m, px = (p[0] - a[0]) * k, py = (p[1] - a[1]) * m;
  const L = bx * bx + by * by;
  const t = L > 0 ? Math.max(0, Math.min(1, (px * bx + py * by) / L)) : 0;
  return { t, d: Math.hypot(px - t * bx, py - t * by) };
}
const lerp = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
const angleDiff = (a, b) => { const d = Math.abs(a - b) % 360; return d > 180 ? 360 - d : d; };
function decodePolyline(s, prec = 6) {
  const f = 10 ** prec, out = []; let i = 0, lat = 0, lon = 0;
  while (i < s.length) {
    for (const which of [0, 1]) {
      let shift = 0, result = 0, b;
      do { b = s.charCodeAt(i++) - 63; result |= (b & 0x1f) << shift; shift += 5; } while (b >= 0x20);
      const d = (result & 1) ? ~(result >> 1) : (result >> 1);
      if (which === 0) lat += d; else lon += d;
    }
    out.push([lon / f, lat / f]);
  }
  return out;
}
function encodePolyline(pts, prec = 6) {
  const f = 10 ** prec; let out = '', pLat = 0, pLon = 0;
  const enc = v => { let x = v < 0 ? ~(v << 1) : (v << 1); while (x >= 0x20) { out += String.fromCharCode((0x20 | (x & 0x1f)) + 63); x >>= 5; } out += String.fromCharCode(x + 63); };
  for (const p of pts) { const la = Math.round(p[1] * f), lo = Math.round(p[0] * f); enc(la - pLat); enc(lo - pLon); pLat = la; pLon = lo; }
  return out;
}
function cumulative(pts) { const c = [0]; for (let i = 1; i < pts.length; i++) c.push(c[i - 1] + dist(pts[i - 1], pts[i])); return c; }
function bboxAround(c, m) { const dLat = m / 111320, dLon = m / (111320 * Math.cos(c[1] * RAD)); return [c[0] - dLon, c[1] - dLat, c[0] + dLon, c[1] + dLat]; }

// Rough sun position: night style between sunset and sunrise where you are.
function sunUp(lon, lat, date = new Date()) {
  const d = (date.getTime() - Date.UTC(2000, 0, 1, 12)) / 864e5;
  const g = (357.529 + 0.98560028 * d) * RAD, q = 280.459 + 0.98564736 * d;
  const L = (q + 1.915 * Math.sin(g) + 0.020 * Math.sin(2 * g)) * RAD, e = (23.439 - 0.00000036 * d) * RAD;
  const dec = Math.asin(Math.sin(e) * Math.sin(L)), ra = Math.atan2(Math.cos(e) * Math.sin(L), Math.cos(L));
  const gmst = ((18.697374558 + 24.06570982441908 * d) % 24 + 24) % 24;
  const ha = (gmst * 15 + lon) * RAD - ra;
  const el = Math.asin(Math.sin(lat * RAD) * Math.sin(dec) + Math.cos(lat * RAD) * Math.cos(dec) * Math.cos(ha));
  return el / RAD > -0.833;
}

// ------------------------------------------------------------------ units
const U = {
  dist(m) {
    if (settings.imperial) {
      const ft = m * 3.28084;
      if (ft < 1000) return `${Math.max(10, Math.round(ft / 10) * 10)} ft`;
      const mi = m / 1609.344; return `${mi < 10 ? mi.toFixed(1) : Math.round(mi)} mi`;
    }
    if (m < 1000) return `${Math.max(10, Math.round(m / 10) * 10)} m`;
    const km = m / 1000; return `${km < 10 ? km.toFixed(1) : Math.round(km)} km`;
  },
  spoken(m) {
    if (settings.imperial) {
      const ft = m * 3.28084;
      if (ft < 900) return `${Math.max(50, ft < 300 ? Math.round(ft / 50) * 50 : Math.round(ft / 100) * 100)} feet`;
      const mi = m / 1609.344;
      if (mi < 0.35) return 'a quarter mile';
      if (mi < 0.6) return 'half a mile';
      if (mi < 0.85) return 'three quarters of a mile';
      if (mi < 1.15) return '1 mile';
      return `${mi < 10 ? Math.round(mi * 2) / 2 : Math.round(mi)} miles`;
    }
    if (m < 950) return `${Math.max(50, m < 300 ? Math.round(m / 50) * 50 : Math.round(m / 100) * 100)} meters`;
    const km = m / 1000, v = km < 10 ? Math.round(km * 2) / 2 : Math.round(km);
    return `${v} kilometer${v === 1 ? '' : 's'}`;
  },
  dur(s) { const m = Math.round(s / 60); if (m < 60) return `${Math.max(1, m)} min`; const hh = Math.floor(m / 60), mm = m % 60; return mm ? `${hh} hr ${mm} min` : `${hh} hr`; },
  speed: mps => Math.round(settings.imperial ? mps * 2.23694 : mps * 3.6),
  limit: kmh => settings.imperial ? Math.round(kmh / 1.609344 / 5) * 5 : Math.round(kmh),
  unit: () => settings.imperial ? 'mph' : 'km/h',
  clock: ms => new Date(ms).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }),
};

// ------------------------------------------------------------------ network
async function getJSON(url, opt = {}) {
  const { timeout = 12000, ...rest } = opt;
  const c = new AbortController(); const t = setTimeout(() => c.abort(), timeout);
  try {
    const r = await fetch(url, { ...rest, signal: c.signal });
    if (!r.ok) {
      let msg = `HTTP ${r.status}`;
      try { const j = await r.json(); msg = j.error || j.message || msg; } catch { /* not json */ }
      throw new Error(msg);
    }
    return await r.json();
  } catch (e) {
    if (e.name === 'AbortError') throw new Error('timed out');
    throw e;
  } finally { clearTimeout(t); }
}
// text/plain keeps these "simple" CORS requests (no preflight); the server parses the JSON body either way.
const postJSON = (url, body, opt = {}) => getJSON(url, { method: 'POST', headers: { 'Content-Type': 'text/plain' }, body: JSON.stringify(body), ...opt });

// ------------------------------------------------------------------ search (Photon)
const CATEGORIES = [
  { label: 'Gas', emoji: '⛽', tags: ['amenity:fuel'] },
  { label: 'Food', emoji: '🍔', tags: ['amenity:restaurant', 'amenity:fast_food'] },
  { label: 'Coffee', emoji: '☕', tags: ['amenity:cafe'] },
  { label: 'Parking', emoji: '🅿️', tags: ['amenity:parking'] },
  { label: 'EV charging', emoji: '🔌', tags: ['amenity:charging_station'] },
  { label: 'Groceries', emoji: '🛒', tags: ['shop:supermarket', 'shop:grocery', 'shop:convenience'] },
  { label: 'Hotels', emoji: '🛏️', tags: ['tourism:hotel', 'tourism:motel'] },
  { label: 'Hospitals', emoji: '🏥', tags: ['amenity:hospital'] },
];
function photonPlace(f) {
  const p = f.properties || {}, c = f.geometry.coordinates;
  const street = [p.housenumber, p.street].filter(Boolean).join(' ');
  const city = p.city || p.locality || p.county || '';
  const address = [...new Set([street, city, p.state, p.country === 'United States' ? '' : p.country].filter(Boolean))].join(', ');
  const name = p.name || street || city || 'Place';
  const cat = (p.osm_value && !['yes', 'no'].includes(p.osm_value) ? p.osm_value : p.osm_key || '').replace(/_/g, ' ');
  return { name, address, lon: c[0], lat: c[1], category: cat };
}
function parseCoords(q) {
  const m = q.match(/^\s*(-?\d{1,2}(?:\.\d+)?)\s*[, ]\s*(-?\d{1,3}(?:\.\d+)?)\s*$/);
  if (!m) return null;
  const lat = +m[1], lon = +m[2];
  return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 ? { name: `${lat.toFixed(5)}, ${lon.toFixed(5)}`, address: 'Coordinates', lat, lon, category: 'coords' } : null;
}
const biasPoint = () => here ? here.pos : (map ? map.getCenter().toArray() : null);
async function searchPlaces(q) {
  const c = parseCoords(q); if (c) return [c];
  const near = biasPoint();
  let url = `${PHOTON}/api/?q=${encodeURIComponent(q)}&limit=15&lang=en`;
  if (near) url += `&lat=${near[1].toFixed(5)}&lon=${near[0].toFixed(5)}&location_bias_scale=0.3`;
  const j = await getJSON(url, { timeout: 9000 });
  const seen = new Set();
  return j.features.map(photonPlace).filter(p => { const k = `${p.name.toLowerCase()}|${p.lat.toFixed(3)}|${p.lon.toFixed(3)}`; if (seen.has(k)) return false; seen.add(k); return true; });
}
async function nearby(cat) {
  const near = biasPoint();
  const url = r => `${PHOTON}/reverse?lat=${near[1]}&lon=${near[0]}&limit=30&radius=${r}&lang=en` + cat.tags.map(t => '&osm_tag=' + encodeURIComponent(t)).join('');
  const parse = j => j.features.map(f => ({ ...photonPlace(f), category: cat.label, emoji: cat.emoji })).filter(p => p.name && p.name !== 'Place');
  let res = parse(await getJSON(url(10), { timeout: 9000 }));
  if (res.length < 5) res = res.concat(parse(await getJSON(url(40), { timeout: 9000 }).catch(() => ({ features: [] }))));
  const seen = new Set();
  return res.filter(p => { const k = p.name + p.lat.toFixed(4); if (seen.has(k)) return false; seen.add(k); return true; })
    .sort((a, b) => dist(near, [a.lon, a.lat]) - dist(near, [b.lon, b.lat])).slice(0, 40);
}
async function reverse(lngLat) {
  try {
    const j = await getJSON(`${PHOTON}/reverse?lat=${lngLat[1]}&lon=${lngLat[0]}&lang=en&limit=1`, { timeout: 6000 });
    if (j.features.length) { const p = photonPlace(j.features[0]); return { ...p, lon: lngLat[0], lat: lngLat[1] }; }
  } catch { /* offline */ }
  return { name: 'Dropped pin', address: `${lngLat[1].toFixed(5)}, ${lngLat[0].toFixed(5)}`, lon: lngLat[0], lat: lngLat[1], category: 'pin' };
}

// ------------------------------------------------------------------ routing (Valhalla)
const MODES = { drive: { label: 'Drive', icon: '🚗', costing: 'auto' }, bike: { label: 'Bike', icon: '🚲', costing: 'bicycle' }, walk: { label: 'Walk', icon: '🚶', costing: 'pedestrian' } };
const TURN = {
  1: 'depart', 2: 'depart', 3: 'depart', 4: 'arrive', 5: 'arrive', 6: 'arrive', 7: 'straight', 8: 'straight', 22: 'straight', 17: 'straight',
  9: 'slight-right', 10: 'right', 11: 'sharp-right', 12: 'uturn', 13: 'uturn', 14: 'sharp-left', 15: 'left', 16: 'slight-left',
  18: 'ramp-right', 19: 'ramp-left', 20: 'exit-right', 21: 'exit-left', 23: 'keep-right', 24: 'keep-left',
  25: 'merge', 37: 'merge', 38: 'merge', 26: 'roundabout', 27: 'roundabout', 28: 'ferry', 29: 'ferry',
};
function routeRequest(from, to, mode, heading, avoid, alternates) {
  const costing = MODES[mode].costing;
  const opts = {};
  if (costing === 'auto') opts.auto = { use_tolls: settings.avoidTolls ? 0 : 0.5, use_highways: settings.avoidHighways ? 0 : 1, use_ferry: settings.avoidFerries ? 0 : 0.5 };
  if (costing === 'bicycle') opts.bicycle = { bicycle_type: 'hybrid' };
  const start = { lat: from[1], lon: from[0] };
  if (heading != null) { start.heading = Math.round(heading); start.heading_tolerance = 60; }
  const req = { locations: [start, { lat: to[1], lon: to[0] }], costing, costing_options: opts, units: 'kilometers', language: 'en-US', id: 'roadwise' };
  if (avoid.length) req.exclude_locations = avoid.map(p => ({ lat: p[1], lon: p[0] }));
  if (alternates) req.alternates = 2;
  return req;
}
async function valhalla(endpoint, req) {
  // GET with ?json= is a simple CORS request (no preflight), which the public server allows.
  return getJSON(`${VALHALLA}/${endpoint}?json=${encodeURIComponent(JSON.stringify(req))}`, { timeout: 20000 });
}
function parseTrip(trip, mode, dest) {
  const points = [], maneuvers = [], times = [];
  trip.legs.forEach((leg, l) => {
    const offset = points.length ? points.length - 1 : 0;
    const shape = decodePolyline(leg.shape, 6);
    points.push(...(points.length ? shape.slice(1) : shape));
    for (const m of leg.maneuvers) {
      const begin = (m.begin_shape_index || 0) + offset, end = (m.end_shape_index || 0) + offset;
      times.push([begin, end, m.time || 0]);
      if (l > 0 && m.type >= 1 && m.type <= 3) continue;
      if (l < trip.legs.length - 1 && m.type >= 4 && m.type <= 6) continue;
      const streets = m.begin_street_names || m.street_names;
      const text = (m.verbal_transition_alert_instruction || m.instruction || '').replace(/\.$/, '');
      const spoken = (m.verbal_transition_alert_instruction || m.verbal_pre_transition_instruction || text).replace(/\.$/, '');
      maneuvers.push({ turn: TURN[m.type] || 'straight', text, spoken, street: streets ? streets.join(' / ') : null, i: Math.min(begin, points.length - 1), exit: m.roundabout_exit_count || 0 });
    }
  });
  const seg = new Array(points.length).fill(0);
  for (const [b, e, t] of times) {
    if (e <= b) continue;
    let len = 0; for (let i = b; i < Math.min(e, points.length - 1); i++) len += dist(points[i], points[i + 1]);
    if (len <= 0) continue;
    for (let i = b; i < Math.min(e, points.length - 1); i++) seg[i] = t * dist(points[i], points[i + 1]) / len;
  }
  const cumTime = [0]; for (let i = 1; i < points.length; i++) cumTime.push(cumTime[i - 1] + seg[i - 1]);
  const cumDist = cumulative(points);
  const s = trip.summary || {};
  // Label with the road you spend the longest on.
  let best = '', bestLen = -1;
  maneuvers.forEach((m, i) => {
    if (!m.street) return;
    const end = i + 1 < maneuvers.length ? maneuvers[i + 1].i : points.length - 1;
    const len = cumDist[end] - cumDist[m.i];
    if (len > bestLen) { bestLen = len; best = m.street.split(' / ')[0]; }
  });
  return {
    points, maneuvers, cumTime, cumDist, distance: cumDist[cumDist.length - 1], duration: s.time || cumTime[cumTime.length - 1],
    limits: new Array(points.length).fill(0), label: best ? `via ${best}` : 'Fastest route',
    tolls: !!s.has_toll, highways: !!s.has_highway, ferry: !!s.has_ferry, mode, dest,
  };
}
function overlap(a, b) {
  const step = Math.max(1, Math.floor(a.points.length / 100)), bs = b.points.filter((_, i) => i % Math.max(1, Math.floor(b.points.length / 500)) === 0);
  let n = 0, near = 0;
  for (let i = 0; i < a.points.length; i += step) {
    n++; const p = a.points[i];
    if (bs.some(q => Math.abs(q[1] - p[1]) < 0.002 && Math.abs(q[0] - p[0]) < 0.0026 && dist(p, q) < 120)) near++;
  }
  return n ? near / n : 0;
}
async function getRoutes(from, to, mode, heading = null, alternates = true) {
  const avoid = mode === 'drive' ? closuresNear(from, to) : [];
  let j;
  try { j = await valhalla('route', routeRequest(from, to, mode, heading, avoid, alternates)); }
  catch (e) {
    // A closure that can't be matched to a road makes Valhalla reject the whole request.
    if (avoid.length) j = await valhalla('route', routeRequest(from, to, mode, heading, [], alternates)); else throw e;
  }
  const out = [parseTrip(j.trip, mode, to)];
  for (const alt of j.alternates || []) { try { const r = parseTrip(alt.trip, mode, to); if (out.every(o => overlap(r, o) < 0.85)) out.push(r); } catch { /* skip */ } }
  return out;
}
async function fetchSpeedLimits(route) {
  if (route.mode !== 'drive' || route.points.length < 2 || route.points.length > 15000) return;
  try {
    const j = await getJSON(`${VALHALLA}/trace_attributes`, {
      method: 'POST', headers: { 'Content-Type': 'text/plain' }, timeout: 20000,
      body: JSON.stringify({ encoded_polyline: encodePolyline(route.points, 6), shape_match: 'edge_walk', costing: 'auto', filters: { attributes: ['edge.speed_limit', 'edge.begin_shape_index', 'edge.end_shape_index'], action: 'include' } }),
    });
    for (const e of j.edges || []) {
      const lim = e.speed_limit || 0; if (lim <= 0 || lim > 200) continue;
      for (let k = e.begin_shape_index; k < Math.min(e.end_shape_index, route.limits.length); k++) if (k >= 0) route.limits[k] = lim;
    }
  } catch { /* speed limits are a bonus */ }
}

// ------------------------------------------------------------------ reports
const RTYPES = {
  police: { label: 'Police', emoji: '👮', color: '#1e88e5', ttl: 120, spoken: 'Police reported ahead' },
  accident: { label: 'Crash', emoji: '💥', color: '#e53935', ttl: 180, spoken: 'Crash reported ahead' },
  hazard: { label: 'Hazard', emoji: '⚠️', color: '#ffa000', ttl: 240, spoken: 'Hazard on the road ahead' },
  jam: { label: 'Traffic', emoji: '🚗', color: '#d81b60', ttl: 60, spoken: 'Heavy traffic reported ahead' },
  closure: { label: 'Closure', emoji: '⛔', color: '#6d4c41', ttl: 1440, spoken: 'Road closure reported ahead' },
  camera: { label: 'Speed trap', emoji: '📸', color: '#8e24aa', ttl: 240, spoken: 'Speed trap reported ahead' },
  construction: { label: 'Roadwork', emoji: '🚧', color: '#f4511e', ttl: 10080, spoken: 'Roadwork reported ahead' },
  weather: { label: 'Weather', emoji: '🌧️', color: '#546e7a', ttl: 180, spoken: 'Bad weather reported ahead' },
};
let localReports = store.get('reports', []);   // made on this device (kept even with no server)
let serverReports = [];
const saveLocalReports = () => { const now = Date.now(); localReports = localReports.filter(r => r.expires > now); store.set('reports', localReports); };
function allReports() {
  const now = Date.now(), ids = new Set(serverReports.map(r => r.id));
  return serverReports.concat(localReports.filter(r => !r.serverId || !ids.has(r.serverId))).filter(r => r.expires > now && !(r.down >= 2 && r.down > r.up));
}
function closuresNear(a, b) {
  const minLon = Math.min(a[0], b[0]) - 0.05, maxLon = Math.max(a[0], b[0]) + 0.05, minLat = Math.min(a[1], b[1]) - 0.05, maxLat = Math.max(a[1], b[1]) + 0.05;
  return allReports().filter(r => r.type === 'closure' && r.lon > minLon && r.lon < maxLon && r.lat > minLat && r.lat < maxLat).slice(0, 20).map(r => [r.lon, r.lat]);
}
let syncing = false, lastSyncCenter = null;
async function syncReports(force = false) {
  const srv = serverUrl(); if (!srv || syncing || !map) return;
  const c = here ? here.pos : map.getCenter().toArray();
  if (!force && lastSyncCenter && dist(lastSyncCenter, c) < 20000 && Date.now() - lastSyncCenter.t < 60000) return;
  syncing = true;
  try {
    for (const p of localReports.filter(r => !r.serverId)) {
      const res = await postJSON(`${srv}/api/reports`, { type: p.type, lat: p.lat, lon: p.lon, heading: p.heading, note: p.note, by: settings.nickname, clientId });
      p.serverId = res.id; p.expires = res.expires || p.expires;
    }
    saveLocalReports();
    const bb = bboxAround(c, 80000);
    const j = await getJSON(`${srv}/api/reports?bbox=${bb.join(',')}`, { timeout: 10000 });
    serverReports = j.reports.map(r => ({ ...r, mine: r.clientId === clientId }));
    lastSyncCenter = Object.assign(c.slice(), { t: Date.now() });
  } catch (e) { console.warn('report sync', e); }
  finally { syncing = false; drawReports(); if (nav) nav.rebuildHazards(); }
}
async function addReport(type) {
  const pos = here ? here.pos : map.getCenter().toArray();
  const t = RTYPES[type]; const now = Date.now();
  const r = { id: 'l-' + now, type, lon: pos[0], lat: pos[1], heading: here?.heading || 0, note: '', created: now, expires: now + t.ttl * 60000, up: 0, down: 0, by: settings.nickname || 'Me', mine: true };
  localReports.push(r); saveLocalReports(); drawReports();
  toast(`${t.emoji} ${t.label} reported${serverUrl() ? '' : ' on this phone'} — thanks!`);
  if (serverUrl()) syncReports(true);
  if (nav) nav.rebuildHazards();
}
async function voteReport(r, up) {
  if (!up && (r.mine || !r.serverId && r.id.startsWith('l-'))) { localReports = localReports.filter(x => x.id !== r.id && x.serverId !== r.id); }
  const sid = r.serverId || (r.id.startsWith('l-') ? null : r.id);
  if (up) r.up++; else r.down++;
  saveLocalReports(); drawReports();
  if (sid && serverUrl()) { try { await postJSON(`${serverUrl()}/api/reports/${sid}/vote`, { vote: up ? 'up' : 'down', clientId }); } catch { /* best effort */ } syncReports(true); }
  toast(up ? 'Thanks for confirming' : 'Thanks — marked as gone');
}

// ------------------------------------------------------------------ voice + chime
const voice = {
  ctx: null,
  unlock() {
    // iPhone only allows speech and sound after a tap, so this runs from the Start button.
    try { if (!this.ctx) this.ctx = new (window.AudioContext || window.webkitAudioContext)(); this.ctx.resume(); } catch { /* no audio */ }
    try { const u = new SpeechSynthesisUtterance(' '); u.volume = 0; speechSynthesis.speak(u); } catch { /* no speech */ }
  },
  speak(text, interrupt = false) {
    if (!settings.voice || !('speechSynthesis' in window)) return;
    if (interrupt) speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text); u.lang = 'en-US'; u.rate = 1.02;
    speechSynthesis.speak(u);
  },
  stop() { try { speechSynthesis.cancel(); } catch { /* none */ } },
  chime() {
    if (!this.ctx) return;
    const t0 = this.ctx.currentTime;
    for (const [f, dt] of [[880, 0], [1175, 0.16]]) {
      const o = this.ctx.createOscillator(), g = this.ctx.createGain();
      o.frequency.value = f; o.type = 'sine'; o.connect(g); g.connect(this.ctx.destination);
      g.gain.setValueAtTime(0.0001, t0 + dt); g.gain.exponentialRampToValueAtTime(0.35, t0 + dt + 0.02); g.gain.exponentialRampToValueAtTime(0.0001, t0 + dt + 0.3);
      o.start(t0 + dt); o.stop(t0 + dt + 0.32);
    }
  },
};
let wakeLock = null;
async function keepAwake(on) {
  try {
    if (on && 'wakeLock' in navigator && !wakeLock) { wakeLock = await navigator.wakeLock.request('screen'); wakeLock.addEventListener('release', () => { wakeLock = null; }); }
    if (!on && wakeLock) { await wakeLock.release(); wakeLock = null; }
  } catch { /* not allowed */ }
}
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && nav) keepAwake(true); });

// ------------------------------------------------------------------ map
let map, puck, here = null, follow = false, styleKey = '', destMarker = null, compassHeading = null;
const reportMarkers = new Map();

function wantNight() {
  if (settings.theme === 'day') return false;
  if (settings.theme === 'night') return true;
  const c = here ? here.pos : (map ? map.getCenter().toArray() : [-98, 39]);
  return !sunUp(c[0], c[1]);
}
function currentStyleKey() { return (settings.satellite || wantNight()) ? 'night' : 'day'; }
function applyTheme() {
  document.body.classList.toggle('night', wantNight() || settings.satellite);
  const key = currentStyleKey();
  // diff:false forces a full reload so 'style.load' fires and our route/satellite layers get re-added.
  if (map && key !== styleKey) { styleKey = key; map.setStyle(STYLES[key], { diff: false }); }
  else if (map && map.isStyleLoaded()) addOverlays();
}

function initMap() {
  const view = store.get('view', { c: [-98.5, 39.5], z: 3.6 });
  styleKey = currentStyleKey();
  document.body.classList.toggle('night', wantNight() || settings.satellite);
  // A link like …/Roadwise/#15/40.0017/-83.0197 opens the map at that spot.
  const m = location.hash.match(/^#(\d+(?:\.\d+)?)\/(-?\d+(?:\.\d+)?)\/(-?\d+(?:\.\d+)?)/);
  if (m) { view.z = +m[1]; view.c = [+m[3], +m[2]]; store.set('hadFix', true); }
  map = new maplibregl.Map({ container: 'map', style: STYLES[styleKey], center: view.c, zoom: view.z, attributionControl: { compact: true }, maxPitch: 70 });
  map.on('style.load', () => { baseVisibility = null; addOverlays(); });
  map.on('moveend', () => {
    store.set('view', { c: map.getCenter().toArray(), z: map.getZoom() });
    syncReports();
  });
  map.on('dragstart', () => { if (follow) setFollow(false); });
  map.on('click', async e => {
    const hit = map.getLayer('route-hit') && ui.routes.length > 1 ? map.queryRenderedFeatures(e.point, { layers: ['route-hit'] }) : [];
    if (hit.length && ui.mode === 'routes') { ui.selected = hit[0].properties.idx; drawRoutes(); renderSheet(); return; }
    if (ui.mode === 'nav') return;
    if (ui.mode === 'browse' || ui.mode === 'place') {
      if (!$('#results').classList.contains('hidden')) { hideResults(); return; }
      if (ui.mode === 'place') { closeSheet(); return; }
    }
  });
  let pressTimer;
  const longPress = async lngLat => { if (ui.mode === 'nav') return; const p = await reverse(lngLat.toArray()); showPlace(p); };
  map.on('contextmenu', e => longPress(e.lngLat));
  map.on('touchstart', e => { if (e.originalEvent.touches.length !== 1) return clearTimeout(pressTimer); pressTimer = setTimeout(() => longPress(e.lngLat), 600); });
  for (const ev of ['touchend', 'touchmove', 'movestart']) map.on(ev, () => clearTimeout(pressTimer));
  map.on('error', e => console.warn('map', e && e.error && e.error.message));
  const el = h('div', { class: 'puck', html: '<svg viewBox="0 0 26 26"><circle cx="13" cy="13" r="11" fill="#fff"/><circle cx="13" cy="13" r="8" fill="#1a73e8"/><path d="M13 3 L18 15 L13 12.5 L8 15 Z" fill="#fff" opacity=".95"/></svg>' });
  puck = new maplibregl.Marker({ element: el, rotationAlignment: 'map', pitchAlignment: 'map' });
}

const OUR_LAYERS = ['sat', 'route-casing', 'route-line', 'route-hit'];
let baseVisibility = null;   // the style's own layer visibility, captured when a style loads
function addOverlays() {
  if (!map.getSource('sat')) map.addSource('sat', { type: 'raster', tiles: [SAT_TILES], tileSize: 256, maxzoom: 19, attribution: 'Imagery © Esri, Maxar, Earthstar Geographics' });
  const layers = map.getStyle().layers;
  if (!baseVisibility) baseVisibility = Object.fromEntries(layers.filter(l => !OUR_LAYERS.includes(l.id)).map(l => [l.id, l.layout?.visibility || 'visible']));
  const firstSymbol = layers.find(l => l.type === 'symbol')?.id;
  // Satellite: aerial photos at the bottom, base-map fills and lines hidden, street labels kept on top.
  if (settings.satellite && !map.getLayer('sat')) map.addLayer({ id: 'sat', type: 'raster', source: 'sat' }, layers[0]?.id);
  if (!settings.satellite && map.getLayer('sat')) map.removeLayer('sat');
  for (const l of layers) {
    if (OUR_LAYERS.includes(l.id) || l.type === 'symbol' || !(l.id in baseVisibility)) continue;
    map.setLayoutProperty(l.id, 'visibility', settings.satellite ? 'none' : baseVisibility[l.id]);
  }
  if (!map.getSource('routes')) {
    map.addSource('routes', { type: 'geojson', data: { type: 'FeatureCollection', features: [] } });
    map.addLayer({ id: 'route-casing', type: 'line', source: 'routes', layout: { 'line-join': 'round', 'line-cap': 'round', 'line-sort-key': ['get', 'sel'] }, paint: { 'line-color': ['case', ['==', ['get', 'sel'], 1], '#0b57d0', '#80868b'], 'line-width': ['interpolate', ['linear'], ['zoom'], 8, 6, 16, 14] } }, firstSymbol);
    map.addLayer({ id: 'route-line', type: 'line', source: 'routes', layout: { 'line-join': 'round', 'line-cap': 'round', 'line-sort-key': ['get', 'sel'] }, paint: { 'line-color': ['case', ['==', ['get', 'sel'], 1], '#4285f4', '#bdc1c6'], 'line-width': ['interpolate', ['linear'], ['zoom'], 8, 4, 16, 10] } }, firstSymbol);
    map.addLayer({ id: 'route-hit', type: 'line', source: 'routes', paint: { 'line-color': '#000', 'line-opacity': 0, 'line-width': 24 } });
  }
  drawRoutes();
}

function setFollow(on) {
  follow = on;
  $('#btnLocate').classList.toggle('follow', on);
  $('#btnRecenter').classList.toggle('hidden', on || ui.mode !== 'nav');
  if (on && here) moveCamera(true);
}
function moveCamera(jump = false) {
  if (!here || !follow) return;
  if (ui.mode === 'nav') {
    const b = nav?.state.bearing ?? here.heading ?? map.getBearing();
    map.easeTo({ center: nav?.state.snapped || here.pos, zoom: speedZoom(), bearing: b, pitch: 55, padding: { top: Math.round(innerHeight * 0.42), bottom: 40, left: 0, right: 0 }, duration: jump ? 600 : 950, easing: t => t });
  } else {
    map.easeTo({ center: here.pos, zoom: Math.max(map.getZoom(), 15), duration: jump ? 700 : 500, padding: { top: 0, bottom: 0, left: 0, right: 0 } });
  }
}
function speedZoom() { const v = here?.speed || 0; return v > 27 ? 15 : v > 18 ? 15.6 : v > 10 ? 16.3 : 17; }

// ------------------------------------------------------------------ location
let watchId = null, simulating = false;
function startLocation(explicit = false) {
  if (!('geolocation' in navigator)) { if (explicit) toast('Location is not available in this browser'); return; }
  if (watchId != null) return;
  watchId = navigator.geolocation.watchPosition(p => {
    if (simulating) return;
    const c = p.coords;
    onLocation({ pos: [c.longitude, c.latitude], accuracy: c.accuracy || 30, speed: c.speed != null && c.speed >= 0 ? c.speed : null, heading: c.heading != null && !isNaN(c.heading) && (c.speed || 0) > 1 ? c.heading : null });
  }, err => {
    watchId = null;
    if (explicit || err.code === 1) toast(err.code === 1 ? 'Location is off. Allow it in Settings › Safari › Location (or Privacy › Location Services).' : 'Can\'t get your location right now', 5000);
  }, { enableHighAccuracy: true, maximumAge: 1000, timeout: 30000 });
}
function onLocation(loc) {
  const first = !here;
  loc.t = Date.now();
  if (loc.speed == null) loc.speed = here ? Math.min(60, dist(here.pos, loc.pos) / Math.max(0.5, (loc.t - here.t) / 1000)) : 0;
  if (loc.heading == null) loc.heading = (loc.speed || 0) > 2 && here ? bearing(here.pos, loc.pos) : (compassHeading ?? here?.heading ?? 0);
  here = loc;
  puck.setLngLat(loc.pos).setRotation(loc.heading || 0);
  if (!puck.added) { puck.addTo(map); puck.added = true; }
  if (first) { applyTheme(); if (ui.mode === 'browse' && !store.get('hadFix')) { store.set('hadFix', true); setFollow(true); } syncReports(); }
  if (nav) nav.onLocation(loc);
  if (live.active) live.onLocation();
  moveCamera();
  updateSpeed();
}
function enableCompass() {
  const handler = e => {
    const hd = e.webkitCompassHeading ?? (e.absolute && e.alpha != null ? 360 - e.alpha : null);
    if (hd == null) return;
    compassHeading = hd;
    if (here && (here.speed || 0) < 2 && !simulating) { here.heading = hd; puck.setRotation(hd); }
  };
  const DOE = window.DeviceOrientationEvent;
  if (DOE && typeof DOE.requestPermission === 'function') DOE.requestPermission().then(s => { if (s === 'granted') addEventListener('deviceorientation', handler); }).catch(() => {});
  else if (DOE) addEventListener('deviceorientationabsolute' in window ? 'deviceorientationabsolute' : 'deviceorientation', handler);
}

// ------------------------------------------------------------------ navigation engine
class Nav {
  constructor(route, dest) {
    this.route = route; this.dest = dest; this.reset();
    this.state = { remaining: route.distance, remainingS: route.duration, eta: Date.now() + route.duration * 1000, next: route.maneuvers[1] || route.maneuvers[0], nextIdx: 1, distToNext: 0, then: null, bearing: null, snapped: null, speedLimit: 0, offRoute: false, arrived: false, alert: null };
    this.lastReroute = 0; this.rerouting = false; this.overSince = 0; this.lastChime = 0;
    this.cameras = [];
    this.rebuildHazards();
    fetchSpeedLimits(route);
    this.loadCameras();
  }
  // Fixed speed cameras mapped in OpenStreetMap along the route (driving only).
  async loadCameras() {
    const r = this.route;
    if (r.mode !== 'drive') return;
    const bb = r.points.reduce((b, p) => [Math.min(b[0], p[0]), Math.min(b[1], p[1]), Math.max(b[2], p[0]), Math.max(b[3], p[1])], [180, 90, -180, -90]);
    if ((bb[2] - bb[0]) * (bb[3] - bb[1]) > 16) return;   // very long trips: skip rather than hammer Overpass
    const q = `[out:json][timeout:20];node[highway=speed_camera](${bb[1] - 0.01},${bb[0] - 0.01},${bb[3] + 0.01},${bb[2] + 0.01});out 500;`;
    for (const host of ['https://overpass-api.de/api/interpreter', 'https://overpass.private.coffee/api/interpreter', 'https://maps.mail.ru/osm/tools/overpass/api/interpreter']) {
      try {
        const j = await getJSON(host, { method: 'POST', body: 'data=' + encodeURIComponent(q), headers: { 'Content-Type': 'application/x-www-form-urlencoded' }, timeout: 15000 });
        if (nav !== this || this.route !== r) return;
        const kmh = raw => { const n = parseInt(raw, 10) || 0; return /mph/i.test(raw || '') ? n * 1.609344 : n; };
        this.cameras = j.elements.map(e => ({ id: 'cam-' + e.id, lon: e.lon, lat: e.lat, maxspeed: kmh(e.tags?.maxspeed) }))
          .map(c => [c, this.along([c.lon, c.lat], 35)]).filter(([, at]) => at != null);
        return;
      } catch { /* try the next mirror */ }
    }
  }
  reset() { this.seg = 0; this.spoken = new Map(); this.postSpoken = new Set(); this.off = 0; this.alerted = new Set(); }
  rebuildHazards() {
    const r = this.route; const out = [];
    const bb = r.points.reduce((b, p) => [Math.min(b[0], p[0]), Math.min(b[1], p[1]), Math.max(b[2], p[0]), Math.max(b[3], p[1])], [180, 90, -180, -90]);
    for (const rep of allReports()) {
      if (rep.lon < bb[0] - 0.01 || rep.lon > bb[2] + 0.01 || rep.lat < bb[1] - 0.01 || rep.lat > bb[3] + 0.01) continue;
      const at = this.along([rep.lon, rep.lat], 45); if (at != null) out.push([rep, at]);
    }
    this.hazards = out;
  }
  along(p, maxOff) {
    const pts = this.route.points; let best = Infinity, at = 0;
    for (let i = 0; i < pts.length - 1; i++) {
      if (Math.abs(pts[i][1] - p[1]) > 0.05 || Math.abs(pts[i][0] - p[0]) > 0.05) continue;
      const { t, d } = project(p, pts[i], pts[i + 1]);
      if (d < best) { best = d; at = this.route.cumDist[i] + t * (this.route.cumDist[i + 1] - this.route.cumDist[i]); }
    }
    return best <= maxOff ? at : null;
  }
  onLocation(loc) {
    const r = this.route, pts = r.points, s = this.state;
    if (s.arrived || this.rerouting) return;
    let bi = this.seg, bt = 0, bd = Infinity;
    for (let i = Math.max(0, this.seg - 3); i <= Math.min(this.seg + 120, pts.length - 2); i++) {
      const { t, d } = project(loc.pos, pts[i], pts[i + 1]);
      let score = d;
      if (loc.speed > 3 && loc.heading != null && angleDiff(bearing(pts[i], pts[i + 1]), loc.heading) > 100) score += 30;
      if (score < bd) { bd = score; bi = i; bt = t; }
    }
    const offDist = project(loc.pos, pts[bi], pts[bi + 1]).d;
    const threshold = Math.max(r.mode === 'drive' ? 45 : 30, (loc.accuracy || 20) * 1.3);
    if (offDist > threshold) {
      this.off++; s.offRoute = this.off >= 3; s.snapped = null;
      if (this.off >= 3) this.reroute(loc);
      renderNav(); return;
    }
    this.off = 0; this.seg = bi; s.offRoute = false;
    const progress = r.cumDist[bi] + bt * (r.cumDist[bi + 1] - r.cumDist[bi]);
    s.snapped = lerp(pts[bi], pts[bi + 1], bt);
    s.bearing = bearing(pts[bi], pts[bi + 1]);
    s.remaining = Math.max(0, r.distance - progress);
    const tAt = r.cumTime[bi] + (r.cumTime[bi + 1] - r.cumTime[bi]) * bt;
    s.remainingS = Math.max(0, r.cumTime[r.cumTime.length - 1] - tAt) * (r.duration / Math.max(1, r.cumTime[r.cumTime.length - 1]));
    s.eta = Date.now() + s.remainingS * 1000;
    let ni = r.maneuvers.findIndex(m => r.cumDist[m.i] > progress + 8); if (ni < 0) ni = r.maneuvers.length - 1;
    const next = r.maneuvers[ni];
    s.next = next; s.nextIdx = ni; s.distToNext = Math.max(0, r.cumDist[next.i] - progress);
    const then = r.maneuvers[ni + 1]; s.then = then && r.cumDist[then.i] - r.cumDist[next.i] < 250 ? then : null;
    s.speedLimit = r.limits[bi] || 0;
    if (s.remaining < 25 || (dist(loc.pos, r.dest) < 30 && progress > r.distance * 0.8)) {
      s.arrived = true; s.remaining = 0; s.remainingS = 0; s.next = r.maneuvers[r.maneuvers.length - 1]; s.distToNext = 0;
      voice.speak(`You have arrived at ${this.dest.name}`, true);
      renderNav(); if (live.active && live.untilArrival) live.push(true).finally(() => live.stop());
      return;
    }
    drawNavProgress();
    this.announce(ni, next, s.distToNext, loc.speed || 0, s.then);
    this.checkAlerts(progress, loc.speed || 0);
    this.checkSpeed(loc.speed || 0, s.speedLimit);
    renderNav();
  }
  announce(ni, m, d, speed, then) {
    if (m.turn === 'depart') return;
    const r = this.route;
    const v = Math.max(speed, r.mode === 'drive' ? 12 : r.mode === 'bike' ? 4 : 1.3);
    const far = Math.min(2600, Math.max(250, v * 50)), near = Math.min(700, Math.max(60, v * 15)), now = Math.min(110, Math.max(15, v * 4.5));
    const prevGap = ni > 0 ? r.cumDist[m.i] - r.cumDist[r.maneuvers[ni - 1].i] : Infinity;
    const stage = this.spoken.has(ni) ? this.spoken.get(ni) : -1;
    const lower = t => t.length > 1 && t[1] === t[1].toLowerCase() ? t[0].toLowerCase() + t.slice(1) : t;
    if (d <= now && stage < 2) {
      this.spoken.set(ni, 2);
      voice.speak(m.spoken.charAt(0).toUpperCase() + m.spoken.slice(1) + (then ? `, then ${lower(then.spoken)}` : ''));
    } else if (d <= near && stage < 1 && d > now * 1.5) {
      this.spoken.set(ni, 1); voice.speak(`In ${U.spoken(d)}, ${lower(m.spoken)}`);
    } else if (d <= far && stage < 0 && d > near * 1.6 && prevGap > near * 2) {
      this.spoken.set(ni, 0); voice.speak(`In ${U.spoken(d)}, ${lower(m.spoken)}`);
    } else if (stage < 0 && d > far * 1.3 && ni > 1 && !this.postSpoken.has(ni - 1) && d > 3000) {
      this.postSpoken.add(ni - 1);
      const road = r.maneuvers[ni - 1].street?.split(' / ')[0];
      voice.speak(`Continue ${road ? `on ${road} ` : ''}for ${U.spoken(d)}`);
    }
  }
  checkAlerts(progress, speed) {
    const look = this.route.mode === 'drive' ? Math.min(1200, Math.max(500, speed * 40)) : 200;
    if (settings.reportAlerts) for (const [rep, at] of this.hazards) {
      const ahead = at - progress;
      if (ahead >= 0 && ahead <= look && !this.alerted.has(rep.id)) {
        this.alerted.add(rep.id);
        const t = RTYPES[rep.type] || RTYPES.hazard;
        voice.speak(t.spoken);
        showAlert(t.emoji, t.label, `${U.dist(ahead)} ahead${rep.by ? ' · by ' + rep.by : ''}`, rep);
        return;
      }
    }
    if (this.route.mode !== 'drive' || !settings.cameraAlerts) return;
    for (const [cam, at] of this.cameras) {
      const ahead = at - progress;
      if (ahead >= 0 && ahead <= look * 0.7 && !this.alerted.has(cam.id)) {
        this.alerted.add(cam.id);
        voice.speak('Speed camera ahead');
        showAlert('📷', 'Speed camera', `${U.dist(ahead)} ahead${cam.maxspeed ? ` · limit ${U.limit(cam.maxspeed)} ${U.unit()}` : ''}`);
        return;
      }
    }
  }
  checkSpeed(speed, limKmh) {
    const s = this.state;
    if (!settings.speedAlert || !limKmh || this.route.mode !== 'drive') { this.overSince = 0; s.over = false; return; }
    s.over = U.speed(speed) > U.limit(limKmh) + Number(settings.tolerance || 0);
    const now = Date.now();
    if (s.over) { if (!this.overSince) this.overSince = now; if (now - this.overSince > 2500 && now - this.lastChime > 30000) { this.lastChime = now; voice.chime(); } }
    else this.overSince = 0;
  }
  async reroute(loc) {
    const now = Date.now();
    if (this.rerouting || now - this.lastReroute < 12000) return;
    this.lastReroute = now; this.rerouting = true; renderNav();
    voice.speak('Rerouting', true);
    try {
      const [nr] = await getRoutes(loc.pos, this.route.dest, this.route.mode, loc.speed > 2 ? loc.heading : null, false);
      if (nav !== this) return;
      this.route = nr; this.reset(); this.rebuildHazards(); fetchSpeedLimits(nr); this.loadCameras();
      ui.routes = [nr]; ui.selected = 0; drawRoutes();
    } catch (e) { toast('Couldn\'t reroute: ' + e.message); }
    finally { this.rerouting = false; this.state.offRoute = false; renderNav(); }
  }
}
let nav = null;

// Drives the selected route with simulated GPS (about 3x real time) — handy for a preview.
let simTimer = null;
function simulate(route) {
  stopSimulation(); simulating = true;
  let t = 0; const total = route.cumTime[route.cumTime.length - 1];
  const step = () => {
    if (!simulating) return;
    t = Math.min(total, t + 3);
    let i = route.cumTime.findIndex(x => x > t); if (i <= 0) i = route.points.length - 1;
    const a = route.points[i - 1], b = route.points[i], segT = route.cumTime[i] - route.cumTime[i - 1];
    const f = segT > 0 ? (t - route.cumTime[i - 1]) / segT : 1;
    const speed = segT > 0 ? dist(a, b) / segT : 10;
    onLocation({ pos: lerp(a, b, Math.min(1, f)), accuracy: 5, speed, heading: bearing(a, b) });
    if (t >= total || (nav && nav.state.arrived)) { stopSimulation(); return; }
    simTimer = setTimeout(step, 1000);
  };
  step();
}
function stopSimulation() { simulating = false; clearTimeout(simTimer); }

// ------------------------------------------------------------------ live location sharing
const live = {
  active: false, id: '', token: '', url: '', expires: 0, untilArrival: false, last: 0, timer: null,
  async start(minutes, untilArrival = false) {
    const srv = serverUrl();
    if (!srv) throw new Error('Add a Roadwise server in Settings to share live location');
    if (this.active) await this.stop();
    const res = await postJSON(`${srv}/api/live`, { name: settings.nickname || 'Someone', minutes: untilArrival ? 1440 : minutes, clientId });
    Object.assign(this, { active: true, id: res.id, token: res.token, url: `${srv}/live/${res.id}`, expires: untilArrival ? Infinity : Date.now() + minutes * 60000, untilArrival, last: 0 });
    this.push(); this.timer = setInterval(() => this.tick(), 5000);
    return this.url;
  },
  tick() {
    if (!this.active) return;
    if (Date.now() > this.expires || (this.untilArrival && !nav)) { this.stop(); return; }
    if (Date.now() - this.last > (nav ? 8000 : 15000)) this.push();
  },
  onLocation() { if (Date.now() - this.last > 8000) this.push(); },
  async push(arrived = false) {
    if (!this.active) return;
    this.last = Date.now();
    const b = { token: this.token, arrived, imperial: settings.imperial };
    if (here) Object.assign(b, { lat: here.pos[1], lon: here.pos[0], speed: here.speed || 0, heading: here.heading || 0, accuracy: here.accuracy || 0 });
    if (nav) Object.assign(b, { eta: Math.round(nav.state.eta), remainingM: nav.state.remaining, destName: nav.dest.name, destLat: nav.dest.lat, destLon: nav.dest.lon });
    try { await postJSON(`${serverUrl()}/api/live/${this.id}`, b, { timeout: 8000 }); }
    catch (e) { if (/ended|forbidden/.test(e.message)) this.stop(); }
  },
  async stop() {
    if (!this.active) return;
    const { id, token } = this; this.active = false; clearInterval(this.timer);
    try { await postJSON(`${serverUrl()}/api/live/${id}/stop`, { token }, { timeout: 6000 }); } catch { /* ended anyway */ }
    if (ui.mode === 'nav') renderSheet();
  },
};
async function shareText(text, url) {
  if (navigator.share) { try { await navigator.share(url ? { text, url } : { text }); return; } catch (e) { if (e.name === 'AbortError') return; } }
  try { await navigator.clipboard.writeText(url ? `${text} ${url}` : text); toast('Copied to clipboard'); } catch { prompt('Copy this:', url ? `${text} ${url}` : text); }
}
const mapLink = (lat, lon) => `https://maps.google.com/?q=${lat.toFixed(6)},${lon.toFixed(6)}`;

// ------------------------------------------------------------------ saved places + recents
let saved = store.get('saved', { home: null, work: null, favorites: [] });
let recents = store.get('recents', []);
const saveSaved = () => store.set('saved', saved);
function addRecent(p) { recents = [p, ...recents.filter(r => !(r.name === p.name && Math.abs(r.lat - p.lat) < 1e-4))].slice(0, 12); store.set('recents', recents); }

// ------------------------------------------------------------------ UI state
const ui = { mode: 'browse', place: null, routes: [], selected: 0, travel: store.get('travel', 'drive'), routeError: '', loading: false, chip: null };

function setMode(m) {
  const wasNav = ui.mode === 'nav';
  ui.mode = m;
  $('#top').classList.toggle('hidden', m === 'nav' || m === 'routes');
  $('#banner').classList.toggle('hidden', m !== 'nav');
  $('#speed').classList.toggle('hidden', m !== 'nav');
  $('#btnLayers').classList.toggle('hidden', m === 'nav');
  $('#btnRecenter').classList.toggle('hidden', !(m === 'nav' && !follow));
  if (m !== 'nav') $('#alert').classList.add('hidden');
  if (wasNav && m !== 'nav') map.easeTo({ pitch: 0, bearing: 0, padding: { top: 0, bottom: 0, left: 0, right: 0 }, duration: 500 });
  renderSheet();
}
function closeSheet() {
  if (destMarker) { destMarker.remove(); destMarker = null; }
  ui.place = null; ui.routes = []; drawRoutes(); setMode('browse');
}
function placeEmoji(p) { return p.emoji || (p.category === 'pin' ? '📍' : p.category === 'coords' ? '🧭' : p.kind === 'home' ? '🏠' : p.kind === 'work' ? '💼' : '📍'); }
function placeRow(p, onclick) {
  const d = here && (p.lat || p.lon) ? U.dist(dist(here.pos, [p.lon, p.lat])) : '';
  return h('button', { class: 'row', onclick }, h('span', { class: 'ico' }, placeEmoji(p)),
    h('span', { class: 'txt' }, h('div', { class: 't1' }, p.name), h('div', { class: 't2' }, p.address || p.category || '')), d && h('span', { class: 'dist' }, d));
}

// ---------- search UI
let searchTimer, searchSeq = 0;
function showResults(nodes) { const r = $('#results'); r.replaceChildren(...nodes.filter(Boolean)); r.classList.remove('hidden'); }
function hideResults() { $('#results').classList.add('hidden'); }
function showDefaultList() {
  const rows = [];
  rows.push(h('div', { class: 'hdr' }, 'Saved'));
  rows.push(placeRow(saved.home ? { ...saved.home, kind: 'home', name: 'Home', address: saved.home.address || saved.home.name } : { name: 'Home', address: 'Tap to set — search a place, then ☆ Save', kind: 'home', lat: 0, lon: 0 }, () => saved.home ? pick(saved.home) : toast('Search for your home address, then tap ☆ Save › Home')));
  rows.push(placeRow(saved.work ? { ...saved.work, kind: 'work', name: 'Work', address: saved.work.address || saved.work.name } : { name: 'Work', address: 'Tap to set — search a place, then ☆ Save', kind: 'work', lat: 0, lon: 0 }, () => saved.work ? pick(saved.work) : toast('Search for your work address, then tap ☆ Save › Work')));
  for (const f of saved.favorites) rows.push(placeRow({ ...f, emoji: '⭐' }, () => pick(f)));
  if (recents.length) { rows.push(h('div', { class: 'hdr' }, 'Recent')); for (const p of recents) rows.push(placeRow({ ...p, emoji: '🕘' }, () => pick(p))); }
  showResults(rows);
}
async function runSearch(q) {
  const seq = ++searchSeq;
  if (q.trim().length < 2) { showDefaultList(); return; }
  showResults([h('div', { class: 'empty' }, 'Searching…')]);
  const local = [saved.home && { ...saved.home, kind: 'home' }, saved.work && { ...saved.work, kind: 'work' }, ...saved.favorites, ...recents]
    .filter(p => p && (p.name + ' ' + (p.address || '')).toLowerCase().includes(q.toLowerCase())).slice(0, 3);
  try {
    const res = await searchPlaces(q);
    if (seq !== searchSeq) return;
    const all = [...local, ...res];
    showResults(all.length ? all.map(p => placeRow(p, () => pick(p))) : [h('div', { class: 'empty' }, 'No results. Try adding a city or state.')]);
  } catch (e) {
    if (seq !== searchSeq) return;
    showResults([...local.map(p => placeRow(p, () => pick(p))), h('div', { class: 'empty' }, navigator.onLine ? 'Search is unavailable right now (' + e.message + ').' : 'You\'re offline — search needs a connection.')]);
  }
}
async function runCategory(cat) {
  ui.chip = cat.label; renderChips();
  showResults([h('div', { class: 'empty' }, `Finding ${cat.label.toLowerCase()} nearby…`)]);
  try {
    const res = await nearby(cat);
    if (ui.chip !== cat.label) return;
    showResults(res.length ? [h('div', { class: 'hdr' }, `${cat.emoji} ${cat.label} nearby`), ...res.map(p => placeRow(p, () => pick(p)))] : [h('div', { class: 'empty' }, 'Nothing found nearby.')]);
    if (res.length) { const b = new maplibregl.LngLatBounds(); res.slice(0, 12).forEach(p => b.extend([p.lon, p.lat])); if (here) b.extend(here.pos); map.fitBounds(b, { padding: { top: 380, bottom: 60, left: 50, right: 50 }, maxZoom: 15, duration: 600 }); }
  } catch (e) { showResults([h('div', { class: 'empty' }, 'Couldn\'t load nearby places (' + e.message + ').')]); }
}
function renderChips() {
  $('#chips').replaceChildren(...CATEGORIES.map(c => h('button', { class: 'chip' + (ui.chip === c.label ? ' on' : ''), role: 'listitem', onclick: () => ui.chip === c.label ? (ui.chip = null, renderChips(), hideResults()) : runCategory(c) }, `${c.emoji} ${c.label}`)));
}
function pick(p) {
  hideResults(); $('#q').blur(); ui.chip = null; renderChips();
  addRecent({ name: p.name, address: p.address, lat: p.lat, lon: p.lon, category: p.category });
  showPlace(p);
}

// ---------- place sheet
function showPlace(p) {
  ui.place = p; ui.routes = []; drawRoutes();
  if (destMarker) destMarker.remove();
  destMarker = new maplibregl.Marker({ color: '#e53935' }).setLngLat([p.lon, p.lat]).addTo(map);
  setFollow(false);
  map.easeTo({ center: [p.lon, p.lat], zoom: Math.max(map.getZoom(), 15), padding: { bottom: 220, top: 0, left: 0, right: 0 }, duration: 700 });
  setMode('place');
}
function savedMenu(p) {
  const strip = { name: p.name, address: p.address, lat: p.lat, lon: p.lon, category: p.category };
  openPanel('Save place', [
    h('div', { class: 'group' },
      h('button', { class: 'row', onclick: () => { saved.home = strip; saveSaved(); closePanel(); toast('Saved as Home'); } }, h('span', { class: 'ico' }, '🏠'), h('span', { class: 'txt' }, h('div', { class: 't1' }, 'Set as Home'))),
      h('button', { class: 'row', onclick: () => { saved.work = strip; saveSaved(); closePanel(); toast('Saved as Work'); } }, h('span', { class: 'ico' }, '💼'), h('span', { class: 'txt' }, h('div', { class: 't1' }, 'Set as Work'))),
      h('button', { class: 'row', onclick: () => { saved.favorites = [strip, ...saved.favorites.filter(f => f.name !== p.name)].slice(0, 30); saveSaved(); closePanel(); toast('Added to Favorites'); } }, h('span', { class: 'ico' }, '⭐'), h('span', { class: 'txt' }, h('div', { class: 't1' }, 'Add to Favorites'))),
    ),
    saved.favorites.some(f => f.name === p.name) && h('button', { class: 'btn', onclick: () => { saved.favorites = saved.favorites.filter(f => f.name !== p.name); saveSaved(); closePanel(); toast('Removed from Favorites'); } }, 'Remove from Favorites'),
  ]);
}

// ---------- routes
async function planRoutes() {
  const p = ui.place; if (!p) return;
  ui.routeError = ''; ui.loading = true; ui.routes = []; ui.selected = 0; setMode('routes');
  const from = ui.from || (here && here.pos);
  if (!from) { ui.loading = false; ui.routeError = 'need-location'; renderSheet(); startLocation(true); return; }
  try {
    ui.routes = await getRoutes(from, [p.lon, p.lat], ui.travel, here && here.speed > 2 ? here.heading : null, true);
    ui.loading = false; drawRoutes(); fitRoutes(); renderSheet();
  } catch (e) {
    ui.loading = false; ui.routeError = navigator.onLine ? `Couldn't find a route (${e.message}).` : 'You\'re offline — routing needs a connection in the web version.';
    renderSheet();
  }
}
function drawRoutes() {
  if (!map || !map.getSource('routes')) return;
  const feats = ui.routes.map((r, idx) => ({ type: 'Feature', properties: { idx, sel: idx === ui.selected ? 1 : 0 }, geometry: { type: 'LineString', coordinates: r.points } }));
  map.getSource('routes').setData({ type: 'FeatureCollection', features: feats });
}
// While navigating: the part already driven turns gray, the rest stays blue.
function drawNavProgress() {
  if (!nav || !map.getSource('routes') || !nav.state.snapped) return;
  const pts = nav.route.points, i = nav.seg, p = nav.state.snapped;
  const line = (coords, sel) => ({ type: 'Feature', properties: { idx: 0, sel }, geometry: { type: 'LineString', coordinates: coords } });
  map.getSource('routes').setData({ type: 'FeatureCollection', features: [line(pts.slice(0, i + 1).concat([p]), 0), line([p].concat(pts.slice(i + 1)), 1)] });
}
function fitRoutes() {
  if (!ui.routes.length) return;
  const b = new maplibregl.LngLatBounds(); ui.routes.forEach(r => r.points.forEach((p, i) => { if (i % 5 === 0) b.extend(p); })); b.extend(ui.routes[0].points[ui.routes[0].points.length - 1]);
  map.fitBounds(b, { padding: { top: 70, bottom: Math.min(innerHeight * 0.55, 380), left: 40, right: 40 }, duration: 700 });
}
function startNav(preview = false) {
  const r = ui.routes[ui.selected]; if (!r) return;
  voice.unlock(); keepAwake(true);
  nav = new Nav(r, ui.place);
  ui.routes = [r]; ui.selected = 0; drawRoutes();
  setMode('nav'); setFollow(true);
  const first = r.maneuvers[0];
  voice.speak(`Starting route to ${ui.place.name}. ${U.spoken(r.distance)}, about ${U.dur(r.duration).replace('hr', 'hours').replace('min', 'minutes')}. ${first && first.turn === 'depart' ? first.spoken : ''}`, true);
  if (preview) simulate(r); else startLocation(true);
  renderNav();
}
function endNav() {
  stopSimulation(); voice.stop(); keepAwake(false);
  if (live.active && live.untilArrival) live.stop();
  nav = null; ui.routes = []; drawRoutes(); setFollow(false);
  if (destMarker) { destMarker.remove(); destMarker = null; }
  ui.place = null; setMode('browse');
}

// ---------- nav rendering
const ARROW_ROT = { straight: 0, merge: 0, 'slight-right': 40, right: 90, 'sharp-right': 135, 'slight-left': -40, left: -90, 'sharp-left': -135, 'keep-right': 25, 'keep-left': -25, 'exit-right': 45, 'exit-left': -45, 'ramp-right': 45, 'ramp-left': -45 };
function turnIcon(turn) {
  if (turn === 'arrive') return '🏁';
  if (turn === 'roundabout') return '⟳';
  if (turn === 'ferry') return '⛴️';
  if (turn === 'uturn') return '⤺';
  const rot = ARROW_ROT[turn] ?? 0;
  const el = h('span', { html: `<svg viewBox="0 0 50 50"><g transform="rotate(${rot} 25 25)"><path d="M25 6 L37 22 H29 V44 H21 V22 H13 Z" fill="#fff"/></g></svg>` });
  return el;
}
function renderNav() {
  if (!nav || ui.mode !== 'nav') return;
  const s = nav.state, b = $('#banner');
  b.classList.toggle('off', s.offRoute || nav.rerouting);
  const turnEl = $('#bTurn');
  if (nav.rerouting) { turnEl.replaceChildren('↻'); $('#bDist').textContent = 'Rerouting…'; $('#bText').textContent = ''; }
  else if (s.arrived) { turnEl.replaceChildren('🏁'); $('#bDist').textContent = 'Arrived'; $('#bText').textContent = nav.dest.name; }
  else {
    const m = s.next || nav.route.maneuvers[0];
    turnEl.replaceChildren(turnIcon(m.turn));
    $('#bDist').textContent = s.offRoute ? 'Off route' : U.dist(s.distToNext);
    $('#bText').textContent = m.text || m.street || '';
  }
  const then = $('#bThen');
  if (s.then && !s.arrived && !nav.rerouting) { then.replaceChildren('Then ', h('b', {}, s.then.text || '')); then.classList.remove('hidden'); }
  else then.classList.add('hidden');
  updateSpeed();
  renderSheet();
}
function updateSpeed() {
  if (ui.mode !== 'nav') return;
  $('#speedVal').textContent = here ? U.speed(here.speed || 0) : 0;
  $('#speedUnit').textContent = U.unit();
  const lim = nav?.state.speedLimit || 0;
  const le = $('#limit');
  le.classList.toggle('hidden', !lim); le.classList.toggle('metric', !settings.imperial);
  if (lim) $('#limitVal').textContent = U.limit(lim);
  $('#speedNow').classList.toggle('over', !!nav?.state.over);
}
let alertTimer;
function showAlert(emoji, title, detail, rep) {
  const a = $('#alert');
  a.replaceChildren(...[h('span', { class: 'e' }, emoji), h('div', {}, h('b', {}, title), h('small', {}, detail)),
    rep && h('button', { class: 'btn small', onclick: () => { voteReport(rep, true); a.classList.add('hidden'); } }, '👍'),
    rep && h('button', { class: 'btn small', onclick: () => { voteReport(rep, false); a.classList.add('hidden'); } }, 'Gone')].filter(Boolean));
  a.classList.remove('hidden');
  const b = $('#banner').getBoundingClientRect();
  a.style.top = b.height ? `${Math.round(b.bottom + 10)}px` : '';
  clearTimeout(alertTimer); alertTimer = setTimeout(() => a.classList.add('hidden'), 20000);
}

// ---------- the bottom sheet for each mode
function renderSheet() {
  const sh = $('#sheet');
  const fabs = $('#fabs');
  if (ui.mode === 'browse') { sh.classList.add('hidden'); fabs.style.bottom = ''; return; }
  sh.classList.remove('hidden');
  let kids = [];
  if (ui.mode === 'place') {
    const p = ui.place;
    const d = here ? ` · ${U.dist(dist(here.pos, [p.lon, p.lat]))} away` : '';
    kids = [
      h('button', { class: 'icon-btn close', 'aria-label': 'Close', onclick: closeSheet }, '✕'),
      h('h2', {}, p.name),
      h('div', { class: 'sub' }, (p.address || p.category || '') + d),
      h('div', { class: 'actions' },
        h('button', { class: 'btn primary', onclick: () => { ui.from = null; planRoutes(); } }, '↱ Directions'),
        h('button', { class: 'btn', onclick: () => savedMenu(p) }, '☆ Save'),
        h('button', { class: 'btn', onclick: () => shareText(`📍 ${p.name}${p.address ? ' — ' + p.address : ''}`, mapLink(p.lat, p.lon)) }, '↗ Share')),
    ];
  } else if (ui.mode === 'routes') {
    const p = ui.place;
    kids = [
      h('button', { class: 'icon-btn close', 'aria-label': 'Close', onclick: () => { ui.routes = []; drawRoutes(); setMode('place'); } }, '✕'),
      h('div', { class: 'from' }, `${ui.from ? 'From map center' : 'From your location'} → `, h('b', {}, p.name)),
      h('div', { class: 'modes' }, ...Object.entries(MODES).map(([k, m]) => h('button', { class: ui.travel === k ? 'on' : '', onclick: () => { ui.travel = k; store.set('travel', k); planRoutes(); } }, `${m.icon} ${m.label}`))),
    ];
    if (ui.loading) kids.push(h('div', { class: 'sub' }, 'Finding the best routes…'));
    else if (ui.routeError === 'need-location') kids.push(h('div', { class: 'err' }, 'Turn on location to get directions from where you are.'), h('div', { class: 'actions' },
      h('button', { class: 'btn primary', onclick: () => { startLocation(true); setTimeout(() => here && planRoutes(), 2500); } }, 'Use my location'),
      h('button', { class: 'btn', onclick: () => { ui.from = map.getCenter().toArray(); planRoutes(); } }, 'Start from map center')));
    else if (ui.routeError) kids.push(h('div', { class: 'err' }, ui.routeError), h('button', { class: 'btn', onclick: planRoutes }, 'Try again'));
    else {
      const fastest = Math.min(...ui.routes.map(r => r.duration));
      ui.routes.forEach((r, i) => kids.push(h('button', { class: 'route-card' + (i === ui.selected ? ' on' : ''), onclick: () => { ui.selected = i; drawRoutes(); renderSheet(); } },
        h('div', {}, h('div', { class: 'dur' + (r.duration === fastest ? ' fast' : '') }, U.dur(r.duration)), h('div', { class: 'meta' }, r.label, r.tolls && h('span', { class: 'tag' }, 'Tolls'), r.ferry && h('span', { class: 'tag' }, 'Ferry'))),
        h('div', { class: 'meta', style: 'text-align:right' }, U.dist(r.distance), h('br'), `Arrive ${U.clock(Date.now() + r.duration * 1000)}`))));
      if (ui.travel === 'drive') kids.push(h('div', { class: 'modes' },
        ...[['avoidTolls', 'No tolls'], ['avoidHighways', 'No highways'], ['avoidFerries', 'No ferries']].map(([k, l]) => h('button', { class: settings[k] ? 'on' : '', onclick: () => { settings[k] = !settings[k]; saveSettings(); planRoutes(); } }, l))));
      kids.push(h('div', { class: 'actions' },
        h('button', { class: 'btn go', onclick: () => startNav(false), disabled: !ui.routes.length || (!here && !ui.from) }, '▶ Start'),
        h('button', { class: 'btn', onclick: () => startNav(true), disabled: !ui.routes.length }, '👁 Preview drive')));
      if (!here) kids.push(h('div', { class: 'sub', style: 'margin-top:8px' }, 'Turn-by-turn needs your location. Preview drive shows the route without it.'));
    }
  } else if (ui.mode === 'nav' && nav) {
    const s = nav.state;
    kids = [h('div', { class: 'nav-bottom' },
      h('div', { class: 'eta' }, h('b', {}, s.arrived ? 'Arrived' : U.clock(s.eta)), h('div', {}, s.arrived ? nav.dest.name : `${U.dur(s.remainingS)} · ${U.dist(s.remaining)}${simulating ? ' · preview' : ''}`)),
      h('button', { class: 'round', 'aria-label': settings.voice ? 'Mute voice' : 'Unmute voice', onclick: () => { settings.voice = !settings.voice; saveSettings(); if (!settings.voice) voice.stop(); renderSheet(); } }, settings.voice ? '🔊' : '🔇'),
      h('button', { class: 'round', 'aria-label': 'Report', onclick: openReport }, '⚠️'),
      h('button', { class: 'round', 'aria-label': 'Share trip', onclick: shareTrip }, live.active ? '🔴' : '↗'),
      h('button', { class: 'btn danger', onclick: endNav }, s.arrived ? 'Done' : 'End'))];
  }
  sh.replaceChildren(...kids.filter(Boolean));
  requestAnimationFrame(() => { fabs.style.bottom = `${sh.offsetHeight + 16}px`; });
}

// ------------------------------------------------------------------ report UI
function openReport() {
  openPanel('Report', [
    h('p', { class: 'sub' }, here ? 'Tap what you see. It\'s placed where you are now.' : 'No location yet, so it\'s placed at the center of the map.'),
    h('div', { class: 'grid' }, ...Object.entries(RTYPES).map(([k, t]) => h('button', { class: 'rtype', onclick: () => { closePanel(); addReport(k); } }, h('span', {}, t.emoji), t.label))),
    h('p', { class: 'note' }, serverUrl() ? 'Reports are shared with everyone using your Roadwise server.' : 'No report server set, so reports stay on this phone. Add one in Settings to share them.'),
  ]);
}
function drawReports() {
  if (!map) return;
  const list = allReports(), keep = new Set();
  for (const r of list) {
    const key = r.serverId || r.id; keep.add(key);
    if (reportMarkers.has(key)) continue;
    const t = RTYPES[r.type] || RTYPES.hazard;
    const el = h('div', { class: 'rmarker' + (r.serverId || !r.id.startsWith('l-') || !serverUrl() ? '' : ' pending'), style: `background:${t.color}`, title: t.label }, t.emoji);
    const ageMin = Math.max(1, Math.round((Date.now() - r.created) / 60000));
    const popup = new maplibregl.Popup({ offset: 20, closeButton: true }).setDOMContent(h('div', { class: 'pop' },
      h('h4', {}, `${t.emoji} ${t.label}`),
      h('small', {}, `${ageMin < 60 ? ageMin + ' min' : Math.round(ageMin / 60) + ' hr'} ago${r.by ? ' · by ' + r.by : ''}${r.up ? ` · ${r.up} 👍` : ''}`),
      r.note && h('small', {}, r.note),
      h('div', { class: 'actions' },
        h('button', { class: 'btn small primary', onclick: () => { popup.remove(); voteReport(r, true); } }, 'Still there'),
        h('button', { class: 'btn small', onclick: () => { popup.remove(); voteReport(r, false); } }, 'Not there'))));
    reportMarkers.set(key, new maplibregl.Marker({ element: el }).setLngLat([r.lon, r.lat]).setPopup(popup).addTo(map));
  }
  for (const [k, m] of reportMarkers) if (!keep.has(k)) { m.remove(); reportMarkers.delete(k); }
}

// ------------------------------------------------------------------ share UI
function shareTrip() {
  if (!nav) return openShare();
  const s = nav.state;
  const text = `🚗 On my way to ${nav.dest.name} — arriving around ${U.clock(s.eta)} (${U.dur(s.remainingS)}, ${U.dist(s.remaining)} away).`;
  openPanel('Share trip', [
    h('div', { class: 'group' },
      h('button', { class: 'row', onclick: () => { closePanel(); shareText(text + (here ? `\nI'm here now: ${mapLink(here.pos[1], here.pos[0])}` : '')); } }, h('span', { class: 'ico' }, '✉️'), h('span', { class: 'txt' }, h('div', { class: 't1' }, 'Send my ETA'), h('div', { class: 't2' }, 'A one-time message with your arrival time'))),
      liveRows(true, text)),
  ]);
}
function openShare() {
  const text = here ? `📍 Here's my location: ${mapLink(here.pos[1], here.pos[0])}` : null;
  openPanel('Share location', [
    h('div', { class: 'group' },
      h('button', { class: 'row', disabled: !text, onclick: () => { closePanel(); shareText(text); } }, h('span', { class: 'ico' }, '📍'), h('span', { class: 'txt' }, h('div', { class: 't1' }, 'Send my current location'), h('div', { class: 't2' }, text ? 'A map link that opens anywhere' : 'Waiting for your location…'))),
      liveRows(false)),
    !here && h('button', { class: 'btn', onclick: () => { startLocation(true); closePanel(); } }, 'Turn on location'),
  ]);
}
function liveRows(navigating, tripText = '') {
  if (live.active) return [
    h('div', { class: 'opt col' }, h('div', { class: 'lbl' }, '🔴 Sharing live location', h('small', {}, live.untilArrival ? 'Until you arrive' : `Until ${U.clock(live.expires)}`))),
    h('div', { class: 'opt' }, h('button', { class: 'btn primary', onclick: () => shareText('Follow my location live:', live.url) }, 'Send link again'), h('button', { class: 'btn danger', onclick: () => { live.stop(); closePanel(); toast('Stopped sharing'); } }, 'Stop sharing')),
  ];
  if (!serverUrl()) return h('div', { class: 'opt col' }, h('div', { class: 'lbl' }, '🔴 Live location', h('small', {}, 'Friends watch you move on a web map. This needs a Roadwise server — add its address in Settings.')));
  const opts = [[15, '15 minutes'], [60, '1 hour'], [480, '8 hours']];
  if (navigating) opts.unshift([0, 'Until I arrive']);
  return [h('div', { class: 'opt col' }, h('div', { class: 'lbl' }, '🔴 Share live location', h('small', {}, 'Friends watch you on a web map — no app needed. Keep Roadwise open on screen while sharing.'))),
    h('div', { class: 'opt', style: 'flex-wrap:wrap;justify-content:flex-start' }, ...opts.map(([min, label]) => h('button', { class: 'btn small', onclick: async () => {
      try { const url = await live.start(min, min === 0); closePanel(); renderSheet(); await shareText(tripText ? tripText + '\nFollow along live:' : 'Follow my location live:', url); }
      catch (e) { toast(e.message, 4000); }
    } }, label)))];
}

// ------------------------------------------------------------------ panels (settings etc.)
function openPanel(title, body) {
  const p = $('#panel');
  p.replaceChildren(h('div', { class: 'panel-inner' }, h('header', {}, h('h2', {}, title), h('button', { class: 'icon-btn', 'aria-label': 'Close', onclick: closePanel }, '✕')), ...[body].flat(Infinity).filter(Boolean)));
  p.classList.remove('hidden'); p.scrollTop = 0;
}
function closePanel() { $('#panel').classList.add('hidden'); }
function toggle(key, label, sub, after) {
  const inp = h('input', { type: 'checkbox' }); inp.checked = !!settings[key];
  inp.addEventListener('change', () => { settings[key] = inp.checked; saveSettings(); after && after(); });
  return h('label', { class: 'opt' }, h('span', { class: 'lbl' }, label, sub && h('small', {}, sub)), h('span', { class: 'switch' }, inp, h('span')));
}
function seg(key, label, choices, after) {
  const wrap = h('div', { class: 'seg' });
  const draw = () => wrap.replaceChildren(...choices.map(([v, l]) => h('button', { class: settings[key] === v ? 'on' : '', onclick: () => { settings[key] = v; saveSettings(); draw(); after && after(); } }, l)));
  draw();
  return h('div', { class: 'opt' }, h('span', { class: 'lbl' }, label), wrap);
}
function openSettings() {
  const server = h('input', { type: 'url', placeholder: 'https://your-server.example', value: settings.server, autocapitalize: 'off', autocorrect: 'off', spellcheck: 'false' });
  const nick = h('input', { type: 'text', placeholder: 'Shown on your reports and live map', value: settings.nickname, maxlength: '40' });
  const testOut = h('small', {});
  const tol = h('input', { type: 'number', min: '0', max: '20', value: settings.tolerance, style: 'width:70px' });
  tol.addEventListener('change', () => { settings.tolerance = Math.max(0, Math.min(20, +tol.value || 0)); saveSettings(); });
  nick.addEventListener('change', () => { settings.nickname = nick.value.trim(); saveSettings(); });
  const offlineBar = h('div', { class: 'progress hidden' }, h('div'));
  const offlineMsg = h('small', {}, 'Saves the map tiles for the area on screen so it still shows with no signal. Search and new routes need a connection.');
  openPanel('Settings', [
    h('div', { class: 'group' }, h('h3', {}, 'Map'),
      seg('theme', 'Map style', [['auto', 'Auto'], ['day', 'Day'], ['night', 'Night']], applyTheme),
      toggle('satellite', 'Satellite view', 'Aerial photos with street labels', applyTheme),
      seg('imperial', 'Units', [[true, 'mi'], [false, 'km']], () => { renderSheet(); updateSpeed(); })),
    h('div', { class: 'group' }, h('h3', {}, 'Navigation'),
      toggle('voice', 'Voice guidance'),
      toggle('speedAlert', 'Speeding chime', 'Plays a chime when you go over the limit'),
      h('div', { class: 'opt' }, h('span', { class: 'lbl' }, 'Chime tolerance', h('small', {}, `How far over the limit, in ${U.unit()}`)), tol),
      toggle('reportAlerts', 'Report alerts', 'Spoken warnings for reports on your route'),
      toggle('cameraAlerts', 'Speed camera alerts', 'Fixed cameras mapped in OpenStreetMap'),
      toggle('avoidTolls', 'Avoid tolls'), toggle('avoidHighways', 'Avoid highways'), toggle('avoidFerries', 'Avoid ferries')),
    h('div', { class: 'group' }, h('h3', {}, 'Reports and live sharing'),
      h('div', { class: 'opt col' }, h('span', { class: 'lbl' }, 'Your name'), nick),
      h('div', { class: 'opt col' }, h('span', { class: 'lbl' }, 'Roadwise server URL', h('small', {}, 'The same server the Android app uses. Leave blank to keep reports on this phone.')), server,
        h('div', { class: 'actions', style: 'margin-top:4px' }, h('button', { class: 'btn small primary', onclick: async () => {
          settings.server = server.value.trim(); saveSettings(); lastSyncCenter = null;
          if (!settings.server) { testOut.textContent = 'Server removed. Reports stay on this phone.'; return; }
          testOut.textContent = 'Testing…';
          try { const j = await getJSON(`${serverUrl()}/api/health`, { timeout: 8000 }); testOut.textContent = `✅ Connected — ${j.active} active reports on the server`; syncReports(true); }
          catch (e) { testOut.textContent = `❌ Couldn't connect: ${e.message}`; }
        } }, 'Save & test')), testOut)),
    h('div', { class: 'group' }, h('h3', {}, 'Offline'),
      h('div', { class: 'opt col' }, h('span', { class: 'lbl' }, 'Save this map area', offlineMsg), offlineBar,
        h('div', { class: 'actions', style: 'margin-top:4px' }, h('button', { class: 'btn small primary', onclick: e => saveOffline(e.target, offlineBar, offlineMsg) }, 'Save area on screen')))),
    h('div', { class: 'group' }, h('h3', {}, 'About'),
      h('div', { class: 'opt col' }, h('span', { class: 'lbl' }, 'Roadwise for iPhone (web app)', h('small', {}, 'Free and open source. Uses OpenStreetMap data, OpenFreeMap tiles, Valhalla routing and Photon search.'))),
      h('div', { class: 'opt' }, h('a', { href: REPO_URL, target: '_blank', rel: 'noopener' }, 'Source code on GitHub'), h('a', { href: APK_URL }, 'Android app (APK)'))),
    h('p', { class: 'note' }, 'Map data © OpenStreetMap contributors. Imagery © Esri.'),
  ]);
}

// Pre-fetch vector tiles for the visible area (zoom up to 14) so the service worker caches them.
async function saveOffline(btn, bar, msg) {
  const tilesFor = (b, z) => {
    const x = lon => Math.floor((lon + 180) / 360 * 2 ** z);
    const y = lat => Math.floor((1 - Math.log(Math.tan(lat * RAD) + 1 / Math.cos(lat * RAD)) / Math.PI) / 2 * 2 ** z);
    const out = []; for (let i = x(b.getWest()); i <= x(b.getEast()); i++) for (let j = y(b.getNorth()); j <= y(b.getSouth()); j++) out.push([z, i, j]); return out;
  };
  const src = Object.values(map.getStyle().sources).find(s => s.type === 'vector');
  const srcId = Object.keys(map.getStyle().sources).find(k => map.getStyle().sources[k] === src);
  const templates = map.getSource(srcId)?.tiles;
  if (!templates || !templates.length) { msg.textContent = 'Map not ready yet — try again in a moment.'; return; }
  const b = map.getBounds(); let list = [];
  for (let z = Math.max(0, Math.floor(map.getZoom()) - 2); z <= 14; z++) { list = list.concat(tilesFor(b, z)); if (list.length > 4000) break; }
  if (list.length > 4000) { msg.textContent = 'That area is too big. Zoom in to a city or county and try again.'; return; }
  btn.disabled = true; bar.classList.remove('hidden'); let done = 0, failed = 0;
  const queue = list.slice();
  const worker = async () => { while (queue.length) { const [z, x, y] = queue.shift(); try { const r = await fetch(templates[0].replace('{z}', z).replace('{x}', x).replace('{y}', y)); if (!r.ok) failed++; } catch { failed++; } done++; bar.firstChild.style.width = `${Math.round(done / list.length * 100)}%`; } };
  await Promise.all(Array.from({ length: 6 }, worker));
  btn.disabled = false;
  msg.textContent = `Saved ${list.length - failed} map tiles for this area${failed ? ` (${failed} failed)` : ''}. They'll show with no signal.`;
}

// ------------------------------------------------------------------ wiring
function wire() {
  const q = $('#q');
  q.addEventListener('focus', () => { if (!q.value) showDefaultList(); });
  q.addEventListener('input', () => { $('#btnClear').classList.toggle('hidden', !q.value); ui.chip = null; renderChips(); clearTimeout(searchTimer); searchTimer = setTimeout(() => runSearch(q.value), 300); });
  q.addEventListener('keydown', e => { if (e.key === 'Enter') { clearTimeout(searchTimer); runSearch(q.value); } if (e.key === 'Escape') { hideResults(); q.blur(); } });
  $('#btnClear').addEventListener('click', () => { q.value = ''; $('#btnClear').classList.add('hidden'); hideResults(); q.focus(); });
  $('#btnMenu').addEventListener('click', openSettings);
  // Voice search where the browser supports it (Safari on iPhone does).
  const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (SR) {
    const mic = $('#btnMic'); mic.classList.remove('hidden');
    let rec = null;
    mic.addEventListener('click', () => {
      if (rec) { rec.stop(); return; }
      rec = new SR(); rec.lang = 'en-US'; rec.interimResults = true; rec.maxAlternatives = 1;
      mic.classList.add('listening'); q.placeholder = 'Listening…';
      rec.onresult = e => {
        const text = Array.from(e.results).map(r => r[0].transcript).join('');
        q.value = text; $('#btnClear').classList.toggle('hidden', !text);
        if (e.results[e.results.length - 1].isFinal) runSearch(text);
      };
      rec.onerror = e => { if (e.error === 'not-allowed') toast('Allow microphone access to search by voice'); };
      rec.onend = () => { rec = null; mic.classList.remove('listening'); q.placeholder = 'Search Roadwise'; };
      try { rec.start(); } catch { rec = null; mic.classList.remove('listening'); }
    });
  }
  $('#btnLocate').addEventListener('click', () => { startLocation(true); enableCompass(); if (here) setFollow(!follow || ui.mode === 'nav'); else { toast('Finding your location…'); follow = true; $('#btnLocate').classList.add('follow'); } });
  $('#btnRecenter').addEventListener('click', () => setFollow(true));
  $('#btnReport').addEventListener('click', openReport);
  $('#btnShare').addEventListener('click', () => nav ? shareTrip() : openShare());
  $('#btnLayers').addEventListener('click', () => { settings.satellite = !settings.satellite; saveSettings(); applyTheme(); toast(settings.satellite ? 'Satellite view' : 'Map view', 1200); });
  renderChips();
  setInterval(() => { applyTheme(); syncReports(); saveLocalReports(); drawReports(); }, 60000);
}

function installTip() {
  const ios = /iPhone|iPad|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const standalone = navigator.standalone || matchMedia('(display-mode: standalone)').matches;
  if (!ios || standalone || store.get('tipDone')) return;
  const tip = h('div', { class: 'install-tip' }, h('b', {}, 'Install Roadwise on your iPhone'),
    'Tap the Share button ', h('b', { style: 'display:inline' }, '⎋'), ' in Safari, then ', h('b', { style: 'display:inline' }, 'Add to Home Screen'), '. It opens full-screen like an app.',
    h('div', { class: 'actions' }, h('button', { class: 'btn small primary', onclick: () => { tip.remove(); store.set('tipDone', true); } }, 'Got it')));
  document.body.append(tip);
}

function boot() {
  if (!window.maplibregl) { document.body.innerHTML = '<p style="padding:24px;font-family:sans-serif">Roadwise couldn\'t load the map library. Check your connection and reload.</p>'; return; }
  initMap(); wire(); drawReports();
  map.once('load', () => { syncReports(true); });
  // Start location quietly if the person already allowed it before.
  if (navigator.permissions?.query) navigator.permissions.query({ name: 'geolocation' }).then(s => { if (s.state === 'granted') startLocation(); }).catch(() => {});
  else if (store.get('hadFix')) startLocation();
  installTip();
  if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js').catch(() => {});
  // Expose a tiny hook for automated checks.
  window.roadwise = { ui, settings, get map() { return map; }, get nav() { return nav; }, get here() { return here; }, pick, planRoutes, startNav, endNav };
}
boot();
})();
