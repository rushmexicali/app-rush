-- =====================================================================
-- La visita de la caja guarda su TICKET y su MONTO  (migracion 137).
--
-- Corre contra la base REAL y revierte TODO con un `raise` al final, asi que
-- no ensucia la cola del supervisor ni el CRM. Pasa si dice "PASADA".
--
-- El grupo B es el que de verdad importa a largo plazo: comprueba que
-- `recibo_del_carro()` y la expresion que usa `ligar_visitas_de_import()`
-- contesten LO MISMO sobre todos los carros reales. Son los dos lugares donde
-- se pregunta "cual es el recibo de este carro", y este proyecto ya se ha
-- quemado seis veces con la misma regla escrita dos veces.
-- =====================================================================
do $prueba$
declare
  v_carro    bigint;
  v_carro2   bigint;
  v_persona  bigint;
  v_uuid     text;
  r          jsonb;
  v_ticket   text;
  v_monto    numeric;
  n          int;
  fallos     text := '';
begin
  -- ---------------------------------------------------------------
  -- A) Una visita nueva de caja trae el ticket y el monto de su carro.
  -- ---------------------------------------------------------------
  select c.id into v_carro
    from public.carros c
    join public.ventas v on v.purchase_uuid = c.purchase_uuid
   where not c.es_prueba and c.cancelado_en is null
     and public.detalle_venta(v.payload) ->> 'purchaseNumber' is not null
     and coalesce(c.producto,'') not ilike 'gratis%'
     and not exists (select 1 from public.visitas w
                      where w.carro_id = c.id and w.estado = 'activa')
   order by c.id desc limit 1;

  select id into v_persona from public.personas order by id desc limit 1;

  if v_carro is null or v_persona is null then
    raise exception 'PRUEBA INVALIDA: no hay carro libre con venta, o no hay personas';
  end if;

  r := public.registrar_visita_con_carro(v_persona, v_carro);
  if not (r->>'ok')::boolean then
    fallos := fallos || format(' [A] la RPC rechazo el registro: %s;', r->>'error');
  else
    select ticket, monto into v_ticket, v_monto
      from public.visitas where id = (r->>'visita')::bigint;

    if v_ticket is distinct from public.recibo_del_carro(v_carro) then
      fallos := fallos || format(' [A] ticket guardado %s, esperado %s;',
                                 coalesce(v_ticket,'NULL'),
                                 coalesce(public.recibo_del_carro(v_carro),'NULL'));
    end if;
    if v_ticket is null then
      fallos := fallos || ' [A] el ticket quedo NULL con una venta que si lo tiene;';
    end if;
    if v_monto is distinct from (select monto from public.carros where id = v_carro) then
      fallos := fallos || ' [A] el monto no es el del carro;';
    end if;
  end if;

  -- ---------------------------------------------------------------
  -- B) ANTI-DESFASE: recibo_del_carro() == la expresion del ligado del
  --    import, sobre TODOS los carros con venta. Si alguien cambia una de
  --    las dos y no la otra, esto se cae.
  -- ---------------------------------------------------------------
  select count(*) into n
    from public.carros c
    join public.ventas v on v.purchase_uuid = c.purchase_uuid
   where public.recibo_del_carro(c.id)
         is distinct from (public.detalle_venta(v.payload) ->> 'purchaseNumber');
  if n > 0 then
    fallos := fallos || format(' [B] %s carros donde recibo_del_carro NO coincide con el ligado del import;', n);
  end if;

  -- ---------------------------------------------------------------
  -- C) NUNCA BLOQUEA: un carro cuya venta todavia no llego (el webhook va
  --    en camino) se registra igual, con el ticket en NULL.
  -- ---------------------------------------------------------------
  -- venta_id apunta a una venta real (la columna es not-null porque el carro
  -- siempre nace del trigger de una venta), pero el purchase_uuid NO empata
  -- con ninguna: eso es justo el hueco que recibo_del_carro tiene que
  -- aguantar sin inventar y sin bloquear.
  v_uuid := 'prueba-137-' || md5(clock_timestamp()::text);
  insert into public.carros (venta_id, purchase_uuid, producto, variante, monto, estado, nota)
  values ((select id from public.ventas order by id desc limit 1),
          v_uuid, 'Completo RUSH', 'Chico', 260, 'prelavado', 'PRUEBA 137')
  returning id into v_carro2;

  if public.recibo_del_carro(v_carro2) is not null then
    fallos := fallos || ' [C] recibo_del_carro invento un ticket para un carro sin venta;';
  end if;

  r := public.registrar_visita_con_carro(v_persona, v_carro2);
  if not (r->>'ok')::boolean then
    fallos := fallos || format(' [C] un carro sin venta BLOQUEO el registro: %s;', r->>'error');
  elsif (select ticket from public.visitas where id = (r->>'visita')::bigint) is not null then
    fallos := fallos || ' [C] se guardo un ticket que no existe;';
  end if;

  -- ---------------------------------------------------------------
  -- D) El relleno de la 137 no dejo pendientes.
  -- ---------------------------------------------------------------
  select count(*) into n
    from public.visitas
   where caja <> 'import' and carro_id is not null and ticket is null
     and carro_id <> v_carro2;                       -- el de la prueba C no cuenta
  if n > 0 then
    fallos := fallos || format(' [D] quedan %s visitas de caja con carro y sin ticket;', n);
  end if;

  -- ---------------------------------------------------------------
  -- E) El relleno NO se paso al CNT. Hay visitas de import sin ticket a
  --    proposito (§11.10: tickets que Zettle no respalda); si el update
  --    hubiera alcanzado al import, este numero seria cero.
  -- ---------------------------------------------------------------
  select count(*) into n from public.visitas where caja = 'import' and ticket is null;
  if n = 0 then
    fallos := fallos || ' [E] ya no hay visitas de import sin ticket: el relleno alcanzo al CNT;';
  end if;

  -- ---------------------------------------------------------------
  -- F) No se rompio el candado del canje sin saldo (migracion 105).
  -- ---------------------------------------------------------------
  select c.id into v_carro
    from public.carros c
   where not c.es_prueba and c.cancelado_en is null
     and public.clase_de_gratis(c.producto, c.variante) = 'canje'
     and not exists (select 1 from public.visitas w
                      where w.carro_id = c.id and w.estado = 'activa')
   order by c.id desc limit 1;

  if v_carro is not null then
    select p.id into v_persona
      from public.personas p
      join public.lealtad_por_persona l on l.persona_id = p.id
     where l.disponibles <= 0 limit 1;

    r := public.registrar_visita_con_carro(v_persona, v_carro, true);
    if (r->>'ok')::boolean then
      fallos := fallos || ' [F] dejo canjear a alguien sin saldo;';
    elsif r->>'motivo' <> 'sin_saldo' then
      fallos := fallos || format(' [F] rechazo por el motivo equivocado: %s;', r->>'motivo');
    end if;
  end if;

  -- ---------------------------------------------------------------
  if fallos <> '' then
    raise exception 'PRUEBA FALLIDA ->%', fallos;
  end if;
  raise exception 'PRUEBA PASADA -> la visita de caja guarda ticket y monto, no bloquea sin venta, y el recibo no se desfasa del import';
end $prueba$;
