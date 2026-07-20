-- =====================================================================
-- RUSH Car Wash — "que servicio es" y "se lava a mano" son DOS preguntas
--
-- Error mio, encontrado el 20/jul/2026 con cuatro ventas reales que hizo
-- el dueno a proposito para probar:
--
--   96  Super Brillo    / Normal   $800   -> entra al tunel
--   97  Super Brillo    / Manual   $1000  -> se lava A MANO
--   98  Encerado Manual / Normal   $600   -> entra al tunel
--   99  Encerado Manual / Manual   $700   -> se lava A MANO
--
-- Los cuatro salian solo con la banderita del servicio. Al 97 y al 99 les
-- faltaba la de lavado a mano.
--
-- ---------------------------------------------------------------------
-- Que se me habia pasado
-- ---------------------------------------------------------------------
-- Yo leia el NOMBRE DEL PRODUCTO para decidir si era a mano. Pero en este
-- catalogo quien lo dice es la VARIANTE:
--
--   Encerado Manual / Normal  -> el producto dice "Manual" y NO es a mano
--   Super Brillo / Manual     -> el producto no dice "Manual" y SI lo es
--
-- O sea que el nombre del producto engaña en las dos direcciones. La
-- palabra "Manual" en "Encerado Manual" describe el ENCERADO (se encera a
-- mano), no el LAVADO. Es la misma clase de trampa que ya estaba
-- documentada con Manual+Express, y volvi a caer en ella.
--
-- ---------------------------------------------------------------------
-- La correccion
-- ---------------------------------------------------------------------
-- Son dos preguntas independientes y un carro puede necesitar las dos
-- banderitas, igual que ya pasaba con express + a mano:
--
--   aviso_de_servicio -> QUE trabajo es    (SUPER BRILLO, ENCERADO MANUAL, DETALLADO)
--   es_lavado_a_mano  -> COMO se lava      (a mano, o entra al tunel)
--
-- Meterlas en una sola funcion fue el error: una tapaba a la otra.
--
-- Regla de a mano, ahora con la variante:
--   producto  'Manual%'   -> el paquete de lavado a mano
--   variante  'Manual%'   -> Super Brillo/Manual, Encerado Manual/Manual,
--                            Pasajeros/Manual Completo...
--
-- Se revisaron las variantes del catalogo real: las unicas que empiezan
-- con "Manual" son de Pasajeros, Encerado Manual y Super Brillo, y en las
-- tres significa lo mismo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- El aviso de servicio ya NO habla del lavado a mano
-- ---------------------------------------------------------------------
create or replace function public.aviso_de_servicio(
  p_producto text, p_variante text, p_categoria text
)
returns text
language sql
immutable
as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then null

    -- La taxonomia del dueno manda.
    when btrim(coalesce(p_categoria, '')) = 'Paquetes Especial'
      then upper(btrim(p_producto))

    -- Respaldo por nombre, para carros viejos sin categoria guardada.
    when lower(btrim(p_producto)) like 'encerado%'
      or translate(lower(btrim(p_producto)), 'áéíóúü', 'aeiouu') like '%brillo%'
      or lower(btrim(p_producto)) like 'detallado%'
      then upper(btrim(p_producto))

    else null
  end;
$$;

comment on function public.aviso_de_servicio(text, text, text) is
  'QUE trabajo es: SUPER BRILLO, ENCERADO MANUAL, DETALLADO. NULL = lavado normal. Lo de "a mano" va aparte, en es_lavado_a_mano.';

-- ---------------------------------------------------------------------
-- Como se lava: a mano o por el tunel
-- ---------------------------------------------------------------------
create or replace function public.es_lavado_a_mano(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_producto, '') ilike 'manual%'
      or coalesce(p_variante, '') ilike 'manual%';
$$;

comment on function public.es_lavado_a_mano(text, text) is
  'COMO se lava. La VARIANTE es la que manda: Super Brillo/Manual si, Encerado Manual/Normal no.';

-- ---------------------------------------------------------------------
-- Las columnas generadas
--
-- Se tira y se vuelve a crear "aviso" porque Postgres no recalcula una
-- columna generada al cambiar la funcion: los carros 96-99 se habrian
-- quedado con el valor viejo. No se pierde nada — es una columna
-- derivada, se reconstruye sola de producto/variante/categoria.
-- ---------------------------------------------------------------------
alter table public.carros drop column if exists aviso;

alter table public.carros
  add column aviso text
  generated always as (
    public.aviso_de_servicio(producto, variante, categoria)
  ) stored;

alter table public.carros
  add column if not exists a_mano boolean
  generated always as (
    public.es_lavado_a_mano(producto, variante)
  ) stored;

comment on column public.carros.aviso is
  'Servicio especial (SUPER BRILLO, ENCERADO MANUAL, DETALLADO). NULL = lavado normal. Generada.';
comment on column public.carros.a_mano is
  'Se lava a mano, no entra al tunel. Generada. Independiente de aviso: un carro puede llevar las dos banderitas.';
