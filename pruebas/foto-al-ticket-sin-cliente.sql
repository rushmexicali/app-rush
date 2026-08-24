-- Prueba de la migracion 136: "No asignar a cliente".
--
--   La foto que tomo la camara de la caja se le pega al ticket SIN crear
--   ninguna visita, conservando los tres candados que ya tenia ese camino.
--
-- Corre contra la base real y REVIERTE TODO con el raise final.
--
--   bash scripts/releer-fotos/q.sh pruebas/foto-al-ticket-sin-cliente.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta  bigint;
  c1       bigint;   -- carro sin foto: la de la caja SI se le pega
  c2       bigint;   -- carro que YA trae foto del supervisor: no se pisa
  r        jsonb;
  v_txt    text;
  v_n      int;
  v_placa  text := 'ZZ136' || (extract(epoch from now())::bigint % 100000);
  v_msg    text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;

  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, estado)
  values
    ('prueba-136-a-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now(), 'prelavado')
  returning id into c1;

  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, estado, foto_path)
  values
    ('prueba-136-b-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now(), 'prelavado', '2026-08-24/la-del-supervisor.jpg')
  returning id into c2;

  -- ==================================================================
  -- 1) SE PEGA LA FOTO Y NO SE CREA NINGUNA VISITA
  --    Es el punto entero: el carro entra a la base, el cliente no.
  -- ==================================================================
  r := public.pegar_foto_de_caja(
         p_carro        := c1,
         p_foto_path    := '2026-08-24/prueba-136.jpg',
         p_placa        := v_placa,
         p_marca        := 'TOYOTA',
         p_submarca     := 'COROLLA',
         p_tipo         := 'automovil',
         p_hubo_lectura := true);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: no se pudo pegar la foto -> %', r->>'error';
  end if;
  if not (r->>'pego')::boolean then
    raise exception 'FALLA: dijo que no pego la foto en un carro que no tenia';
  end if;

  select foto_path into v_txt from public.carros where id = c1;
  if v_txt is distinct from '2026-08-24/prueba-136.jpg' then
    raise exception 'FALLA: la foto no quedo en el carro (quedo %)', coalesce(v_txt,'(nada)');
  end if;

  select marca into v_txt from public.carros where id = c1;
  if v_txt is distinct from 'TOYOTA' then
    raise exception 'FALLA: no se guardo lo que leyo la camara (marca=%)', coalesce(v_txt,'(nada)');
  end if;

  select count(*) into v_n from public.visitas where carro_id = c1;
  if v_n <> 0 then
    raise exception 'FALLA: se crearon % visitas, y este camino NO debe crear ninguna', v_n;
  end if;
  select count(*) into v_n from public.personas where nombre ilike 'ZZ136%';
  if v_n <> 0 then
    raise exception 'FALLA: se creo una persona, y este camino no debe crear ninguna';
  end if;
  v_msg := v_msg || 'pega la foto y NO crea visita OK. ';

  -- ==================================================================
  -- 2) CANDADO 1: no se pisa la foto del supervisor
  -- ==================================================================
  r := public.pegar_foto_de_caja(
         p_carro        := c2,
         p_foto_path    := '2026-08-24/la-de-la-caja.jpg',
         p_placa        := v_placa || 'B',
         p_marca        := 'HONDA',
         p_hubo_lectura := true);

  if (r->>'pego')::boolean then
    raise exception 'FALLA: dijo que pego la foto encima de la del supervisor';
  end if;
  select foto_path into v_txt from public.carros where id = c2;
  if v_txt is distinct from '2026-08-24/la-del-supervisor.jpg' then
    raise exception 'FALLA: se piso la foto del supervisor (quedo %)', v_txt;
  end if;

  -- ==================================================================
  -- 3) CANDADO 2: si la foto no se pego, TAMPOCO se guarda la lectura.
  --    Sin esto, la placa de la caja pisaba la del supervisor en un carro
  --    que ya tenia su propia foto -- o sea, de otro vehiculo.
  -- ==================================================================
  select marca into v_txt from public.carros where id = c2;
  if v_txt is not null then
    raise exception 'FALLA: se guardo la lectura (marca=%) en un carro cuya foto NO se pego', v_txt;
  end if;
  v_msg := v_msg || 'no pisa la foto ni la lectura del supervisor OK. ';

  -- ==================================================================
  -- 4) CANDADO 3: sin lectura, `placa_en` se queda NULO para que el obrero
  --    de fondo lo relea (migracion 104).
  -- ==================================================================
  declare
    c3 bigint; v_placa_en timestamptz;
  begin
    insert into public.carros
      (purchase_uuid, venta_id, producto, variante, monto, creado_en, estado)
    values
      ('prueba-136-c-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
       now(), 'prelavado')
    returning id into c3;

    r := public.pegar_foto_de_caja(
           p_carro        := c3,
           p_foto_path    := '2026-08-24/prueba-136-sin-lectura.jpg',
           p_hubo_lectura := false);

    if not (r->>'pego')::boolean then
      raise exception 'FALLA: no pego la foto cuando no hubo lectura, y si debe pegarla';
    end if;
    select placa_en into v_placa_en from public.carros where id = c3;
    if v_placa_en is not null then
      raise exception 'FALLA: estampo placa_en sin que hubiera lectura; el carro no entraria a la cola de relectura';
    end if;
    v_msg := v_msg || 'sin lectura deja placa_en nulo OK. ';
  end;

  -- ==================================================================
  -- 5) Un carro cancelado se rechaza, con su mensaje.
  -- ==================================================================
  update public.carros set cancelado_en = now() where id = c1;
  r := public.pegar_foto_de_caja(c1, '2026-08-24/otra.jpg');
  if (r->>'ok')::boolean then
    raise exception 'FALLA: acepto pegarle una foto a un lavado cancelado';
  end if;
  v_msg := v_msg || 'rechaza el lavado cancelado OK. ';

  -- ==================================================================
  -- 6) Y LA REGLA VIVE EN UN SOLO LUGAR: registrar_visita_con_carro ya no
  --    trae su propia copia. Esta es la parte que evita que vuelva.
  -- ==================================================================
  select count(*) into v_n
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'registrar_visita_con_carro'
     and pg_get_functiondef(p.oid) like '%foto_url_expira = null%';
  if v_n > 0 then
    raise exception 'FALLA: registrar_visita_con_carro volvio a traer su copia de la regla de la foto';
  end if;
  v_msg := v_msg || 'la regla vive en un solo lugar OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
