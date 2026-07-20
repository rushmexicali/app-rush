-- =====================================================================
-- RUSH Car Wash — los entregados del dia
--
-- Sirve para deshacer una entrega equivocada: el supervisor los ve del
-- mas reciente al mas viejo y puede restaurar uno.
--
-- Va en la base y no en la Edge Function a proposito. Calcular "hoy en
-- Mexicali" en JavaScript obliga a escribir el desfase a mano (-07:00),
-- y Mexicali cambia a -08:00 en invierno: la lista se cortaria una hora
-- antes medio ano sin que nadie lo note. Postgres ya sabe manejar
-- 'America/Tijuana' con sus cambios de horario, igual que en
-- reporte_del_dia y en congelar_reporte.
-- =====================================================================

create or replace function public.entregados_del_dia(p_fecha date default null)
returns setof public.carros
language sql
stable
as $$
  select c.*
    from public.carros c
   where c.estado = 'entregado'
     and c.entregado_en >= (
           (coalesce(p_fecha, (now() at time zone 'America/Tijuana')::date)::text || ' 00:00:00')
           ::timestamp at time zone 'America/Tijuana'
         )
     and c.entregado_en < (
           (coalesce(p_fecha, (now() at time zone 'America/Tijuana')::date)::text || ' 00:00:00')
           ::timestamp at time zone 'America/Tijuana' + interval '1 day'
         )
   order by c.entregado_en desc
   limit 200;
$$;

comment on function public.entregados_del_dia(date) is
  'Carros entregados en un dia (hora de Mexicali), del mas reciente al mas viejo. Sin fecha = hoy.';
