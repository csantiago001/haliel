// sw.js — Haliel PWA
// La versión la cambia tools/nueva-version.py en cada publicación (junto con index.html y version.json)
const VERSION = 'haliel-2026.10.27.4';

// Librerías externas con versión fija (nunca cambian): se guardan para que la app cargue rápido.
// El código de la app (index.html) SIEMPRE se pide a internet sin copias; la copia guardada
// solo se usa si no hay conexión. Los datos (Supabase, Telegram) nunca pasan por aquí.
const CDN_ESTATICOS = [
  'fonts.googleapis.com', 'fonts.gstatic.com', 'cdnjs.cloudflare.com',
  'cdn.jsdelivr.net', 'fastly.jsdelivr.net', 'cdn.sheetjs.com'
];

self.addEventListener('install', () => {
  self.skipWaiting();          // el SW nuevo no se queda "esperando"
});

self.addEventListener('activate', e => e.waitUntil((async () => {
  const keys = await caches.keys();
  await Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))); // borra copias viejas
  await self.clients.claim();  // toma control inmediato de la app abierta
})()));

self.addEventListener('message', e => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});

// Pide a internet saltándose cualquier copia del navegador
const sinCopias = req => fetch(new Request(req.url, { method: 'GET', cache: 'no-store', credentials: 'same-origin', redirect: 'follow' }));

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;                       // POST/PATCH/DELETE: directo a la red
  if (req.headers.has('range') || req.destination === 'video' || req.destination === 'audio') return; // el video de la intro lo maneja el navegador
  const url = new URL(req.url);
  const mismoOrigen = url.origin === self.location.origin;
  if (!mismoOrigen && !CDN_ESTATICOS.includes(url.hostname)) return; // Supabase, Telegram, etc.
  if (mismoOrigen && /\/(version\.json|sw\.js)$/.test(url.pathname)) return; // siempre directo, nunca se guardan

  const esHTML = req.mode === 'navigate' || (req.headers.get('accept') || '').includes('text/html');

  // Archivos de la app (página, logos, manifiesto): SIEMPRE de internet, sin copias.
  // Se guarda una copia solo para poder abrir sin conexión.
  if (mismoOrigen) {
    e.respondWith((async () => {
      try {
        const fresh = await sinCopias(req);
        if (fresh.ok) {
          const copia = fresh.clone();
          const clave = esHTML ? new URL('./', self.registration.scope).href : req.url;
          caches.open(VERSION).then(c => c.put(clave, copia));
        }
        return fresh;
      } catch (_) {
        return (await caches.match(esHTML ? new URL('./', self.registration.scope).href : req.url)) ||
               (await caches.match(req)) || Response.error();
      }
    })());
    return;
  }

  // Librerías externas (versión fija): copia guardada primero, actualizando en segundo plano
  e.respondWith((async () => {
    const cached = await caches.match(req);
    const net = fetch(req).then(r => {
      if (r && (r.ok || r.type === 'opaque')) {
        const copia = r.clone();
        caches.open(VERSION).then(c => c.put(req, copia));
      }
      return r;
    }).catch(() => cached || Response.error());
    if (cached) { e.waitUntil(net.catch(() => {})); return cached; }
    return net;
  })());
});
