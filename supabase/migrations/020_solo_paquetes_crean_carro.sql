-- =====================================================================
-- RUSH Car Wash — solo un PAQUETE crea carro
--
-- El carro 12 se creo de una venta de puro "Pinito" (aromatizante,
-- categoria "Aroma", $50). No era un vehiculo: era un producto de
-- mostrador. Pero el disparador leia siempre products[0], asi que entro a
-- la cola como si fuera un carro.
--
-- Se detecto el 19/jul/2026 armando el reporte diario: inflaba el conteo
-- de "vehiculos lavados".
--
-- Catalogo real observado (de las ventas ya guardadas):
--
--   Paquetes -> Completo, Completo Cera, Express, Manual, Solo Interior
--   Promo    -> Gratis (6to Lavado)
--   Aroma    -> Pinito
--
-- Ahora se busca en TODOS los renglones del ticket, no solo en el
-- primero. Eso arregla de paso un segundo caso que nadie habia notado: un
-- ticket con el Pinito primero y el Completo despues se guardaba como
-- "Pinito". Ya no.
-- =====================================================================

-- ---------------------------------------------------------------------
-- El renglon del ticket que representa al vehiculo
--
-- Devuelve el primer producto de categoria Paquetes o Promo, o NULL si el
-- ticket no trae ninguno (venta de mostrador).
--
-- Valvula de seguridad: si NINGUN renglon trae categoria — porque Zettle
-- cambio de forma, o porque es una venta vieja rescatada a mano — se cae
-- al primer renglon, como antes. Es preferible un carro de mas que dejar
-- de registrar ventas de golpe por un cambio que no vimos venir.
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

  -- 1) El primer paquete de verdad.
  select p into elegido
    from jsonb_array_elements(renglones) as p
   where coalesce(p -> 'category' ->> 'name', '') in ('Paquetes', 'Promo')
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

  -- 3) Hay categorias y ninguna es paquete: venta de mostrador. Sin carro.
  return null;
end;
$$;

comment on function public.producto_del_vehiculo(jsonb) is
  'El renglon del ticket que representa al vehiculo. NULL = venta de mostrador (no crea carro).';

-- ---------------------------------------------------------------------
-- El disparador
--
-- Unico cambio: usa producto_del_vehiculo() y se sale sin crear nada si
-- devuelve NULL. Todo lo demas queda igual que en la 018.
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
  producto := producto_del_vehiculo(new.payload);

  -- Venta de mostrador (aroma, accesorio). La venta SI se guarda en
  -- ventas; simplemente no hay vehiculo que meter a la cola.
  if producto is null then
    return new;
  end if;

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
