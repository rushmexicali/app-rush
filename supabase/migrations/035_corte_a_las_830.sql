-- =====================================================================
-- RUSH Car Wash — el corte del dia pasa de las 10 PM a las 8:30 PM
--
-- Pedido del dueno el 20/jul/2026. El taller ya no esta trabajando a esa
-- hora: el unico dia con datos reales (19/jul) la ultima venta entro a
-- las 19:36 y la ultima entrega fue a las 20:14. Nada despues de 20:30.
--
-- ---------------------------------------------------------------------
-- Por que dos horarios de cron y no uno
-- ---------------------------------------------------------------------
-- pg_cron corre en UTC y Mexicali cambia de horario dos veces al ano.
-- 20:30 local es una hora UTC distinta segun la epoca:
--
--   verano (PDT, UTC-7):  20:30 local = 03:30 UTC
--   invierno (PST, UTC-8): 20:30 local = 04:30 UTC
--
-- Por eso se agendan LAS DOS y la funcion decide. Solo escribe si en
-- Mexicali son las 20:xx, asi que exactamente una de las dos pega cada
-- dia y la otra se va en blanco:
--
--   03:30 UTC en verano   -> 20:30 local  -> ESCRIBE
--   04:30 UTC en verano   -> 21:30 local  -> no hace nada
--   03:30 UTC en invierno -> 19:30 local  -> no hace nada
--   04:30 UTC en invierno -> 20:30 local  -> ESCRIBE
--
-- Es el mismo truco que ya tenia el corte de las 10 PM (05:00 y 06:00
-- UTC); solo se corrieron las horas.
--
-- Ojo con la FECHA: a las 03:30 UTC del dia 21 en Mexicali son las 20:30
-- del dia 20. Por eso el dia se saca de la hora LOCAL — si se sacara de
-- UTC se congelaria el reporte del dia equivocado, y encima vacio.
--
-- ---------------------------------------------------------------------
-- Lo que se pierde, dicho de frente
-- ---------------------------------------------------------------------
-- Un carro entregado despues de las 20:30 NO entra en la fila congelada
-- de ese dia. Con 10 PM ese riesgo era casi nulo; con 8:30 es mas chico
-- el margen. Hoy no afecta porque el taller cierra antes, pero si algun
-- dia se alarga el turno hay que mover esto o se van a perder carros del
-- historico. El reporte de HOY siempre se recalcula al vuelo, asi que en
-- pantalla si se ven; lo que queda corto es lo que se guarda para
-- siempre.
-- =====================================================================

create or replace function public.congelar_reporte()
returns text
language plpgsql
as $$
declare
  local_ahora timestamp;
  dia         date;
begin
  local_ahora := (now() at time zone 'America/Tijuana');

  -- 20 y no 22: el corte se movio a las 8:30 PM.
  if extract(hour from local_ahora)::int <> 20 then
    return 'no son las 8:30 PM en Mexicali (son las ' ||
           to_char(local_ahora, 'HH24:MI') || '), no se hizo nada';
  end if;

  dia := local_ahora::date;

  insert into public.reportes_diarios (fecha, datos, congelado_en)
  values (dia, public.reporte_del_dia(dia), now())
  on conflict (fecha) do update
    set datos = excluded.datos,
        congelado_en = excluded.congelado_en;

  return 'congelado el reporte del ' || dia;
end;
$$;

comment on function public.congelar_reporte() is
  'Congela el reporte del dia. Solo hace algo si en Mexicali son las 20:xx (corte de 8:30 PM).';

-- ---------------------------------------------------------------------
-- Reagendar. cron.schedule con un nombre que ya existe lo reemplaza.
-- ---------------------------------------------------------------------
select cron.schedule(
  'congelar-reporte',
  '30 3,4 * * *',
  'select public.congelar_reporte();'
);
