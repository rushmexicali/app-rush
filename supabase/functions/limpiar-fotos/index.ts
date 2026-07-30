// =====================================================================
// RUSH Car Wash — Edge Function: limpiar-fotos
//
// Las fotos que se toman y se suben se borran despues de 3 MESES (decision
// del dueno, 29/jul/2026). El plan gratis de Supabase da 1 GB de Storage y
// las fotos crecen ~230 MB/mes; sin una regla, en unos meses se llena.
//
// POR QUE UN EDGE FUNCTION Y NO PURO SQL: borrar la fila de storage.objects
// con un DELETE deja el archivo fisico HUERFANO en el backend (no libera
// espacio). La unica via que libera espacio es la API de Storage
// (storage.remove), que solo se puede llamar desde aqui con la llave de
// servicio. La seleccion de "cuales" y la limpieza del apuntador viven en
// la base (migracion 091); aqui solo se orquesta el borrado real.
//
// Corre sola una vez al dia, disparada por pg_cron (migracion 091). Se
// protege con un token (x-tarea) para que no la pueda disparar cualquiera:
// el token vive en los secretos de la funcion y en Vault (nunca en Git).
//
// Desplegar:  supabase functions deploy limpiar-fotos --no-verify-jwt
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  "";

// El token que autoriza la tarea. Si no esta configurado se bloquea TODO a
// proposito: mas vale que la limpieza no corra a que corra abierta.
const TOKEN = Deno.env.get("LIMPIEZA_TOKEN") ?? "";

// 3 meses. Se deja como constante por si algun dia el dueno lo cambia.
const DIAS = 90;

// storage.remove tiene un tope por llamada; se borra en tandas.
const TANDA = 500;

const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
});

function json(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  // Guard: solo con el token correcto. Se acepta por header o por query,
  // para que el cron (pg_net) pueda mandarlo comodo.
  const url = new URL(req.url);
  const dado = req.headers.get("x-tarea") ?? url.searchParams.get("t") ?? "";
  if (!TOKEN || dado !== TOKEN) {
    console.error("limpiar-fotos: token invalido o no configurado.");
    return json({ ok: false, error: "no autorizado" }, 401);
  }

  // 1) Los archivos con mas de 3 meses (fotos de carros y capturas de caja).
  const { data: nombres, error: errSel } = await db.rpc("fotos_viejas", { p_dias: DIAS });
  if (errSel) {
    console.error("fotos_viejas:", errSel);
    return json({ ok: false, error: errSel.message }, 500);
  }

  const paths: string[] = (nombres ?? []) as string[];
  let borradas = 0;
  const fallos: string[] = [];

  // 2) Borrar de verdad via la API de Storage, en tandas.
  for (let i = 0; i < paths.length; i += TANDA) {
    const tanda = paths.slice(i, i + TANDA);
    const { data: quitadas, error: errDel } = await db.storage.from("fotos").remove(tanda);
    if (errDel) {
      console.error("storage.remove tanda", i, ":", errDel);
      fallos.push(errDel.message);
      continue;
    }
    borradas += (quitadas ?? []).length;
  }

  // 3) Olvidar el apuntador en los carros cuya foto ya se borro, para que la
  // app no muestre una liga muerta. Se hace despues del borrado: si el
  // borrado fallo, el apuntador se queda y la proxima corrida lo reintenta.
  const { data: olvidados, error: errOlv } = await db.rpc("olvidar_fotos_viejas", { p_dias: DIAS });
  if (errOlv) console.error("olvidar_fotos_viejas:", errOlv);

  const resumen = {
    ok: fallos.length === 0,
    candidatas: paths.length,
    borradas,
    apuntadores_limpiados: olvidados ?? 0,
    fallos: fallos.length,
    dias: DIAS,
    cuando: new Date().toISOString(),
  };
  console.log("limpiar-fotos:", JSON.stringify(resumen));
  return json(resumen);
});
