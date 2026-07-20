// sw.js — Haliel PWA
const VERSION = 'haliel-v3';   // ⬅️ SÚBELE EL NÚMERO EN CADA DESPLIEGUE (v4, v5, …)

self.addEventListener('install', e => {
  self.skipWaiting();          // el SW nuevo no se queda "esperando"
});

self.addEventListener('activate', e => e.waitUntil((async () => {
  const keys = await caches.keys();
  await Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))); // borra cachés viejas
  await self.clients.claim();  // toma control inmediato de la app abierta
})()));

self.addEventListener('message', e => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', e => {
  const req = e.request;
  const esHTML = req.mode === 'navigate' ||
                 (req.headers.get('accept') || '').includes('text/html');

  // HTML / navegación: RED PRIMERO → siempre el código más nuevo; caché solo sin internet
  if (esHTML) {
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        const c = await caches.open(VERSION);
        c.put(req, fresh.clone());
        return fresh;
      } catch (_) {
        return (await caches.match(req)) || (await caches.match('/')) || Response.error();
      }
    })());
    return;
  }

  // Resto de recursos: caché primero, con relleno en segundo plano
  e.respondWith((async () => {
    const cached = await caches.match(req);
    const net = fetch(req).then(r => {
      caches.open(VERSION).then(c => c.put(req, r.clone()));
      return r;
    }).catch(() => cached);
    return cached || net;
  })());
});
