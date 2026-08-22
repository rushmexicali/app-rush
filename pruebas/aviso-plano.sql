-- Prueba de la migracion 123: el aviso PLANO de Zettle se entiende en las
-- cuatro funciones que lo desarmaban a mano, y los carros con placa dudosa
-- por fin se pueden ver.
--
--   bash scripts/releer-fotos/q.sh pruebas/aviso-plano.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  uid    text := 'prueba123-' || gen_random_uuid();
  tk     text := '990001230';
  c_uno  bigint;
  j      jsonb;
  n      int;
  quedan text;
  msg    text := '';
begin
  -- ---------- 1) nadie desarma el payload a mano ----------
  select string_agg(p.proname, ', ') into quedan
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.prokind='f'
     and pg_get_functiondef(p.oid) like '%payload->>''payload''%';
  if quedan is not null then
    raise exception 'FALLA: siguen desarmando el payload a mano: %', quedan;
  end if;
  msg := msg || 'nadie desarma el payload a mano OK. ';

  -- ---------- 2) una venta PLANA aparece en la caja ----------
  -- Sin la llave 'payload'. Es la forma que Zettle manda a veces y que
  -- `tickets_recientes` no entendia: el ticket sencillamente no salia en la
  -- lista, con el cliente enfrente y la cajera sin saber por que.
  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uid, jsonb_build_object(
        'purchaseUuid', uid, 'purchaseNumber', tk, 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'comment','AU BLANCO',
          'category', jsonb_build_object('name','Paquetes')))), now());

  select id into c_uno from public.carros where purchase_uuid = uid;
  if c_uno is null then raise exception 'FALLA: la venta plana no creo carro'; end if;
  update public.carros set es_prueba = false, cancelado_en = null where id = c_uno;

  j := public.tickets_recientes(20);
  select count(*) into n
    from jsonb_array_elements(j) t where t->>'ticket' = tk;
  if n <> 1 then
    raise exception 'FALLA: el ticket de una venta PLANA no sale en tickets_recientes (n=%)', n;
  end if;
  msg := msg || 'la caja ve el ticket plano OK. ';

  -- ---------- 3) y su detalle tambien ----------
  j := public.ticket_detalle(tk::int);
  if j is null or (j->>'ok') = 'false' then
    raise exception 'FALLA: ticket_detalle no encuentra la venta plana -> %', j;
  end if;
  msg := msg || 'el detalle del ticket plano OK. ';

  -- ---------- 4) los carros con placa dudosa se pueden ver ----------
  -- Se marca el carro de prueba y se comprueba que salga.
  update public.carros set placa_dudosa = 'ZZD123A' where id = c_uno;
  j := public.placas_dudosas_del_rango(
         (now() at time zone 'America/Tijuana')::date,
         (now() at time zone 'America/Tijuana')::date);
  select count(*) into n from jsonb_array_elements(j) x
   where (x->>'carro_id')::bigint = c_uno and x->>'placa_dudosa' = 'ZZD123A';
  if n <> 1 then
    raise exception 'FALLA: el carro con placa dudosa no aparece (n=%)', n;
  end if;
  -- Y trae el ticket, que sale del mismo `detalle_venta`.
  select count(*) into n from jsonb_array_elements(j) x
   where (x->>'carro_id')::bigint = c_uno and x->>'ticket' = tk;
  if n <> 1 then
    raise exception 'FALLA: la lista de placas dudosas no trae el ticket';
  end if;
  msg := msg || 'placa dudosa visible OK. ';

  -- Y un carro SIN placa dudosa no se cuela.
  update public.carros set placa_dudosa = null where id = c_uno;
  j := public.placas_dudosas_del_rango(
         (now() at time zone 'America/Tijuana')::date,
         (now() at time zone 'America/Tijuana')::date);
  select count(*) into n from jsonb_array_elements(j) x
   where (x->>'carro_id')::bigint = c_uno;
  if n <> 0 then
    raise exception 'FALLA: sale un carro que ya no tiene placa dudosa';
  end if;
  msg := msg || 'no se cuela lo limpio OK. ';

  raise exception 'PRUEBA PASADA -> %', msg;
end $$;
