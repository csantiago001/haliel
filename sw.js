// sw.js — Haliel PWA
const VERSION = 'haliel-v7';   // ⬅️ SÚBELE EL NÚMERO EN CADA DESPLIEGUE (v5, v6, …)

// Solo se guardan en caché archivos estáticos: la app y las librerías de CDN.
// Los datos (Supabase, Telegram) SIEMPRE van a la red para no mostrar información vieja.
const CDN_ESTATICOS = [
  'fonts.googleapis.com', 'fonts.gstatic.com', 'cdnjs.cloudflare.com',
  'cdn.jsdelivr.net', 'cdn.sheetjs.com'
];

self.addEventListener('install', () => {
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
  if (req.method !== 'GET') return;                       // POST/PATCH/DELETE: directo a la red
  const url = new URL(req.url);
  const mismoOrigen = url.origin === self.location.origin;
  if (!mismoOrigen && !CDN_ESTATICOS.includes(url.hostname)) return; // Supabase, Telegram, etc.

  const esHTML = req.mode === 'navigate' ||
                 (req.headers.get('accept') || '').includes('text/html');

  // HTML / navegación: RED PRIMERO → siempre el código más nuevo; caché solo sin internet
  if (esHTML) {
    e.respondWith((async () => {
      try {
        const fresh = await fetch(req);
        if (fresh.ok) {
          const copia = fresh.clone();
          caches.open(VERSION).then(c => c.put(req, copia));
        }
        return fresh;
      } catch (_) {
        return (await caches.match(req)) ||
               (await caches.match(new URL('./', self.registration.scope).href)) ||
               (await caches.match(new URL('./index.html', self.registration.scope).href)) ||
               Response.error();
      }
    })());
    return;
  }

  // Recursos estáticos: caché primero, con actualización en segundo plano
  e.respondWith((async () => {
    const cached = await caches.match(req);
    const net = fetch(req).then(r => {
      if (r && (r.ok || r.type === 'opaque')) {
        const copia = r.clone();                            // clonar antes de entregar la respuesta
        caches.open(VERSION).then(c => c.put(req, copia));
      }
      return r;
    }).catch(() => cached || Response.error());
    if (cached) { e.waitUntil(net.catch(() => {})); return cached; }
    return net;
  })());
});
