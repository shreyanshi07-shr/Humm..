/* humm.. service worker: keeps the app opening even with no signal */
const CACHE = 'humm-v16';
const CORE = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './maskable-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting())); });
self.addEventListener('message', e => { if (e.data === 'skip') self.skipWaiting(); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE && k !== 'humm-shared').map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const req = e.request, url = new URL(req.url);
  // an MP3 shared into humm.. from WhatsApp / Files: keep it, then open the app to add it
  if (req.method === 'POST' && url.pathname.endsWith('/share-target')) {
    e.respondWith((async () => {
      try {
        const fd = await req.formData(), files = fd.getAll('song').filter(f => f && f.size);
        const c = await caches.open('humm-shared');
        for (let i = 0; i < files.length; i++) {
          const f = files[i];
          await c.put('shared-song-' + Date.now() + '-' + i, new Response(f, { headers: { 'content-type': f.type || 'audio/mpeg', 'x-name': encodeURIComponent(f.name || 'song.mp3') } }));
        }
      } catch (err) {}
      return Response.redirect(new URL('./?shared=1', self.registration.scope).href, 303);
    })());
    return;
  }
  if (req.method !== 'GET') return;
  if (req.mode === 'navigate') {   // page: fresh when online, cached when not
    e.respondWith(fetch(req).then(r => { const c = r.clone(); caches.open(CACHE).then(x => x.put('./index.html', c)); return r; })
      .catch(() => caches.match('./index.html')));
    return;
  }
  const appFile = url.origin === location.origin && !url.search && /\.(png|webmanifest|js|css|woff2?|svg|jpg)$/i.test(url.pathname);
  if (appFile || /fonts\.(googleapis|gstatic)\.com$/.test(url.hostname)) {   // app files + fonts: cache first
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => { if (r.ok || r.type === 'opaque') { const c = r.clone(); caches.open(CACHE).then(x => x.put(req, c)); } return r; })));
  }
});

/* phone notifications from your person: a note, a new song, "started listening", "joined you" */
self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data ? e.data.text() : '' }; }
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (wins.some(w => w.visibilityState === 'visible')) return;   // the app is open on screen: it shows this itself
    await self.registration.showNotification(d.title || 'humm..', {
      body: d.body || '', tag: d.tag || 'humm', renotify: true,
      badge: new URL('badge-96.png', self.registration.scope).href,
      data: { open: d.open || '', type: d.type || '' }
    });
  })());
});
self.addEventListener('notificationclick', e => {
  e.notification.close();
  const dt = e.notification.data || {};
  const open = e.action || dt.open || (dt.type === 'listening' || dt.type === 'together' ? 'join' : dt.type === 'song' ? 'songs' : '');
  e.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    const w = wins.find(x => x.url.startsWith(self.registration.scope));
    if (w) { await w.focus(); if (open) w.postMessage({ type: 'open', open }); return; }
    await self.clients.openWindow(new URL(open ? './?open=' + open : './', self.registration.scope).href);
  })());
});
