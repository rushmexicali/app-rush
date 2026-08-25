-- =====================================================================
-- LIMPIEZA DE TICKETS EN stg_cnt — correr SIEMPRE antes de importar.
-- Implementa el cotejo del RUNBOOK §4d, que hasta el 24/ago/2026 eran tres
-- consultas sueltas que alguien tenia que mirar y resolver a mano.
--
-- 🔑 LA REGLA, Y NO SE NEGOCIA: lo que se descarta es el TICKET (y su monto,
--    que apunta a la venta de otra persona). La VISITA siempre se queda: el
--    cliente vino de verdad, y quitarsela le quita un sello que se gano.
--
-- No adivina numeros. Un `02373` que "seguramente" es el 2373 se queda sin
-- ticket: inventar un numero es el error que este proyecto ya pago caro.
--
-- Para ensayar sin escribir, cambiar el `raise notice` final por
-- `raise exception` — la API corre todo en una transaccion y se revierte.
-- =====================================================================
do $$
declare a int; b int; c int; quedan int;
begin
  -- La hora real de cada venta, de las DOS fuentes: zettle_compras cubre el
  -- historico (1..25256) y ventas lo que entro por webhook (24503 en adelante).
  -- Con una sola no alcanza para un export de un ano completo.
  create temp table zh on commit drop as
  select purchase_number::bigint n, hora from public.zettle_compras
  union
  select (public.detalle_venta(payload)->>'purchaseNumber')::bigint, creado_en
  from public.ventas
  where public.detalle_venta(payload)->>'purchaseNumber' ~ '^[0-9]+$'
    and (public.detalle_venta(payload)->>'purchaseNumber')::bigint
        not in (select purchase_number from public.zettle_compras);
  create index on zh(n);

  -- (A) Los marcadores 0..5 NO son tickets. Medido el 24/ago/2026: 443 notas,
  --     321 personas, repartidas en 125 dias distintos — el `1` solo aparece
  --     281 veces. Un numero de venta es unico y no se repite jamas.
  update public.stg_cnt set ticket = null, monto_cent = null
  where ticket in ('0','1','2','3','4','5');
  get diagnostics a = row_count;

  -- (B) Numeros que Zettle no tiene: ceros a la izquierda (`02373`), cifras
  --     fuera de rango (`164501`, que parece un telefono) y los que Zettle
  --     TODAVIA no emite (`27943`) — estos ultimos son una mina con fecha:
  --     el dia que Zettle llegue a ese numero, el dedup del import futuro
  --     descarta la visita buena creyendola repetida.
  update public.stg_cnt s set ticket = null, monto_cent = null
  where s.ticket is not null
    and not exists (select 1 from zh where zh.n::text = s.ticket);
  get diagnostics b = row_count;

  -- (C) El mismo ticket en dos notas del MISMO export. Zettle desempata por
  --     fecha: gana la nota mas cercana a la hora de la venta; la otra pierde
  --     ticket y monto, pero sigue siendo visita.
  --     ⚠️ Esto tiene que correr DESPUES de (A) y (B), o los 281 marcadores
  --     `1` se pelearian entre si y 280 de ellos saldrian "perdedores" de un
  --     desempate que no significa nada.
  with d as (
    select s.ctid as fila,
           row_number() over (
             partition by s.ticket
             order by abs(extract(epoch from (
                       (s.dt_local::timestamp at time zone coalesce(s.tz,'America/Tijuana')) - zh.hora))) asc,
                      s.dt_local asc) rn
    from public.stg_cnt s join zh on zh.n::text = s.ticket
    where s.ticket is not null
      and s.ticket in (select ticket from public.stg_cnt where ticket is not null
                       group by ticket having count(*) > 1))
  update public.stg_cnt s set ticket = null, monto_cent = null
  from d where d.fila = s.ctid and d.rn > 1;
  get diagnostics c = row_count;

  select count(*) into quedan from (
    select ticket from public.stg_cnt where ticket is not null
    group by ticket having count(*) > 1) x;

  if quedan <> 0 then
    raise exception 'FALLO: quedaron % tickets repetidos', quedan;
  end if;

  raise notice E'LIMPIEZA DE TICKETS\n'
    '  (A) marcadores 0-5 ................. %\n'
    '  (B) numeros que Zettle no tiene .... %\n'
    '  (C) repetidos, pierde el mas lejano  %\n'
    '  visitas (NO cambia) ................ %\n'
    '  con ticket ......................... %\n'
    '  con monto .......................... %\n'
    '  suma ............................... %',
    a, b, c,
    (select count(*) from public.stg_cnt),
    (select count(*) from public.stg_cnt where ticket is not null),
    (select count(*) from public.stg_cnt where monto_cent is not null),
    (select round(sum(monto_cent)/100.0,2) from public.stg_cnt);
end $$;
