-- 066 · Una venta sin renglon de producto NO crea carro
--
-- El 24/jul/2026 el carro 491 salio de la nada: la venta era un cargo de
-- monto libre en Zettle -- type "CUSTOM_AMOUNT", name "" (vacio), sin
-- categoria -- por $100, con comentario "DIF PAQ MANUEL COMPLETO" (la
-- diferencia de paquete de un lavado que ya estaba en el sistema). Eso NO es
-- un lavado: es un cobro extra sobre un carro que ya existe.
--
-- Aun asi creo un carro fantasma, porque producto_del_vehiculo, en su ruta 2
-- (cuando ningun renglon trae categoria), devolvia `renglones -> 0` a ciegas
-- -- incluido un renglon sin nombre. Ese carro fantasma:
--   - inflo "vehiculos lavados" del 24 en 1,
--   - salio como "sin_clasificar" en el reporte,
--   - y quedo con la MISMA placa que el carro real de ese Ford Bronco (490),
--     porque el supervisor le tomo foto al mismo carro.
--
-- La regla, en UN solo lugar (producto_del_vehiculo, que es EL lugar que
-- decide "hay producto / cual"): un renglon cuenta como producto solo si
-- tiene NOMBRE. Sin nombre no es un lavado y no crea carro.
--
-- No toca la ruta por categoria salvo para exigir tambien el nombre (un
-- CUSTOM_AMOUNT no trae categoria, asi que ya caia en la ruta 2; el filtro
-- en la ruta 1 es defensivo y mantiene la misma regla consistente dentro de
-- la funcion).

create or replace function public.producto_del_vehiculo(p_payload jsonb)
returns jsonb
language plpgsql
stable
as $function$
declare
  detalle       jsonb;
  renglones     jsonb;
  elegido       jsonb;
  con_categoria int;
begin
  -- Una sola vez, no tres.
  detalle := public.detalle_venta(p_payload);

  renglones := case
    when jsonb_typeof(detalle -> 'products') = 'array'
      then detalle -> 'products'
    else '[]'::jsonb
  end;

  if jsonb_array_length(renglones) = 0 then
    return null;
  end if;

  -- 1) El primer renglon que NO sea de mostrador y que SEA un producto de
  --    verdad (con nombre).
  --
  -- Se listan las que NO crean carro, no las que si. Una categoria nueva
  -- que el dueno invente cae del lado de "si crea carro": si sobra, se ve
  -- en la cola y se quita. Al reves, un servicio se vuelve invisible y
  -- nadie se entera -- que es exactamente lo que paso con Paquetes
  -- Especial y Descuento entre el 19 y el 20 de julio, cuando un Super
  -- Brillo de $1,300 se cobraba y nunca aparecia en el telefono.
  select p into elegido
    from jsonb_array_elements(renglones) as p
   where coalesce(p -> 'category' ->> 'name', '')
         not in ('Aroma', 'Extras', 'Insumos')
     and nullif(btrim(coalesce(p -> 'category' ->> 'name', '')), '') is not null
     and nullif(btrim(coalesce(p ->> 'name', '')), '') is not null
   limit 1;

  if elegido is not null then
    return elegido;
  end if;

  -- 2) Nadie trae categoria: no podemos distinguir de mostrador, pero SI
  --    exigimos que sea un producto con nombre. Un CUSTOM_AMOUNT sin nombre
  --    -- una "diferencia de paquete" cobrada como monto libre, p.ej. -- no
  --    es un lavado y no debe crear carro (24/jul/2026, carro 491).
  select count(*) into con_categoria
    from jsonb_array_elements(renglones) as p
   where nullif(btrim(coalesce(p -> 'category' ->> 'name', '')), '') is not null;

  if con_categoria = 0 then
    select p.val into elegido
      from jsonb_array_elements(renglones) with ordinality as p(val, ord)
     where nullif(btrim(coalesce(p.val ->> 'name', '')), '') is not null
     order by p.ord
     limit 1;
    return elegido;   -- null si ningun renglon tiene nombre -> sin carro
  end if;

  -- 3) Todo el ticket es de mostrador. Sin carro.
  return null;
end;
$function$;
