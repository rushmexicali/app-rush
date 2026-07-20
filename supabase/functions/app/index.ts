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
  // Prelavado: 19 minutos.
  //
  // Eran 15, pero desde el 19/jul/2026 este estado ya no es solo el
  // prelavado: cubre todo lo que pasa antes de secar (prelavado + tunel +
  // el rato hasta que el supervisor asigna), porque ahora es un solo
  // toque. 15 de prelavado + 4 del tunel = 19.
  prelavado: 1140,

  // Estos dos ya no se generan: quedan por los carros que venian en
  // camino cuando cambio el flujo. Se pueden borrar cuando la cola este
  // limpia de ellos.
  tunel: 0,
  por_asignar: -1,

  // Secando: 35 minutos.
  secando: 2100,
};

// Que dia es HOY en Mexicali, no en UTC. Despues de las 4-5 PM local ya
// cambio el dia en UTC, y sin esto el reporte del dia se partiria a media
// tarde.
function hoyEnMexicali(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Tijuana",
    year: "numeric", month: "2-digit", day: "2-digit",
  }).format(new Date());
}

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

const INSTRUCCION_PLACA = `Eres un lector de placas vehiculares. La foto es de un auto en un lavado de Mexicali, Baja California.

En Mexicali circulan TRES tipos de placa, y las tres son normales aqui:
1. Placa oficial mexicana (Baja California u otro estado).
2. Placa oficial de ESTADOS UNIDOS. Mexicali es frontera y entran muchas, sobre todo
   de California y Arizona. En estas, el nombre del estado y el lema NO son parte de
   la placa ("California", "Arizona", "Grand Canyon State", "dmv.ca.gov"), ni las
   calcomanias de mes y ano de las esquinas. Devuelve solo el identificador.
3. Placa de ASOCIACION CIVIL, para autos de procedencia extranjera todavia no
   nacionalizados. Llevan impreso el nombre de la organizacion — ONAPPAFA, ANAPROMEX,
   AMLOPAFA, CONDEFA, CODEFA, APROFAM, APROFA, UCD u otra — y un numero de afiliacion,
   normalmente de 4 a 7 digitos, a veces con letras. NO tienen el formato de una placa
   oficial y eso es correcto: NO las rechaces por eso.

Que devolver:
- "placa": el identificador del vehiculo (el numero grande) tal como se ve, CONSERVANDO
  los guiones o espacios que la placa tenga impresos. No agregues separadores que no esten.
- "organizacion": el nombre de la asociacion si la placa es del tipo 3 y alcanzas a
  leerlo. Si es placa oficial, o no se lee, null.
- El MARCO del portaplacas no es parte de la placa: nombres de agencia y lemas
  publicitarios ("Go Further", "Ford", el nombre de una distribuidora) se IGNORAN.

Reglas estrictas:
- legible=true significa: leiste con certeza todos los caracteres del identificador.
  Que el nombre de la organizacion este tapado NO hace ilegible la placa; deja
  organizacion=null y devuelve el numero.
- Si los caracteres del identificador estan borrosos, cortados o tapados, o dudas
  entre dos (0 y O, 1 e I, 8 y B), entonces legible=false y placa=null.
- NUNCA adivines un caracter. NUNCA completes ni corrijas el formato para que "se vea bien".
- Un dato inventado es peor que uno vacio.`;

type Lectura = { placa: string | null; organizacion: string | null };
const SIN_LECTURA: Lectura = { placa: null, organizacion: null };

async function leerPlaca(imagenBase64: string): Promise<Lectura> {
  if (!ANTHROPIC_API_KEY) {
    console.error("ANTHROPIC_API_KEY no configurada. No se leen placas.");
    return SIN_LECTURA;
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
                // Todavia no se guarda en ninguna columna. Se pide de todas
                // formas porque le da al modelo DONDE poner el nombre de la
                // asociacion; sin este campo lo mete dentro de "placa" y
                // ensucia el historial (ONAPPAFA 72973 != 72973).
                organizacion: { anyOf: [{ type: "string" }, { type: "null" }] },
                legible: { type: "boolean" },
              },
              required: ["placa", "organizacion", "legible"],
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
      return SIN_LECTURA;
    }

    const datos = await r.json();

    // Puede negarse a contestar por politica de contenido. No es un error
    // nuestro; simplemente no hay placa.
    if (datos?.stop_reason === "refusal") {
      console.error("Anthropic se nego a leer la foto.");
      return SIN_LECTURA;
    }

    const texto = datos?.content?.find((b: any) => b?.type === "text")?.text ?? "";
    const leido = JSON.parse(texto);

    // La regla de oro: solo se acepta si el modelo dijo que SI se lee.
    if (leido?.legible !== true) return SIN_LECTURA;

    const placa = String(leido?.placa ?? "").trim().toUpperCase();
    if (placa === "") return SIN_LECTURA;

    // La organizacion solo se guarda si vino con placa. Sola no sirve de
    // nada y ademas seria raro: significaria que se leyo el letrero chico
    // de arriba pero no los numeros grandes.
    const org = String(leido?.organizacion ?? "").trim().toUpperCase();
    return { placa, organizacion: org === "" ? null : org };
  } catch (e) {
    console.error("Fallo al leer la placa:", e);
    return SIN_LECTURA;
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
        foto_url, foto_url_expira,
        etapas ( etapa, inicio, fin )
      `)
      .neq("estado", "entregado")
      // Las devoluciones cancelan el carro: sale de la cola sin borrarse.
      .is("cancelado_en", null)
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

    // Quien esta secando cada carro. Hace falta en la pantalla de
    // confirmar entrega: el supervisor esta a punto de registrarle un
    // rechazo a una persona con nombre y tiene que ver a quien.
    //
    // Se limita a los carros de ESTA cola. Antes se pedian todas las
    // asignaciones abiertas, y como la entrega no las cerraba, la lista
    // solo crecia: con 200 carros al dia habrian sido miles de filas
    // viajando al telefono cada 3 segundos. Ya se arreglo la raiz
    // (avanzar_etapa las cierra), pero el filtro se queda: hace la
    // consulta barata sin importar lo que pase con los años.
    const idsEnCola = (data ?? []).map((c: any) => c.id);
    const { data: asignados } = idsEnCola.length
      ? await db
          .from("asignaciones")
          .select("carro_id, secador")
          .is("fin", null)
          .in("carro_id", idsEnCola)
      : { data: [] as any[] };
    const secadoresDe = new Map<number, string[]>();
    for (const a of asignados ?? []) {
      const lista = secadoresDe.get(a.carro_id) ?? [];
      lista.push(a.secador);
      secadoresDe.set(a.carro_id, lista);
    }

    // Enlaces firmados de las fotos.
    //
    // Se REUSA el que ya se guardo, y solo se firma de nuevo cuando
    // vencio. Antes se firmaba en cada consulta, y como el token cambia
    // cada vez, la direccion cambiaba cada 3 segundos: para el navegador
    // eso es una imagen distinta, asi que volvia a bajar la foto completa
    // (93 KB) cada 3 segundos, por cada carro con foto. En el wifi del
    // taller eso son gigabytes por jornada.
    const enlaces = new Map<number, string>();
    const ahora = Date.now();
    const porFirmar: any[] = [];

    for (const c of data ?? []) {
      if (!c.foto_path) continue;
      const vence = c.foto_url_expira ? new Date(c.foto_url_expira).getTime() : 0;
      if (c.foto_url && vence > ahora) enlaces.set(c.id, c.foto_url);
      else porFirmar.push(c);
    }

    if (porFirmar.length) {
      const HORAS = 24;
      const { data: firmados } = await db.storage
        .from("fotos")
        .createSignedUrls(porFirmar.map((c: any) => c.foto_path), HORAS * 3600);

      // Se guarda con un margen de una hora, para que nunca se entregue
      // un enlace que va a vencer mientras el supervisor lo esta viendo.
      const expira = new Date(ahora + (HORAS - 1) * 3600 * 1000).toISOString();

      for (let i = 0; i < porFirmar.length; i++) {
        const url = (firmados ?? [])[i]?.signedUrl;
        if (!url) continue;
        enlaces.set(porFirmar[i].id, url);
        const { error: errUrl } = await db
          .from("carros")
          .update({ foto_url: url, foto_url_expira: expira })
          .eq("id", porFirmar[i].id);
        // Si no se pudo guardar, la foto igual se ve: solo significa que
        // la proxima consulta la vuelve a firmar.
        if (errUrl) console.error("No se pudo guardar el enlace de la foto:", errUrl);
      }
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
        secadores: secadoresDe.get(c.id) ?? [],
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
      .update({
        foto_path: camino,
        foto_en: new Date().toISOString(),
        // Se borra el enlace de la foto ANTERIOR. Si no, /cola lo reusaria
        // y el supervisor seguiria viendo la foto vieja hasta que venciera.
        foto_url: null,
        foto_url_expira: null,
      })
      .eq("id", carro);

    if (errGuardar) {
      console.error("Foto subida pero no se pudo guardar la ruta:", errGuardar);
      return json({ ok: false, error: errGuardar.message }, 500);
    }

    // La placa se lee DESPUES de que la foto ya quedo guardada, para que
    // un problema aqui nunca se lleve entre las patas la foto. Si no se
    // pudo leer se guarda placa_en de todas formas: eso distingue "se
    // intento y no se pudo" de "nunca se intento".
    const { placa, organizacion } = await leerPlaca(puro);
    const { error: errPlaca } = await db
      .from("carros")
      .update({
        placa,
        placa_organizacion: organizacion,
        placa_en: new Date().toISOString(),
      })
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
      .select("id, mostrar, iniciales, color, estado, desde, manual, permanente, rol, orden")
      .in("estado", ["activo", "descanso"])
      // Secadores primero (orden=0), luego tunelero/supervisor/gerente.
      // La pantalla los parte en dos secciones con este mismo campo.
      .order("orden")
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

    // El tipo y el color se capturan en la MISMA pantalla, pero no son
    // asunto de asignar_carro (que valida lineas y secadores). Se guardan
    // aparte, y solo si la asignacion funciono.
    const tipo  = String(cuerpo?.tipo_unidad ?? "").trim();
    const color = String(cuerpo?.color ?? "").trim();
    if ((data as any)?.ok !== false && (tipo || color)) {
      const { error: errDatos } = await db.rpc("editar_carro", {
        p_carro: Number(cuerpo?.carro),
        p_tipo_unidad: tipo || null,
        p_color: color || null,
        p_marca: null,
        p_linea: null,
      });
      // No se le devuelve error al telefono: el carro YA quedo asignado,
      // que es lo que importa. El dato se puede volver a poner con
      // Corregir.
      if (errDatos) {
        console.error("Asignado, pero no se pudo guardar tipo/color:", errDatos);
      }
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

  // --- Rechazar una entrega -------------------------------------------
  // El carro NO cambia de estado: sigue secando con los mismos secadores.
  // Lo unico que pasa es que queda el registro, ligado a cada persona.
  if (ruta === "/rechazar") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);

    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }

    const carro = Number(cuerpo?.carro);
    if (!carro || !Number.isFinite(carro)) {
      return json({ ok: false, error: "falta el numero de carro" }, 400);
    }

    const { data, error } = await db.rpc("rechazar_entrega", {
      p_carro: carro,
      p_motivo: String(cuerpo?.motivo ?? ""),
    });

    if (error) {
      console.error("Fallo al rechazar el carro", carro, ":", error);
      return json({ ok: false, error: error.message }, 500);
    }
    return json(data);
  }

  // --- Los motivos de rechazo -----------------------------------------
  // Viven en la base para que la lista este en un solo lugar. La pantalla
  // los pide una vez y los guarda.
  if (ruta === "/motivos") {
    const { data, error } = await db.rpc("motivos_de_rechazo");
    if (error) {
      console.error("Fallo al leer los motivos:", error);
      return json({ error: error.message }, 500);
    }
    return json({ motivos: data ?? [] });
  }

  // --- Los entregados de hoy ------------------------------------------
  // Del mas reciente al mas viejo, para poder deshacer una entrega
  // equivocada. Solo del dia: un error de entrega se detecta en minutos,
  // y restaurar un carro de ayer ensuciaria el reporte de dos dias.
  //
  // El corte del dia lo calcula Postgres (entregados_del_dia), NO aqui:
  // hacerlo en JavaScript obligaria a escribir el desfase a mano y
  // Mexicali cambia de horario dos veces al ano.
  if (ruta === "/entregados") {
    const { data, error } = await db.rpc("entregados_del_dia", { p_fecha: null });

    if (error) {
      console.error("Fallo al leer los entregados:", error);
      return json({ error: error.message }, 500);
    }

    // La funcion devuelve la fila completa de carros. Se recorta aqui a lo
    // que la pantalla usa: no hay razon para mandarle al telefono el
    // purchase_uuid ni el monto de la venta.
    const carros = (data ?? []).map((c: any) => ({
      id: c.id,
      producto: c.producto,
      variante: c.variante,
      tipo_unidad: c.tipo_unidad,
      color: c.color,
      marca: c.marca,
      placa: c.placa,
      linea: c.linea,
      es_express: c.es_express,
      creado_en: c.creado_en,
      entregado_en: c.entregado_en,
    }));

    return json({ carros });
  }

  // --- Corregir los datos del carro -----------------------------------
  // El camino que la migracion 003 prometio y nunca se construyo: si la
  // nota de la cajera falta o viene mal, el supervisor la arregla.
  // Cualquier campo que no venga se deja como estaba.
  if (ruta === "/editar") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);

    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }

    const carro = Number(cuerpo?.carro);
    if (!carro || !Number.isFinite(carro)) {
      return json({ ok: false, error: "falta el numero de carro" }, 400);
    }

    const limpio = (v: unknown) => {
      const t = String(v ?? "").trim();
      return t === "" ? null : t;
    };

    const { data, error } = await db.rpc("editar_carro", {
      p_carro: carro,
      p_tipo_unidad: limpio(cuerpo?.tipo_unidad),
      p_color: limpio(cuerpo?.color),
      p_marca: limpio(cuerpo?.marca),
      p_linea: cuerpo?.linea == null ? null : Number(cuerpo.linea),
    });

    if (error) {
      console.error("Fallo al editar el carro", carro, ":", error);
      return json({ ok: false, error: error.message }, 500);
    }
    return json(data);
  }

  // --- Reporte diario -------------------------------------------------
  // Los dias pasados salen del congelado (reportes_diarios); el dia de hoy
  // se calcula al vuelo, porque todavia esta cambiando. A las 10 PM el
  // cron lo congela y a partir de ahi ya no se recalcula.
  if (ruta === "/reporte") {
    const fecha = url.searchParams.get("fecha") ?? "";
    if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
      return json({ error: "falta fecha (YYYY-MM-DD)" }, 400);
    }

    // El dia de HOY siempre se calcula al vuelo, aunque exista una fila
    // congelada. Un dia en curso todavia esta cambiando: leerlo de un
    // congelado de hace horas mostraria numeros viejos con cara de
    // definitivos. El cron lo vuelve a congelar a las 10 PM.
    const esHoy = fecha === hoyEnMexicali();

    if (!esHoy) {
      const { data: congelado } = await db
        .from("reportes_diarios")
        .select("datos, congelado_en")
        .eq("fecha", fecha)
        .maybeSingle();

      if (congelado?.datos) {
        return json({ ...congelado.datos, congelado_en: congelado.congelado_en });
      }
    }

    const { data, error } = await db.rpc("reporte_del_dia", { p_fecha: fecha });
    if (error) {
      console.error("Fallo al calcular el reporte de", fecha, ":", error);
      return json({ error: error.message }, 500);
    }
    return json({ ...data, congelado_en: null });
  }

  // --- Que dias hay ---------------------------------------------------
  // Los congelados, mas el dia de hoy (que todavia no lo esta).
  if (ruta === "/reportes") {
    const { data, error } = await db
      .from("reportes_diarios")
      .select("fecha, congelado_en")
      .order("fecha", { ascending: false });

    if (error) {
      console.error("Fallo al listar reportes:", error);
      return json({ error: error.message }, 500);
    }

    const hoy = hoyEnMexicali();

    // Hoy SIEMPRE se reporta como no congelado, aunque exista la fila.
    // /reporte lo calcula en vivo para el dia en curso, asi que si aqui
    // dijera "congelado" las dos rutas contarian historias distintas y el
    // selector diria una cosa y el encabezado otra.
    const dias = (data ?? []).map((d: any) =>
      d.fecha === hoy ? { ...d, congelado_en: null } : d
    );
    if (!dias.some((d: any) => d.fecha === hoy)) {
      dias.unshift({ fecha: hoy, congelado_en: null });
    }
    return json({ dias, hoy });
  }

  // --- Respaldo completo ----------------------------------------------
  // Todos los reportes congelados de un jalon, para bajarlos a un archivo.
  // Es el respaldo mensual manual: si algun dia se pierde el proyecto de
  // Supabase, los numeros historicos siguen existiendo en la computadora
  // del dueno.
  if (ruta === "/respaldo") {
    const { data, error } = await db
      .from("reportes_diarios")
      .select("fecha, datos, congelado_en")
      .order("fecha", { ascending: true });

    if (error) {
      console.error("Fallo al armar el respaldo:", error);
      return json({ error: error.message }, 500);
    }
    return json({ generado_en: new Date().toISOString(), reportes: data ?? [] });
  }

  // --- Historial por placa --------------------------------------------
  // Sin ?q= devuelve las que mas han venido. Con ?q= busca.
  if (ruta === "/placas") {
    const q = (url.searchParams.get("q") ?? "").toUpperCase().replace(/[^A-Z0-9]/g, "");

    let consulta = db
      .from("historial_placas")
      .select("placa, placa_como_se_lee, visitas, primera_visita, ultima_visita, tipo_unidad, color, marca, cliente, gastado")
      .order("visitas", { ascending: false })
      .limit(50);

    if (q) consulta = consulta.ilike("placa", `%${q}%`);

    const { data, error } = await consulta;
    if (error) {
      console.error("Fallo al buscar placas:", error);
      return json({ error: error.message }, 500);
    }
    return json({ placas: data ?? [] });
  }

  return json({ error: "ruta desconocida" }, 404);
});
