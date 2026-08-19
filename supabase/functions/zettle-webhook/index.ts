// =====================================================================
// RUSH Car Wash — Fase 1
// Edge Function: zettle-webhook
//
// Que hace: Zettle avisa aqui cada vez que se cobra una venta.
// Esta funcion lee el aviso y escribe una fila en la tabla "ventas".
// Esa fila es el carro que entra a la cola.
//
// IMPORTANTE al desplegar: apagar el interruptor "Verify JWT".
// Si no, Supabase rechaza el aviso de Zettle antes de que llegue aqui,
// porque Zettle no manda (ni puede mandar) un token de Supabase.
// =====================================================================

// npm: en vez de esm.sh — el arranque en frio es mas confiable (esm.sh a
// veces tardaba/fallaba al bootear y eso salia como HTTP 502 hacia Zettle).
import { createClient } from "npm:@supabase/supabase-js@2";

// Supabase inyecta estas variables solito dentro de la funcion.
// No hay que configurarlas a mano ni pegarlas aqui.
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  "";

const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
});

// Atajo para responder siempre en el mismo formato.
function responder(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Zettle manda la fecha como NUMERO de milisegundos (1784484296491), no como
// texto. Postgres no entiende ese formato y rechazaba la fila completa.
// Devuelve null si no se puede convertir: mejor una venta sin hora que
// una venta perdida.
function aFechaIso(valor: unknown): string | null {
  if (valor === null || valor === undefined) return null;

  if (typeof valor === "number") {
    // Puede venir en segundos o en milisegundos. Arriba de 1e12 son ms.
    const ms = valor > 1e12 ? valor : valor * 1000;
    const f = new Date(ms);
    return isNaN(f.getTime()) ? null : f.toISOString();
  }

  if (typeof valor === "string") {
    // A veces el numero viene envuelto en comillas.
    if (/^\d+$/.test(valor.trim())) return aFechaIso(Number(valor.trim()));
    const f = new Date(valor);
    return isNaN(f.getTime()) ? null : f.toISOString();
  }

  return null;
}

// El monto tambien puede venir como texto segun la version de la API.
function aCentavos(valor: unknown): number | null {
  if (typeof valor === "number" && isFinite(valor)) return valor;
  if (typeof valor === "string" && /^-?\d+$/.test(valor.trim())) {
    return Number(valor.trim());
  }
  return null;
}

// Deja constancia de un aviso: los que se descartan (para que dejen de
// perderse en silencio) y, mientras se aprende el esquema de firma de Zettle,
// tambien las CABECERAS de los buenos.
//
// ⚠️ NUNCA puede tumbar una venta. Va envuelto en try/catch y su fallo se
// traga a proposito: es una bitacora, no el camino del dinero. La leccion de
// la fecha en milisegundos (§7 del CLAUDE.md) aplicada al reves — ahi una
// venta se perdio por un campo secundario; aqui un campo secundario no puede
// perder una venta.
async function anotar(
  db: ReturnType<typeof createClient>,
  req: Request,
  motivo: string,
  evento: string | null,
  crudo: string | null,
) {
  try {
    const cab: Record<string, string> = {};
    for (const [k, v] of req.headers) {
      // El cuerpo ya se guarda aparte; aqui solo interesa el sobre. La firma
      // se guarda entera a proposito: es justo lo que hace falta ver para
      // implementar la verificacion sin adivinar.
      if (k.toLowerCase() === "authorization" || k.toLowerCase() === "cookie") continue;
      cab[k] = v;
    }
    await db.from("webhook_bitacora").insert({
      motivo,
      evento,
      cabeceras: cab,
      // ⏳ TEMPORAL: el cuerpo CRUDO de un aviso bueno tambien se guarda, para
      // poder calcular el HMAC contra la firma real y descubrir QUE es
      // exactamente lo que Zettle firma (el cuerpo entero? el payload? el
      // payload mas el timestamp?). Con `ventas.payload` no alcanza: ahi esta
      // el JSON ya parseado, y volver a serializarlo NO da los mismos bytes.
      // Se quita en cuanto la verificacion este implementada.
      crudo: (crudo ?? "").slice(0, 8000),
    });
  } catch (e) {
    console.error("No se pudo anotar en la bitacora (no afecta la venta):", e);
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  // Abrir la URL en el navegador cae aqui. Sirve para confirmar
  // "si, la funcion esta viva" sin tener que cobrar nada.
  if (req.method === "GET") {
    return responder({ ok: true, servicio: "zettle-webhook" });
  }

  if (req.method !== "POST") {
    return responder({ ok: true, nota: "metodo ignorado" });
  }

  // ---------------------------------------------------------------
  // 1) Leer el aviso
  // ---------------------------------------------------------------
  let crudo: string;
  try {
    crudo = await req.text();
  } catch (e) {
    console.error("No se pudo leer el cuerpo del aviso:", e);
    await anotar(db, req, "cuerpo_ilegible", null, null);
    return responder({ ok: true, nota: "cuerpo ilegible" });
  }

  let evento: Record<string, unknown>;
  try {
    evento = JSON.parse(crudo);
  } catch (e) {
    console.error("El aviso no es JSON valido:", e, "| crudo:", crudo.slice(0, 500));
    // 200 a proposito: reintentar no lo va a arreglar. Ver nota al final.
    await anotar(db, req, "json_invalido", null, crudo);
    return responder({ ok: true, nota: "json invalido" });
  }

  // ---------------------------------------------------------------
  // 2) Abrir el payload
  // Zettle mete los datos de la venta como TEXTO dentro del aviso,
  // asi que hay que parsearlo una segunda vez. Se contempla tambien
  // que algun dia venga ya como objeto, para que no truene.
  // ---------------------------------------------------------------
  let datos: Record<string, unknown> | null = null;
  const bruto = (evento as any)?.payload;

  if (typeof bruto === "string") {
    try {
      datos = JSON.parse(bruto);
    } catch (e) {
      console.error("El payload venia como texto pero no es JSON:", e);
    }
  } else if (bruto && typeof bruto === "object") {
    datos = bruto as Record<string, unknown>;
  }

  const nombreEvento = (evento as any)?.eventName ?? "(sin nombre)";

  // ---------------------------------------------------------------
  // 3) Sacar los datos que nos importan
  // ---------------------------------------------------------------
  const purchaseUuid =
    (datos as any)?.purchaseUUID ??
    (datos as any)?.purchaseUuid ??
    null;

  // Zettle manda el monto en CENTAVOS (12300 = $123.00). Lo pasamos a pesos.
  const centavos = aCentavos((datos as any)?.amount);
  const monto = centavos === null ? null : centavos / 100;

  const recibidoEn =
    aFechaIso((datos as any)?.timestamp) ??
    aFechaIso((evento as any)?.timestamp);

  if (recibidoEn === null) {
    // No tumbamos la venta por esto. Se guarda sin hora y queda el aviso.
    console.warn(
      "No se entendio la fecha del aviso. Se guarda sin hora. valor:",
      (datos as any)?.timestamp ?? (evento as any)?.timestamp,
    );
  }

  // Al crear la suscripcion, Zettle manda un aviso de prueba llamado
  // TestMessage que no trae venta. Es normal, no es un error.
  if (nombreEvento === "TestMessage") {
    console.log("Aviso de prueba de Zettle (TestMessage). Todo bien.");
    return responder({ ok: true, nota: "test message" });
  }

  // Sin purchase_uuid no podemos guardar (es la llave unica que evita
  // duplicados). Lo registramos y respondemos 200: si el aviso viene
  // incompleto, mandarlo otra vez tampoco lo va a completar.
  if (!purchaseUuid) {
    console.error(
      "Aviso sin purchaseUUID. evento:", nombreEvento,
      "| crudo:", crudo.slice(0, 500),
    );
    await anotar(db, req, "sin_purchase_uuid", nombreEvento, crudo);
    return responder({ ok: true, nota: "sin purchase_uuid" });
  }

  // ---------------------------------------------------------------
  // 4) Guardar
  // upsert + ignoreDuplicates: si Zettle manda el mismo aviso dos veces
  // (lo hace cuando no le respondemos a tiempo), la segunda no crea una
  // fila repetida ni truena. El carro entra a la cola una sola vez.
  // ---------------------------------------------------------------
  try {
    const { error } = await db
      .from("ventas")
      .upsert(
        {
          purchase_uuid: purchaseUuid,
          monto: monto,
          recibido_en: recibidoEn,
          payload: evento, // el aviso completo, sin tocar
        },
        { onConflict: "purchase_uuid", ignoreDuplicates: true },
      );

    if (error) {
      // Aqui SI devolvemos 500 a proposito. Ver nota al final.
      console.error("Fallo al guardar la venta", purchaseUuid, ":", error);
      return responder({ ok: false, error: error.message }, 500);
    }
  } catch (e) {
    // Una excepcion de red al hablar con la base (fetch que truena) tumbaba la
    // funcion con un 502 sin atrapar. Ahora se atrapa y se responde 500, que
    // es reintentable: Zettle reintenta y la venta se recupera, no se pierde.
    console.error("Excepcion al guardar la venta", purchaseUuid, ":", e);
    return responder({ ok: false, error: "excepcion al guardar" }, 500);
  }

  console.log("Venta guardada:", purchaseUuid, "| monto:", monto);

  // ⏳ TEMPORAL — quitar en cuanto se implemente la verificacion de firma.
  //
  // Guarda las CABECERAS de un aviso bueno. Sirve para una sola cosa: ver como
  // firma Zettle de verdad. La llave `ZETTLE_SIGNING_KEY` esta guardada desde
  // el dia uno "para verificar firmas mas adelante" y ninguna funcion la lee;
  // no hay documentacion publica confiable del esquema, y adivinarlo aqui
  // significaria rechazar ventas reales si me equivoco. Con una venta real
  // basta para saberlo.
  //
  // No guarda el cuerpo (`crudo` va nulo cuando el motivo es 'ok'), asi que no
  // duplica datos de venta: eso ya vive completo en `ventas.payload`.
  await anotar(db, req, "ok", nombreEvento, null);

  return responder({ ok: true });
});

// =====================================================================
// NOTA SOBRE LOS CODIGOS DE RESPUESTA (importante)
//
// Zettle reintenta el aviso cuando no le respondemos 200, y desactiva el
// destino si falla siempre. Por eso casi todo responde 200. Pero hay una
// excepcion a proposito:
//
//   - Aviso mal formado / sin datos  -> 200. Reintentarlo daria exactamente
//     el mismo aviso roto. Insistir no arregla nada y solo ensucia los logs.
//
//   - Falla al guardar en la base    -> 500. Esto suele ser pasajero (la base
//     tardo, se reinicio, hubo un pico). Aqui SI queremos que Zettle reintente:
//     es la diferencia entre recuperar la venta y perderla para siempre.
//
// El riesgo de responder 200 a todo es silencioso: la venta se pierde y nadie
// se entera. El riesgo del 500 es visible: aparece en los logs y se atiende.
// =====================================================================
