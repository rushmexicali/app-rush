// =====================================================================
// RUSH Car Wash — Edge Function: limpiar-fotos
//
// Las fotos que se toman y se suben se borran despues de 2 MESES (decision
// del dueno, 19/ago/2026; antes eran 3). El plan gratis de Supabase da 1 GB de Storage y
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

// 2 meses. Decision del dueno (19/ago/2026), sobre el hallazgo #8 de la
// auditoria: a 90 dias el Storage llega al 77% del limite de 1 GB en
// regimen; a 60 baja al 51%. Es la unica palanca real y las fotos viejas
// no le sirven de nada.
//
// ⚠️ El otro lado del numero es el default de `olvidar_fotos_viejas` (115).
// Manda ESTE, porque la funcion siempre recibe el suyo desde aqui; el de la
// base es el respaldo para una llamada suelta. Se cambian los dos juntos.
const DIAS = 60;

// storage.remove tiene un tope por llamada; se borra en tandas.
const TANDA = 500;

// Tope de archivos por corrida. Ver el comentario del paso 1: sin esto, la
// primera corrida real de octubre intentaria ~7,400 de un golpe.
const TOPE = 1000;

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
    // 🔑 Solo se avisa cuando el secreto FALTA, que es configuracion nuestra:
    // el cron llama cada noche, no encuentra token, responde 401 y la limpieza
    // no corre NUNCA -- en silencio y para siempre. Es el mismo modo de falla
    // que dejo al obrero de relectura inerte semanas enteras (§11.50), o sea
    // el patron #3 de pruebas/README.md: trabajo a medio terminar que queda
    // quieto sin fallar.
    //
    // Cuando el token simplemente NO COINCIDE no se avisa: esta URL es publica
    // y cualquier escaneo la toca. Avisar ahi convertiria el panel del dueno en
    // un blanco -- y un canal de avisos con ruido es la otra forma de no avisar.
    if (!TOKEN) {
      try {
        await db.rpc("anotar_aviso", {
          p_origen: "limpiar-fotos",
          p_motivo: "no_puede_arrancar",
          p_detalle: "falta el secreto LIMPIEZA_TOKEN: la limpieza de fotos no corre",
        });
      } catch (e) {
        console.error("No se pudo anotar el aviso de token faltante:", e);
      }
    }
    return json({ ok: false, error: "no autorizado" }, 401);
  }

  // 1) Los archivos con mas de 2 meses (fotos de carros y capturas de caja).
  //
  // ⚠️ CON TOPE POR CORRIDA (auditoria del 19/ago). Este camino NUNCA se ha
  // ejecutado de verdad: 21 corridas, 0 archivos borrados, porque la foto mas
  // vieja tiene 33 dias y el umbral son 60. La primera corrida real cae por el
  // 17/sep/2026 y encontraria TODO el atraso junto (~7,400 archivos, unas 15
  // tandas en una sola invocacion) contra el limite de tiempo de la funcion.
  // Con ~85 fotos entrando al dia, 1,000 por corrida drena el atraso inicial
  // en poco mas de una semana y despues el regimen es estable.
  const { data: nombres, error: errSel } = await db.rpc("fotos_viejas", { p_dias: DIAS, p_tope: TOPE });
  if (errSel) {
    console.error("fotos_viejas:", errSel);
    return json({ ok: false, error: errSel.message }, 500);
  }

  const paths: string[] = (nombres ?? []) as string[];
  const quitadasReales: string[] = [];
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
    for (const q of (quitadas ?? []) as Array<{ name?: string }>) {
      if (q?.name) quitadasReales.push(q.name);
    }
  }
  const borradas = quitadasReales.length;

  // 3) Olvidar el apuntador SOLO de las fotos que de verdad se borraron.
  //
  // ⚠️ Antes borraba por EDAD, y el comentario decia que "si el borrado fallo,
  // el apuntador se queda y la proxima corrida lo reintenta". Era falso: se
  // llamaba sin mirar los fallos y limpiaba por fecha, asi que una tanda que
  // fallaba dejaba el archivo en Storage Y el carro sin foto. Con el tope de
  // arriba eso se volvia seguro: cada corrida limpiaria apuntadores de miles
  // de archivos que todavia no se alcanzaron a borrar.
  const { data: olvidados, error: errOlv } = await db.rpc("olvidar_fotos_viejas", {
    p_dias: DIAS,
    p_borradas: quitadasReales,
  });
  if (errOlv) console.error("olvidar_fotos_viejas:", errOlv);

  // 3) Los HUERFANOS: archivos en Storage que ya no apunta ningun carro
  // (ni ninguna visita de la caja).
  //
  // Los deja el boton "Tomar foto otra vez" (migracion 103) y, sobre todo,
  // la CAJA: captura la foto ANTES de ligarla a un cliente, asi que la que
  // se abandona a media captura se queda suelta. Desde que la caja entro en
  // uso real (29/ago) crecen ~50 al dia.
  //
  // 🔑 SE BORRAN SOLAS AL CIERRE DEL DIA (8:30 PM). Regla del dueno,
  // 30/ago/2026, textual: "Todas las fotos huerfanas se borran al finalizar
  // el dia (8:30 PM)". Lo dispara `barrer_huerfanas_si_toca()` (migracion
  // 138), que llama a ESTA funcion con `?huerfanas=1`. Antes solo se
  // contaban y se dejaba un aviso pidiendo autorizacion; con ~50 al dia eso
  // era pedir permiso todos los dias para lo mismo, y el aviso se acumulo de
  // 16 a 151 en una semana.
  //
  // ⚠️ LA UNICA RED QUE QUEDA ES LA GRACIA DE UNA HORA de
  // `fotos_huerfanas_lista` (127), y ahora importa mas que antes porque esto
  // ya no lo revisa nadie: `/foto` sube el archivo a Storage y DESPUES
  // escribe `carros.foto_path`. Entre esas dos cosas una foto viva se ve
  // identica a una huerfana, y esa no se recupera. A las 8:30 PM, con el
  // taller cerrado desde las 8, la gracia cubre de sobra la ultima captura.
  //
  // ⛔ El barrido por EDAD (60 dias) es OTRA regla y sigue en su propio cron
  // a su propia hora. No se mezclan.
  //
  // ⚠️ Se cuenta en la BASE (`fotos_huerfanas`, migracion 126), no listando el
  // bucket. El primer intento uso `storage.from('fotos').list('')` y devolvio
  // 36 — que es el numero de CARPETAS, porque las fotos viven en
  // `AAAA-MM-DD/carro-N.jpg` y esa llamada solo lista el primer nivel. El
  // numero real es 174. Contar basura por abajo es peor que no contarla.
  let huerfanos = 0;
  let huerfanasBorradas = 0;
  try {
    const { data: h, error: errH } = await db.rpc("fotos_huerfanas");
    if (errH) throw errH;
    huerfanos = Number(h?.cuantas ?? 0);

    // ?huerfanas=1 las BORRA. Lo manda el cron del cierre (138) todos los
    // dias a las 8:30 PM, y tambien se puede disparar a mano. El barrido por
    // EDAD (60 dias) es independiente y no pasa por aqui.
    // La gracia de 1 hora vive en `fotos_huerfanas_lista` (127) y es lo unico
    // que separa una foto abandonada de una foto viva a medio guardar.
    if (huerfanos > 0 && url.searchParams.get("huerfanas") === "1") {
      const { data: lista, error: errLista } = await db.rpc("fotos_huerfanas_lista", { p_tope: 500 });
      if (errLista) throw errLista;
      const aBorrar: string[] = (lista ?? []) as string[];
      for (let i = 0; i < aBorrar.length; i += 100) {
        const tanda = aBorrar.slice(i, i + 100);
        const { data: fueron, error: errDel } = await db.storage.from("fotos").remove(tanda);
        if (errDel) { console.error("remove de huerfanas:", errDel); break; }
        huerfanasBorradas += (fueron ?? []).length;
      }
      console.log("limpiar-fotos: huerfanas borradas:", huerfanasBorradas, "de", aBorrar.length);
    } else if (huerfanos > 0) {
      await db.rpc("anotar_aviso", {
        p_origen: "limpiar-fotos",
        p_motivo: "fotos_huerfanas",
        p_detalle: huerfanos + " fotos en Storage que ya no apunta ningun carro " +
                   "(las deja 'Tomar foto otra vez'). No se borran solas: hay que autorizarlo.",
      });
    }
  } catch (e) {
    // Contar huerfanos es un extra: nunca puede tumbar el borrado por edad,
    // que es el trabajo de verdad de esta funcion.
    console.error("No se pudieron contar las fotos huerfanas:", e);
  }

  const resumen = {
    ok: fallos.length === 0,
    candidatas: paths.length,
    quedan_para_manana: paths.length >= TOPE,
    borradas,
    apuntadores_limpiados: olvidados ?? 0,
    huerfanas_encontradas: huerfanos,
    huerfanas_borradas: huerfanasBorradas,
    fallos: fallos.length,
    dias: DIAS,
    cuando: new Date().toISOString(),
  };
  console.log("limpiar-fotos:", JSON.stringify(resumen));
  return json(resumen);
});
