-- Prueba de la migracion 120: las devoluciones son devoluciones, la que
-- ocurre DESPUES de entregar se ve, y el tiempo imposible no se le cuenta a
-- nadie como lavado.
--
--   bash scripts/releer-fotos/q.sh pruebas/numeros-del-reporte.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  r      jsonb;
  n      int;
  msg    text := '';
  emp    text;
  antes  int; despues int;
  uidA   text := 'prueba120a-' || gen_random_uuid();
  uidB   text := 'prueba120b-' || gen_random_uuid();
  c_a    bigint; c_b bigint;
  hoy    date := (now() at time zone 'America/Tijuana')::date;
begin
  -- ---------- 1) el unico devuelto tras entregar de la historia ----------
  -- El carro 70 (19/jul, Completo Cera $270) se devolvio un minuto despues
  -- de entregarse. Es el caso que el §13 describe y que era invisible.
  r := public.reporte_del_dia(date '2026-07-19');
  if (r->>'devoluciones_tras_entregar') is null then
    raise exception 'FALLA: el reporte no trae `devoluciones_tras_entregar`';
  end if;
  if (r->>'devoluciones_tras_entregar')::int <> 1 then
    raise exception 'FALLA: el 19/jul deberia tener 1 devolucion tras entregar, tiene %',
      r->>'devoluciones_tras_entregar';
  end if;
  msg := msg || 'devolucion tras entregar visible OK. ';

  -- ---------- 2) devoluciones != cancelaciones ----------
  -- En toda la historia hay 7 reembolsos y 66 cancelaciones. Si el campo
  -- nuevo copiara a `cancelados`, esta comprobacion lo cacha.
  select coalesce(sum((public.reporte_del_dia(g.d::date)->>'devoluciones')::int), 0),
         coalesce(sum((public.reporte_del_dia(g.d::date)->>'cancelados')::int), 0)
    into antes, despues
    from generate_series(date '2026-07-19', hoy, interval '1 day') g(d);
  if antes >= despues then
    raise exception 'FALLA: devoluciones (%) no puede ser >= cancelados (%): seria el mismo numero con otro nombre',
      antes, despues;
  end if;
  if antes = 0 then
    raise exception 'FALLA: cero devoluciones en toda la historia, pero hay 7 reembolsos en ventas';
  end if;
  msg := msg || 'devoluciones (' || antes || ') < cancelados (' || despues || ') OK. ';

  -- ---------- 3) un reembolso NUEVO se ve el mismo dia ----------
  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uidA, jsonb_build_object('payload', jsonb_build_object(
        'purchaseUuid', uidA, 'purchaseNumber', '990001201', 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes'))))), now());
  select id into c_a from public.carros where purchase_uuid = uidA;
  update public.carros set es_prueba = false, cancelado_en = null,
         entregado_en = now(), estado = 'entregado' where id = c_a;

  antes := (public.reporte_del_dia(hoy)->>'devoluciones_tras_entregar')::int;

  -- El reembolso: una venta que apunta a la anterior. Va PLANO a proposito
  -- (sin la llave 'payload'), que es la forma que ya rompio dos veces al
  -- proyecto por leerse a mano.
  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uidB, jsonb_build_object(
        'purchaseUuid', uidB, 'purchaseNumber', '990001202', 'amount', '-27000',
        'refundsPurchaseUuid', uidA,
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',-27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes')))), now());

  despues := (public.reporte_del_dia(hoy)->>'devoluciones_tras_entregar')::int;
  if despues <> antes + 1 then
    raise exception 'FALLA: un reembolso con aviso PLANO no se conto (antes %, despues %)', antes, despues;
  end if;
  msg := msg || 'reembolso con aviso plano se cuenta OK. ';

  -- ---------- 4) tiempo imposible fuera de las pantallas de personas ------
  select count(*) into n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.prokind='f'
     and p.proname in ('trabajadores','perfil_de_secador')
     and pg_get_functiondef(p.oid) ~ 'tiempo_imposible';
  if n <> 2 then
    raise exception 'FALLA: solo % de 2 funciones de personas filtran tiempo_imposible', n;
  end if;

  -- Y que el filtro SIRVA: se toma a alguien que seque un carro imposible y
  -- se comprueba que ya no se lo cuentan.
  select a.empleado_id into emp
    from public.asignaciones a join public.carros c on c.id = a.carro_id
   where c.tiempo_imposible and not c.es_prueba and c.cancelado_en is null
     and a.empleado_id is not null
   limit 1;
  if emp is not null then
    select count(distinct a.carro_id) into antes
      from public.asignaciones a join public.carros c on c.id = a.carro_id
     where a.empleado_id = emp and not c.es_prueba and c.cancelado_en is null;
    select count(distinct a.carro_id) into despues
      from public.asignaciones a join public.carros c on c.id = a.carro_id
     where a.empleado_id = emp and not c.es_prueba and c.cancelado_en is null
       and not coalesce(c.tiempo_imposible, false);
    if despues >= antes then
      raise exception 'FALLA: el filtro no descuenta nada para % (% vs %)', emp, antes, despues;
    end if;
    select jsonb_array_length(public.trabajadores()) into n;
    if n = 0 then raise exception 'FALLA: trabajadores() quedo vacia'; end if;
    msg := msg || 'tiempo imposible fuera (' || emp || ': ' || antes || '->' || despues || ') OK. ';
  else
    msg := msg || 'tiempo imposible fuera (nadie seco uno) OK. ';
  end if;

  raise exception 'PRUEBA PASADA -> %', msg;
end $$;
