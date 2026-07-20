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

// Los grupos de Jibble de quien PUEDE secar.
//
// Antes se traia solo "Secador", con el comentario de que no tenia caso
// traer a los demas. Resulto falso: el dueno lo corrigio el 20/jul/2026
// — cuando hay mucho trabajo, el tunelero y los supervisores se ponen a
// secar tambien.
//
// La CAJERA sigue fuera a proposito: no seca, y meterla solo alargaria
// la lista que el supervisor recorre con el pulgar.
//
// El rol no limita nada; solo agrupa en la pantalla para que los
// secadores, que son el caso comun, salgan arriba.
const GRUPOS: Array<{ id: string; rol: string }> = [
  { id: Deno.env.get("JIBBLE_GRUPO_SECADOR") ?? "ef74b0bf-ba86-4f90-ac29-05e9037dba7b", rol: "secador" },
  { id: Deno.env.get("JIBBLE_GRUPO_TUNELERO") ?? "4e3e3110-6033-465e-9d5a-abd164604419", rol: "tunelero" },
  { id: Deno.env.get("JIBBLE_GRUPO_SUPERVISOR") ?? "2eefb624-bfc8-42a8-aeab-db75463842e6", rol: "supervisor" },
];

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

    // --- 1) Quien puede secar, por grupo (sin ex-empleados) ----------
    //
    // Una consulta por grupo. Si alguien esta en dos grupos, gana el
    // PRIMERO de la lista: quien es secador y ademas supervisor debe
    // salir con los secadores, que es donde el supervisor lo busca.
    const porId = new Map<string, any>();

    for (const g of GRUPOS) {
      const filtro = `groupId eq ${g.id} and status ne 'Removed'`;
      const urlGente =
        "https://workspace.prod.jibble.io/v1/People" +
        "?$select=id,fullName" +
        "&$filter=" + encodeURIComponent(filtro);

      const rGente = await fetch(urlGente, { headers: cab });
      if (!rGente.ok) throw new Error(`People (${g.rol}) devolvio ` + rGente.status);

      for (const p of ((await rGente.json())?.value ?? [])) {
        if (!porId.has(p.id)) porId.set(p.id, { ...p, rol: g.rol });
      }
    }

    const gente = [...porId.values()];

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
        return { id: p.id, nombre: p.fullName, rol: p.rol, estado: "fuera", desde: null };
      }

      // En descanso = hay un break sin hora de fin.
      const abierto = (d?.trackedHours?.breaks ?? []).find((b: any) => !b?.end);

      return {
        id: p.id,
        nombre: p.fullName,
        rol: p.rol,
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
