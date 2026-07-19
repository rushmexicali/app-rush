// =====================================================================
// RUSH Car Wash — Fase 2
// Edge Function: app  (fuente de datos de la pantalla del supervisor)
//
// La pantalla NO se sirve desde aqui. Supabase le pone a toda Edge
// Function la cabecera "Content-Security-Policy: default-src 'none';
// sandbox", que bloquea scripts y estilos, asi que una pagina servida
// desde aqui no funciona. Es una decision de Supabase, no configurable.
// La pantalla vive en GitHub Pages (carpeta web/) y le pide los datos
// a esta funcion.
//
// La llave de la base NUNCA llega al telefono: vive aqui.
//
// Desplegar:  supabase functions deploy app --no-verify-jwt
// =====================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SUPABASE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ??
  Deno.env.get("SUPABASE_SECRET_KEY") ??
  "";

const db = createClient(SUPABASE_URL, SUPABASE_KEY, {
  auth: { persistSession: false },
});

// La pantalla vive en otro dominio (GitHub Pages), asi que el navegador
// exige permiso explicito para llamar aqui.
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, x-codigo",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

// ---------------------------------------------------------------------
// Codigo de acceso
//
// El repositorio es publico (GitHub Pages gratis lo exige), asi que la
// URL de esta funcion es facil de encontrar. Sin esto, cualquiera podria
// ver la cola y mover carros ajenos.
//
// El codigo NO esta en el repositorio: vive en los secretos de Supabase.
// El supervisor lo teclea una sola vez en el telefono y ahi se queda.
//
// Si el secreto no esta configurado se bloquea TODO a proposito. Es
// preferible que falle de forma obvia y ruidosa a que quede abierto sin
// que nadie se entere.
// ---------------------------------------------------------------------
const CODIGO = Deno.env.get("CODIGO_ACCESO") ?? "";

function autorizado(req: Request, url: URL): boolean {
  if (!CODIGO) return false;
  const dado = req.headers.get("x-codigo") ?? url.searchParams.get("c") ?? "";
  return dado === CODIGO;
}

// ---------------------------------------------------------------------
// Cuando una etapa se pinta de rojo. Calibrado por el dueno el
// 19/jul/2026 viendo la operacion real, no inventado.
//
//    0  = nunca se pone rojo
//   -1  = rojo siempre, desde el primer segundo
//   >0  = segundos despues de los cuales se pone rojo
// ---------------------------------------------------------------------
const DEMORA_SEG: Record<string, number> = {
  // Prelavado: 15 minutos.
  prelavado: 900,

  // Tunel: NUNCA. Es automatico y siempre tarda casi lo mismo, asi que
  // un color que cambia ahi no informaria nada. Y un rojo que aparece
  // sin que haya problema enseña al supervisor a ignorar el rojo.
  tunel: 0,

  // Falta asignar: rojo SIEMPRE. No es una demora que se acumula, es una
  // accion que debe ocurrir en cuanto el carro sale del tunel. Mientras
  // este asi, alguien tiene algo que hacer ya.
  por_asignar: -1,

  // Secando: 35 minutos.
  secando: 2100,
};

function json(cuerpo: unknown, status = 200): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: {
      ...CORS,
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
    },
  });
}

// ---------------------------------------------------------------------
// Leer la placa de la foto (Claude Sonnet 5)
//
// Se le manda la MISMA imagen que ya se subio, sin agrandarla. Se midio
// el 19/jul/2026 con una foto real del taller: la placa medira ~170px de
// ancho y se lee bien; incluso a la cuarta parte de resolucion seguia
// leyendola. La nota del CLAUDE.md que pedia subir a 2000px estaba
// basada en una estimacion pesimista y resulto innecesaria.
//
// Devuelve la placa, o null si no se pudo leer. NUNCA lanza: si Anthropic
// se cae, tarda, o contesta algo raro, se devuelve null y la foto queda
// guardada igual. La foto es opcional y no debe bloquear al carro.
//
// Sonnet 5 y no Opus: tiene vision de alta resolucion (lo que se
// necesita) y cuesta un tercio. Esto es OCR, no razonamiento — por eso
// tambien va con "thinking" apagado y esfuerzo bajo. Si algun dia las
// lecturas salen flojas, ahi es donde hay que subirle.
// ---------------------------------------------------------------------
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

const INSTRUCCION_PLACA = `Eres un lector de placas vehiculares. En la foto hay un vehiculo.

Devuelve la placa EXACTAMENTE como se ve. Son placas mexicanas, en su mayoria de Baja California.

Reglas estrictas:
- Si la placa esta borrosa, cortada, tapada, en angulo, o NO puedes leer todos los caracteres con certeza, devuelve legible=false y placa=null.
- NUNCA adivines un caracter. NUNCA completes ni corrijas el formato para que "se vea bien".
- Si dudas entre dos caracteres (0 y O, 1 e I, 8 y B), eso cuenta como no legible.
- Un dato inventado es peor que uno vacio.`;

async function leerPlaca(imagenBase64: string): Promise<string | null> {
  if (!ANTHROPIC_API_KEY) {
    console.error("ANTHROPIC_API_KEY no configurada. No se leen placas.");
    return null;
  }

  // Si Anthropic se tarda, se corta. Vale mas devolverle la pantalla al
  // supervisor sin placa que dejarlo esperando con el boton en "subiendo".
  const cortar = new AbortController();
  const reloj = setTimeout(() => cortar.abort(), 25000);

  try {
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      signal: cortar.signal,
      headers: {
        "x-api-key": ANTHROPIC_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-sonnet-5",
        max_tokens: 200,
        thinking: { type: "disabled" },
        output_config: {
          effort: "low",
          // Salida obligada a esta forma: no hay que adivinar como vino
          // la respuesta ni parsear texto libre.
          format: {
            type: "json_schema",
            schema: {
              type: "object",
              properties: {
                placa: { anyOf: [{ type: "string" }, { type: "null" }] },
                legible: { type: "boolean" },
              },
              required: ["placa", "legible"],
              additionalProperties: false,
            },
          },
        },
        messages: [{
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: "image/jpeg", data: imagenBase64 },
            },
            { type: "text", text: INSTRUCCION_PLACA },
          ],
        }],
      }),
    });

    if (!r.ok) {
      console.error("Anthropic respondio", r.status, ":", (await r.text()).slice(0, 300));
      return null;
    }

    const datos = await r.json();

    // Puede negarse a contestar por politica de contenido. No es un error
    // nuestro; simplemente no hay placa.
    if (datos?.stop_reason === "refusal") {
      console.error("Anthropic se nego a leer la foto.");
      return null;
    }

    const texto = datos?.content?.find((b: any) => b?.type === "text")?.text ?? "";
    const leido = JSON.parse(texto);

    // La regla de oro: solo se acepta si el modelo dijo que SI se lee.
    if (leido?.legible !== true) return null;

    const placa = String(leido?.placa ?? "").trim().toUpperCase();
    return placa === "" ? null : placa;
  } catch (e) {
    console.error("Fallo al leer la placa:", e);
    return null;
  } finally {
    clearTimeout(reloj);
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }

  // Supabase entrega el path de formas distintas segun por donde entre
  // (/app, /functions/v1/app...). En vez de adivinar el prefijo, se toma
  // el ultimo tramo: si es el nombre de la funcion, es la raiz.
  const url = new URL(req.url);
  const tramos = url.pathname.split("/").filter(Boolean);
  const ultimo = tramos.length ? tramos[tramos.length - 1] : "";
  const ruta = (ultimo === "" || ultimo === "app") ? "/" : "/" + ultimo;

  // Señal de vida. No revela nada, asi que no pide codigo.
  if (ruta === "/") {
    return json({ ok: true, servicio: "app", configurado: CODIGO !== "" });
  }

  if (!autorizado(req, url)) {
    if (!CODIGO) {
      console.error("CODIGO_ACCESO no esta configurado. Todo queda bloqueado.");
      return json({ error: "El servidor no tiene codigo configurado" }, 503);
    }
    return json({ error: "Codigo incorrecto" }, 401);
  }

  // --- La cola de carros ---------------------------------------------
  if (ruta === "/cola") {
    const { data, error } = await db
      .from("carros")
      .select(`
        id, estado, linea, es_express, producto, variante,
        tipo_unidad, color, marca, cliente, nota, creado_en, foto_path, placa,
        etapas ( etapa, inicio, fin )
      `)
      .neq("estado", "entregado")
      .order("creado_en", { ascending: true });

    if (error) {
      console.error("Fallo al leer la cola:", error);
      return json({ error: error.message }, 500);
    }

    // Carros cuyo secador ya se poncho. Se consulta aparte para no
    // complicar la consulta principal, que es la que corre cada 3s.
    const { data: huerfanos } = await db
      .from("carros_sin_secador")
      .select("carro_id, ausentes");
    const sinSecador = new Map<number, string[]>();
    for (const h of huerfanos ?? []) sinSecador.set(h.carro_id, h.ausentes ?? []);

    // Enlaces firmados para las fotos. Caducan en una hora: el bucket
    // es privado y nadie debe poder guardarse una direccion permanente
    // a una foto donde se ve una placa.
    const conFoto = (data ?? []).filter((c: any) => c.foto_path);
    const enlaces = new Map<number, string>();
    if (conFoto.length) {
      const { data: firmados } = await db.storage
        .from("fotos")
        .createSignedUrls(conFoto.map((c: any) => c.foto_path), 3600);
      (firmados ?? []).forEach((f: any, i: number) => {
        if (f?.signedUrl) enlaces.set(conFoto[i].id, f.signedUrl);
      });
    }

    const carros = (data ?? []).map((c: any) => {
      // El cronometro cuenta desde que arranco la etapa ABIERTA (sin fin).
      // Si no hay ninguna abierta, se cae a la hora de entrada del carro.
      const abierta = (c.etapas ?? []).find((e: any) => !e.fin);
      return {
        id: c.id,
        estado: c.estado,
        linea: c.linea,
        es_express: c.es_express,
        producto: c.producto,
        variante: c.variante,
        tipo_unidad: c.tipo_unidad,
        color: c.color,
        marca: c.marca,
        cliente: c.cliente,
        placa: c.placa,
        etapa_inicio: abierta?.inicio ?? c.creado_en,
        limite: DEMORA_SEG[c.estado] ?? 0,
        // Nombres de los secadores que ya se poncharon, si los hay.
        ausentes: sinSecador.get(c.id) ?? [],
        foto: enlaces.get(c.id) ?? null,
      };
    });

    return json({ carros, servidor: new Date().toISOString() });
  }

  // --- Guardar la foto del carro -------------------------------------
  // Llega en base64 desde el telefono, ya reducida por el navegador. El
  // bucket es privado porque en las fotos se ven placas.
  if (ruta === "/foto") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);

    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }

    const carro = Number(cuerpo?.carro);
    const datos = String(cuerpo?.imagen ?? "");
    if (!carro || !datos) return json({ ok: false, error: "falta carro o imagen" }, 400);

    // "data:image/jpeg;base64,XXXX" -> solo XXXX
    const coma = datos.indexOf(",");
    const puro = coma >= 0 ? datos.slice(coma + 1) : datos;

    let binario: Uint8Array;
    try {
      const cruda = atob(puro);
      binario = new Uint8Array(cruda.length);
      for (let i = 0; i < cruda.length; i++) binario[i] = cruda.charCodeAt(i);
    } catch {
      return json({ ok: false, error: "imagen ilegible" }, 400);
    }

    // Nombre con la fecha para que las fotos queden ordenadas en el
    // almacen, y con el id del carro para poder rastrearlas.
    const dia = new Date().toISOString().slice(0, 10);
    const camino = `${dia}/carro-${carro}-${Date.now()}.jpg`;

    const { error: errSubir } = await db.storage
      .from("fotos")
      .upload(camino, binario, { contentType: "image/jpeg", upsert: true });

    if (errSubir) {
      console.error("Fallo al subir la foto del carro", carro, ":", errSubir);
      return json({ ok: false, error: errSubir.message }, 500);
    }

    const { error: errGuardar } = await db
      .from("carros")
      .update({ foto_path: camino, foto_en: new Date().toISOString() })
      .eq("id", carro);

    if (errGuardar) {
      console.error("Foto subida pero no se pudo guardar la ruta:", errGuardar);
      return json({ ok: false, error: errGuardar.message }, 500);
    }

    // La placa se lee DESPUES de que la foto ya quedo guardada, para que
    // un problema aqui nunca se lleve entre las patas la foto. Si no se
    // pudo leer se guarda placa_en de todas formas: eso distingue "se
    // intento y no se pudo" de "nunca se intento".
    const placa = await leerPlaca(puro);
    const { error: errPlaca } = await db
      .from("carros")
      .update({ placa, placa_en: new Date().toISOString() })
      .eq("id", carro);

    if (errPlaca) {
      // No se le devuelve error al telefono: la foto SI se guardo.
      console.error("No se pudo guardar la placa del carro", carro, ":", errPlaca);
    }

    return json({ ok: true, camino, placa });
  }

  // --- Quien puede secar ---------------------------------------------
  // Solo activos y en descanso. Los que estan fuera NO se mandan: si el
  // supervisor los viera, podria asignarle un carro a alguien que ya se
  // fue del taller.
  if (ruta === "/secadores") {
    const { data, error } = await db
      .from("secadores")
      .select("id, mostrar, iniciales, color, estado, desde, manual")
      .in("estado", ["activo", "descanso"])
      .order("mostrar");

    if (error) {
      console.error("Fallo al leer secadores:", error);
      return json({ error: error.message }, 500);
    }

    // Cuantos hay fuera, solo para el resumen de arriba. Es la misma
    // informacion que el dueno ve en su tablero de Jibble.
    const { count: fuera } = await db
      .from("empleados")
      .select("id", { count: "exact", head: true })
      .eq("estado", "fuera");

    return json({ secadores: data ?? [], fuera: fuera ?? 0 });
  }

  // --- Agregar a alguien que no aparece en Jibble ---------------------
  if (ruta === "/secador-manual") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }

    const { data, error } = await db.rpc("agregar_secador_manual", {
      p_nombre: String(cuerpo?.nombre ?? ""),
    });
    if (error) {
      console.error("Fallo al agregar secador manual:", error);
      return json({ ok: false, error: error.message }, 500);
    }
    return json(data);
  }

  // --- Asignar linea, marca y secadores ------------------------------
  if (ruta === "/asignar") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);

    let cuerpo: any;
    try {
      cuerpo = await req.json();
    } catch {
      return json({ ok: false, error: "cuerpo invalido" }, 400);
    }

    const { data, error } = await db.rpc("asignar_carro", {
      p_carro: Number(cuerpo?.carro),
      p_linea: Number(cuerpo?.linea),
      p_secadores: Array.isArray(cuerpo?.secadores) ? cuerpo.secadores : [],
      p_marca: cuerpo?.marca ?? null,
      p_empleados: Array.isArray(cuerpo?.empleados) ? cuerpo.empleados : null,
    });

    if (error) {
      console.error("Fallo al asignar el carro", cuerpo?.carro, ":", error);
      return json({ ok: false, error: error.message }, 500);
    }
    return json(data);
  }

  // --- Mover el carro de etapa, y deshacer ---------------------------
  // La logica vive en la base (avanzar_etapa / regresar_etapa) para que
  // sea atomica. Aqui solo se traduce el toque del boton a una llamada.
  if (ruta === "/avanzar" || ruta === "/corregir") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);

    let carro: number | null = null;
    try {
      const cuerpo = await req.json();
      carro = Number(cuerpo?.carro);
    } catch {
      return json({ error: "cuerpo invalido" }, 400);
    }
    if (!carro || !Number.isFinite(carro)) {
      return json({ error: "falta el numero de carro" }, 400);
    }

    const funcion = ruta === "/avanzar" ? "avanzar_etapa" : "regresar_etapa";
    const { data, error } = await db.rpc(funcion, { p_carro: carro });

    if (error) {
      console.error("Fallo", funcion, "carro", carro, ":", error);
      return json({ ok: false, error: error.message }, 500);
    }
    return json(data);
  }

  return json({ error: "ruta desconocida" }, 404);
});
