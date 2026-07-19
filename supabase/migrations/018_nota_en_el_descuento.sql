-- =====================================================================
-- RUSH Car Wash — la nota tambien puede venir en el DESCUENTO
--
-- Hasta hoy solo se leia products[0].comment. El 19/jul/2026 entro una
-- venta de 6to lavado gratis con la nota "CA BLANCA- ALEXA VASQUEZ" y el
-- carro salio "Sin datos del carro". La nota SI venia, pero aqui:
--
--     "products":  [{ "name": "Gratis", "variantName": "6to Lavado" }],
--     "discounts": [{ "name": "CA BLANCA- ALEXA VASQUEZ ", ... }]
--
-- Porque el 6to lavado se cobra aplicando un descuento del 100%, y la
-- cajera escribio el nombre del cliente en el nombre del descuento en vez
-- del comentario del producto.
--
-- NO es "los gratis van por descuento": el carro 11 tambien fue gratis y
-- ese si traia la nota en el comentario. Depende de como lo capture cada
-- cajera, asi que los dos lugares son validos y hay que leer los dos.
--
-- El interpretador (interpretar_nota) no se toca: ya resolvia bien esa
-- nota, incluso con el guion pegado a "BLANCA-". Lo unico que fallaba era
-- que el texto nunca le llegaba.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Donde buscar la nota
--
-- Primero el comentario del producto, que es el lugar acordado con las
-- cajeras. Si viene vacio, se revisan los descuentos.
--
-- Un descuento se toma como nota SOLO si empieza con un codigo conocido
-- (PU/CA/AU/PA). Eso es lo que protege contra descuentos de verdad: uno
-- que se llame "Descuento empleado" o "Promo martes" no arranca con
-- codigo, interpretar_nota devuelve tipo_unidad nulo, y se ignora. Vale
-- mas dejar el campo vacio que llenarlo con el nombre de una promocion.
-- ---------------------------------------------------------------------
create or replace function public.nota_de_la_venta(p_payload jsonb, p_gratis boolean)
returns text
language sql
stable
as $$
  select coalesce(
    -- 1) El lugar de siempre.
    nullif(btrim(coalesce(detalle_venta(p_payload) -> 'products' -> 0 ->> 'comment', '')), ''),
    -- 2) Respaldo: el primer descuento que se lea como nota de carro.
    (
      select nullif(btrim(d ->> 'name'), '')
      from jsonb_array_elements(
        case
          when jsonb_typeof(detalle_venta(p_payload) -> 'discounts') = 'array'
            then detalle_venta(p_payload) -> 'discounts'
          else '[]'::jsonb
        end
      ) as d
      where (
        interpretar_nota(nullif(btrim(coalesce(d ->> 'name', '')), ''), p_gratis) ->> 'tipo_unidad'
      ) is not null
      limit 1
    )
  );
$$;

comment on function public.nota_de_la_venta(jsonb, boolean) is
  'Saca la nota de la cajera: primero products[0].comment, si no el nombre del descuento.';

-- ---------------------------------------------------------------------
-- El disparador ahora usa esa busqueda
--
-- Unico cambio de fondo: "gratis" se calcula ANTES que "nota", porque
-- ahora la busqueda de la nota lo necesita para interpretar los
-- descuentos. Todo lo demas queda igual.
-- ---------------------------------------------------------------------
create or replace function public.crear_carro_desde_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  producto  jsonb;
  nuevo_id  bigint;
  arranque  timestamptz;
  nota      text;
  gratis    boolean;
  leido     jsonb;
begin
  producto := detalle_venta(new.payload) -> 'products' -> 0;
  arranque := coalesce(new.recibido_en, new.creado_en, now());

  gratis := coalesce(new.monto, 0) = 0 or coalesce(producto ->> 'name', '') ilike 'gratis%';
  nota   := nota_de_la_venta(new.payload, gratis);
  leido  := interpretar_nota(nota, gratis);

  insert into public.carros (
    venta_id, purchase_uuid, monto, producto, variante, es_express, creado_en,
    nota, tipo_unidad, color, cliente, datos_de_nota
  )
  values (
    new.id,
    new.purchase_uuid,
    new.monto,
    producto ->> 'name',
    producto ->> 'variantName',
    coalesce(producto ->> 'name', '') ilike 'express%',
    arranque,
    nota,
    leido ->> 'tipo_unidad',
    leido ->> 'color',
    leido ->> 'cliente',
    (leido ->> 'tipo_unidad') is not null
  )
  on conflict (purchase_uuid) do nothing
  returning id into nuevo_id;

  if nuevo_id is not null then
    insert into public.etapas (carro_id, etapa, inicio)
    values (nuevo_id, 'prelavado', arranque);
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Rescatar los carros que ya entraron sin nota
--
-- Solo toca los que tienen tipo_unidad NULO — o sea, los que nadie ha
-- llenado. Nunca pisa lo que el supervisor haya capturado o corregido a
-- mano en la app. Y solo escribe si de verdad se encontro una nota, para
-- no borrar el campo de los carros que legitimamente no traen ninguna.
-- ---------------------------------------------------------------------
update public.carros c
set nota          = n.nota,
    tipo_unidad   = l.leido ->> 'tipo_unidad',
    color         = l.leido ->> 'color',
    cliente       = l.leido ->> 'cliente',
    datos_de_nota = (l.leido ->> 'tipo_unidad') is not null
from public.ventas v
cross join lateral (
  select (
    coalesce(v.monto, 0) = 0
    or coalesce(detalle_venta(v.payload) -> 'products' -> 0 ->> 'name', '') ilike 'gratis%'
  ) as gratis
) g
cross join lateral (
  select nota_de_la_venta(v.payload, g.gratis) as nota
) n
cross join lateral (
  select interpretar_nota(n.nota, g.gratis) as leido
) l
where c.venta_id = v.id
  and c.tipo_unidad is null
  and n.nota is not null;
