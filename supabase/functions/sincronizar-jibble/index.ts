// =====================================================================
// RUSH Car Wash — Fase 3
// Edge Function: sincronizar-jibble
//
// Pregunta a Jibble quien esta checado y lo deja guardado en la base.
// Corre sola cada minuto.
//
// POR QUE SONDEAR Y NO WEBHOOKS: se probaron los tres endpoints de
// webhooks de Jibble el 19/jul/2026 y los tres dan 404. No existen en
// esta cuenta. Lo que Zapier llama "webhook de Jibble" es Zapier
// preguntando cada rato, igual que esto.
//
// Ademas conviene: un aviso perdido dejaria a alguien fuera de la lista
// sin que nadie se entere. Preguntar se corrige solo — si una consulta
// falla, la siguiente la arregla.
//
// Desplegar:  supabase functions deploy sincronizar-jibble --no-verify-jwt
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  "";

const JIBBLE_ID     = Deno.env.get("JIBBLE_CLIENT_ID") ?? "";
const JIBBLE_SECRET = Deno.env.get("JIBBLE_CLIENT_SECRET") ?? "";

// El grupo "Secador" ya existia en Jibble. Solo esa gente seca carros;
// no tiene caso traer supervisores, tuneleros ni cajeras.
const GRUPO_SECADOR = Deno.env.get("JIBBLE_GRUPO_SECADOR") ??
  "ef74b0bf-ba86-4f90-ac29-05e9037dba7b";

const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
});

function json(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

async function token(): Promise<string> {
  const r = await fetch("https://identity.prod.jibble.io/connect/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "client_credentials",
      client_id: JIBBLE_ID,
      client_secret: JIBBLE_SECRET,
    }),
  });
  const d = await r.json();
  if (!d?.access_token) throw new Error("Jibble no dio token: " + JSON.stringify(d));
  return d.access_token;
}

// La fecha del dia EN MEXICALI. Si se usara UTC, entre las 17:00 y la
// medianoche local Jibble ya estaria contestando por el dia siguiente y
// la lista saldria vacia con todo el turno de la tarde trabajando.
function hoyMexicali(): string {
  const ahora = new Date();
  const local = new Date(ahora.getTime() - 7 * 60 * 60 * 1000);
  return local.toISOString().slice(0, 10);
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (!JIBBLE_ID || !JIBBLE_SECRET) {
    console.error("Faltan las credenciales de Jibble");
    return json({ ok: false, error: "Jibble no esta configurado" }, 503);
  }

  try {
    const tok = await token();
    const cab = { Authorization: "Bearer " + tok };

    // --- 1) Quien es secador (sin ex-empleados) ----------------------
    const filtro = `groupId eq ${GRUPO_SECADOR} and status ne 'Removed'`;
    const urlGente =
      "https://workspace.prod.jibble.io/v1/People" +
      "?$select=id,fullName" +
      "&$filter=" + encodeURIComponent(filtro);

    const rGente = await fetch(urlGente, { headers: cab });
    if (!rGente.ok) throw new Error("People devolvio " + rGente.status);
    const gente = (await rGente.json())?.value ?? [];

    // --- 2) Quien checo hoy ------------------------------------------
    const dia = hoyMexicali();
    const urlHojas =
      "https://time-attendance.prod.jibble.io/v1/Timesheets" +
      `?period=Custom&date=${dia}&endDate=${dia}`;

    const rHojas = await fetch(urlHojas, { headers: cab });
    if (!rHojas.ok) throw new Error("Timesheets devolvio " + rHojas.status);
    const hojas = (await rHojas.json())?.value ?? [];

    const porPersona = new Map<string, any>();
    for (const h of hojas) porPersona.set(h.personId, (h.daily ?? [])[0]);

    // --- 3) Traducir a los tres estados ------------------------------
    const lista = gente.map((p: any) => {
      const d = porPersona.get(p.id);

      // Checado = tiene entrada Y no tiene salida. Las DOS condiciones:
      // quien no vino tampoco tiene salida, y sin este cuidado saldria
      // como disponible alguien que no esta en el taller.
      const dentro = !!d?.firstInTimestamp && !d?.lastOutTimestamp;

      if (!dentro) {
        return { id: p.id, nombre: p.fullName, estado: "fuera", desde: null };
      }

      // En descanso = hay un break sin hora de fin.
      const abierto = (d?.trackedHours?.breaks ?? []).find((b: any) => !b?.end);

      return {
        id: p.id,
        nombre: p.fullName,
        estado: abierto ? "descanso" : "activo",
        desde: abierto ? abierto.start : d.firstInTimestamp,
      };
    });

    // --- 4) Guardar --------------------------------------------------
    const { data, error } = await db.rpc("sincronizar_empleados", { p_gente: lista });
    if (error) throw new Error("Al guardar: " + error.message);

    const activos = lista.filter((x: any) => x.estado === "activo").length;
    const descanso = lista.filter((x: any) => x.estado === "descanso").length;
    console.log(`Sincronizado: ${activos} activos, ${descanso} en descanso, ${lista.length} en total`);

    return json({ ok: true, activos, descanso, total: lista.length, guardado: data });
  } catch (e) {
    // Se responde con error pero NO se borra nada: la app sigue viendo
    // la ultima lista buena. Es preferible una lista de hace 5 minutos
    // a una pantalla vacia con el taller lleno de gente.
    console.error("Fallo la sincronizacion con Jibble:", e);
    return json({ ok: false, error: String(e) }, 500);
  }
});
