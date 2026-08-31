-- =====================================================================
-- LOS SELLOS ARRANCAN DE CERO EN EL ULTIMO GRATIS USADO (migracion 142)
--
-- Regla del gerente, confirmada por el dueno el 31/ago/2026: "el contador
-- empieza desde 0 desde que utilizo el ultimo gratis". Lo acumulado se
-- pierde al canjear.
--
-- Se probo contra los 7 clientes que el dueno verifico A MANO en el
-- ClientNoteTracker, y ademas con escenarios armados aqui. Todo revierte.
-- =====================================================================
do $$
declare
  ok text := ''; malos text := '';
  v_p bigint; s int; d int; r record;
begin
  -- ---- 1. Los 7 que el dueno verifico a mano -----------------------
  declare m1 text := '';
  begin
    for r in select * from (values
        ('KARLA MORA MECHOR',3),('Gabriela Benitez',0),('Ignacio Lozoya',3),
        ('Manuel Parra Salazar',4),('NORMA LETICIA GUTIERREZ ORTIZ',1),
        ('Sara gabriela Reyes',0),('victor manuel hernandez',3)) t(n,e)
    loop
      select l.sellos, l.disponibles into s, d
        from public.lealtad_por_persona l join public.personas p on p.id=l.persona_id
       where p.nombre = r.n;
      if s is distinct from r.e or d is distinct from 0 then
        m1 := m1 || format(' %s(%s/5,%s)', r.n, coalesce(s,-1), coalesce(d,-1));
      end if;
    end loop;
    malos := malos || m1;
    if m1 = '' then ok := ok || 'los 7 del MRT OK. '; end if;
  end;

  -- ---- 2. Sin canjes se sigue acumulando ---------------------------
  -- La regla NO es "ya no se acumulan": quien nunca ha canjeado acumula
  -- igual que antes. Lo que cambia es el momento del canje.
  declare m2 text := '';
  begin
    insert into public.personas (nombre, nombre_norm, origen)
    values ('ZZ PRUEBA ACUMULA', public.normalizar_nombre('ZZ PRUEBA ACUMULA'), 'import')
    returning id into v_p;
    insert into public.visitas (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, creado_en)
    select v_p, false, false, 'activa', 'import', false, now() - (g || ' days')::interval
    from generate_series(1,12) g;
    select sellos, disponibles into s, d from public.lealtad_por_persona where persona_id=v_p;
    if s <> 2 or d <> 2 then m2 := m2 || format(' 12 pagados dieron %s/5 y %s gratis (se esperaba 2/5 y 2)', s, d); end if;
    malos := malos || m2;
    if m2 = '' then ok := ok || 'sin canjes acumula OK. '; end if;
  end;

  -- ---- 3. El canje BORRA lo acumulado ------------------------------
  -- Con 12 pagados traia 2 gratis. Al canjear UNO, los dos se van y el
  -- contador arranca de cero. Es justo lo que cambio.
  declare m3 text := '';
  begin
    insert into public.visitas (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, creado_en)
    values (v_p, true, false, 'activa', 'import', false, now());
    select sellos, disponibles into s, d from public.lealtad_por_persona where persona_id=v_p;
    if s <> 0 or d <> 0 then m3 := m3 || format(' tras canjear quedo %s/5 y %s gratis (se esperaba 0/5 y 0)', s, d); end if;
    malos := malos || m3;
    if m3 = '' then ok := ok || 'el canje borra lo acumulado OK. '; end if;
  end;

  -- ---- 4. Y despues del canje vuelve a contar ----------------------
  declare m4 text := '';
  begin
    insert into public.visitas (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, creado_en)
    select v_p, false, false, 'activa', 'import', false, now() + (g || ' minutes')::interval
    from generate_series(1,7) g;
    select sellos, disponibles into s, d from public.lealtad_por_persona where persona_id=v_p;
    if s <> 2 or d <> 1 then m4 := m4 || format(' 7 despues del canje dieron %s/5 y %s (se esperaba 2/5 y 1)', s, d); end if;
    malos := malos || m4;
    if m4 = '' then ok := ok || 'despues del canje vuelve a contar OK. '; end if;
  end;

  -- ---- 5. La cortesia sigue sin contar de ningun lado --------------
  declare m5 text := '';
  begin
    insert into public.visitas (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, creado_en)
    values (v_p, false, true, 'activa', 'import', false, now() + interval '1 hour');
    select sellos, disponibles into s, d from public.lealtad_por_persona where persona_id=v_p;
    if s <> 2 or d <> 1 then m5 := m5 || ' la cortesia movio el contador'; end if;
    malos := malos || m5;
    if m5 = '' then ok := ok || 'la cortesia no cuenta OK. '; end if;
  end;

  -- ---- 6. La regla de las notas del CNT es IDEMPOTENTE -------------
  -- 🔴 Aqui vivio un bug real: `CINTIA MENDOZA ORDUÑO` tiene dos visitas sin
  -- ticket en el mismo minuto, y cada corrida se comia un lavado bueno.
  declare m6 text := ''; r1 jsonb; r2 jsonb;
  begin
    r1 := public.aplicar_notas_especiales_del_cnt();
    r2 := public.aplicar_notas_especiales_del_cnt();
    if (r1->>'marcadores')::int <> 0 or (r1->>'canjes')::int <> 0
       or (r2->>'marcadores')::int <> 0 or (r2->>'canjes')::int <> 0 then
      m6 := m6 || format(' no es idempotente (%s / %s)', r1::text, r2::text);
    end if;
    malos := malos || m6;
    if m6 = '' then ok := ok || 'las notas del CNT son idempotentes OK. '; end if;
  end;

  -- ---- 7. Y quedaron aplicadas, no a medias ------------------------
  declare m7 text := ''; n_m int; n_c int;
  begin
    select count(*) filter (where clase='MARCADOR'), count(*) filter (where clase='CANJE')
      into n_m, n_c from public.cnt_notas_especiales;
    if n_m <> 31 or n_c <> 15 then m7 := m7 || format(' la lista quedo en %s/%s', n_m, n_c); end if;
    if exists (select 1 from public.bak_visitas_pendientes_0831 b join public.visitas v on v.id=b.visita_id
                where b.clase='MARCADOR' and v.estado <> 'descartada') then
      m7 := m7 || ' quedo un marcador activo';
    end if;
    if exists (select 1 from public.bak_visitas_pendientes_0831 b join public.visitas v on v.id=b.visita_id
                where b.clase='CANJE' and not v.es_gratis) then
      m7 := m7 || ' quedo un canje sin marcar';
    end if;
    malos := malos || m7;
    if m7 = '' then ok := ok || 'las 46 notas quedaron aplicadas OK. '; end if;
  end;

  if malos <> '' then raise exception 'PRUEBA FALLIDA ->%', malos; end if;
  raise exception 'PRUEBA PASADA -> %', ok;
end $$;
