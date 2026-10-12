// =====================================================================
// RUSH Car Wash — Aviso de version nueva
//
// Lo cargan la cola del supervisor (index.html) y la caja (caja.html). Es UN
// archivo y no un bloque copiado en cada pantalla a proposito: la regla de
// "cuando hay version nueva" tiene que vivir en un solo lugar.
//
// POR QUE EXISTE (6/sep/2026). El arreglo del Storage se desplego el 5/sep a
// las 16:53 y la caja siguio mandando fotos de 800 KB hasta que el dueno
// reinicio la tablet a las 11:10 del dia siguiente. Pages servia lo nuevo y el
// service worker nuevo ya estaba instalado, pero NADA obliga a una PWA que
// nunca se cierra a tomar una version nueva: el JS que ya corre sigue
// corriendo hasta que alguien recarga. Y en el taller nadie recarga.
//
// COMO FUNCIONA.
//   1. Registra sw.js (antes lo hacia cada pantalla por su cuenta).
//   2. Cada 5 minutos —y cada vez que la app vuelve al frente— le pide al
//      navegador que revise si sw.js cambio. Hace falta pedirlo: por si solo
//      el navegador revisa al navegar o cada 24 h, y estas pantallas se
//      quedan abiertas todo el turno sin navegar a ningun lado.
//   3. Si sw.js cambio (version nueva = otro nombre de CACHE), el worker
//      nuevo se instala, y en cuanto llega a "installed" se pinta el aviso
//      rojo. Se exige que la pagina YA tuviera un worker: sin eso, la primera
//      instalacion de la vida —que tambien pasa por "installed"— pediria
//      reiniciar una app recien abierta.
//   4. Tocar el aviso recarga la pagina. Con skipWaiting + clients.claim en
//      sw.js, la pagina recargada ya la sirve el worker nuevo, y como la
//      estrategia es red-primero, trae el HTML nuevo.
//
// NO recarga sola, a proposito: una recarga a media captura, con el cliente
// enfrente, le pierde a la cajera lo que estaba haciendo (y al supervisor la
// asignacion que va a la mitad). El aviso es rojo y grande para que se vea;
// el toque lo decide la persona, entre un cliente y otro.
//
// ⚠️ Lo que dispara el aviso es que sw.js CAMBIE. Publicar una pantalla sin
// subirle la version a sw.js no avisa a nadie; scripts/publicar-docs.sh se
// niega a publicar en ese caso.
//
// Cada pantalla pone un <div id="aviso-version"></div> donde quiere el aviso.
// Va EN EL FLUJO de la pagina y no fijo encima de todo: un elemento fijo
// taparia la barra de confirmar de la pantalla de asignar, o el boton de
// Ayuda de la caja.
// =====================================================================
(function () {
  if (!("serviceWorker" in navigator)) return;

  var CADA_MS = 5 * 60 * 1000;

  var estilo = document.createElement("style");
  estilo.textContent =
    "#aviso-version{display:none}" +
    "#aviso-version.visible{display:block;background:#da3633;color:#fff;text-align:center;" +
      "border-radius:14px;padding:14px 12px;margin:0 0 12px;cursor:pointer;" +
      "box-shadow:0 4px 14px rgba(0,0,0,.45)}" +
    "#aviso-version .av-titulo{font-size:22px;font-weight:900;letter-spacing:.5px}" +
    "#aviso-version .av-sub{font-size:17px;font-weight:700;margin-top:4px}";
  document.head.appendChild(estilo);

  function avisar() {
    var e = document.getElementById("aviso-version");
    if (!e || e.classList.contains("visible")) return;
    e.innerHTML =
      '<div class="av-titulo">HAY UNA ACTUALIZACIÓN</div>' +
      '<div class="av-sub">Toca aquí para reiniciar la app</div>';
    e.classList.add("visible");
    e.addEventListener("click", function () { location.reload(); });
  }

  // Un worker que se esta instalando: en cuanto quede instalado, avisar.
  function seguir(w) {
    if (!w) return;
    w.addEventListener("statechange", function () {
      if (w.state === "installed" && navigator.serviceWorker.controller) avisar();
    });
  }

  function vigilar(reg) {
    reg.addEventListener("updatefound", function () { seguir(reg.installing); });
    // Por si el nuevo ya venia instalandose o esperando antes de llegar aqui.
    if (navigator.serviceWorker.controller) {
      if (reg.waiting) avisar();
      seguir(reg.installing);
    }
    function revisar() { reg.update().catch(function () {}); }
    setInterval(revisar, CADA_MS);
    document.addEventListener("visibilitychange", function () {
      if (!document.hidden) revisar();
    });
  }

  window.addEventListener("load", function () {
    navigator.serviceWorker.register("sw.js").then(vigilar).catch(function () {});
  });
})();
