/* humm.. service worker: keeps the app opening even with no signal */
const CACHE = 'humm-v11';
const CORE = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './maskable-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(CORE)).then(() => self.skipWaiting())); });
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
