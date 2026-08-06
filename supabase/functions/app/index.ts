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
  // Prelavado: 20 minutos.
  //
  // Este estado cubre todo lo que pasa antes de secar (prelavado + tunel +
  // el rato hasta que el supervisor asigna). El dueno lo subio a 20 min el
  // 20/jul/2026: un lavado normal que pasa de 20 min sin asignarse casi
  // seguro es que el supervisor lo olvido (paso con una Acura de 38 min).
  // OJO: los lavados a MANO no se pintan rojo por prelavado (tardan mas de
  // por si); esa excepcion vive abajo, en el calculo de 'limite' por carro.
  prelavado: 1200,

  // Secando: 35 minutos.
  secando: 2100,

  // Los estados 'tunel' y 'por_asignar' se quitaron de aqui el
  // 22/jul/2026. Dejaron de generarse cuando el flujo paso a un solo
  // toque (migracion 024) y solo seguian por los carros que venian en
  // camino ese dia. Se comprobo antes de quitarlos: la cola esta en CERO
  // carros abiertos, y ningun camino del codigo los vuelve a producir
  // (regresar_etapa solo devuelve 'prelavado' o 'secando'). Si por lo que
  // sea reapareciera uno, el "?? 0" de abajo lo deja sin rojo en vez de
  // tronar.
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
// Leer la foto del carro (Claude Sonnet 5): placa + marca + submarca + tipo
//
// Se le manda la MISMA imagen que ya se subio, sin agrandarla. Se midio
// el 19/jul/2026 con una foto real del taller: la placa medira ~170px de
// ancho y se lee bien; incluso a la cuarta parte de resolucion seguia
// leyendola. La nota del CLAUDE.md que pedia subir a 2000px estaba
// basada en una estimacion pesimista y resulto innecesaria.
//
// Desde el 24/jul/2026 la misma llamada saca tambien MARCA, SUBMARCA
// (modelo) y TIPO de carroceria. Se probo sobre 59 fotos reales: la foto
// (trasera, para la placa) trae el modelo emblemado en la cajuela, y el
// mercado mexicano lo hace legible. La marca sale ~98% cuando se
// compromete. El costo marginal es casi cero: la imagen ya se manda.
//
// Devuelve lo que pudo leer; cada campo por su cuenta (aceptacion parcial:
// la placa puede salir y la marca no, o al reves). NUNCA lanza: si
// Anthropic se cae, tarda, o contesta algo raro, se devuelve todo null y
// la foto queda guardada igual. La foto es opcional y no bloquea al carro.
//
// Sonnet 5 y no Opus: tiene vision de alta resolucion (lo que se
// necesita) y cuesta un tercio. Va con "thinking" apagado y esfuerzo bajo.
// Si algun dia las lecturas salen flojas, ahi es donde hay que subirle.
// ---------------------------------------------------------------------
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

const TIPOS_VALIDOS = ["automovil", "camioneta", "pickup", "pasajeros"];

const INSTRUCCION_FOTO = `Miras la foto de un auto en un lavado de Mexicali, Baja California, y devuelves dos cosas: la PLACA y la IDENTIFICACION del vehiculo (marca, modelo y tipo de carroceria).

== PLACA ==
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

Campos de placa:
- "placa": el identificador del vehiculo (el numero grande) tal como se ve, CONSERVANDO
  los guiones o espacios que la placa tenga impresos. No agregues separadores que no esten.
- "organizacion": el nombre de la asociacion si la placa es del tipo 3 y alcanzas a
  leerlo. Si es placa oficial, o no se lee, null.
- El MARCO del portaplacas no es parte de la placa: nombres de agencia y lemas
  publicitarios ("Go Further", "Ford", el nombre de una distribuidora) se IGNORAN.
- "placa_legible" = true SOLO si leiste con certeza todos los caracteres del
  identificador. Si estan borrosos, cortados, tapados, o dudas entre dos (0 y O, 1 e I,
  8 y B), entonces placa_legible=false y placa=null. NUNCA adivines un caracter de la
  placa. Que el nombre de la organizacion este tapado NO hace ilegible la placa.

== IDENTIFICACION DEL VEHICULO ==
Casi todos los autos traen el logo de la marca al centro y el modelo escrito en un
emblema en la cajuela o compuerta trasera.
- "marca": la marca (Toyota, Honda, Nissan, Ford, Chevrolet, Volkswagen, Kia, RAM,
  Buick, etc.). Si lees la SUBMARCA pero no distingues el logo, DEDUCE la marca del
  modelo (un "Corolla" es Toyota, un "Civic" es Honda, un "K5" es Kia). El marco o
  portaplacas NO define la marca; usa el logo y los emblemas del propio auto.
- "submarca": el modelo (Corolla, Civic, CR-V, Sentra, Versa, Aveo, Jetta, K5, L200...).
  Es el MODELO, no la version: "Big Horn", "Sport", "LE", "XLE", "Limited", "Sense",
  "Advance" son versiones, no submarcas — no las pongas.
- "tipo": la carroceria, uno de: "automovil" (sedan o hatchback), "camioneta" (SUV o van
  familiar), "pickup" (con batea de carga), "pasajeros" (combi o van de 5 hileras de
  asientos). Usa el modelo cuando lo conozcas: un Corolla es "automovil", una RAV4 es
  "camioneta", una L200 es "pickup".

Para marca, submarca y tipo: da tu MEJOR identificacion aunque no estes 100% seguro;
deja null SOLO si de plano no puedes distinguir. Pero NUNCA inventes un modelo que no
corresponde a lo que ves — un dato inventado es peor que uno vacio. (Esto es distinto de
la placa, donde la regla es estricta: solo si la leiste con certeza.)`;

type Lectura = {
  placa: string | null;
  organizacion: string | null;
  marca: string | null;
  submarca: string | null;
  tipo: string | null;
};
// Devuelve un objeto SOLO cuando de verdad hubo una lectura del modelo (los
// campos pueden venir null: "mire y no identifique esto"). Devuelve `null`
// cuando NO hubo lectura (sin API key, timeout, error de red, o el modelo se
// nego): en ese caso no sabemos nada, y quien llama NO debe tocar los datos
// del carro — si no, un timeout en una re-subida borraria una lectura buena
// anterior. Es la diferencia entre "la foto no muestra nada" (dato) y "no
// alcanzamos a mirar" (falla de infra).
async function leerFoto(imagenBase64: string): Promise<Lectura | null> {
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
        max_tokens: 300,
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
                // Le da al modelo DONDE poner el nombre de la asociacion;
                // sin este campo lo mete dentro de "placa" y ensucia el
                // historial (ONAPPAFA 72973 != 72973).
                organizacion: { anyOf: [{ type: "string" }, { type: "null" }] },
                placa_legible: { type: "boolean" },
                // Marca, modelo y carroceria del auto. Se aceptan con
                // cualquier confianza (solo null se descarta); la placa
                // sigue siendo estricta con placa_legible.
                marca: { anyOf: [{ type: "string" }, { type: "null" }] },
                submarca: { anyOf: [{ type: "string" }, { type: "null" }] },
                tipo: {
                  anyOf: [
                    { type: "string", enum: ["automovil", "camioneta", "pickup", "pasajeros"] },
                    { type: "null" },
                  ],
                },
              },
              required: ["placa", "organizacion", "placa_legible", "marca", "submarca", "tipo"],
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
            { type: "text", text: INSTRUCCION_FOTO },
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

    const limpiar = (v: unknown): string | null => {
      const t = String(v ?? "").trim();
      return t === "" ? null : t;
    };

    // La placa es ESTRICTA: solo se acepta si el modelo dijo que la leyo
    // con certeza. Si no, placa=null — pero eso ya NO tumba marca/submarca/
    // tipo (esa es la aceptacion parcial que pidio el dueño).
    let placa: string | null = null;
    let organizacion: string | null = null;
    if (leido?.placa_legible === true) {
      placa = limpiar(leido?.placa)?.toUpperCase() ?? null;
      // La organizacion solo acompana a una placa leida: sola seria raro
      // (se leyo el letrero chico pero no los numeros grandes).
      if (placa) organizacion = limpiar(leido?.organizacion)?.toUpperCase() ?? null;
    }

    // Marca/submarca/tipo: mejor identificacion con cualquier confianza;
    // null si vino vacio. La marca se guarda en mayusculas en la RPC.
    const marca = limpiar(leido?.marca);
    const submarca = limpiar(leido?.submarca);
    const tipoRaw = limpiar(leido?.tipo)?.toLowerCase() ?? null;
    const tipo = tipoRaw && TIPOS_VALIDOS.includes(tipoRaw) ? tipoRaw : null;

    return { placa, organizacion, marca, submarca, tipo };
  } catch (e) {
    console.error("Fallo al leer la foto:", e);
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
        id, estado, linea, es_express, producto, variante, aviso, a_mano,
        tipo_unidad, color, marca, submarca, cliente, nota, creado_en, foto_path, placa, placa_display,
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
          .select("carro_id, secador, empleado_id")
          .is("fin", null)
          .in("carro_id", idsEnCola)
      : { data: [] as any[] };
    const secadoresDe = new Map<number, string[]>();
    // Los ids van EN EL MISMO ORDEN que los nombres, para que la pantalla de
    // Corregir pueda preseleccionar en la rejilla (que empareja por id).
    const secadorIdsDe = new Map<number, (string | null)[]>();
    for (const a of asignados ?? []) {
      const nombres = secadoresDe.get(a.carro_id) ?? [];
      nombres.push(a.secador);
      secadoresDe.set(a.carro_id, nombres);
      const ids = secadorIdsDe.get(a.carro_id) ?? [];
      ids.push(a.empleado_id ?? null);
      secadorIdsDe.set(a.carro_id, ids);
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

      // A los cuantos segundos se pinta rojo. Un lavado a mano tarda
      // legitimamente mas en prelavado (se lava a mano, no pasa por tunel),
      // asi que NO se pinta rojo por el tiempo de prelavado: un a_mano de 30
      // min ahi es normal, un lavado normal de 30 min significa que el
      // supervisor olvido asignarlo. Los demas estados no cambian.
      let limite = DEMORA_SEG[c.estado] ?? 0;
      if (c.estado === "prelavado" && c.a_mano) limite = 0;

      return {
        id: c.id,
        estado: c.estado,
        linea: c.linea,
        es_express: c.es_express,
        producto: c.producto,
        variante: c.variante,
        // Dos banderitas INDEPENDIENTES, las dos como columna generada en
        // la base (nunca recalculadas aqui: dos reglas para la misma
        // pregunta siempre se desfasan). Ver migraciones 044/045/046.
        //   aviso  -> QUE trabajo es (SUPER BRILLO, ENCERADO MANUAL...)
        //   a_mano -> COMO se lava (a mano, o entra al tunel)
        // Un Super Brillo/Manual lleva las dos.
        aviso: c.aviso,
        a_mano: c.a_mano,
        tipo_unidad: c.tipo_unidad,
        color: c.color,
        marca: c.marca,
        submarca: c.submarca,
        cliente: c.cliente,
        placa: c.placa,
        placa_display: c.placa_display,
        etapa_inicio: abierta?.inicio ?? c.creado_en,
        limite,
        // Nombres de los secadores que ya se poncharon, si los hay.
        ausentes: sinSecador.get(c.id) ?? [],
        secadores: secadoresDe.get(c.id) ?? [],
        // Ids en el mismo orden que los nombres: Corregir los usa para
        // preseleccionar en la rejilla.
        secador_ids: secadorIdsDe.get(c.id) ?? [],
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

    // La foto se LEE despues de que ya quedo guardada, para que un problema
    // aqui nunca se lleve entre las patas la foto. De una sola llamada salen
    // placa, marca, submarca y tipo.
    //
    // SOLO se escribe si de verdad hubo lectura. guardar_datos_de_foto (063)
    // SOBREESCRIBE (la foto nueva es autoritativa: re-tomar una foto buena
    // limpia el dato de un carro fotografiado por error). Justo por eso NO se
    // debe llamar cuando leerFoto devolvio null (timeout/error/negativa): ahi
    // no hubo lectura, y sobrescribir borraria una lectura buena anterior. La
    // foto ya quedo guardada; el supervisor puede re-subir para reintentar.
    const lectura = await leerFoto(puro);
    if (lectura) {
      const { error: errDatos } = await db.rpc("guardar_datos_de_foto", {
        p_carro: carro,
        p_placa: lectura.placa,
        p_org: lectura.organizacion,
        p_marca: lectura.marca,
        p_submarca: lectura.submarca,
        p_tipo: lectura.tipo,
      });
      if (errDatos) {
        // No se le devuelve error al telefono: la foto SI se guardo.
        console.error("No se pudieron guardar los datos de la foto del carro", carro, ":", errDatos);
      }
    } else {
      console.error("Foto guardada pero sin lectura del modelo; los datos del carro no se tocan:", carro);
    }

    return json({
      ok: true,
      camino,
      placa: lectura?.placa ?? null,
      marca: lectura?.marca ?? null,
      submarca: lectura?.submarca ?? null,
      tipo: lectura?.tipo ?? null,
    });
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

  // --- Asignar linea y secadores -------------------------------------
  // Desde el 24/jul/2026 la pantalla de asignar solo pide linea + secador.
  // El tipo y el color ya vienen de la nota de la cajera (guardados al
  // crear el carro); la marca/submarca/tipo ahora salen de la foto. Por eso
  // este handler dejo de recibir y guardar tipo/color/marca.
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
      p_marca: null,
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

  // --- Borrar una unidad sin asignar (informacion basura) -------------
  // Saca de la cola un carro que el supervisor nunca va a trabajar (se fue
  // el cliente, se olvido). No borra la fila: pone cancelado_en, que lo
  // excluye de /cola y del reporte, conservando la hora de entrada y sin
  // fabricar hora de salida. Los candados (sin asignar + 30 min) viven en
  // la base (borrar_unidad), asi que una llamada suelta no puede borrar un
  // carro bueno aunque el front falle.
  if (ruta === "/borrar") {
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

    const { data, error } = await db.rpc("borrar_unidad", { p_carro: carro });
    if (error) {
      console.error("Fallo al borrar la unidad", carro, ":", error);
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

    // La pantalla ahora manda VARIOS motivos (arreglo). Se acepta tambien
    // el singular `motivo` por si algun telefono viejo lo sigue mandando:
    // asi un cambio de la app no rompe una entrega a medias.
    const motivos: string[] = Array.isArray(cuerpo?.motivos)
      ? cuerpo.motivos.map((m: any) => String(m))
      : (cuerpo?.motivo != null ? [String(cuerpo.motivo)] : []);

    const { data, error } = await db.rpc("rechazar_entrega", {
      p_carro: carro,
      p_motivos: motivos,
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
    // Sin fecha = hoy. La funcion de la base ya aceptaba el parametro
    // desde la migracion 028; aqui estaba fijo en null.
    const pedida = url.searchParams.get("fecha") ?? "";
    const fecha = /^\d{4}-\d{2}-\d{2}$/.test(pedida) ? pedida : null;

    const { data, error } = await db.rpc("entregados_del_dia", { p_fecha: fecha });

    if (error) {
      console.error("Fallo al leer los entregados:", error);
      return json({ error: error.message }, 500);
    }

    // La funcion devuelve la fila completa de carros. Se recorta aqui a lo
    // que la pantalla usa: no hay razon para mandarle al telefono el
    // purchase_uuid ni el monto de la venta.
    const carros = (data ?? []).map((c: any) => ({
      id: c.id,
      // Va explicito porque "Corregir" abre la misma pantalla que la cola
      // y esa decide con el estado si muestra linea y secadores. Sin este
      // campo funcionaba por accidente (undefined nunca es "secando"), y
      // el primero que agregue logica sobre el estado lo rompe sin verlo.
      estado: c.estado,
      producto: c.producto,
      variante: c.variante,
      tipo_unidad: c.tipo_unidad,
      color: c.color,
      marca: c.marca,
      submarca: c.submarca,
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
      // La marca ya no la toca el supervisor: sale de la foto (061). Se
      // manda null, que por el coalesce de editar_carro nunca la borra.
      p_marca: null,
      p_linea: cuerpo?.linea == null ? null : Number(cuerpo.linea),
      // Solo cuando se mandan (Corregir de un carro secando). Nulo = no
      // tocar los secadores. Los dos van juntos: nombres para el historial,
      // ids para medir eficiencia por persona.
      p_secadores: Array.isArray(cuerpo?.secadores) ? cuerpo.secadores : null,
      p_empleados: Array.isArray(cuerpo?.empleados) ? cuerpo.empleados : null,
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
    // Acepta un dia suelto (?fecha=) o un intervalo (?desde=&hasta=).
    // Con intervalo NUNCA se usa la fila congelada: los congelados son
    // POR DIA y los promedios hay que ponderarlos por carro, no
    // promediar promedios. Se calcula al vuelo, que es lo correcto.
    const desde = url.searchParams.get("desde") ?? "";
    const hasta = url.searchParams.get("hasta") ?? "";
    const esFecha = (s: string) => /^\d{4}-\d{2}-\d{2}$/.test(s);

    if (esFecha(desde) && esFecha(hasta)) {
      if (desde > hasta) {
        return json({ error: "el dia inicial es posterior al final" }, 400);
      }
      const { data, error } = await db.rpc("reporte_del_rango", {
        p_desde: desde, p_hasta: hasta,
      });
      if (error) {
        console.error("Fallo el reporte por rango:", error);
        return json({ error: error.message }, 500);
      }
      return json(data);
    }

    const fecha = url.searchParams.get("fecha") ?? "";
    if (!esFecha(fecha)) {
      return json({ error: "falta fecha (YYYY-MM-DD) o desde/hasta" }, 400);
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

  // --- Desglose de un carro -------------------------------------------
  // Lo abre el supervisor al tocar una tarjeta en "Finalizados".
  if (ruta === "/carro") {
    const id = Number(url.searchParams.get("id") ?? 0);
    if (!id) return json({ error: "falta id" }, 400);

    const { data, error } = await db.rpc("detalle_del_carro", { p_carro: id });
    if (error) {
      console.error("Fallo el detalle del carro:", error);
      return json({ error: error.message }, 500);
    }
    if (!data) return json({ error: "Ese carro no existe" }, 404);

    // La foto vive en un bucket PRIVADO (en las fotos se ven placas), asi
    // que la ruta cruda no sirve: hay que firmarla. Se firma al vuelo y no
    // se cachea como en /cola porque el desglose se abre de tanto en tanto,
    // no cada 3 segundos. Si falla, el carro se ve igual, solo sin foto.
    if (data.foto_path) {
      const { data: firmada } = await db.storage
        .from("fotos")
        .createSignedUrl(data.foto_path, 3600);
      data.foto = firmada?.signedUrl ?? null;
    }

    return json(data);
  }

  // --- Historial por placa --------------------------------------------
  // Sin ?q= devuelve las que mas han venido. Con ?q= busca.
  if (ruta === "/placas") {
    // A cada placa se le agregan dos cosas de su ULTIMA visita, para las
    // columnas clicables del Historial por placa:
    //   secadores       -> tripulacion (nombre + empleado_id) -> perfil del secador
    //   cliente_lealtad  -> dueno de lealtad (id + nombre)     -> perfil del cliente
    // Una RPC por cosa, en paralelo, para las DOS fuentes (busqueda o top),
    // asi no hay dos reglas. cliente_lealtad NO pisa 'cliente' (el texto de
    // la nota): el front usa el de lealtad si existe, y si no el texto.
    const enriquecer = async (placas: any[]): Promise<any[]> => {
      const lista = placas ?? [];
      const claves = lista.map((p: any) => p.placa).filter(Boolean);
      if (!claves.length) return lista;
      const [secs, clis] = await Promise.all([
        db.rpc("secadores_de_placas", { p_placas: claves }),
        db.rpc("clientes_de_placas", { p_placas: claves }),
      ]);
      // Si alguna falla, esa columna sale vacia pero la tabla no se cae.
      if (secs.error) console.error("secadores_de_placas:", secs.error);
      if (clis.error) console.error("clientes_de_placas:", clis.error);
      const ms = (secs.data ?? {}) as Record<string, any[]>;
      const mc = (clis.data ?? {}) as Record<string, any>;
      return lista.map((p: any) => ({
        ...p,
        secadores: ms[p.placa] ?? [],
        cliente_lealtad: mc[p.placa] ?? null,
      }));
    };

    // Con q: busca por placa, marca o submarca (RPC que normaliza acentos y
    // mayusculas). Sin q: top 50 por visitas, directo de la vista.
    const q = (url.searchParams.get("q") ?? "").trim();
    if (q) {
      const { data, error } = await db.rpc("buscar_vehiculos", { p_q: q });
      if (error) { console.error("buscar_vehiculos:", error); return json({ error: error.message }, 500); }
      return json({ placas: await enriquecer(data ?? []) });
    }
    const { data, error } = await db
      .from("historial_placas")
      .select("placa, placa_como_se_lee, visitas, primera_visita, ultima_visita, tipo_unidad, color, marca, submarca, cliente, gastado")
      .order("visitas", { ascending: false })
      .limit(50);
    if (error) {
      console.error("Fallo al buscar placas:", error);
      return json({ error: error.message }, 500);
    }
    return json({ placas: await enriquecer(data ?? []) });
  }

  // --- Ultimos lavados (reporte, seccion Clientes) --------------------
  // Segunda lista, aparte de la de lealtad: los ultimos carros que pasaron
  // por el lavado (tabla carros), que SI se actualiza sola con la operacion
  // del dia (la de lealtad depende de la caja o del ClientNoteTracker). Regla
  // del dueno: se muestra el nombre; si no hay, la placa; si no hay placa,
  // no aparece (eso ya lo filtra carros_recientes). Aqui se agrega el dueno
  // de lealtad por placa con clientes_de_placas — la MISMA fuente que el
  // Historial por placa, para no tener dos reglas de "quien es el dueno".
  if (ruta === "/carros-recientes") {
    const n = Math.min(Math.max(Number(url.searchParams.get("n")) || 20, 1), 50);
    const { data, error } = await db.rpc("carros_recientes", { p_limite: n });
    if (error) { console.error("carros_recientes:", error); return json({ error: error.message }, 500); }
    const lista = (data ?? []) as any[];
    const claves = lista.map((c) => c.placa).filter(Boolean);
    let mc: Record<string, any> = {};
    if (claves.length) {
      const { data: clis, error: e2 } = await db.rpc("clientes_de_placas", { p_placas: claves });
      if (e2) console.error("clientes_de_placas:", e2);
      else mc = (clis ?? {}) as Record<string, any>;
    }
    const carros = lista.map((c) => ({ ...c, cliente_lealtad: c.placa ? (mc[c.placa] ?? null) : null }));
    return json({ carros });
  }

  // --- Aviso: placas repetidas el mismo dia (foto mal pegada) ---------
  // Dos o mas carros del mismo dia local con la misma placa: senal de que la
  // foto se pego al carro equivocado. El reporte lo muestra como alerta para
  // el rango/dia consultado. Solo lectura, aparte del reporte congelado.
  if (ruta === "/placas-repetidas") {
    const desde = url.searchParams.get("desde");
    const hasta = url.searchParams.get("hasta") ?? desde;
    if (!desde) return json({ error: "falta desde" }, 400);
    const { data, error } = await db.rpc("placas_repetidas_del_rango", { p_desde: desde, p_hasta: hasta });
    if (error) { console.error("placas_repetidas_del_rango:", error); return json({ error: error.message }, 500); }
    return json({ repetidas: data ?? [] });
  }

  // --- Trabajadores: lista y perfil de secado -------------------------
  // La lista incluye a TODOS los empleados (activos, en descanso y fuera):
  // el dueno quiere poder abrir el perfil de alguien que hoy descansa y no
  // sale en la grilla de asignar. La logica vive en la base (089).
  if (ruta === "/trabajadores") {
    const { data, error } = await db.rpc("trabajadores");
    if (error) { console.error("trabajadores:", error); return json({ error: error.message }, 500); }
    return json({ trabajadores: data ?? [] });
  }

  // Perfil de UNA persona: su historial de secado (cada carro con placa,
  // inicio/fin de secado, minutos y motivos de rechazo).
  if (ruta === "/trabajador") {
    const id = (url.searchParams.get("id") ?? "").trim();
    if (!id) return json({ error: "falta id" }, 400);
    const { data, error } = await db.rpc("perfil_de_secador", { p_empleado: id });
    if (error) { console.error("perfil_de_secador:", error); return json({ error: error.message }, 500); }
    if (!data) return json({ error: "Ese trabajador no existe" }, 404);
    return json({ trabajador: data });
  }

  // --- Galeria de fotos de una placa ----------------------------------
  // Una foto por visita que tuvo foto, de la mas nueva a la mas vieja, con
  // la hora en que se tomo. El bucket es privado (se ven placas), asi que
  // cada path se firma al vuelo. Se abre desde el boton "Galeria" del perfil
  // de la placa, de tanto en tanto, no cada 3s: no hace falta cachear.
  if (ruta === "/fotos-placa") {
    const placa = (url.searchParams.get("placa") ?? "").trim();
    if (!placa) return json({ error: "falta placa" }, 400);
    const { data, error } = await db.rpc("fotos_de_placa", { p_placa: placa });
    if (error) { console.error("fotos_de_placa:", error); return json({ error: error.message }, 500); }
    const fotos: any[] = [];
    for (const f of (data ?? []) as any[]) {
      let signed: string | null = null;
      if (f.foto_path) {
        const { data: s } = await db.storage.from("fotos").createSignedUrl(f.foto_path, 3600);
        signed = s?.signedUrl ?? null;
      }
      fotos.push({ carro_id: f.carro_id, tomada_en: f.tomada_en, url: signed });
    }
    return json({ fotos });
  }

  // ===================================================================
  // CRM / Lealtad de la cajera (067). Todas detras del codigo de acceso.
  // Modelo persona-centrico: la lealtad es de la PERSONA; la placa solo
  // facilita la busqueda (N-a-N). La logica vive en la base (RPCs).
  // ===================================================================

  // --- Personas: buscar (por placa o por nombre) / crear-editar --------
  if (ruta === "/personas") {
    if (req.method === "GET") {
      // Por id: el perfil completo de una persona (para abrirlo desde un
      // resultado de vehiculo, donde solo se tiene el id de la persona).
      const id = url.searchParams.get("id");
      if (id !== null) {
        const { data, error } = await db.rpc("persona_json", { p_persona: Number(id) });
        if (error) { console.error("persona_json:", error); return json({ error: error.message }, 500); }
        return json({ persona: data });
      }
      // Antes de escribir, el buscador de clientes muestra las ultimas N
      // personas con visita registrada. Reusa persona_json, asi que la
      // pantalla las pinta igual que un resultado de busqueda.
      const recientes = url.searchParams.get("recientes");
      if (recientes !== null) {
        const n = Math.min(Math.max(Number(recientes) || 10, 1), 50);
        const { data, error } = await db.rpc("personas_recientes", { p_limite: n });
        if (error) { console.error("personas_recientes:", error); return json({ error: error.message }, 500); }
        return json({ personas: data ?? [] });
      }
      const placa = url.searchParams.get("placa");
      const q = url.searchParams.get("q");
      if (placa !== null) {
        const { data, error } = await db.rpc("personas_por_placa", { p_placa: placa });
        if (error) { console.error("personas_por_placa:", error); return json({ error: error.message }, 500); }
        return json({ personas: data ?? [] });
      }
      if (q !== null) {
        const { data, error } = await db.rpc("buscar_personas", { p_q: q });
        if (error) { console.error("buscar_personas:", error); return json({ error: error.message }, 500); }
        return json({ personas: data ?? [] });
      }
      return json({ error: "falta placa o q" }, 400);
    }
    if (req.method === "POST") {
      let cuerpo: any;
      try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
      const { data, error } = await db.rpc("upsert_persona", {
        p_id: cuerpo?.id ?? null,
        p_nombre: cuerpo?.nombre ?? null,
        p_telefono: cuerpo?.telefono ?? null,
        p_notas: cuerpo?.notas ?? null,
      });
      if (error) { console.error("upsert_persona:", error); return json({ error: error.message }, 500); }
      return json(data);
    }
    return json({ error: "usa GET o POST" }, 405);
  }

  // --- Confirmar / descartar una placa SUGERIDA de una persona ---------
  // Las placas que salen de la foto entran como "por confirmar". Aqui un
  // humano (cajera o dueno) las vuelve seguras, o las quita si estan mal.
  if (ruta === "/placa-confirmar" || ruta === "/placa-descartar") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
    const persona = Number(cuerpo?.persona);
    const placa = String(cuerpo?.placa ?? "");
    if (!persona || !Number.isFinite(persona) || !placa) {
      return json({ ok: false, error: "falta persona o placa" }, 400);
    }
    const fn = ruta === "/placa-confirmar" ? "confirmar_placa_de_persona" : "descartar_placa_de_persona";
    const { data, error } = await db.rpc(fn, { p_persona: persona, p_placa: placa });
    if (error) { console.error(fn, ":", error); return json({ ok: false, error: error.message }, 500); }
    return json(data);
  }

  // --- Leer la placa de una foto (sin tocar ningun carro) --------------
  // Igual que /foto pero la lectura es para la caja: sube la foto a
  // capturas/ y devuelve lo que leyo. El amarre al carro se hace despues,
  // con /enlazar, cuando ya nacio el carro de la venta.
  if (ruta === "/leer-placa") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
    const datos = String(cuerpo?.imagen ?? "");
    if (!datos) return json({ ok: false, error: "falta imagen" }, 400);

    const coma = datos.indexOf(",");
    const puro = coma >= 0 ? datos.slice(coma + 1) : datos;

    let binario: Uint8Array;
    try {
      const cruda = atob(puro);
      binario = new Uint8Array(cruda.length);
      for (let i = 0; i < cruda.length; i++) binario[i] = cruda.charCodeAt(i);
    } catch { return json({ ok: false, error: "imagen ilegible" }, 400); }

    const dia = new Date().toISOString().slice(0, 10);
    const camino = `capturas/${dia}/cap-${Date.now()}.jpg`;
    const { error: errSubir } = await db.storage
      .from("fotos").upload(camino, binario, { contentType: "image/jpeg", upsert: true });
    if (errSubir) { console.error("Fallo al subir la captura:", errSubir); return json({ ok: false, error: errSubir.message }, 500); }

    const lectura = await leerFoto(puro);
    return json({
      ok: true,
      foto_path: camino,
      placa: lectura?.placa ?? null,
      marca: lectura?.marca ?? null,
      submarca: lectura?.submarca ?? null,
      tipo: lectura?.tipo ?? null,
    });
  }

  // --- Registrar una visita (cuenta lealtad; auto-liga la placa) -------
  if (ruta === "/visita") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
    if (!cuerpo?.persona) return json({ ok: false, error: "falta persona" }, 400);
    const { data, error } = await db.rpc("registrar_visita", {
      p_persona: Number(cuerpo.persona),
      p_placa: cuerpo?.placa ?? null,
      p_marca: cuerpo?.marca ?? null,
      p_submarca: cuerpo?.submarca ?? null,
      p_tipo: cuerpo?.tipo ?? null,
      p_color: cuerpo?.color ?? null,
      p_foto_path: cuerpo?.foto_path ?? null,
      p_es_gratis: cuerpo?.es_gratis ?? false,
      p_caja: cuerpo?.caja ?? "principal",
    });
    if (error) { console.error("registrar_visita:", error); return json({ error: error.message }, 500); }
    return json(data);
  }

  // --- Descartar una visita (no hubo venta) ---------------------------
  if (ruta === "/descartar-visita") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
    if (!cuerpo?.visita) return json({ ok: false, error: "falta visita" }, 400);
    const { data, error } = await db.rpc("descartar_visita", { p_visita: Number(cuerpo.visita) });
    if (error) { console.error("descartar_visita:", error); return json({ error: error.message }, 500); }
    return json(data);
  }

  // --- Enlazar una visita al carro de su venta (autoritativo) ---------
  if (ruta === "/enlazar") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
    if (!cuerpo?.visita || !cuerpo?.carro) return json({ ok: false, error: "falta visita o carro" }, 400);
    const { data, error } = await db.rpc("enlazar_visita_a_carro", {
      p_visita: Number(cuerpo.visita), p_carro: Number(cuerpo.carro),
    });
    if (error) { console.error("enlazar_visita_a_carro:", error); return json({ error: error.message }, 500); }
    return json(data);
  }

  // --- Desenlazar (soltar el carro; no descuenta lealtad) -------------
  if (ruta === "/desenlazar") {
    if (req.method !== "POST") return json({ error: "usa POST" }, 405);
    let cuerpo: any;
    try { cuerpo = await req.json(); } catch { return json({ ok: false, error: "cuerpo invalido" }, 400); }
    if (!cuerpo?.visita) return json({ ok: false, error: "falta visita" }, 400);
    const { data, error } = await db.rpc("desenlazar_visita", { p_visita: Number(cuerpo.visita) });
    if (error) { console.error("desenlazar_visita:", error); return json({ error: error.message }, 500); }
    return json(data);
  }

  // --- Candidatos para enlazar (carros recien nacidos + visitas) ------
  if (ruta === "/pendientes") {
    const caja = url.searchParams.get("caja") ?? "principal";
    const mins = Number(url.searchParams.get("minutos") ?? 20);
    const { data, error } = await db.rpc("candidatos_para_enlazar", { p_caja: caja, p_minutos: mins });
    if (error) { console.error("candidatos_para_enlazar:", error); return json({ error: error.message }, 500); }
    return json(data);
  }

  // --- Historial de un cliente (visitas: carro, entrada, salida, secadores) --
  if (ruta === "/historial") {
    // Por placa: todas las visitas de esa placa, con la persona de lealtad
    // de cada venta. Por persona: las visitas de esa persona (lo de antes).
    const placa = url.searchParams.get("placa");
    if (placa !== null) {
      // Dos cosas: las visitas lavadas de la placa y sus dueno(s) de lealtad
      // (persona_placas). Los duenos importan cuando la placa es del CRM y no
      // tiene ninguna visita lavada (tabla vacia, pero si hay dueno).
      const [h, d] = await Promise.all([
        db.rpc("historial_de_placa", { p_placa: placa }),
        db.rpc("duenos_de_placa", { p_placa: placa }),
      ]);
      if (h.error) { console.error("historial_de_placa:", h.error); return json({ error: h.error.message }, 500); }
      if (d.error) { console.error("duenos_de_placa:", d.error); return json({ error: d.error.message }, 500); }
      return json({ historial: h.data ?? [], duenos: d.data ?? [] });
    }
    const persona = Number(url.searchParams.get("persona") ?? 0);
    if (!persona) return json({ error: "falta persona o placa" }, 400);
    const { data, error } = await db.rpc("historial_de_persona", { p_persona: persona });
    if (error) { console.error("historial_de_persona:", error); return json({ error: error.message }, 500); }
    return json({ historial: data ?? [] });
  }

  // --- Buscar tickets por CONTENIDO (número, cajera, producto...) -----
  // Buscador en vivo con infinite scroll: 2+ caracteres -> página de tickets
  // (más nuevos primero) cuyo contenido contiene el texto. `offset` para pedir
  // la siguiente página. La página es de 30; el front sabe que hay más si
  // recibe 30.
  if (ruta === "/tickets") {
    const q = (url.searchParams.get("q") ?? "").trim();
    if (q.length < 2) return json({ tickets: [] });
    const offset = Math.max(0, Number(url.searchParams.get("offset") ?? 0) || 0);
    const { data, error } = await db.rpc("buscar_tickets", { p_q: q, p_limite: 30, p_offset: offset });
    if (error) { console.error("buscar_tickets:", error); return json({ error: error.message }, 500); }
    return json({ tickets: data ?? [] });
  }

  // --- Detalle de un ticket (venta de Zettle por purchaseNumber) ------
  if (ruta === "/ticket") {
    const num = Number(url.searchParams.get("num") ?? 0);
    if (!num) return json({ error: "falta num" }, 400);
    const { data, error } = await db.rpc("ticket_detalle", { p_num: num });
    if (error) { console.error("ticket_detalle:", error); return json({ error: error.message }, 500); }
    return json({ ticket: data });
  }

  return json({ error: "ruta desconocida" }, 404);
});
