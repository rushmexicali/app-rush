-- Prueba de la migracion 106. Revierte todo con el raise final.
--   bash scripts/releer-fotos/q.sh pruebas/perfil-y-jibble.sql
do $$
declare
  v_venta bigint;
  emp     text;
  c_auto  bigint;   -- carro cerrado solo: sus minutos son ficcion
  c_corto bigint;   -- secado de 30 s: olvido registrado tarde
  c_bueno bigint;   -- secado normal
  c_prueb bigint;   -- carro de prueba, con rechazo
  h       jsonb;
  r       jsonb;
  antes   int;
  v_msg   text := '';
  g_uno   uuid := gen_random_uuid();
  g_dos   uuid := gen_random_uuid();
begin
  select id into v_venta from public.ventas order by id desc limit 1;
  -- ⚠️ Se pide NO MANUAL, y no "el que no este fuera".
  --
  -- Antes decia `where estado <> 'fuera'` y eso hacia la prueba dependiente de
  -- LA HORA: despues del cierre todos los de Jibble estan 'fuera' y el unico
  -- que queda es Guillermo, que es `manual` — y a los manuales
  -- `sincronizar_empleados` los exceptua a proposito (para eso existe la
  -- columna). Con un manual de sujeto, el grupo 5 de esta prueba contaba 0
  -- donde esperaba 1 y fallaba sin que nada estuviera roto. Se cacho el
  -- 21/ago a las 20:25, corriendo la suite despues del cierre.
  select id into emp from public.empleados where not manual order by id limit 1;
  if emp is null then raise exception 'no hay empleados para la prueba'; end if;

  -- ---------- escenario ----------
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en, entregado_en, cerrado_automaticamente)
  values ('p106-a-'||gen_random_uuid(), v_venta, 'Completo RUSH','Chico',270, now()-interval '6 hour', now()-interval '1 hour', now()-interval '1 hour')
  returning id into c_auto;
  insert into public.etapas (carro_id, etapa, inicio, fin)
  values (c_auto, 'secando', now()-interval '6 hour', now()-interval '1 hour');

  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en, entregado_en)
  values ('p106-b-'||gen_random_uuid(), v_venta, 'Completo RUSH','Chico',270, now()-interval '3 hour', now()-interval '2 hour')
  returning id into c_corto;
  insert into public.etapas (carro_id, etapa, inicio, fin)
  values (c_corto, 'secando', now()-interval '2 hour', now()-interval '2 hour' + interval '30 second');

  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en, entregado_en)
  values ('p106-c-'||gen_random_uuid(), v_venta, 'Completo RUSH','Chico',270, now()-interval '3 hour', now()-interval '2 hour')
  returning id into c_bueno;
  insert into public.etapas (carro_id, etapa, inicio, fin)
  values (c_bueno, 'secando', now()-interval '3 hour', now()-interval '3 hour' + interval '30 minute');

  insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
  select x, 2, 'x', emp, now()-interval '3 hour' from unnest(array[c_auto,c_corto,c_bueno]) x;

  -- ---------- 1) el perfil marca lo que es ficcion ----------
  -- `p_limite := 0` = todo (110). Explicito a proposito: desde que el perfil
  -- pagina, un default de 50 haria que esta prueba dependa de cuantos carros
  -- lleve esa persona hoy, y fallaria sola con el tiempo sin que nadie rompa
  -- nada.
  h := public.perfil_de_secador(emp, p_limite := 0) -> 'historial';

  if not exists (select 1 from jsonb_array_elements(h) e
                  where (e->>'carro_id')::bigint = c_auto and (e->>'cerrado_solo')::boolean) then
    raise exception 'FALLA: el carro cerrado solo NO viene marcado';
  end if;
  if not exists (select 1 from jsonb_array_elements(h) e
                  where (e->>'carro_id')::bigint = c_corto and (e->>'secado_corto')::boolean) then
    raise exception 'FALLA: el secado de 30 s NO viene marcado como corto';
  end if;
  if exists (select 1 from jsonb_array_elements(h) e
              where (e->>'carro_id')::bigint = c_bueno
                and ((e->>'cerrado_solo')::boolean or (e->>'secado_corto')::boolean)) then
    raise exception 'FALLA: un carro normal salio marcado';
  end if;
  -- y el numero crudo sigue ahi, no se escondio
  if (select (e->>'secado_seg')::int from jsonb_array_elements(h) e
       where (e->>'carro_id')::bigint = c_corto) <> 30 then
    raise exception 'FALLA: se perdio el secado_seg crudo';
  end if;
  v_msg := v_msg || 'banderas del perfil OK. ';

  -- ---------- 2) los rechazos se cuentan por EVENTO ----------
  antes := (public.perfil_de_secador(emp, p_limite := 0) ->> 'rechazos')::int;
  -- un solo rechazo con DOS motivos: dos filas, un grupo
  insert into public.rechazos (carro_id, secador, empleado_id, motivo, grupo, creado_en)
  values (c_bueno, 'x', emp, 'Vidrios', g_uno, now()),
         (c_bueno, 'x', emp, 'Rines',   g_uno, now());

  if (public.perfil_de_secador(emp, p_limite := 0) ->> 'rechazos')::int <> antes + 1 then
    raise exception 'FALLA: un rechazo con dos motivos conto como % (esperaba 1 mas que %)',
      (public.perfil_de_secador(emp, p_limite := 0) ->> 'rechazos')::int, antes;
  end if;
  v_msg := v_msg || 'rechazo por evento OK. ';

  -- ---------- 3) un carro de PRUEBA no le anota rechazos a nadie ----------
  antes := (public.perfil_de_secador(emp, p_limite := 0) ->> 'rechazos')::int;
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en, es_prueba)
  values ('p106-d-'||gen_random_uuid(), v_venta, 'Completo RUSH','Chico',270, now(), true)
  returning id into c_prueb;
  insert into public.rechazos (carro_id, secador, empleado_id, motivo, grupo, creado_en)
  values (c_prueb, 'x', emp, 'Tablero', g_dos, now());

  if (public.perfil_de_secador(emp, p_limite := 0) ->> 'rechazos')::int <> antes then
    raise exception 'FALLA: un carro de PRUEBA le anoto un rechazo a una persona real';
  end if;
  v_msg := v_msg || 'carro de prueba no anota OK. ';

  -- ---------- 4) Jibble con lista vacia NO toca a nadie ----------
  antes := (select count(*) from public.empleados where estado <> 'fuera');
  r := public.sincronizar_empleados('[]'::jsonb);
  if (r->>'ok')::boolean then
    raise exception 'FALLA: acepto una lista vacia';
  end if;
  if (select count(*) from public.empleados where estado <> 'fuera') <> antes then
    raise exception 'FALLA: con lista vacia SI movio a la gente (% -> %)',
      antes, (select count(*) from public.empleados where estado <> 'fuera');
  end if;
  v_msg := v_msg || 'lista vacia no toca a nadie OK. ';

  -- ---------- 5) un id nulo ya no desactiva la barrida ----------
  -- Con el `<> all()` viejo, un solo nulo hacia que NADIE se marcara fuera.
  -- Ahora los nulos se ignoran y la barrida funciona igual.
  r := public.sincronizar_empleados(
         jsonb_build_array(
           jsonb_build_object('id', emp, 'nombre', 'Prueba 106', 'estado', 'activo', 'rol', 'secador'),
           jsonb_build_object('id', null, 'nombre', 'Sin id')));
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: rechazo una lista que SI traia un id bueno (%)', r->>'error';
  end if;
  if (select count(*) from public.empleados where not manual and estado <> 'fuera') <> 1 then
    raise exception 'FALLA: con un id nulo en la lista la barrida no corrio (quedaron % dentro)',
      (select count(*) from public.empleados where not manual and estado <> 'fuera');
  end if;
  v_msg := v_msg || 'id nulo no desactiva la barrida OK. ';

  raise exception 'PRUEBA 106 PASADA -> %', v_msg;
end $$;
