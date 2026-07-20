-- =====================================================================
-- RUSH Car Wash — el catalogo REAL de Zettle
--
-- El 20/jul/2026 el dueno mando el export del catalogo completo. Hasta
-- ese momento todo lo que sabiamos del catalogo salia de UN dia de
-- ventas, asi que media tienda estaba fuera del sistema sin que se viera.
--
-- ---------------------------------------------------------------------
-- LO GRAVE: seis servicios NUNCA creaban carro
-- ---------------------------------------------------------------------
-- La migracion 020 limito la creacion de carros a las categorias
-- 'Paquetes' y 'Promo' para matar el carro fantasma del Pinito. Correcto
-- en su momento — pero dejo fuera DOS categorias legitimas que ese dia
-- no se habian vendido:
--
--   Descuento          -> Instagram, Passie Completo, Completo Arrendatarios
--   Paquetes Especial  -> Encerado Manual, Super Brillo, Detallado
--
-- O sea que un Super Brillo de $1,300 —el servicio mas caro del
-- catalogo— se cobraba y el carro NUNCA aparecia en el telefono del
-- supervisor. Y los de Instagram y Passie, que existen justamente para
-- medir si la publicidad sirve, tampoco se registraban.
--
-- No habia tronado porque el 19/jul no se vendio ninguno.
--
-- Las categorias que NO crean carro quedan explicitas ahora, en vez de
-- estar implicitas en una lista de dos: Aroma, Extras e Insumos son
-- mostrador. Asi, cuando el dueno cree una categoria nueva, cae del lado
-- de "si crea carro" — que es el error barato. Al reves (un servicio
-- invisible) es el caro, y es el que acaba de pasar.
--
-- ---------------------------------------------------------------------
-- La categoria de Zettle es la que manda para agrupar
-- ---------------------------------------------------------------------
-- Antes se adivinaba el tipo de servicio por el NOMBRE del producto, y
-- se adivinaba mal: se habia supuesto que 'Manual' era el encerado
-- manual. No lo es. El catalogo real tiene:
--
--   Manual (Paquetes, $400-500)          -> lavado a mano. Servicio normal.
--   Encerado Manual (Especial, $600-900) -> ESTE es el encerado.
--   Super Brillo (Especial, $800-1300)   -> el mas caro.
--
-- El dueno ya separo eso el mismo, en Zettle, con la categoria
-- "Paquetes Especial". Usar su taxonomia en vez de inventar la nuestra
-- significa que cuando de alta un producto nuevo ahi, cae solo en la
-- seccion correcta sin tocar codigo.
--
-- Por eso se guarda carros.categoria.
--
-- ---------------------------------------------------------------------
-- Instagram y Passie son Completo Cera
-- ---------------------------------------------------------------------
-- Dicho por el dueno: son el mismo servicio, con descuento de publicidad,
-- y los tiene aparte para cuantificar que tan efectiva es la publicidad.
-- Para medir SECADO son completos y ahi van. La categoria 'Descuento' se
-- conserva en la columna, asi que medir la efectividad de la publicidad
-- sigue siendo posible con una consulta.
-- =====================================================================

alter table public.carros
  add column if not exists categoria text;

comment on column public.carros.categoria is
  'Categoria del producto en Zettle (Paquetes, Paquetes Especial, Descuento, Promo). Agrupa el reporte y permite medir la publicidad.';

-- ---------------------------------------------------------------------
-- Que renglon del ticket es el vehiculo
-- ---------------------------------------------------------------------
create or replace function public.producto_del_vehiculo(p_payload jsonb)
returns jsonb
language plpgsql
stable
as $$
declare
  renglones jsonb;
  elegido   jsonb;
  con_categoria int;
begin
  renglones := case
    when jsonb_typeof(detalle_venta(p_payload) -> 'products') = 'array'
      then detalle_venta(p_payload) -> 'products'
    else '[]'::jsonb
  end;

  if jsonb_array_length(renglones) = 0 then
    return null;
  end if;

  -- 1) El primer renglon que NO sea de mostrador.
  --
  -- Se listan las que no crean carro, no las que si. Una categoria nueva
  -- que el dueno invente cae del lado de "si crea carro": si sobra, se ve
  -- en la cola y se quita. Al reves, un servicio se vuelve invisible y
  -- nadie se entera — que es exactamente lo que paso con Paquetes
  -- Especial y Descuento entre el 19 y el 20 de julio.
  select p into elegido
    from jsonb_array_elements(renglones) as p
   where coalesce(p -> 'category' ->> 'name', '')
         not in ('Aroma', 'Extras', 'Insumos')
     and nullif(btrim(coalesce(p -> 'category' ->> 'name', '')), '') is not null
   limit 1;

  if elegido is not null then
    return elegido;
  end if;

  -- 2) Nadie trae categoria: no podemos distinguir, no rompemos nada.
  select count(*) into con_categoria
    from jsonb_array_elements(renglones) as p
   where nullif(btrim(coalesce(p -> 'category' ->> 'name', '')), '') is not null;

  if con_categoria = 0 then
    return renglones -> 0;
  end if;

  -- 3) Todo el ticket es de mostrador. Sin carro.
  return null;
end;
$$;

comment on function public.producto_del_vehiculo(jsonb) is
  'El renglon del ticket que representa al vehiculo. NULL = venta de mostrador (Aroma/Extras/Insumos).';

-- ---------------------------------------------------------------------
-- Express: ahora tambien Pasajeros con variante Express
--
-- Pasajeros (combis, 5 hileras) tiene variantes Tunel Express, Tunel
-- Completo, Manual Express, Manual Completo y Solo interior. Las de
-- Express son express; las demas no.
-- ---------------------------------------------------------------------
create or replace function public.es_lavado_express(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_producto, '') ilike 'express%'
      or (coalesce(p_producto, '') ilike 'manual%'
          and coalesce(p_variante, '') ilike 'express%')
      or (coalesce(p_producto, '') ilike 'pasajeros%'
          and coalesce(p_variante, '') ilike '%express%');
$$;

comment on function public.es_lavado_express(text, text) is
  'Express: producto Express, o Manual/Pasajeros con variante Express. Va a linea 1 y no lleva aspirado.';

-- ---------------------------------------------------------------------
-- Aspirado: la lista blanca, ahora con todo el catalogo real
--
-- Sigue siendo lista blanca a proposito: un producto que no conocemos
-- devuelve NULL y se ve como "sin clasificar", en vez de colarse a un
-- promedio.
-- ---------------------------------------------------------------------
create or replace function public.lleva_aspirado(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select case
    when coalesce(p_producto, '') ilike any (array[
           -- Paquetes
           'express%', 'completo%', 'solo interior%', 'manual%',
           'pasajeros%', 'tricera%',
           -- Promo
           'gratis%',
           -- Descuento (publicidad y convenios; son completos)
           'instagram%', 'passie%',
           -- Paquetes Especial
           'encerado%', 'super brillo%', 'superbrillo%', 'detallado%'
         ])
      then not public.es_lavado_express(p_producto, p_variante)
    else null
  end;
$$;

-- ---------------------------------------------------------------------
-- El tipo de servicio, ahora con la categoria del dueno
--
-- Se conserva la firma vieja de dos argumentos por si algo la llama;
-- delega en la nueva sin categoria.
-- ---------------------------------------------------------------------
create or replace function public.tipo_de_servicio(
  p_producto text, p_variante text, p_categoria text
)
returns text
language sql
immutable
as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then null

    -- La taxonomia del dueno manda. Lo que el puso en "Paquetes
    -- Especial" tarda mas por naturaleza y se mide solo contra si mismo.
    -- Asi, un producto nuevo que de alta ahi cae solo en su seccion.
    when btrim(coalesce(p_categoria, '')) = 'Paquetes Especial' then 'encerado'

    -- Respaldo por nombre, para los carros viejos que no traen categoria
    -- guardada y por si un dia llega sin ella.
    when lower(btrim(p_producto)) like 'encerado%'
      or translate(lower(btrim(p_producto)), 'áéíóúü', 'aeiouu') like '%brillo%'
      or lower(btrim(p_producto)) like 'detallado%'
      then 'encerado'

    -- Se pregunta por lleva_aspirado y NO por es_lavado_express: esta si
    -- distingue "no lleva" (false) de "no conozco el producto" (null).
    when public.lleva_aspirado(p_producto, p_variante) is true  then 'con_aspirado'
    when public.lleva_aspirado(p_producto, p_variante) is false then 'sin_aspirado'

    else null
  end;
$$;

create or replace function public.tipo_de_servicio(p_producto text, p_variante text)
returns text
language sql
immutable
as $$
  select public.tipo_de_servicio(p_producto, p_variante, null);
$$;

comment on function public.tipo_de_servicio(text, text, text) is
  'Agrupa el reporte: con_aspirado, sin_aspirado, encerado (categoria Paquetes Especial). NULL = no reconocido, se muestra aparte.';
