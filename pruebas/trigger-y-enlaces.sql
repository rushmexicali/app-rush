-- Prueba de la migracion 111:
--
--   #24  un error creando el carro ya NO tumba la venta, y queda escrito.
--   #25  enlazar_visita_a_carro normaliza la placa y respeta el candado.
--   #25  desenlazar_visita no borra la foto ni el cliente que no puso.
--   #25  cerrar_pendientes alcanza al carro que entro despues del corte.
--
-- Corre contra la base real y REVIERTE TODO con el raise final.
--
--   bash scripts/releer-fotos/q.sh pruebas/trigger-y-enlaces.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta   bigint;
  v_venta2  bigint;
  p_uno     bigint;
  c_ayer    bigint;
  c_placa   bigint;   -- ya trae la placa de hoy
  c_choca   bigint;   -- el que va a intentar repetirla
  c_limpio  bigint;
  c_desenl  bigint;   -- carro aparte para probar desenlazar (114: un lavado, una visita)
  vis       bigint;
  vis2      bigint;
  vis3      bigint;
  r         jsonb;
  v_txt     text;
  v_n       int;
  v_msg     text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;

  -- ==================================================================
  -- #24 - la venta sobrevive aunque el carro reviente
  -- ==================================================================
  -- Se rompe el insert del carro con una restriccion temporal, en vez de
  -- reemplazar una funcion de verdad: asi la prueba no toca ninguna regla
  -- del negocio y la falla ocurre EXACTAMENTE donde el hallazgo dice (al
  -- insertar el carro, dentro del trigger).
  alter table public.carros
    add constraint prueba_111_boom check (producto <> 'PRODUCTO QUE REVIENTA 111');

  insert into public.ventas (purchase_uuid, monto, payload)
  values ('prueba-111-boom-' || gen_random_uuid(), 270,
          '{"products":[{"name":"PRODUCTO QUE REVIENTA 111","variantName":"Chico","quantity":"1","unitPrice":27000,"category":{"name":"Paquetes"}}]}'::jsonb)
  returning id into v_venta2;

  if v_venta2 is null then
    raise exception 'FALLA (#24): la venta no se guardo';
  end if;
  if exists (select 1 from public.carros where venta_id = v_venta2) then
    raise exception 'FALLA: el carro se creo y la restriccion de prueba no sirvio (la prueba no mide nada)';
  end if;
  if not exists (select 1 from public.webhook_bitacora
                  where motivo = 'trigger_carro_fallo'
                    and crudo like '%PRODUCTO QUE REVIENTA 111%') then
    raise exception 'FALLA (#24): la venta se salvo pero el error NO quedo escrito en la bitacora';
  end if;
  alter table public.carros drop constraint prueba_111_boom;
  v_msg := v_msg || 'venta sobrevive y queda escrito OK. ';

  -- ==================================================================
  -- #25 - el indice existe
  -- ==================================================================
  if not exists (select 1 from pg_indexes
                  where schemaname = 'public' and indexname = 'asignaciones_empleado_idx') then
    raise exception 'FALLA (#25): falta el indice asignaciones_empleado_idx';
  end if;
  v_msg := v_msg || 'indice OK. ';

  -- ==================================================================
  -- #25 - enlazar_visita_a_carro
  -- ==================================================================
  insert into public.personas (nombre, origen) values ('ZZZ Prueba 111', 'prueba')
    returning id into p_uno;

  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-111-limpio-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now())
  returning id into c_limpio;

  insert into public.visitas (persona_id, placa, marca, tipo_unidad, es_gratis, estado, caja, es_prueba)
  values (p_uno, 'zz-p111-b', 'toyota', 'automovil', false, 'activa', 'prueba', false)
  returning id into vis;

  r := public.enlazar_visita_a_carro(vis, c_limpio);
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: no dejo enlazar una visita limpia -> %', r->>'error';
  end if;

  -- La placa se guarda NORMALIZADA, y lo tecleado queda en placa_display.
  select placa into v_txt from public.carros where id = c_limpio;
  if v_txt is distinct from public.normalizar_placa('zz-p111-b') then
    raise exception 'FALLA (#25): guardo la placa cruda (%) en vez de la normalizada', v_txt;
  end if;
  if v_txt <> upper(v_txt) then
    raise exception 'FALLA: la placa quedo en minusculas (%)', v_txt;
  end if;
  -- La marca tambien se sube a mayusculas, como en el camino de la foto.
  select marca into v_txt from public.carros where id = c_limpio;
  if v_txt is distinct from 'TOYOTA' then
    raise exception 'FALLA: la marca no quedo normalizada (%)', v_txt;
  end if;
  v_msg := v_msg || 'placa normalizada OK. ';

  -- ---------- el candado de placa repetida del dia ----------
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en, placa)
  values ('prueba-111-placa-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
          public.normalizar_placa('ZZP111C'))
  returning id into c_placa;

  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en)
  values ('prueba-111-choca-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now())
  returning id into c_choca;

  insert into public.visitas (persona_id, placa, es_gratis, estado, caja, es_prueba)
  values (p_uno, 'ZZP111C', false, 'activa', 'prueba', false)
  returning id into vis2;

  r := public.enlazar_visita_a_carro(vis2, c_choca);
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: el choque de placa no debe impedir el enlace, solo la escritura de la placa';
  end if;
  if not (r->>'placa_dudosa')::boolean then
    raise exception 'FALLA (#25): la caja se salto el candado de placa repetida del dia';
  end if;
  select placa into v_txt from public.carros where id = c_choca;
  if v_txt is not null then
    raise exception 'FALLA (#25): escribio la placa repetida (%) en el carro equivocado', v_txt;
  end if;
  select placa_dudosa into v_txt from public.carros where id = c_choca;
  if v_txt is null then
    raise exception 'FALLA: no dejo la placa dudosa para revisar';
  end if;
  -- Y NO se le pego esa placa al cliente: seria darle el carro de otro.
  if exists (select 1 from public.persona_placas
              where persona_id = p_uno and placa_norm = public.normalizar_placa('ZZP111C')) then
    raise exception 'FALLA (#25): ligo al cliente una placa que estaba en choque';
  end if;
  v_msg := v_msg || 'candado de la caja OK. ';

  -- ==================================================================
  -- #25 - desenlazar_visita no se lleva lo que no es suyo
  -- ==================================================================
  -- El carro trae el cliente de la NOTA de la cajera y la foto del
  -- SUPERVISOR; la visita no aporto ninguna de las dos.
  --
  -- ⚠️ Va en un carro APARTE, no en c_limpio: ese ya tiene la visita `vis`
  -- pegada, y desde la 114 un lavado no puede tener dos visitas activas. El
  -- indice unico cacho esta prueba cuando se creo — la prueba estaba armando
  -- un escenario que en produccion ya no puede existir.
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en,
                             cliente, foto_path)
  values ('prueba-111-desenl-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270, now(),
          'JUAN DE LA NOTA', 'supervisor/prueba-111.jpg')
  returning id into c_desenl;

  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, carro_id, enlazada_en)
  values (p_uno, false, 'activa', 'prueba', false, c_desenl, now())
  returning id into vis3;

  r := public.desenlazar_visita(vis3);
  if not (r->>'ok')::boolean then
    raise exception 'FALLA: no dejo desenlazar';
  end if;

  select cliente into v_txt from public.carros where id = c_desenl;
  if v_txt is distinct from 'JUAN DE LA NOTA' then
    raise exception 'FALLA (#25): borro el cliente que puso la nota de caja (quedo %)', coalesce(v_txt, '<nulo>');
  end if;
  select foto_path into v_txt from public.carros where id = c_desenl;
  if v_txt is distinct from 'supervisor/prueba-111.jpg' then
    raise exception 'FALLA (#25): borro la foto del supervisor (quedo %)', coalesce(v_txt, '<nulo>');
  end if;
  v_msg := v_msg || 'desenlazar respeta lo ajeno OK. ';

  -- Y la foto que SI aporto la visita si se quita.
  update public.visitas set carro_id = c_desenl, enlazada_en = now(), foto_path = 'caja/prueba-111.jpg'
   where id = vis3;
  update public.carros set foto_path = 'caja/prueba-111.jpg' where id = c_desenl;

  r := public.desenlazar_visita(vis3);
  select foto_path into v_txt from public.carros where id = c_desenl;
  if v_txt is not null then
    raise exception 'FALLA: no quito la foto que SI era de la visita (quedo %)', v_txt;
  end if;
  v_msg := v_msg || 'y si quita la suya OK. ';

  -- ==================================================================
  -- #25 - cerrar_pendientes alcanza al que entro despues del corte
  -- ==================================================================
  insert into public.carros (purchase_uuid, venta_id, producto, variante, monto, creado_en, estado)
  values ('prueba-111-ayer-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
          now() - interval '1 day', 'secando')
  returning id into c_ayer;
  insert into public.etapas (carro_id, etapa, inicio)
  values (c_ayer, 'secando', now() - interval '1 day');

  r := public.cerrar_pendientes();

  select estado into v_txt from public.carros where id = c_ayer;
  if v_txt is distinct from 'entregado' then
    raise exception 'FALLA (#25): el carro de ayer sigue abierto (estado %)', v_txt;
  end if;
  if (select cerrado_automaticamente from public.carros where id = c_ayer) is null then
    raise exception 'FALLA: lo cerro pero no lo marco como cerrado automaticamente';
  end if;
  select count(*) into v_n from public.etapas where carro_id = c_ayer and fin is null;
  if v_n <> 0 then
    raise exception 'FALLA: dejo % etapas abiertas', v_n;
  end if;
  v_msg := v_msg || 'cerrar_pendientes alcanza al rezagado OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
