// =====================================================================
// RUSH Car Wash — Service worker
//
// Hace dos cosas:
//   1. Permite que Android ofrezca instalar la app en la pantalla de
//      inicio (Chrome lo exige para mostrar el aviso de instalacion).
//   2. Guarda la pantalla para que abra aunque el wifi del taller este
//      caido. Los DATOS siempre se piden a la red, nunca del cache: una
//      cola de carros vieja es peor que una pantalla vacia, porque el
//      supervisor no tendria como saber que esta viendo el pasado.
// =====================================================================

// Se sube la version cuando cambian los BASICOS: al activarse, el worker
// borra los caches con otro nombre, y asi los telefonos que ya tienen la
// app instalada reciben los archivos nuevos en vez de quedarse con los
// viejos guardados.
//   v2 (19/jul/2026) — entra el logo y los iconos de verdad.
//   v3 (19/jul/2026) — confirmar entrega, rechazos y lista de entregados.
var CACHE = "rush-v3";
var BASICOS = [
  "./", "./index.html", "./manifest.json",
  "./RUSH-Logo.png", "./icono-192.png", "./icono-512.png"
];

self.addEventListener("install", function (ev) {
  ev.waitUntil(
    caches.open(CACHE).then(function (c) { return c.addAll(BASICOS); })
      .then(function () { return self.skipWaiting(); })
  );
});

self.addEventListener("activate", function (ev) {
  ev.waitUntil(
    caches.keys().then(function (llaves) {
      return Promise.all(llaves.map(function (k) {
        if (k !== CACHE) return caches.delete(k);
      }));
    }).then(function () { return self.clients.claim(); })
  );
});

self.addEventListener("fetch", function (ev) {
  var url = new URL(ev.request.url);

  // Todo lo que sea de Supabase (la cola, los botones) va SIEMPRE a la
  // red. Nunca se sirve de cache.
  if (url.hostname.indexOf("supabase.co") >= 0) return;

  // La pantalla: se intenta la red primero para que un cambio de diseno
  // se vea al instante; si no hay red, se usa la copia guardada.
  ev.respondWith(
    fetch(ev.request)
      .then(function (r) {
        var copia = r.clone();
        caches.open(CACHE).then(function (c) { c.put(ev.request, copia); });
        return r;
      })
      .catch(function () { return caches.match(ev.request); })
  );
});
