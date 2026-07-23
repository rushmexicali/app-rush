-- =====================================================================
-- 059 — El trigger de la venta deja de repetir el mismo trabajo
--
-- Zettle guarda los datos de la venta como TEXTO dentro del aviso, asi
-- que hay que parsear un JSON adentro de otro. Eso lo hace
-- detalle_venta(), que ademas lleva un try/catch por si viene mal.
--
-- Estaba escrita como expresion repetida en vez de calcularse una vez:
--
--   nota_de_la_venta()      la llamaba 3 veces
--   producto_del_vehiculo() la llamaba 3 veces
--
-- O sea que cada venta que entra reparsea el mismo JSON seis veces. No
-- es que hoy duela (una venta tarda ~1.8 s de punta a punta y esto es
-- una fraccion minuscula), pero Zettle EXIGE que el endpoint responda
-- 200 rapido o marca el destino como fallido — y trabajo repetido en el
-- camino critico de una venta no tiene ninguna razon de ser.
--
-- El resultado es identico: se comprueba abajo releyendo las 331 ventas
-- reales que hay guardadas y comparando producto, variante, categoria y
-- nota, una por una.
--
-- LO QUE NO SE TOCA, a proposito: interpretar_nota() se sigue llamando
-- dos veces por venta — una dentro de nota_de_la_venta (para decidir si
-- un descuento se lee como nota de carro) y otra en el trigger (para
-- leerla de verdad). Quitar esa segunda pasada obligaria a cambiar el
-- contrato de nota_de_la_venta, que hoy devuelve TEXTO. Son 90 llamadas
-- al dia sobre una funcion inmutable; el riesgo de tocar el camino por
-- donde entra el dinero no vale ese ahorro.
-- =====================================================================

create or replace function public.nota_de_la_venta(p_payload jsonb, p_gratis boolean)
returns text
language sql stable as $$
  -- detalle_venta() una sola vez, no tres.
  with d as (select public.detalle_venta(p_payload) as j)
  select coalesce(
    -- 1) El lugar de siempre: el comentario del primer producto.
    (select nullif(btrim(coalesce(d.j -> 'products' -> 0 ->> 'comment', '')), '') from d),

    -- 2) Respaldo: el primer descuento que se lea como nota de carro.
    --    Pasa en los 6to lavado gratis, que se cobran aplicando un
    --    descuento del 100%, y hay cajeras que escriben ahi el nombre
    --    del cliente en vez de en el comentario.
    --    Solo cuenta si arranca con codigo conocido (PU/CA/AU/PA); asi
    --    "Descuento empleado" o "Promo martes" se ignoran solos y nunca
    --    acaban en la ficha del carro.
    (
      select nullif(btrim(x ->> 'name'), '')
        from d,
             lateral jsonb_array_elements(
               case when jsonb_typeof(d.j -> 'discounts') = 'array'
                    then d.j -> 'discounts'
                    else '[]'::jsonb end
             ) as x
       where (public.interpretar_nota(
                nullif(btrim(coalesce(x ->> 'name', '')), ''), p_gratis
              ) ->> 'tipo_unidad') is not null
       limit 1
    )
  );
$$;

create or replace function public.producto_del_vehiculo(p_payload jsonb)
returns jsonb
language plpgsql stable as $$
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

  -- 1) El primer renglon que NO sea de mostrador.
  --
  -- Se listan las que NO crean carro, no las que si. Una categoria nueva
  -- que el dueno invente cae del lado de "si crea carro": si sobra, se ve
  -- en la cola y se quita. Al reves, un servicio se vuelve invisible y
  -- nadie se entera — que es exactamente lo que paso con Paquetes
  -- Especial y Descuento entre el 19 y el 20 de julio, cuando un Super
  -- Brillo de $1,300 se cobraba y nunca aparecia en el telefono.
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
