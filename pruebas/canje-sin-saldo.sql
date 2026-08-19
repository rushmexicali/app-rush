-- Prueba: un canje sin saldo se RECHAZA (decision del dueno, 19/ago/2026),
-- y todo lo que YA funcionaba sigue funcionando.
--
-- Corre contra la base real y REVIERTE TODO con el raise final. Es el patron
-- del proyecto: probar de verdad sin ensuciar la cola del supervisor.
--
--   bash scripts/releer-fotos/q.sh pruebas/canje-sin-saldo.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta   bigint;
  p_nuevo   bigint;   -- persona sin un solo lavado: saldo 0
  p_conuno  bigint;   -- persona con saldo 1 (se le siembran 5 pagados)
  c_6to     bigint;   -- ticket Gratis / 6to Lavado
  c_6toexp  bigint;   -- ticket Gratis / 6to Express
  c_normal  bigint;   -- ticket Completo RUSH
  c_cort    bigint;   -- ticket Gratis / Cortesia
  c_otro    bigint;   -- otro ticket normal, limpio, para el caso del switch
  r         jsonb;
  v_msg     text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;

  insert into public.personas (nombre, origen) values ('ZZZ Prueba Saldo Cero', 'prueba')
    returning id into p_nuevo;
  insert into public.personas (nombre, origen) values ('ZZZ Prueba Con Saldo', 'prueba')
    returning id into p_conuno;

  -- Cinco lavados pagados => 1 gratis ganado, 0 canjeados => saldo 1.
  insert into public.visitas (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba)
  select p_conuno, false, false, 'activa', 'prueba', false from generate_series(1,5);

  if public.saldo_de_gratis(p_conuno) <> 1 then
    raise exception 'FALLA: el escenario no quedo bien, saldo=% (esperaba 1)', public.saldo_de_gratis(p_conuno);
  end if;
  if public.saldo_de_gratis(p_nuevo) <> 0 then
    raise exception 'FALLA: la persona nueva deberia tener saldo 0';
  end if;
  v_msg := v_msg || 'escenario OK. ';

  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-105-a-' || gen_random_uuid(), v_venta, 'Gratis', '6to Lavado', 0, now())
  returning id into c_6to;
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-105-b-' || gen_random_uuid(), v_venta, 'Gratis', '6to Express', 0, now())
  returning id into c_6toexp;
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-105-c-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now())
  returning id into c_normal;
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-105-d-' || gen_random_uuid(), v_venta, 'Gratis', 'Cortesia', 0, now())
  returning id into c_cort;
  -- Un ticket limpio para el ultimo caso: si se reusa uno ya registrado, el
  -- candado de "ese ticket ya se registro" lo ataja ANTES y la prueba mide
  -- otra cosa. (Asi fallo la primera version de esta prueba.)
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-105-e-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now())
  returning id into c_otro;

  -- ---------- 1) LO NUEVO: canje sin saldo se rechaza ----------
  r := public.registrar_visita_con_carro(p_persona := p_nuevo, p_carro := c_6to);
  if (r->>'ok')::boolean then
    raise exception 'FALLA: dejo canjear un 6to a alguien SIN saldo';
  end if;
  if r->>'motivo' is distinct from 'sin_saldo' then
    raise exception 'FALLA: rechazo pero sin el motivo sin_saldo (dio %)', r->>'motivo';
  end if;
  if not exists (select 1 from public.visitas where carro_id = c_6to) then
    null;  -- correcto: no se registro nada
  else
    raise exception 'FALLA: rechazo pero SI dejo la visita escrita';
  end if;
  v_msg := v_msg || 'rechaza sin saldo OK. ';

  -- ---------- 2) CON saldo si pasa, y consume el gratis ----------
  r := public.registrar_visita_con_carro(p_persona := p_conuno, p_carro := c_6to);
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: NO dejo canjear teniendo saldo 1 (%)', r->>'error';
  end if;
  if not (r->>'es_gratis')::boolean then
    raise exception 'FALLA: paso pero no lo conto como canje';
  end if;
  if public.saldo_de_gratis(p_conuno) <> 0 then
    raise exception 'FALLA: el canje no consumio el gratis (saldo=%)', public.saldo_de_gratis(p_conuno);
  end if;
  v_msg := v_msg || 'canje con saldo OK. ';

  -- ---------- 3) y ya sin saldo, el segundo se rechaza ----------
  r := public.registrar_visita_con_carro(p_persona := p_conuno, p_carro := c_6toexp);
  if (r->>'ok')::boolean then
    raise exception 'FALLA: dejo un SEGUNDO canje con el saldo ya en cero';
  end if;
  v_msg := v_msg || 'segundo canje rechazado OK. ';

  -- ---------- 4) lo que NO es canje no se toca ----------
  r := public.registrar_visita_con_carro(p_persona := p_nuevo, p_carro := c_normal);
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: un lavado NORMAL se rechazo por saldo (%)', r->>'error';
  end if;
  r := public.registrar_visita_con_carro(p_persona := p_nuevo, p_carro := c_cort);
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: una CORTESIA se rechazo por saldo (%)', r->>'error';
  end if;
  if not (r->>'es_cortesia')::boolean then
    raise exception 'FALLA: la cortesia no se marco como cortesia';
  end if;
  v_msg := v_msg || 'normal y cortesia intactos OK. ';

  -- ---------- 5) el 6to Express ya es express ----------
  if not public.es_lavado_express('Gratis', '6to Express') then
    raise exception 'FALLA: `Gratis`+`6to Express` sigue sin contar como express';
  end if;
  if public.lleva_aspirado('Gratis', '6to Express') then
    raise exception 'FALLA: el 6to Express sigue contando con aspirado';
  end if;
  if not public.es_lavado_express('Gratis', '6to Lavado') = false then
    raise exception 'FALLA: un 6to Lavado normal se volvio express';
  end if;
  if public.lleva_aspirado('Gratis', '6to Lavado') is not true then
    raise exception 'FALLA: el 6to Lavado normal dejo de llevar aspirado';
  end if;
  v_msg := v_msg || '6to Express OK. ';

  -- ---------- 6) el switch de la cajera sigue con su candado ----------
  r := public.registrar_visita_con_carro(p_persona := p_conuno, p_carro := c_otro, p_usa_gratis := true);
  if (r->>'ok')::boolean then
    raise exception 'FALLA: acepto el switch de gratis con un ticket que no es 6to';
  end if;
  if r->>'motivo' is distinct from 'sin_gratis' then
    raise exception 'FALLA: motivo equivocado para el switch (%)', r->>'motivo';
  end if;
  v_msg := v_msg || 'switch de la cajera OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
