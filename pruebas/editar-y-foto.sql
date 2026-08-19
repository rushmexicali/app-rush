-- Prueba de la migracion 109:
--
--   #17  editar_carro no escribe nada si va a rechazar el guardado.
--   #18  una lectura de foto que no vio un campo ya no borra ese campo,
--        salvo que la placa diga que lo guardado era de OTRO carro.
--
-- Corre contra la base real y REVIERTE TODO con el raise final.
--
--   bash scripts/releer-fotos/q.sh pruebas/editar-y-foto.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta  bigint;
  v_emp    text;
  c_edit   bigint;   -- carro secando, para editar_carro
  c_b      bigint;   -- foto: sin placa, con marca
  c_c      bigint;   -- foto: con placa, lectura de OTRO carro
  c_d      bigint;   -- foto: lectura totalmente muda
  c_e      bigint;   -- foto: dueno de la placa, para el choque
  c_f      bigint;   -- foto: el que choca
  r        jsonb;
  v_txt    text;
  v_txt2   text;
  v_n      int;
  v_msg    text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;
  select id into v_emp   from public.empleados limit 1;

  -- ==================================================================
  -- #17 - editar_carro
  -- ==================================================================
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en,
     estado, linea, tipo_unidad, color)
  values
    ('prueba-109-edit-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
     'secando', 2, 'automovil', 'AZUL')
  returning id into c_edit;

  insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
  values (c_edit, 2, 'PRUEBA109', v_emp, now());

  if public.es_lavado_express('Completo RUSH', 'Chico') then
    raise exception 'FALLA: el escenario no sirve, el carro de prueba salio express';
  end if;

  -- ---------- 1) rechaza por quedarse sin secadores y NO escribe ----------
  r := public.editar_carro(
         p_carro     := c_edit,
         p_color     := 'ROJO',
         p_secadores := array[]::text[],
         p_empleados := array[]::text[]);

  if (r->>'ok')::boolean then
    raise exception 'FALLA: dejo guardar un carro secando sin ningun secador';
  end if;

  select color into v_txt from public.carros where id = c_edit;
  if v_txt is distinct from 'AZUL' then
    raise exception 'FALLA (#17): guardo el color % aunque rechazo el guardado', v_txt;
  end if;

  select count(*) into v_n from public.asignaciones where carro_id = c_edit and fin is null;
  if v_n <> 1 then
    raise exception 'FALLA (#17): las asignaciones quedaron en % despues de un guardado rechazado', v_n;
  end if;
  v_msg := v_msg || 'rechazo sin escribir OK. ';

  -- ---------- 2) rechaza por la linea 1 y tampoco escribe ----------
  r := public.editar_carro(
         p_carro     := c_edit,
         p_color     := 'NEGRO',
         p_linea     := 1::smallint,
         p_secadores := array['PRUEBA109'],
         p_empleados := array[v_emp]);

  if (r->>'ok')::boolean then
    raise exception 'FALLA: mando un no-express a la linea 1';
  end if;
  select color, linea::text into v_txt, v_txt2 from public.carros where id = c_edit;
  if v_txt is distinct from 'AZUL' or v_txt2 is distinct from '2' then
    raise exception 'FALLA (#17): la linea 1 rechazada dejo color=% linea=%', v_txt, v_txt2;
  end if;
  v_msg := v_msg || 'linea 1 OK. ';

  -- ---------- 3) un guardado bueno sigue guardando ----------
  r := public.editar_carro(
         p_carro     := c_edit,
         p_color     := 'verde',
         p_linea     := 3::smallint,
         p_secadores := array['PRUEBA109', 'PRUEBA109B'],
         p_empleados := array[v_emp, v_emp]);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: rechazo un guardado que era valido -> %', r->>'error';
  end if;
  select color, linea::text into v_txt, v_txt2 from public.carros where id = c_edit;
  if v_txt is distinct from 'VERDE' or v_txt2 is distinct from '3' then
    raise exception 'FALLA: el guardado bueno dejo color=% linea=%', v_txt, v_txt2;
  end if;
  select count(*) into v_n from public.asignaciones where carro_id = c_edit and fin is null;
  if v_n <> 2 then
    raise exception 'FALLA: se esperaban 2 secadores y quedaron %', v_n;
  end if;
  select count(*) into v_n from public.asignaciones where carro_id = c_edit and linea = 3;
  if v_n <> 2 then
    raise exception 'FALLA: las asignaciones no siguieron a la linea nueva';
  end if;
  v_msg := v_msg || 'guardado bueno OK. ';

  -- ==================================================================
  -- #18 - guardar_datos_de_foto
  -- ==================================================================

  -- ---------- 4) lectura que ve la placa pero no la marca ----------
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, marca, submarca)
  values
    ('prueba-109-b-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
     'TOYOTA', 'TUNDRA')
  returning id into c_b;

  r := public.guardar_datos_de_foto(
         p_carro := c_b, p_placa := 'ZZP109B', p_marca := null, p_submarca := null);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: guardar_datos_de_foto rechazo el carro B';
  end if;
  select marca into v_txt from public.carros where id = c_b;
  if v_txt is distinct from 'TOYOTA' then
    raise exception 'FALLA (#18): la lectura muda borro la marca, quedo %', coalesce(v_txt, '<nulo>');
  end if;
  select submarca into v_txt from public.carros where id = c_b;
  if v_txt is distinct from 'TUNDRA' then
    raise exception 'FALLA (#18): la lectura muda borro la submarca, quedo %', coalesce(v_txt, '<nulo>');
  end if;
  select placa into v_txt from public.carros where id = c_b;
  if v_txt is distinct from public.normalizar_placa('ZZP109B') then
    raise exception 'FALLA: no guardo la placa que si se leyo, quedo %', coalesce(v_txt, '<nulo>');
  end if;
  v_msg := v_msg || 'nulo no borra OK. ';

  -- ---------- 5) placa distinta = era otro carro, se reemplaza entero ----------
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, marca, submarca, placa)
  values
    ('prueba-109-c-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
     'HONDA', 'CIVIC', public.normalizar_placa('ZZP109C1'))
  returning id into c_c;

  r := public.guardar_datos_de_foto(
         p_carro := c_c, p_placa := 'ZZP109C2', p_marca := null, p_submarca := null);

  select placa into v_txt from public.carros where id = c_c;
  if v_txt is distinct from public.normalizar_placa('ZZP109C2') then
    raise exception 'FALLA: la placa nueva no reemplazo a la vieja, quedo %', coalesce(v_txt, '<nulo>');
  end if;
  select marca into v_txt from public.carros where id = c_c;
  if v_txt is not null then
    raise exception 'FALLA (#18): la placa dijo que era otro carro y la marca % se quedo', v_txt;
  end if;
  select submarca into v_txt from public.carros where id = c_c;
  if v_txt is not null then
    raise exception 'FALLA (#18): la submarca de otro carro se quedo (%)', v_txt;
  end if;
  v_msg := v_msg || 'otro carro se reemplaza OK. ';

  -- ---------- 6) lectura totalmente muda: no pierde nada, pero cuenta como intento ----------
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, marca, placa)
  values
    ('prueba-109-d-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
     'MAZDA', public.normalizar_placa('ZZP109D'))
  returning id into c_d;

  r := public.guardar_datos_de_foto(p_carro := c_d);

  select placa into v_txt from public.carros where id = c_d;
  if v_txt is distinct from public.normalizar_placa('ZZP109D') then
    raise exception 'FALLA (#18): una lectura muda borro la placa buena';
  end if;
  select marca into v_txt from public.carros where id = c_d;
  if v_txt is distinct from 'MAZDA' then
    raise exception 'FALLA (#18): una lectura muda borro la marca buena';
  end if;
  if (select placa_en from public.carros where id = c_d) is null then
    raise exception 'FALLA: no estampo placa_en, el carro volveria a la cola de relectura para siempre';
  end if;
  v_msg := v_msg || 'lectura muda OK. ';

  -- ---------- 7) el candado de placa repetida del dia sigue vivo ----------
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, placa)
  values
    ('prueba-109-e-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
     public.normalizar_placa('ZZP109E'))
  returning id into c_e;

  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, marca)
  values
    ('prueba-109-f-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(), 'KIA')
  returning id into c_f;

  r := public.guardar_datos_de_foto(p_carro := c_f, p_placa := 'ZZP109E', p_marca := 'NISSAN');

  if not (r->>'placa_dudosa')::boolean then
    raise exception 'FALLA: el candado de placa repetida del dia dejo de atajar';
  end if;
  select placa into v_txt from public.carros where id = c_f;
  if v_txt is not null then
    raise exception 'FALLA: escribio la placa repetida en el carro equivocado';
  end if;
  select marca into v_txt from public.carros where id = c_f;
  if v_txt is distinct from 'KIA' then
    raise exception 'FALLA: el choque de placa toco la marca (quedo %)', coalesce(v_txt, '<nulo>');
  end if;
  select placa_dudosa into v_txt from public.carros where id = c_f;
  if v_txt is null then
    raise exception 'FALLA: no dejo la placa dudosa para revisar';
  end if;
  v_msg := v_msg || 'placa repetida OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
