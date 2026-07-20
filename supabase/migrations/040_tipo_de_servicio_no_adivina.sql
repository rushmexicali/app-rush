-- =====================================================================
-- RUSH Car Wash — un producto desconocido NO cae en "con aspirado"
--
-- Bug encontrado el 20/jul/2026 probando la funcion de la migracion 039
-- con un producto inventado ("Lavado Ceramico"): en vez de quedar sin
-- clasificar, caia en con_aspirado.
--
-- La causa es sutil y vale la pena entenderla, porque las dos funciones
-- se parecen pero NO se comportan igual:
--
--   es_lavado_express()  -> es un OR simple. Un producto que no reconoce
--                           devuelve FALSE, nunca NULL.
--   lleva_aspirado()     -> tiene la LISTA BLANCA de productos conocidos
--                           y devuelve NULL cuando no reconoce.
--
-- tipo_de_servicio preguntaba "es express?" y, al recibir el false de un
-- producto desconocido, concluia "entonces lleva aspirado". O sea que
-- cualquier paquete nuevo que el dueno diera de alta en Zettle se metia
-- solo, y en silencio, a la seccion de completos — justo el promedio que
-- toda esta separacion existe para mantener limpio.
--
-- Ahora se monta sobre lleva_aspirado, que es la que sabe distinguir
-- "no lleva" de "no se". Sigue siendo una sola autoridad por pregunta:
-- es_lavado_express dice que es express, lleva_aspirado dice que es un
-- paquete conocido, y esta solo agrupa.
--
-- El encerado se evalua ANTES, asi que el superbrillo cae bien aunque no
-- este en la lista blanca de lleva_aspirado.
-- =====================================================================

create or replace function public.tipo_de_servicio(p_producto text, p_variante text)
returns text
language sql
immutable
as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then null

    -- Encerado: tarda mas por naturaleza, no se compara con nada.
    -- Va primero para que atrape al superbrillo aunque lleva_aspirado
    -- todavia no lo conozca. El Manual express NO entra: ese es express.
    when (lower(btrim(p_producto)) like 'manual%'
          and public.es_lavado_express(p_producto, p_variante) is not true)
      or translate(lower(btrim(p_producto)),
                   'áéíóúü', 'aeiouu') like '%brillo%'
      then 'encerado'

    -- Se pregunta por lleva_aspirado y NO por es_lavado_express: esta si
    -- distingue "no lleva aspirado" (false) de "no conozco este producto"
    -- (null). Con es_lavado_express, lo desconocido se colaba a completos.
    when public.lleva_aspirado(p_producto, p_variante) is true  then 'con_aspirado'
    when public.lleva_aspirado(p_producto, p_variante) is false then 'sin_aspirado'

    else null
  end;
$$;

comment on function public.tipo_de_servicio(text, text) is
  'Agrupa para el reporte: con_aspirado (paquetes), sin_aspirado (express), encerado (manual/superbrillo). NULL = producto no reconocido, se muestra aparte.';
