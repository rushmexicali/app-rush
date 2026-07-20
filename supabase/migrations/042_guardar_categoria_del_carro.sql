-- =====================================================================
-- RUSH Car Wash — el carro guarda su categoria de Zettle
--
-- Sigue de la 041. Ahi se decidio que la categoria del dueno es la que
-- agrupa el reporte; aqui se empieza a guardar y se rellena hacia atras.
--
-- Unico cambio en el disparador: se toma producto -> category -> name y
-- se guarda en carros.categoria. Todo lo demas es identico a la 029.
-- =====================================================================

create or replace function public.crear_carro_desde_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  detalle   jsonb;
  producto  jsonb;
  nuevo_id  bigint;
  arranque  timestamptz;
  nota      text;
  gratis    boolean;
  leido     jsonb;
  devuelve  text;
begin
  detalle  := detalle_venta(new.payload);
  devuelve := nullif(btrim(coalesce(detalle ->> 'refundsPurchaseUuid', '')), '');

  -- --- Devolucion -----------------------------------------------------
  if devuelve is not null or coalesce(new.monto, 0) < 0 then
    if devuelve is not null then
      update public.carros
         set cancelado_en = now()
       where purchase_uuid = devuelve
         and estado <> 'entregado'
         and cancelado_en is null;
    end if;
    return new;
  end if;

  producto := producto_del_vehiculo(new.payload);

  if producto is null then
    return new;
  end if;

  arranque := coalesce(new.recibido_en, new.creado_en, now());

  gratis := coalesce(new.monto, 0) = 0 or coalesce(producto ->> 'name', '') ilike 'gratis%';
  nota   := nota_de_la_venta(new.payload, gratis);
  leido  := interpretar_nota(nota, gratis);

  insert into public.carros (
    venta_id, purchase_uuid, monto, producto, variante, categoria, es_express, creado_en,
    nota, tipo_unidad, color, cliente, datos_de_nota
  )
  values (
    new.id,
    new.purchase_uuid,
    new.monto,
    producto ->> 'name',
    producto ->> 'variantName',
    -- Nuevo: la taxonomia del dueno viaja con el carro.
    nullif(btrim(coalesce(producto -> 'category' ->> 'name', '')), ''),
    es_lavado_express(producto ->> 'name', producto ->> 'variantName'),
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
-- Rellenar hacia atras, leyendo la categoria del payload guardado
--
-- Se puede porque desde el dia uno se guarda el aviso completo de Zettle
-- en ventas.payload, aunque entonces no se usara. Esa decision es la que
-- hace posible este relleno hoy.
-- ---------------------------------------------------------------------
update public.carros c
   set categoria = nullif(btrim(coalesce(
         public.producto_del_vehiculo(v.payload) -> 'category' ->> 'name', '')), '')
  from public.ventas v
 where v.id = c.venta_id
   and c.categoria is null;
