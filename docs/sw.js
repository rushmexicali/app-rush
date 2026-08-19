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
//   v4 (19/jul/2026) — el boton de volver, fijo arriba de los entregados.
//   v5 (26/jul/2026) — entra la app de la caja (CRM/lealtad).
//   v6 (4/ago/2026) — la caja usa el feed de la Reolink (go2rtc/Tailscale),
//                     con respaldo a la camara del dispositivo si falla.
//   v7 (4/ago/2026) — elegir camara Exterior/Tablet + boton Regresar; se quita
//                     el boton de la camara nativa de Android.
//   v8 (15/ago/2026) — la caja se simplifica: buscador arriba, el ticket se
//                     elige antes de registrar, y se quita la captura manual
//                     de placa.
//   v9 (17/ago/2026) — la FOTO sale del stream principal de la Reolink
//                     (2560x1920) en vez del cuadro del feed chico (640x480).
//  v10 (17/ago/2026) — el FEED en vivo tambien pasa al principal: en el chico
//                     se veia mal en el tablet. Como el cuadro del feed ya
//                     sirve, la foto vuelve a ser instantanea.
//  v11 (19/ago/2026) — la caja avisa si la lectura de placa CORRIO o no
//                     (`leida`), para que una caida del servicio no quede
//                     disfrazada de "se intento y no se pudo" y el obrero de
//                     fondo pueda releer la foto solo (migracion 104).
//  v12 (19/ago/2026) — arreglos de la auditoria: la cola del supervisor deja
//                     de vaciarse ante un error, las peticiones tienen corte a
//                     los 20 s, el candado de pantalla se vuelve a pedir, y la
//                     caja pinta en rojo un 6to sin saldo antes de tocarlo.
var CACHE = "rush-v12";
var BASICOS = [
  "./", "./index.html", "./manifest.json",
  "./caja.html", "./caja.webmanifest",
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
        // Solo se guarda lo que salio BIEN. Sin este candado, un 404 con
        // cuerpo HTML —lo que devuelve Pages durante los segundos de un
        // despliegue— quedaba guardado, y despues se servia sin wifi como si
        // fuera la app. Es el arreglo que la revision del 3/ago dejo anotado.
        if (r && r.ok) {
          var copia = r.clone();
          caches.open(CACHE).then(function (c) { c.put(ev.request, copia); });
        }
        return r;
      })
      .catch(function () { return caches.match(ev.request); })
  );
});
