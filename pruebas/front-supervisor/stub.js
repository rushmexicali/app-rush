// Arnes de pruebas del front del supervisor. NO toca la API real:
// reemplaza window.fetch antes de que corra el script de la app.
// La app se sirve byte a byte igual que en produccion salvo la linea
// que carga este archivo.
(function () {
  try { localStorage.setItem("rush_codigo", "PRUEBA"); } catch (e) {}

  var PIX = "data:image/gif;base64,R0lGODlhAQABAIAAAP///wAAACH5BAEAAAAALAAAAAABAAEAAAICRAEAOw==";

  function haceRato(min) { return new Date(Date.now() - min * 60000).toISOString(); }

  var LAB = window.LAB = {
    colgado: false,      // la peticion nunca responde (wifi COLGADO, no caido)
    falla: false,        // responde 500
    retraso: 0,          // ms antes de responder
    log: [],             // rutas pedidas
    enVuelo: 0,
    rutas: {}            // sobreescribir la respuesta de una ruta
  };

  var COLA = {
    carros: [
      {
        id: 101, estado: "secando", linea: 2, es_express: false,
        producto: "Completo RUSH", variante: "Chico", aviso: null, a_mano: false,
        tipo_unidad: "automovil", color: "BLANCO", marca: "TOYOTA", submarca: "COROLLA",
        cliente: null, placa: "ABC1234", placa_display: "ABC-123-4",
        etapa_inicio: haceRato(12), limite: 2100,
        ausentes: [], secadores: ["Jesus Gil"], secador_ids: [7],
        foto: PIX
      },
      {
        id: 102, estado: "prelavado", linea: null, es_express: true,
        producto: "Express", variante: "Express", aviso: null, a_mano: false,
        tipo_unidad: "camioneta", color: "NEGRA", marca: null, submarca: null,
        cliente: null, placa: null, placa_display: null,
        etapa_inicio: haceRato(3), limite: 1200,
        ausentes: [], secadores: [], secador_ids: [],
        foto: null
      }
    ],
    servidor: new Date().toISOString()
  };

  var ENTREGADOS = {
    carros: [
      { id: 201, estado: "entregado", producto: "Completo RUSH", variante: "Chico",
        tipo_unidad: "automovil", color: "GRIS", marca: "HONDA", submarca: "CIVIC",
        placa: "BVJ113A", linea: 3, es_express: false,
        creado_en: haceRato(120), entregado_en: haceRato(60) },
      { id: 202, estado: "entregado", producto: "Express", variante: "Express",
        tipo_unidad: "camioneta", color: "ROJA", marca: null, submarca: null,
        placa: null, linea: 1, es_express: true,
        creado_en: haceRato(200), entregado_en: haceRato(180) }
    ]
  };

  var SECADORES = {
    secadores: [
      { id: 7,  mostrar: "Jesus Gil",     iniciales: "JG", color: "#3fb950", estado: "activo",   rol: "secador",  orden: 0 },
      { id: 8,  mostrar: "Pablo Cruz",    iniciales: "PC", color: "#58a6ff", estado: "activo",   rol: "secador",  orden: 0 },
      { id: 9,  mostrar: "Luis Luna",     iniciales: "LL", color: "#d29922", estado: "descanso", rol: "secador",  orden: 0 },
      { id: 10, mostrar: "Guillermo Lara", iniciales: "GL", color: "#a371f7", estado: "activo",  rol: "supervisor", orden: 1 }
    ],
    fuera: 2
  };

  function detalle(id, enCurso) {
    if (enCurso) {
      return {
        id: id, producto: "Completo RUSH", variante: "Chico", linea: 2,
        tipo_unidad: "automovil", color: "BLANCO", marca: "TOYOTA", submarca: "COROLLA",
        placa: "ABC1234", placa_display: "ABC-123-4", es_express: false, aviso: null, a_mano: false,
        creado_en: haceRato(40), entregado_en: null,
        prelavado_seg: 900, tunel_seg: 242, secando_seg: null, total_seg: null,
        abierta_etapa: "secando", abierta_inicio: haceRato(12),
        secadores: ["Jesus Gil"], foto: PIX,
        cerrado_automaticamente: false, tiempo_imposible: false
      };
    }
    return {
      id: id, producto: "Completo RUSH", variante: "Chico", linea: 3,
      tipo_unidad: "automovil", color: "GRIS", marca: "HONDA", submarca: "CIVIC",
      placa: "BVJ113A", placa_display: "BVJ-113-A", es_express: false, aviso: null, a_mano: false,
      creado_en: haceRato(120), entregado_en: haceRato(60),
      prelavado_seg: 800, tunel_seg: 242, secando_seg: 2100, total_seg: 3600,
      abierta_etapa: null, abierta_inicio: null,
      secadores: ["Jesus Gil", "Pablo Cruz"], foto: PIX,
      cerrado_automaticamente: false, tiempo_imposible: false
    };
  }

  function cuerpoDe(ruta, busca) {
    if (LAB.rutas[ruta] !== undefined) return LAB.rutas[ruta];
    if (ruta === "/cola") return COLA;
    if (ruta === "/entregados") return ENTREGADOS;
    if (ruta === "/secadores") return SECADORES;
    if (ruta === "/reportes") return { hoy: "2026-08-24", dias: [{ fecha: "2026-08-24" }, { fecha: "2026-08-23" }, { fecha: "2026-08-22" }] };
    if (ruta === "/carro") return detalle(Number(busca.get("id") || 0), Number(busca.get("id")) === 101);
    return { ok: true };
  }

  function respuesta(cuerpo, estado) {
    var texto = JSON.stringify(cuerpo);
    return {
      ok: estado >= 200 && estado < 300,
      status: estado,
      json: function () { return Promise.resolve(JSON.parse(texto)); },
      text: function () { return Promise.resolve(texto); }
    };
  }

  window.fetch = function (url, opciones) {
    opciones = opciones || {};
    var u = String(url);
    var corte = u.indexOf("/functions/v1/app");
    var resto = corte >= 0 ? u.slice(corte + "/functions/v1/app".length) : u;
    var partes = resto.split("?");
    var ruta = partes[0];
    var busca = new URLSearchParams(partes[1] || "");

    LAB.log.push({ ruta: ruta, t: Date.now(), metodo: opciones.method || "GET" });
    LAB.enVuelo++;

    return new Promise(function (resolver, rechazar) {
      var listo = false;
      function terminar(fn) { if (listo) return; listo = true; LAB.enVuelo--; fn(); }

      if (opciones.signal) {
        opciones.signal.addEventListener("abort", function () {
          terminar(function () {
            var e = new Error("Abortado"); e.name = "AbortError"; rechazar(e);
          });
        });
      }

      // Wifi COLGADO: la conexion se abre y nunca contesta. No es lo mismo
      // que caido (que rechaza de inmediato).
      if (LAB.colgado) return;

      setTimeout(function () {
        terminar(function () {
          if (LAB.falla) return resolver(respuesta({ ok: false, error: "falla de prueba" }, 500));
          resolver(respuesta(cuerpoDe(ruta, busca), 200));
        });
      }, LAB.retraso);
    });
  };
})();

// --- Rutas de la pantalla de la CAJA ---------------------------------
// El mismo stub sirve las dos pantallas: caja.html y index.html hablan con
// el mismo Edge Function, asi que una sola tabla de respuestas alcanza.
(function () {
  var LAB = window.LAB;
  if (!LAB) return;

  // Clientes falsos: 40 "Lopez" para poder ejercitar el recorte de 25 y el
  // aviso de "se muestran 25 de N" que la 134 hizo posible.
  var PERSONAS = [];
  for (var i = 1; i <= 40; i++) {
    PERSONAS.push({
      id: 1000 + i,
      nombre: "JUAN LOPEZ " + i,
      placas: i % 3 === 0 ? ["ABC" + (1000 + i)] : [],
      lealtad: { visitas_totales: i, lavados_pagados: i, canjes: 0, disponibles: 0, faltan: 6 - (i % 6) }
    });
  }

  function horaHace(min) { return new Date(Date.now() - min * 60000).toISOString(); }

  LAB.tickets = {
    tickets: [
      { carro_id: 101, ticket: "27401", monto: "270", contenido: "Completo RUSH · Chico",
        hora: horaHace(3), placa: "ABC-123-4", motivo: null, clase: null },
      { carro_id: 102, ticket: "27400", monto: "160", contenido: "Express",
        hora: horaHace(9), placa: null, motivo: null, clase: null },
      { carro_id: 103, ticket: "27399", monto: "0", contenido: "Gratis · 6to Lavado",
        hora: horaHace(20), placa: null, motivo: null, clase: "canje" }
    ]
  };

  var fetchBase = window.fetch;
  window.fetch = function (url, opciones) {
    var u = String(url);
    var corte = u.indexOf("/functions/v1/app");
    var resto = corte >= 0 ? u.slice(corte + "/functions/v1/app".length) : u;
    var partes = resto.split("?");
    var ruta = partes[0];
    var busca = new URLSearchParams(partes[1] || "");

    var propio = null;
    if (ruta === "/tickets-recientes") propio = LAB.tickets;
    else if (ruta === "/personas") {
      if (busca.get("recientes") !== null) propio = { personas: PERSONAS.slice(0, 10) };
      else if (busca.get("q") !== null) {
        var q = (busca.get("q") || "").toLowerCase();
        var casan = PERSONAS.filter(function (p) { return p.nombre.toLowerCase().indexOf(q) >= 0; });
        // El backend recorta a 25 y manda el total aparte (migracion 134).
        propio = { personas: casan.slice(0, 25), total: casan.length, limite: 25 };
      } else propio = { personas: [] };
    }
    else if (ruta === "/historial") propio = { visitas: [] };

    if (propio === null) return fetchBase(url, opciones);

    LAB.log.push({ ruta: ruta, t: Date.now(), metodo: (opciones && opciones.method) || "GET" });
    return new Promise(function (resolver, rechazar) {
      var listo = false;
      function terminar(fn) { if (listo) return; listo = true; fn(); }
      if (opciones && opciones.signal) {
        opciones.signal.addEventListener("abort", function () {
          terminar(function () { var e = new Error("Abortado"); e.name = "AbortError"; rechazar(e); });
        });
      }
      if (LAB.colgado) return;
      setTimeout(function () {
        terminar(function () {
          var cuerpo = LAB.falla ? { ok: false, error: "falla de prueba" } : propio;
          var estado = LAB.falla ? 500 : (LAB.estado || 200);
          var texto = JSON.stringify(cuerpo);
          resolver({
            ok: estado >= 200 && estado < 300,
            status: estado,
            json: function () { return Promise.resolve(JSON.parse(texto)); },
            text: function () { return Promise.resolve(texto); }
          });
        });
      }, LAB.retraso);
    });
  };
})();
