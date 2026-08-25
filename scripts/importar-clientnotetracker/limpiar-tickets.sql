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
  --     hora: gana la nota mas cercana a la venta; la otra pierde ticket y
  --     monto, pero SIGUE siendo visita.
  --
  --     ⚠️ Corre DESPUES de (A) y (B), o los 281 marcadores `1` se pelearian
  --     entre si y 280 saldrian "perdedores" de un desempate sin sentido.
  --
  --     🔑 SI EL EMPATE ES EXACTO, NO GANA NADIE. Pasa cuando dos clientes
  --     distintos traen el mismo ticket en el MISMO minuto (una ficha partida:
  --     la cajera anoto la misma visita con dos nombres). Ahi Zettle no aporta
  --     ninguna evidencia, y adivinar al 50% deja escrito como hecho algo que
  --     no lo es: se le quita el ticket a los dos y el lavado se queda sin
  --     dueno. Es la regla del §11.35 del CLAUDE.md, y ademas es lo unico
  --     reproducible — hasta el 24/ago/2026 el ganador salia del orden fisico
  --     de las filas y dos corridas del mismo export daban resultados
  --     distintos (12 filas de 15,340 bailaban).
  with r as (
    select s.ctid as fila, s.ticket,
           rank() over (
             partition by s.ticket
             order by abs(extract(epoch from (
                       (s.dt_local::timestamp at time zone coalesce(s.tz,'America/Tijuana')) - zh.hora)))) rk
    from public.stg_cnt s join zh on zh.n::text = s.ticket
    where s.ticket is not null
      and s.ticket in (select ticket from public.stg_cnt where ticket is not null
                       group by ticket having count(*) > 1)),
  con_ganador as (
    select ticket from r where rk = 1 group by ticket having count(*) = 1)
  update public.stg_cnt s set ticket = null, monto_cent = null
  from r
  where r.fila = s.ctid
    and (r.rk > 1 or r.ticket not in (select ticket from con_ganador));
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
