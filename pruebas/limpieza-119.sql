-- Prueba de la migracion 119: un nulo no borra, lo muerto esta muerto, y el
-- candado de Jibble por fin candea.
--
--   bash scripts/releer-fotos/q.sh pruebas/limpieza-119.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  uid    text := 'prueba119-' || gen_random_uuid();
  uid2   text := 'prueba119b-' || gen_random_uuid();
  c_uno  bigint; c_dos bigint;
  p_uno  bigint;
  v1     bigint; v2 bigint;
  r      jsonb;
  n      int;
  t1     text; t2 text;
  cuerpo text;
  msg    text := '';
begin
  -- ---------- escenario ----------
  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uid, jsonb_build_object('payload', jsonb_build_object(
        'purchaseUuid', uid, 'purchaseNumber', '990001191', 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes'))))), now()),
    (uid2, jsonb_build_object('payload', jsonb_build_object(
        'purchaseUuid', uid2, 'purchaseNumber', '990001192', 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes'))))), now());

  select id into c_uno from public.carros where purchase_uuid = uid;
  select id into c_dos from public.carros where purchase_uuid = uid2;
  update public.carros set es_prueba = false, cancelado_en = null where id in (c_uno, c_dos);

  insert into public.personas (nombre, origen) values ('ZZZ Prueba 119','prueba') returning id into p_uno;

  -- ---------- 1) un nulo no borra ----------
  -- El carro trae marca y submarca leidas de la FOTO, y la misma placa.
  update public.carros
     set placa = public.normalizar_placa('ZZP119A'), marca = 'TOYOTA', submarca = 'COROLLA'
   where id = c_uno;

  -- La cajera registra la visita con la MISMA placa y SIN marca (lo normal:
  -- la caja no captura marca).
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, placa)
  values (p_uno, false, 'activa', 'prueba', false, now(), 'ZZP119A') returning id into v1;

  r := public.enlazar_visita_a_carro(v1, c_uno);
  if (r->>'ok') = 'false' then raise exception 'FALLA: no enlazo -> %', r->>'error'; end if;

  if (select marca from public.carros where id = c_uno) is distinct from 'TOYOTA' then
    raise exception 'FALLA: un nulo borro la marca (quedo %)',
      (select coalesce(marca,'(nula)') from public.carros where id = c_uno);
  end if;
  if (select submarca from public.carros where id = c_uno) is distinct from 'COROLLA' then
    raise exception 'FALLA: un nulo borro la submarca';
  end if;
  msg := msg || 'un nulo no borra OK. ';

  -- ---------- 2) pero una placa DISTINTA si reemplaza el juego ----------
  -- Dos placas distintas son dos carros distintos: lo guardado era de otro.
  update public.carros
     set placa = public.normalizar_placa('ZZP119B'), marca = 'HONDA', submarca = 'CIVIC'
   where id = c_dos;

  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, placa)
  values (p_uno, false, 'activa', 'prueba', false, now(), 'ZZP119C') returning id into v2;

  r := public.enlazar_visita_a_carro(v2, c_dos);
  if (r->>'ok') = 'false' then raise exception 'FALLA: no enlazo el segundo -> %', r->>'error'; end if;

  if (select marca from public.carros where id = c_dos) is not null then
    raise exception 'FALLA: con placa distinta debia limpiarse la marca ajena (quedo %)',
      (select marca from public.carros where id = c_dos);
  end if;
  msg := msg || 'placa distinta si reemplaza OK. ';

  -- ---------- 3) lo muerto esta muerto ----------
  select count(*) into n from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname in ('registrar_visita','importar_personas');
  if n <> 0 then
    raise exception 'FALLA: siguen vivas % funcion(es) que debian borrarse', n;
  end if;
  -- Y la que SI registra visitas sigue ahi, con su regla de cortesia.
  select pg_get_functiondef(p.oid) into cuerpo
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.prokind='f' and p.proname='registrar_visita_con_carro';
  if cuerpo is null then
    raise exception 'FALLA: se borro la funcion equivocada, ya no existe registrar_visita_con_carro';
  end if;
  if position('clase_de_gratis' in cuerpo) = 0 then
    raise exception 'FALLA: la unica que registra visitas ya no consulta clase_de_gratis';
  end if;
  msg := msg || 'lo muerto esta muerto OK. ';

  -- ---------- 4) el candado de Jibble ----------
  select pg_get_functiondef(p.oid) into cuerpo
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.prokind='f' and p.proname='sincronizar_jibble_si_toca';
  -- Se quitan los comentarios antes de buscar: el comentario que explica por
  -- que se quito el lock NOMBRA al lock, y la primera version de esta prueba
  -- fallo por eso — media el comentario, no el codigo.
  if regexp_replace(cuerpo, '--[^\n]*', '', 'g') ~ 'pg_try_advisory' then
    raise exception 'FALLA: volvio el lock de transaccion, que no puede candar trabajo asincrono';
  end if;
  if position('jibble_disparos' in cuerpo) = 0 then
    raise exception 'FALLA: la funcion ya no usa la marca de tiempo que si sobrevive entre transacciones';
  end if;
  select count(*) into n from public.jibble_disparos;
  if n <> 1 then raise exception 'FALLA: jibble_disparos deberia tener exactamente 1 fila, tiene %', n; end if;

  -- Dos llamadas seguidas. La segunda NO puede disparar, ni con el taller
  -- abierto (se salta por la espera) ni cerrado (fuera de horario). Se
  -- comprueba asi para que la prueba valga a cualquier hora del dia.
  t1 := public.sincronizar_jibble_si_toca();
  t2 := public.sincronizar_jibble_si_toca();
  if t2 like 'sincronizado%' then
    raise exception 'FALLA: dos corridas seguidas dispararon las dos (1=%, 2=%)', t1, t2;
  end if;
  if t1 like 'sincronizado%' and t2 not like '%se salta%' then
    raise exception 'FALLA: la segunda no se salto por la espera (dijo %)', t2;
  end if;
  msg := msg || 'candado de Jibble OK (1=' || left(t1, 24) || '). ';

  raise exception 'PRUEBA PASADA -> %', msg;
end $$;
