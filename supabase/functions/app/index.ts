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
// Cuando una etapa se considera demorada (se pinta de rojo).
//
// OJO: estos numeros son PROVISIONALES. El CLAUDE.md tiene pendiente
// definir los tiempos reales de cada etapa. Estan aqui para que el rojo
// exista y se pueda calibrar viendo la pantalla con el supervisor, no
// porque sepamos que son correctos.
// ---------------------------------------------------------------------
const DEMORA_SEG: Record<string, number> = {
  prelavado: 300,    // 5 min
  tunel: 300,        // 5 min
  por_asignar: 120,  // 2 min — aqui el carro esta parado sin hacer nada
  secando: 900,      // 15 min
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
        tipo_unidad, color, cliente, nota, creado_en,
        etapas ( etapa, inicio, fin )
      `)
      .neq("estado", "entregado")
      .order("creado_en", { ascending: true });

    if (error) {
      console.error("Fallo al leer la cola:", error);
      return json({ error: error.message }, 500);
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
        cliente: c.cliente,
        etapa_inicio: abierta?.inicio ?? c.creado_en,
        limite: DEMORA_SEG[c.estado] ?? 0,
      };
    });

    return json({ carros, servidor: new Date().toISOString() });
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
