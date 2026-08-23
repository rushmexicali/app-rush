-- Prueba de la migracion 115.
--
--   * la retencion de fotos quedo en 60 dias
--   * una venta que llega SIN envolver ya se indexa (la caja la encuentra)
--   * la busqueda de tickets sigue devolviendo lo mismo, y con indice
--   * los comodines de LIKE se buscan literales
--
--   bash scripts/releer-fotos/q.sh pruebas/payload-y-busquedas.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_id    bigint;
  v_txt   text;
  v_n     int;
  v_msg   text := '';
begin
  -- ---------- 1) retencion en 60 dias ----------
  select pg_get_function_arguments(p.oid) into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'olvidar_fotos_viejas';
  if v_txt not like '%p_dias integer DEFAULT 60%' then
    raise exception 'FALLA: la retencion no quedo en 60 dias (%)', v_txt;
  end if;
  v_msg := v_msg || 'retencion 60 OK. ';

  -- ---------- 2) una venta SIN envolver ya se indexa ----------
  -- Es la forma que dejaba ventas invisibles para la caja: el aviso llega
  -- con los campos hasta arriba, no dentro de una llave `payload`.
  insert into public.ventas (purchase_uuid, monto, payload)
  values ('prueba-115-' || gen_random_uuid(), 270,
          jsonb_build_object(
            'purchaseNumber', 999001,
            'userDisplayName', 'CAJERA DE PRUEBA',
            'products', jsonb_build_array(
              jsonb_build_object('name','Completo RUSH','variantName','Chico',
                                 'category', jsonb_build_object('name','Paquetes')))))
  returning id into v_id;

  select ticket_num into v_n from public.ventas where id = v_id;
  if v_n is distinct from 999001 then
    raise exception 'FALLA (#22): la venta sin envolver no saco ticket_num (quedo %)', v_n;
  end if;
  select cajero into v_txt from public.ventas where id = v_id;
  if v_txt is distinct from 'CAJERA DE PRUEBA' then
    raise exception 'FALLA (#22): no saco la cajera (quedo %)', coalesce(v_txt, '<nulo>');
  end if;
  select busqueda into v_txt from public.ventas where id = v_id;
  if v_txt is null or v_txt not like '%completo rush%' then
    raise exception 'FALLA (#22): no armo el texto de busqueda (quedo %)', coalesce(v_txt, '<nulo>');
  end if;
  if (select prods from public.ventas where id = v_id) is null then
    raise exception 'FALLA (#22): no guardo los productos';
  end if;
  v_msg := v_msg || 'venta sin envolver indexada OK. ';

  -- Y la caja la encuentra por numero.
  if jsonb_array_length(public.buscar_tickets('999001', 10)) < 1 then
    raise exception 'FALLA (#22): la caja no encuentra la venta recien indexada';
  end if;
  v_msg := v_msg || 'la caja la encuentra OK. ';

  -- ---------- 3) la venta ENVUELTA sigue funcionando igual ----------
  insert into public.ventas (purchase_uuid, monto, payload)
  values ('prueba-115-env-' || gen_random_uuid(), 270,
          jsonb_build_object('payload', jsonb_build_object(
            'purchaseNumber', 999002,
            'userDisplayName', 'CAJERA ENVUELTA',
            'products', jsonb_build_array(
              jsonb_build_object('name','Express','variantName','Chico',
                                 'category', jsonb_build_object('name','Paquetes'))))))
  returning id into v_id;

  select ticket_num into v_n from public.ventas where id = v_id;
  if v_n is distinct from 999002 then
    raise exception 'FALLA: se rompio la forma ENVUELTA, que es la normal (ticket %)', v_n;
  end if;
  v_msg := v_msg || 'la forma envuelta intacta OK. ';

  -- ---------- 4) los comodines se buscan literales ----------
  if public.como_literal('50%') <> '50\%' then
    raise exception 'FALLA: no escapo el %% (dio %)', public.como_literal('50%');
  end if;
  if public.como_literal('a_b') <> 'a\_b' then
    raise exception 'FALLA: no escapo el guion bajo (dio %)', public.como_literal('a_b');
  end if;
  -- Un patron con comodin no debe traer de mas: '%' solo NO puede devolver
  -- todos los tickets, porque se busca literal.
  if jsonb_array_length(public.buscar_tickets('%', 30)) <> 0 then
    raise exception 'FALLA: buscar "%%" devolvio tickets — el comodin no se escapo';
  end if;
  v_msg := v_msg || 'comodines literales en tickets OK. ';

  -- ---------- 5) ...y en las OTRAS DOS busquedas (migracion 130) ----------
  -- Hasta el 23/ago la regla vivia en `como_literal()` y solo `buscar_tickets`
  -- la usaba. Medido entonces: buscar_personas('%') devolvia 25 clientes
  -- cualquiera y buscar_vehiculos('%') 50 placas. La cajera veia una lista con
  -- cara de resultado bueno y podia tocar al cliente equivocado.
  if jsonb_array_length(public.buscar_personas('%')) <> 0
     or jsonb_array_length(public.buscar_personas('_')) <> 0 then
    raise exception 'FALLA: buscar_personas trata los comodines como comodines';
  end if;
  if jsonb_array_length(public.buscar_vehiculos('%')) <> 0
     or jsonb_array_length(public.buscar_vehiculos('_')) <> 0 then
    raise exception 'FALLA: buscar_vehiculos trata los comodines como comodines';
  end if;
  -- Y lo de verdad sigue saliendo: escapar no puede apagar la busqueda.
  if jsonb_array_length(public.buscar_personas('gonz')) = 0
     or jsonb_array_length(public.buscar_vehiculos('toyota')) = 0 then
    raise exception 'FALLA: escapar apago una busqueda normal';
  end if;
  v_msg := v_msg || 'comodines literales en personas y vehiculos OK. ';

  -- ---------- 6) el indice que si sirve (migracion 130) ----------
  -- El viejo estaba sobre la forma ENVUELTA del aviso, la que la 115 declaro
  -- equivocada: no servia a ninguna consulta viva y se evaluaba en cada insert.
  if exists (select 1 from pg_indexes
              where schemaname='public' and indexname='ventas_purchase_number_idx') then
    raise exception 'FALLA: el indice muerto ventas_purchase_number_idx volvio';
  end if;
  if not exists (select 1 from pg_indexes
                  where schemaname='public' and indexname='ventas_recibo_idx') then
    raise exception 'FALLA: falta ventas_recibo_idx, el que usa el join del import';
  end if;
  v_msg := v_msg || 'indice del recibo OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
