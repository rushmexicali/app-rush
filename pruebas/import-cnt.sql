-- Prueba del import del ClientNoteTracker: el paso que lo mato cinco dias.
--
--   bash scripts/releer-fotos/q.sh pruebas/import-cnt.sql
--
-- Por que existe: el 19/ago/2026 la migracion 114 puso el candado "un lavado,
-- un cliente" y con eso rompio el ligado del import. La suite habria dicho
-- TODO PASO justo antes de romperlo, porque no habia una sola prueba de la
-- tuberia que carga el 99.8% de las visitas. Esta es esa prueba.
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  uid_a   text := 'prueba118-a-' || gen_random_uuid();
  uid_b   text := 'prueba118-b-' || gen_random_uuid();
  uid_c   text := 'prueba118-c-' || gen_random_uuid();
  tk_a    text := '990000001';   -- aviso ENVUELTO
  tk_b    text := '990000002';   -- aviso PLANO (sin la llave 'payload')
  tk_c    text := '990000003';   -- carro que ya tiene dueno
  c_a     bigint; c_b bigint; c_c bigint;
  p_uno   bigint; p_dos bigint; p_tres bigint;
  v_a1    bigint; v_a2 bigint; v_b bigint; v_c bigint;
  r       jsonb;
  n       int;
  msg     text := '';
  trono   boolean;
  cuerpo  text;
begin
  -- ------------------------------------------------------------------
  -- 0) Escenario: tres ventas reales, una de ellas con el aviso PLANO.
  --    El trigger de ventas crea el carro solo, igual que en produccion.
  -- ------------------------------------------------------------------
  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uid_a, jsonb_build_object('payload', jsonb_build_object(
        'purchaseUuid', uid_a, 'purchaseNumber', tk_a, 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes'))))),
     now() - interval '3 hours');

  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uid_b, jsonb_build_object(
        'purchaseUuid', uid_b, 'purchaseNumber', tk_b, 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes')))),
     now() - interval '2 hours');

  insert into public.ventas (purchase_uuid, payload, creado_en) values
    (uid_c, jsonb_build_object('payload', jsonb_build_object(
        'purchaseUuid', uid_c, 'purchaseNumber', tk_c, 'amount', '27000',
        'products', jsonb_build_array(jsonb_build_object(
          'name','Completo RUSH','variantName','Chico','unitPrice',27000,'quantity','1',
          'category', jsonb_build_object('name','Paquetes'))))),
     now() - interval '1 hour');

  select id into c_a from public.carros where purchase_uuid = uid_a;
  select id into c_b from public.carros where purchase_uuid = uid_b;
  select id into c_c from public.carros where purchase_uuid = uid_c;
  if c_a is null or c_b is null or c_c is null then
    raise exception 'FALLA: el trigger de ventas no creo los tres carros (% % %)', c_a, c_b, c_c;
  end if;
  update public.carros set es_prueba = false, cancelado_en = null
   where id in (c_a, c_b, c_c);

  insert into public.personas (nombre, origen) values ('ZZZ Prueba 118 Uno','prueba')  returning id into p_uno;
  insert into public.personas (nombre, origen) values ('ZZZ Prueba 118 Dos','prueba')  returning id into p_dos;
  insert into public.personas (nombre, origen) values ('ZZZ Prueba 118 Tres','prueba') returning id into p_tres;

  -- ------------------------------------------------------------------
  -- 1) EL BUG VIEJO, reproducido: la sentencia que traia el import se cae
  --    ENTERA en cuanto un carro ya tiene dueno. No deja una visita sin
  --    ligar: tumba el bloque y no entra NINGUNA.
  -- ------------------------------------------------------------------
  insert into public.visitas (persona_id, carro_id, es_gratis, estado, caja, es_prueba, creado_en)
  values (p_tres, c_c, false, 'activa', 'principal', false, now() - interval '55 minutes');

  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, ticket)
  values (p_uno, false, 'activa', 'import', false, now() - interval '50 minutes', tk_c)
  returning id into v_c;

  trono := false;
  begin
    update public.visitas vi set carro_id = m.carro_id
    from (select c.id as carro_id, ((v.payload->>'payload')::jsonb->>'purchaseNumber') as recibo
          from public.carros c join public.ventas v on v.purchase_uuid = c.purchase_uuid
          where not c.es_prueba and c.cancelado_en is null) m
    where vi.caja='import' and vi.ticket = m.recibo and vi.carro_id is null;
  exception when unique_violation then
    trono := true;
  end;
  if not trono then
    raise exception 'FALLA: el ligado viejo ya no revienta; esta prueba dejo de medir el bug';
  end if;
  msg := msg || 'bug viejo reproducido OK. ';

  -- ------------------------------------------------------------------
  -- 2) El ligado nuevo NO revienta, y deja anotado el conflicto.
  -- ------------------------------------------------------------------
  r := public.ligar_visitas_de_import();
  if (r->>'error') is not null then
    raise exception 'FALLA: el ligado nuevo devolvio error %', r->>'error';
  end if;
  if (select carro_id from public.visitas where id = v_c) is not null then
    raise exception 'FALLA: se ligo un lavado que ya tenia dueno';
  end if;
  select count(*) into n from public.imp_ligado_conflictos
   where visita_id = v_c and motivo like 'ese lavado%';
  if n <> 1 then
    raise exception 'FALLA: el conflicto no quedo anotado (n=%)', n;
  end if;
  msg := msg || 'carro ocupado se respeta y se anota OK. ';

  -- ------------------------------------------------------------------
  -- 3) El aviso PLANO tambien liga. Es el error que la 115 le corrigio a
  --    ventas_indexar y que aqui seguia vivo: leer solo la forma envuelta
  --    dejaba ventas sin ligar en silencio.
  -- ------------------------------------------------------------------
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, ticket)
  values (p_uno, false, 'activa', 'import', false, now() - interval '2 hours', tk_b)
  returning id into v_b;

  r := public.ligar_visitas_de_import();
  if (select carro_id from public.visitas where id = v_b) is distinct from c_b then
    raise exception 'FALLA: la venta con aviso PLANO no se ligo (visita % -> %)',
      v_b, (select carro_id from public.visitas where id = v_b);
  end if;
  msg := msg || 'aviso plano liga OK. ';

  -- ------------------------------------------------------------------
  -- 4) Dos visitas peleando el mismo lavado: gana la mas cercana en el
  --    tiempo, la otra queda sin ligar y ANOTADA.
  -- ------------------------------------------------------------------
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, ticket)
  values (p_uno, false, 'activa', 'import', false, now() - interval '178 minutes', tk_a)
  returning id into v_a1;
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, ticket)
  values (p_dos, false, 'activa', 'import', false, now() - interval '90 minutes', tk_a)
  returning id into v_a2;

  r := public.ligar_visitas_de_import();
  if (select carro_id from public.visitas where id = v_a1) is distinct from c_a then
    raise exception 'FALLA: no gano la visita mas cercana en el tiempo';
  end if;
  if (select carro_id from public.visitas where id = v_a2) is not null then
    raise exception 'FALLA: se ligaron DOS visitas al mismo lavado';
  end if;
  select count(*) into n from public.imp_ligado_conflictos
   where visita_id = v_a2 and motivo like 'dos visitas%';
  if n <> 1 then
    raise exception 'FALLA: la visita perdedora no quedo anotada (n=%)', n;
  end if;
  msg := msg || 'desempate determinista OK. ';

  -- ------------------------------------------------------------------
  -- 5) Las VISITAS sobreviven aunque el ligado no ligue. Es la regla que
  --    costo los cinco dias: un enlace se rehace, una visita que no entro
  --    hay que volver a sacarla del export.
  -- ------------------------------------------------------------------
  select count(*) into n from public.visitas where id in (v_a1, v_a2, v_b, v_c);
  if n <> 4 then
    raise exception 'FALLA: se perdieron visitas en el camino (quedan % de 4)', n;
  end if;
  msg := msg || 'las visitas sobreviven OK. ';

  -- ------------------------------------------------------------------
  -- 6) TODO se guarda en hora de TIJUANA, pero el export no siempre VIENE en
  --    Tijuana: el CNT escribe con la zona del telefono del dueno, y el
  --    21/ago/2026 se le descompuso el horario (el PDF salio en
  --    America/Ciudad_Juarez, una hora adelante). Por eso la zona de origen
  --    viaja en `stg_cnt.tz` — medida contra Zettle, no leida del PDF.
  --    Clavar Tijuana cuando no lo es guardaria cada visita una hora tarde.
  -- ------------------------------------------------------------------
  if ('2026-08-20 18:45:00'::timestamp at time zone 'America/Ciudad_Juarez')
     <> ('2026-08-20 17:45:00'::timestamp at time zone 'America/Tijuana') then
    raise exception 'FALLA: Ciudad Juarez dejo de ir una hora adelante de Tijuana';
  end if;
  select count(*) into n from information_schema.columns
   where table_schema='public' and table_name='stg_cnt' and column_name='tz';
  if n <> 1 then
    raise exception 'FALLA: stg_cnt no tiene la columna tz; el import volveria a clavar Tijuana';
  end if;
  msg := msg || 'zona horaria del export OK. ';

  -- ------------------------------------------------------------------
  -- 7) El dedup del incremental: mismo ticket y misma persona+hora no
  --    entran dos veces.
  -- ------------------------------------------------------------------
  select count(*) into n
  from (values (tk_b)) t(ticket)
  where not exists (select 1 from public.visitas v where v.caja='import' and v.ticket = t.ticket);
  if n <> 0 then
    raise exception 'FALLA: el dedup por ticket dejaria entrar una visita repetida';
  end if;
  select count(*) into n
  from (values ((select creado_en from public.visitas where id = v_b))) t(cuando)
  where not exists (select 1 from public.visitas v
                     where v.caja='import' and v.persona_id = p_uno and v.creado_en = t.cuando);
  if n <> 0 then
    raise exception 'FALLA: el dedup por persona+hora dejaria entrar una visita repetida';
  end if;
  msg := msg || 'dedup OK. ';

  -- ------------------------------------------------------------------
  -- 8) Y el ligado sigue viviendo en UN solo lugar.
  -- ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into cuerpo
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname='public' and p.proname='ligar_visitas_de_import';
  if cuerpo is null then
    raise exception 'FALLA: no existe public.ligar_visitas_de_import()';
  end if;
  if position('detalle_venta' in cuerpo) = 0 then
    raise exception 'FALLA: el ligado dejo de usar detalle_venta(); vuelve el bug del aviso plano';
  end if;
  msg := msg || 'una sola regla OK. ';

  raise exception 'PRUEBA PASADA -> %', msg;
end $$;
