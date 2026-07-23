-- =====================================================================
-- 055 — Una sola regla para "¿esto es un servicio especial?"
--
-- El problema: aviso_de_servicio() y tipo_de_servicio() contenian la
-- MISMA condicion copiada palabra por palabra —
--
--     categoria = 'Paquetes Especial'
--     o producto like 'encerado%' / '%brillo%' / 'detallado%'
--
-- — y cada una devolvia algo distinto con ella: la primera el nombre del
-- servicio para la banderita morada, la segunda la palabra 'encerado'
-- para la seccion del reporte. Dos copias de la misma pregunta.
--
-- Es el error que este proyecto ya cometio cuatro veces (ver CLAUDE.md:
-- el aviso que tapaba al lavado a mano, express vs aspirado, el reporte
-- por dia vs por rango). El dia que se de de alta un servicio nuevo en
-- Zettle, con dos copias hay una que se entera y otra que no — y la que
-- no se entera falla EN SILENCIO.
--
-- Ahora la condicion vive en es_servicio_especial() y las dos funciones
-- le preguntan a ella. Cambiar la regla es cambiar un solo lugar.
--
-- De paso: el "quitar acentos" estaba escrito a mano adentro de las dos
-- (translate(lower(x), 'aeiouu'...)) aunque sin_acentos() ya existia.
-- Las dos versiones cubrian letras DISTINTAS. Ahora se usa sin_acentos(),
-- que cubre mas (a la vuelta, 'Super Brillo' escrito 'Súper Brillo' sigue
-- funcionando igual que antes, y ademas 'Ñ' y 'Ç' que antes no).
--
-- Y se borra tipo_de_servicio(text, text) — la sobrecarga de DOS
-- argumentos. Le pasaba null a la categoria, o sea que se saltaba la
-- taxonomia del dueno y caia al respaldo por nombre. Nadie la llamaba ya
-- (se reviso todo el codigo vivo). Se quita porque una sobrecarga sin
-- usar es una trampa esperando: es exactamente lo que obligo a la
-- migracion 052 a hacer drop de la firma vieja de editar_carro.
--
-- SEGURIDAD: carros.aviso y carros.tiempo_imposible son columnas
-- GENERADAS sobre estas funciones. Reemplazar la funcion NO recalcula lo
-- ya guardado, asi que al final se fuerza el recalculo y se comprueba que
-- ni un solo carro cambio de valor.
-- =====================================================================

-- --- La pregunta, en un solo lugar ----------------------------------
create or replace function public.es_servicio_especial(
  p_producto  text,
  p_categoria text
) returns boolean
language sql immutable as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then false

    -- La taxonomia del dueno manda. Lo que el puso en "Paquetes
    -- Especial" tarda mas por naturaleza. Asi, un producto nuevo que de
    -- alta ahi cae solo del lado correcto sin tocar codigo.
    when btrim(coalesce(p_categoria, '')) = 'Paquetes Especial' then true

    -- Respaldo por nombre, para los carros viejos que no traen categoria
    -- guardada y por si un dia llega sin ella.
    when public.sin_acentos(btrim(p_producto)) like 'ENCERADO%'
      or public.sin_acentos(btrim(p_producto)) like '%BRILLO%'
      or public.sin_acentos(btrim(p_producto)) like 'DETALLADO%' then true

    else false
  end;
$$;

comment on function public.es_servicio_especial(text, text) is
  'La UNICA definicion de "servicio especial" (encerado, super brillo, '
  'detallado). aviso_de_servicio y tipo_de_servicio le preguntan a esta. '
  'Si la regla cambia, se cambia aqui y nada mas.';

-- --- QUE trabajo es: el texto de la banderita morada -----------------
-- El texto sale del NOMBRE DEL PRODUCTO, no de una etiqueta inventada:
-- si el dueno da de alta "Encerado Ceramico", la tarjeta lo anuncia sola.
create or replace function public.aviso_de_servicio(
  p_producto  text,
  p_variante  text,
  p_categoria text
) returns text
language sql immutable as $$
  select case
    when public.es_servicio_especial(p_producto, p_categoria)
      then upper(btrim(p_producto))
  end;
$$;

comment on function public.aviso_de_servicio(text, text, text) is
  'El texto de la banderita morada. Delega la decision en '
  'es_servicio_especial(); aqui solo se decide COMO se escribe.';

-- --- En que seccion del reporte se mide ------------------------------
create or replace function public.tipo_de_servicio(
  p_producto  text,
  p_variante  text,
  p_categoria text
) returns text
language sql immutable as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then null

    when public.es_servicio_especial(p_producto, p_categoria) then 'encerado'

    -- Se pregunta por lleva_aspirado y NO por es_lavado_express: esta si
    -- distingue "no lleva" (false) de "no conozco el producto" (null).
    -- Con es_lavado_express, un paquete nuevo se colaria en silencio a la
    -- seccion de completos — el promedio que toda la separacion existe
    -- para mantener limpio.
    when public.lleva_aspirado(p_producto, p_variante) is true  then 'con_aspirado'
    when public.lleva_aspirado(p_producto, p_variante) is false then 'sin_aspirado'

    else null
  end;
$$;

comment on function public.tipo_de_servicio(text, text, text) is
  'En que seccion del reporte se mide el carro. Delega "es especial" en '
  'es_servicio_especial(), la misma que usa la banderita morada.';

-- --- Fuera la sobrecarga de 2 argumentos -----------------------------
-- Le pasaba null a la categoria: se saltaba la taxonomia del dueno.
-- Nadie la llama en el codigo vivo (revisado migracion por migracion y
-- en las tres Edge Functions).
drop function if exists public.tipo_de_servicio(text, text);

-- --- Recalcular lo ya guardado --------------------------------------
-- carros.aviso y carros.tiempo_imposible son columnas GENERADAS: cambiar
-- la funcion no vuelve a calcular las filas viejas. Sin esto quedarian
-- dos verdades conviviendo — justo lo que estas funciones existen para
-- evitar.
update public.carros set producto = producto;
