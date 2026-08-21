-- Prueba de la migracion 114: un lavado no puede quedar a nombre de dos
-- clientes, y el candado vive en la BASE, no solo en una funcion.
--
--   bash scripts/releer-fotos/q.sh pruebas/un-lavado-un-cliente.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta bigint;
  p_uno   bigint;
  p_dos   bigint;
  c_uno   bigint;
  v1      bigint;
  v2      bigint;
  r       jsonb;
  v_n     int;
  v_msg   text := '';
  v_fallo boolean;
begin
  select id into v_venta from public.ventas order by id desc limit 1;

  -- ---------- 1) no queda ningun lavado con dos duenos ----------
  select count(*) into v_n from (
    select carro_id from public.visitas
     where estado = 'activa' and carro_id is not null
     group by carro_id having count(*) > 1) x;
  if v_n <> 0 then
    raise exception 'FALLA: quedan % lavados reclamados por dos clientes', v_n;
  end if;
  v_msg := v_msg || 'no quedan lavados con dos duenos OK. ';

  -- ---------- 2) el candado esta en la BASE ----------
  insert into public.personas (nombre, origen) values ('ZZZ Prueba 114 A', 'prueba')
    returning id into p_uno;
  insert into public.personas (nombre, origen) values ('ZZZ Prueba 114 B', 'prueba')
    returning id into p_dos;

  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-114-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now())
  returning id into c_uno;

  insert into public.visitas (persona_id, carro_id, es_gratis, estado, caja, es_prueba)
  values (p_uno, c_uno, false, 'activa', 'prueba', false) returning id into v1;

  -- El segundo insert DEBE reventar. Ojo: se prueba el camino crudo (un
  -- insert directo), no `enlazar_visita_a_carro`, porque el punto de la 114
  -- es justo que la regla ya no dependa de que se pase por esa funcion —
  -- los 14 casos entraron por el import, que no pasaba.
  v_fallo := false;
  begin
    insert into public.visitas (persona_id, carro_id, es_gratis, estado, caja, es_prueba)
    values (p_dos, c_uno, false, 'activa', 'prueba', false) returning id into v2;
  exception when unique_violation then
    v_fallo := true;
  end;
  if not v_fallo then
    raise exception 'FALLA: la base dejo que dos clientes reclamaran el mismo lavado';
  end if;
  v_msg := v_msg || 'candado en la base OK. ';

  -- ---------- 3) pero NO estorba lo legitimo ----------
  -- (a) La misma persona puede tener muchas visitas: son muchos lavados.
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba)
  values (p_uno, false, 'activa', 'prueba', false);
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba)
  values (p_uno, false, 'activa', 'prueba', false);

  -- (b) Muchas visitas SIN lavado ligado conviven sin problema (el indice
  --     es parcial: solo mira las que tienen carro_id).
  select count(*) into v_n from public.visitas
   where persona_id = p_uno and estado = 'activa' and carro_id is null;
  if v_n <> 2 then
    raise exception 'FALLA: el candado estorbo a las visitas sin lavado (quedaron %)', v_n;
  end if;

  -- (c) Una visita DESCARTADA no bloquea: asi se puede corregir un enlace
  --     equivocado sin tener que borrar la fila.
  update public.visitas set estado = 'descartada' where id = v1;
  insert into public.visitas (persona_id, carro_id, es_gratis, estado, caja, es_prueba)
  values (p_dos, c_uno, false, 'activa', 'prueba', false) returning id into v2;
  if v2 is null then
    raise exception 'FALLA: con la primera descartada, la segunda deberia entrar';
  end if;
  v_msg := v_msg || 'no estorba lo legitimo OK. ';

  -- ---------- 4) y una placa SI puede ser de dos personas ----------
  -- Es la otra mitad de la regla del dueno: la mama y el hijo comparten
  -- carro y cada quien tiene su cuenta.
  perform public.ligar_placa_a_persona(p_uno, 'ZZP114A', 'cajera', true);
  perform public.ligar_placa_a_persona(p_dos, 'ZZP114A', 'cajera', true);
  select count(*) into v_n from public.persona_placas
   where placa_norm = public.normalizar_placa('ZZP114A');
  if v_n <> 2 then
    raise exception 'FALLA: una placa dejo de poder ser de dos personas (quedaron %)', v_n;
  end if;
  v_msg := v_msg || 'placa compartida sigue OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
