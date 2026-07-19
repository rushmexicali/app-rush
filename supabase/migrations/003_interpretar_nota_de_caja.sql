-- =====================================================================
-- RUSH Car Wash — Fase 2: leer la nota que la cajera escribe en Zettle
--
-- La cajera puede escribir una nota en la venta. Viene en el webhook
-- dentro de products[0].comment. Formato acordado:
--
--     <CODIGO> <COLOR> [NOMBRE DEL CLIENTE]
--
--     PU = pickup      CA = camioneta
--     AU = automovil   PA = pasajeros (tipo combi, 5 hileras)
--
-- Ejemplos:
--     "CA NEGRA"                -> camioneta negra
--     "PU NEGRA LUIS GONZALEZ"  -> pickup negra, 6to lavado de Luis Gonzalez
--
-- Esto PRELLENA la ficha del carro. No es la fuente de la verdad: si la
-- nota falta o viene mal, el supervisor la llena o la corrige en la app.
-- =====================================================================

alter table public.carros add column if not exists nota        text;
alter table public.carros add column if not exists tipo_unidad text;
alter table public.carros add column if not exists color       text;
alter table public.carros add column if not exists cliente     text;

-- Marca si el dato vino de la nota o lo capturo el supervisor. Sirve para
-- medir despues que tan seguido se esta llenando la nota en caja.
alter table public.carros add column if not exists datos_de_nota boolean not null default false;

alter table public.carros drop constraint if exists carros_tipo_unidad_valido;
alter table public.carros add constraint carros_tipo_unidad_valido
  check (tipo_unidad is null or tipo_unidad in ('pickup','camioneta','automovil','pasajeros'));

-- ---------------------------------------------------------------------
-- Interpretar la nota
--
-- Sobre la ambiguedad de "PU NEGRA LUIS GONZALEZ": no hay forma de saber
-- por gramatica donde acaba el color y empieza el nombre. Se usa el dato
-- que ya tenemos: solo los lavados GRATIS llevan nombre de cliente.
--   - Venta normal: todo lo que sigue al codigo es color ("AZUL MARINO").
--   - Venta gratis: la siguiente palabra es el color, el resto es nombre.
-- ---------------------------------------------------------------------
create or replace function public.interpretar_nota(p_nota text, p_gratis boolean default false)
returns jsonb
language plpgsql
immutable
as $$
declare
  partes  text[];
  n       int;
  tipo    text;
  color   text;
  cliente text;
begin
  if p_nota is null or btrim(p_nota) = '' then
    return jsonb_build_object('tipo_unidad', null, 'color', null, 'cliente', null);
  end if;

  partes := regexp_split_to_array(upper(btrim(p_nota)), '\s+');
  n := array_length(partes, 1);

  tipo := case partes[1]
    when 'PU' then 'pickup'
    when 'CA' then 'camioneta'
    when 'AU' then 'automovil'
    when 'PA' then 'pasajeros'
    else null
  end;

  -- Codigo no reconocido: no se adivina nada. Mejor un campo vacio que un
  -- dato inventado, porque el supervisor confia en lo que ve en pantalla.
  if tipo is null then
    return jsonb_build_object('tipo_unidad', null, 'color', null, 'cliente', null);
  end if;

  if n >= 2 then
    if p_gratis and n >= 3 then
      color   := partes[2];
      cliente := array_to_string(partes[3:n], ' ');
    else
      color   := array_to_string(partes[2:n], ' ');
    end if;
  end if;

  return jsonb_build_object('tipo_unidad', tipo, 'color', color, 'cliente', cliente);
end;
$$;

-- ---------------------------------------------------------------------
-- El disparador ahora tambien lee la nota
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

  nota   := nullif(btrim(coalesce(producto ->> 'comment', '')), '');
  gratis := coalesce(new.monto, 0) = 0 or coalesce(producto ->> 'name', '') ilike 'gratis%';
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
-- Releer las notas de los carros que ya existen
-- Solo toca los que NO han sido corregidos a mano (datos_de_nota = false
-- y tipo_unidad nulo), para no pisar lo que capture el supervisor.
-- ---------------------------------------------------------------------
update public.carros c
set nota          = datos.nota,
    tipo_unidad   = datos.leido ->> 'tipo_unidad',
    color         = datos.leido ->> 'color',
    cliente       = datos.leido ->> 'cliente',
    datos_de_nota = (datos.leido ->> 'tipo_unidad') is not null
from (
  select
    v.purchase_uuid,
    nullif(btrim(coalesce(detalle_venta(v.payload) -> 'products' -> 0 ->> 'comment', '')), '') as nota,
    interpretar_nota(
      nullif(btrim(coalesce(detalle_venta(v.payload) -> 'products' -> 0 ->> 'comment', '')), ''),
      coalesce(v.monto, 0) = 0
    ) as leido
  from public.ventas v
) datos
where c.purchase_uuid = datos.purchase_uuid
  and c.tipo_unidad is null;

comment on column public.carros.nota          is 'Nota cruda que escribio la cajera en Zettle.';
comment on column public.carros.datos_de_nota is 'true si el tipo/color vinieron de la nota; false si los capturo el supervisor.';
