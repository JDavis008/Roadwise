// Roadwise service worker: caches the app itself plus every map tile you've looked at,
// so the app opens and the map still shows with no signal.
const VERSION = 'v2';
const SHELL = `rw-shell-${VERSION}`;
const TILES = 'rw-tiles';
const SHELL_FILES = ['./', 'index.html', 'style.css', 'app.js', 'manifest.webmanifest', 'icon.svg', 'icon-192.png', 'icon-512.png', 'apple-touch-icon.png',
  'https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.js', 'https://unpkg.com/maplibre-gl@4.7.1/dist/maplibre-gl.css'];
const MAX_TILES = 12000;

self.addEventListener('install', e => {
  e.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k.startsWith('rw-shell-') && k !== SHELL).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});

async function trim() {
  const c = await caches.open(TILES); const keys = await c.keys();
  if (keys.length > MAX_TILES) for (const k of keys.slice(0, keys.length - MAX_TILES)) await c.delete(k);
}
let puts = 0;

async function cacheFirst(req) {
  const c = await caches.open(TILES);
  const hit = await c.match(req);
  if (hit) return hit;
  const res = await fetch(req);
  if (res.ok) { c.put(req, res.clone()); if (++puts % 200 === 0) trim(); }
  return res;
}
async function networkFirst(req, cacheName) {
  const c = await caches.open(cacheName);
  try {
    const res = await fetch(req);
    if (res.ok) c.put(req, res.clone());
    return res;
  } catch (e) {
    const hit = await c.match(req, { ignoreSearch: req.mode === 'navigate' });
    if (hit) return hit;
    if (req.mode === 'navigate') { const idx = await c.match('index.html'); if (idx) return idx; }
    throw e;
  }
}

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === self.location.origin) { e.respondWith(networkFirst(req, SHELL)); return; }
  if (url.hostname === 'unpkg.com') { e.respondWith(caches.match(req).then(r => r || fetch(req))); return; }
  if (url.hostname === 'tiles.openfreemap.org') {
    // Tiles, fonts and sprites live under versioned paths and never change; styles and tile indexes can.
    const versioned = /\.(pbf|png|webp|json)$/.test(url.pathname) && !/^\/(styles|planet)\/?[^/]*$/.test(url.pathname);
    e.respondWith(versioned ? cacheFirst(req) : networkFirst(req, TILES));
    return;
  }
  if (url.hostname === 'server.arcgisonline.com') { e.respondWith(cacheFirst(req)); return; }
  // Search, routing and the report server always go to the network.
});
