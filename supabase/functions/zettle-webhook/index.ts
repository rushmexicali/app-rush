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

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

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
    return responder({ ok: true, nota: "cuerpo ilegible" });
  }

  let evento: Record<string, unknown>;
  try {
    evento = JSON.parse(crudo);
  } catch (e) {
    console.error("El aviso no es JSON valido:", e, "| crudo:", crudo.slice(0, 500));
    // 200 a proposito: reintentar no lo va a arreglar. Ver nota al final.
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
    return responder({ ok: true, nota: "sin purchase_uuid" });
  }

  // ---------------------------------------------------------------
  // 4) Guardar
  // upsert + ignoreDuplicates: si Zettle manda el mismo aviso dos veces
  // (lo hace cuando no le respondemos a tiempo), la segunda no crea una
  // fila repetida ni truena. El carro entra a la cola una sola vez.
  // ---------------------------------------------------------------
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

  console.log("Venta guardada:", purchaseUuid, "| monto:", monto);
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
