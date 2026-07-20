-- =====================================================================
-- RUSH Car Wash — un carro entregado demasiado rapido no se cuenta
--
-- Regla del dueno (20/jul/2026): hay tiempos que fisicamente no se
-- pueden hacer, ni con el taller vacio.
--
--   con aspirado (completos, encerados)  minimo 20 min
--   express (sin aspirado)               minimo 10 min
--
-- Textual: "si hay una venta que se entrega en menos de esos tiempos, muy
-- posiblemente fue un error o prueba y no deberia ser contabilizada".
-- El propio dueno creo una venta y la entrego en menos de 10 minutos
-- mientras se familiarizaba con la app.
--
-- ---------------------------------------------------------------------
-- Se midio antes de fijar los numeros
-- ---------------------------------------------------------------------
-- Contra los 40 carros reales del 19/jul:
--
--   con aspirado  33 carros  min 2 min   promedio 48 min   max 128 min
--   express        7 carros  min 13 min  promedio 19 min   max  24 min
--
-- La regla descarta 4 carros, y los cuatro huelen mal por otras razones:
--
--   71  Completo       2 min   18:52->18:54
--   70  Completo Cera  3 min   18:51->18:54
--   42  Solo Interior  3 min   16:02->16:05
--   76  Completo      18 min   19:29->19:47  (sin etapa de secado)
--
-- Los carros 70 y 71 son los del apuro de las 18:54 que ya se habian
-- detectado por OTRO camino —la foto mal pegada del Accord— y el 70 es
-- ademas el que se devolvio un minuto despues de entregarse. Tres señales
-- independientes apuntando al mismo momento: buena señal de que el
-- umbral esta bien puesto.
--
-- ---------------------------------------------------------------------
-- POR QUE DOS UMBRALES Y NO UNO
-- ---------------------------------------------------------------------
-- Esto lo dijo el dueno y los datos lo confirman: los express reales del
-- 19/jul duraron entre 13 y 24 minutos. Un umbral unico de 20 min
-- habria descartado TRES express buenos. Comparar peras con manzanas
-- otra vez, pero ahora en los umbrales.
--
-- ---------------------------------------------------------------------
-- No se esconden: se cuentan aparte
-- ---------------------------------------------------------------------
-- Es una heuristica, no una certeza — el dueno mismo dice "muy
-- posiblemente". Asi que salen de los promedios y del conteo de lavados,
-- pero el reporte dice CUANTOS se descartaron. Si un dia salen ocho, no
-- es que la regla este mal: es que algo raro paso ese dia y hay que ir a
-- ver. Mismo criterio que cerrados_automaticamente.
-- =====================================================================

create or replace function public.tiempo_minimo_seg(p_tipo text)
returns integer
language sql
immutable
as $$
  -- El express es el unico mas corto. Un tipo desconocido cae en el
  -- umbral largo: mas vale marcar de mas y que se vea, que dejar pasar
  -- un tiempo imposible.
  select case when p_tipo = 'sin_aspirado' then 10 * 60 else 20 * 60 end;
$$;

comment on function public.tiempo_minimo_seg(text) is
  'Minimo fisicamente posible de pago a entrega: 10 min express, 20 min lo demas.';

alter table public.carros
  add column if not exists tiempo_imposible boolean
  generated always as (
    entregado_en is not null
    and extract(epoch from (entregado_en - creado_en))
        < public.tiempo_minimo_seg(
            public.tipo_de_servicio(producto, variante, categoria))
  ) stored;

comment on column public.carros.tiempo_imposible is
  'Se entrego mas rapido de lo fisicamente posible: casi seguro error o prueba. No cuenta en el reporte, pero se reporta cuantos hubo.';
