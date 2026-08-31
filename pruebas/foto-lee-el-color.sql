-- =====================================================================
-- LA FOTO LEE EL COLOR Y LA FOTO MANDA (migracion 141).
--
-- Va APARTE de la migracion a proposito: escribe sobre un carro real y
-- termina en `raise` para revertir. Si viviera dentro del archivo de la
-- migracion, ese mismo raise revertiria tambien el DDL y la migracion no
-- se aplicaria nunca. Es el patron de pruebas/ de siempre.
-- =====================================================================
-- ---------------------------------------------------------------------
do $$
declare
  v_carro bigint;
  v_antes text;
  v_color text;
  malos   text := '';
begin
  -- Un carro real de hoy, con color puesto por la nota.
  select id, color into v_carro, v_antes
    from public.carros
   where color is not null and cancelado_en is null and not es_prueba
   order by id desc limit 1;
  if v_carro is null then raise exception 'no hay carro con color para probar'; end if;

  -- 1) La foto MANDA: escribe el color aunque ya hubiera uno de la nota.
  perform public.guardar_datos_de_foto(v_carro, null, null, null, null, null, 'verde limon');
  select color into v_color from public.carros where id = v_carro;
  if v_color is distinct from 'VERDE LIMON' then
    malos := malos || ' la foto no sobreescribio (' || coalesce(v_color,'null') || ')';
  end if;

  -- 2) Un NULO no borra: la nota sigue siendo la red de apoyo.
  perform public.guardar_datos_de_foto(v_carro, null, null, 'TOYOTA', null, null, null);
  select color into v_color from public.carros where id = v_carro;
  if v_color is distinct from 'VERDE LIMON' then
    malos := malos || ' un nulo borro el color';
  end if;

  -- 3) Se guarda en MAYUSCULAS, para poderlo comparar contra el de la nota.
  perform public.guardar_datos_de_foto(v_carro, null, null, null, null, null, '  azul marino ');
  select color into v_color from public.carros where id = v_carro;
  if v_color is distinct from 'AZUL MARINO' then
    malos := malos || ' no normalizo (' || coalesce(v_color,'null') || ')';
  end if;

  -- 4) Las tres firmas nuevas existen y las viejas ya no.
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='guardar_datos_de_foto') <> 1 then
    malos := malos || ' quedaron dos guardar_datos_de_foto';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='pegar_foto_de_caja') <> 1 then
    malos := malos || ' quedaron dos pegar_foto_de_caja';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='registrar_visita_con_carro') <> 1 then
    malos := malos || ' quedaron dos registrar_visita_con_carro';
  end if;

  -- 5) Y registrar_visita_con_carro de verdad recibe el color.
  if (select pg_get_function_identity_arguments(p.oid)
        from pg_proc p join pg_namespace n on n.oid=p.pronamespace
       where n.nspname='public' and p.proname='registrar_visita_con_carro') not like '%p_color text%' then
    malos := malos || ' registrar_visita_con_carro no recibe p_color';
  end if;

  if malos <> '' then
    raise exception 'FALLO 141:%', malos;
  end if;
  raise notice 'la foto manda, un nulo no borra, y las firmas quedaron unicas';
end $$;

-- ---------------------------------------------------------------------
-- La CADENA de la caja: registrar_visita_con_carro -> pegar_foto_de_caja ->
-- guardar_datos_de_foto. El color tiene que llegar hasta el final.
-- Es la parte que la 141 cambio en TRES firmas, y donde un parametro que se
-- queda a medio camino no se nota: la visita se registra igual y el color
-- simplemente no aparece.
-- ---------------------------------------------------------------------
do $$
declare
  v_carro   bigint;
  v_persona bigint;
  v_res     jsonb;
  v_color   text;
  malos     text := '';
begin
  -- Un carro SIN foto (pegar_foto_de_caja solo lee cuando la foto se pega de
  -- verdad a ESTE carro) y sin visita activa.
  select c.id into v_carro
    from public.carros c
   where c.foto_path is null and c.cancelado_en is null and not c.es_prueba
     and not exists (select 1 from public.visitas v where v.carro_id = c.id and v.estado='activa')
   order by c.id desc limit 1;
  if v_carro is null then raise exception 'no hay carro sin foto para probar la cadena'; end if;

  select id into v_persona from public.personas order by id desc limit 1;

  v_res := public.registrar_visita_con_carro(
    p_persona      => v_persona,
    p_carro        => v_carro,
    p_usa_gratis   => false,
    p_caja         => 'prueba',
    p_foto_path    => '2026-08-30/prueba-color.jpg',
    p_placa        => 'ZZZ-999-Z',
    p_marca        => 'MAZDA',
    p_submarca     => 'MAZDA3',
    p_tipo         => 'automovil',
    p_hubo_lectura => true,
    p_color        => 'rojo');

  if coalesce((v_res->>'ok')::boolean, false) is not true then
    malos := malos || ' la caja rechazo el registro: ' || coalesce(v_res->>'error','?');
  end if;

  select color into v_color from public.carros where id = v_carro;
  if v_color is distinct from 'ROJO' then
    malos := malos || ' el color NO llego hasta el carro (' || coalesce(v_color,'null') || ')';
  end if;

  if malos <> '' then raise exception 'FALLO cadena de la caja:%', malos; end if;
  raise exception 'PRUEBA PASADA -> la foto manda sobre la nota, un nulo no borra, las firmas quedaron unicas, y el color llega de la caja hasta el carro (%)', v_color;
end $$;
