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
//  v13 (19/ago/2026) — el corte de peticiones no aplica a /foto (esa ruta
//                     espera la lectura de placa y tarda mas a proposito).
//  v14 (19/ago/2026) — el SW solo cachea lo de ESTA pagina. Antes dejaba pasar
//                     el cuadro de la camara de la caja, y si el relay se caia
//                     servia la foto del carro ANTERIOR como si fuera la de
//                     ahora, con r.ok en true.
//  v15 (19/ago/2026) — del rechazo de entrega ya hay regreso: el que le pica
//                     por error vuelve a la decision sin cerrar la pantalla.
//  v16 (30/ago/2026) — la foto tambien lee el COLOR y la foto manda sobre la
//                     nota de caja (migracion 141). La caja pasa el color
//                     que leyo la camara junto con placa/marca/submarca/tipo.
//  v17 (31/ago/2026) — "Borrar unidad" deja de esperar: ya no se apaga
//                     hasta los 30 min sin asignar ni las 2 h secando.
//                     Queda habilitado desde el primer segundo, y los
//                     candados de tiempo tambien se fueron de la base.
//  v18 (5/sep/2026)  — la caja manda dos fotos: la grande solo se lee, la
//                     chica (1280 px) es la que se guarda. El bucket del
//                     plan estaba a 850 MB de 1,024 por las capturas de 800 KB.
//  v19 (5/sep/2026)  — arreglos de la auditoria del 2-5/sep en las dos
//                     pantallas: la cola dejaba de pintarse con el wifi lento,
//                     los botones quedaban muertos tras un fallo de red, la
//                     caja pinta la cortesia y avisa si la ficha ya existia.
//  v20 (6/sep/2026)  — las dos pantallas AVISAN cuando hay version nueva
//                     (actualizacion.js): un aviso rojo que al tocarlo recarga.
//                     Nada obligaba a la tablet a tomar un arreglo: el del
//                     Storage estuvo un dia entero desplegado sin llegar.
//                     ⚠️ Desde aqui, SUBIR ESTA VERSION es lo que avisa: una
//                     pantalla publicada sin subirla no le llega a nadie.
var CACHE = "rush-v20";
var BASICOS = [
  "./", "./index.html", "./manifest.json",
  "./caja.html", "./caja.webmanifest", "./actualizacion.js",
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

  // ⚠️ SOLO se cachea lo que es de esta misma pagina (el HTML, los iconos).
  // Antes se exceptuaba nada mas a Supabase, y eso dejaba pasar al cache el
  // cuadro de la camara de la caja: esa URL es IDENTICA en cada foto, asi que
  // si el relay se caia, el `catch` devolvia el JPEG GUARDADO —con r.ok en
  // true— y la caja leia la placa del CARRO ANTERIOR y se la pegaba al cliente
  // presente. La cajera veia el congelado con el spinner encima y no tenia
  // forma de saberlo.
  //
  // Se compara contra el origen en vez de listar hosts: un host nuevo (otra
  // camara, otro relay) queda protegido solo, sin que nadie se acuerde.
  if (url.origin !== self.location.origin) return;

  // La pantalla: se intenta la red primero para que un cambio de diseno
  // se vea al instante; si no hay red, se usa la copia guardada.
  //
  // ⚠️ `cache: "no-cache"` no apaga nada: obliga al navegador a REVALIDAR con
  // el servidor en vez de servir de su propio cache HTTP. Hace falta porque
  // GitHub Pages manda `max-age=600` en index.html, asi que "red primero"
  // podia devolver hasta 10 minutos de HTML viejo despues de publicar —
  // justo cuando se acaba de subir un arreglo. Pages contesta 304 cuando no
  // cambio, o sea que no cuesta datos.
  ev.respondWith(
    fetch(ev.request, { cache: "no-cache" })
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
