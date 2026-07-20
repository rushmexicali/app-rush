-- =====================================================================
-- RUSH Car Wash — Fase 5: el reporte diario
--
-- Corte a las 10 PM hora de Mexicali con lo que pidio el dueno:
--   - vehiculos lavados
--   - autos atendidos por equipo
--   - tiempo promedio de secado por equipo
--   - tiempo promedio de espera por carro
--   - desglose con / sin aspirado
--
-- ADVERTENCIA sobre los primeros dias: al 19/jul/2026 hay UN solo dia de
-- operacion y ademas sucio (13 carros marcados es_prueba porque la app se
-- construyo durante el turno). Estos numeros sirven para comprobar que la
-- maquinaria funciona, NO para tomar decisiones del negocio todavia.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Con o sin aspirado
--
-- Regla de negocio dictada por el dueno el 19/jul/2026. No se pudo sacar
-- de los datos: la palabra "aspirado" no existe en ningun lado del
-- catalogo de Zettle.
--
--   CON: Completo, Completo Cera, Solo Interior, Gratis, Manual
--   SIN: Express, y Manual con variante Express / Express Grande
--
-- La trampa es Manual: el MISMO producto cae de los dos lados segun su
-- variante. Por eso esto vive en una sola funcion — si se copia la regla
-- a dos lugares, tarde o temprano se desincronizan.
--
-- Un producto que no reconozcamos devuelve NULL, no false. El reporte lo
-- cuenta aparte como "sin clasificar". Adivinar seria peor: si manana
-- aparece un paquete nuevo, queremos enterarnos, no que se esconda en la
-- columna equivocada.
-- ---------------------------------------------------------------------
create or replace function public.lleva_aspirado(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select case
    -- Express nunca lleva, ni como producto ni como variante de Manual.
    when coalesce(p_producto, '') ilike 'express%' then false
    when coalesce(p_producto, '') ilike 'manual%'
     and coalesce(p_variante, '') ilike 'express%' then false

    when coalesce(p_producto, '') ilike 'completo%'      then true
    when coalesce(p_producto, '') ilike 'solo interior%' then true
    when coalesce(p_producto, '') ilike 'gratis%'        then true
    when coalesce(p_producto, '') ilike 'manual%'        then true

    else null
  end;
$$;

comment on function public.lleva_aspirado(text, text) is
  'Si el paquete incluye aspirado. NULL = producto no reconocido (se cuenta aparte).';

-- ---------------------------------------------------------------------
-- El reporte de un dia
--
-- Un dia es de 00:00 a 23:59 hora de MEXICALI (America/Tijuana), no UTC.
-- Sin esto, todo lo que entre despues de las 4-5 PM caeria en el dia
-- siguiente.
--
-- Dos trampas del modelo que este calculo respeta a proposito:
--
--  1) asignaciones.fin casi siempre es NULL. Solo regresar_etapa lo
--     llena; la entrega normal nunca cierra la asignacion. Por eso el
--     tiempo de secado sale de la ETAPA del carro, no de la asignacion.
--
--  2) Un carro puede tener VARIAS filas de la misma etapa: al usar
--     "Corregir" se borra la etapa abierta y se reabre la anterior. Por
--     eso se suma con sum(segundos) por carro, no se supone una fila.
-- ---------------------------------------------------------------------
create or replace function public.reporte_del_dia(p_fecha date)
returns jsonb
language plpgsql
stable
as $$
declare
  arranca timestamptz;
  termina timestamptz;
  salida  jsonb;
begin
  arranca := (p_fecha::text || ' 00:00:00')::timestamp at time zone 'America/Tijuana';
  termina := arranca + interval '1 day';

  with
  -- Los carros del dia. es_prueba fuera: son los del dia que se construyo
  -- la app, con etapas de 1 segundo y de 2 horas que no significan nada.
  del_dia as (
    select c.*
      from public.carros c
     where not c.es_prueba
       and c.creado_en >= arranca
       and c.creado_en <  termina
  ),

  -- Secado por carro. Suma de TODAS las filas cerradas de la etapa.
  secado as (
    select e.carro_id, sum(e.segundos)::int as segundos
      from public.etapas e
     where e.etapa = 'secando'
       and e.segundos is not null
     group by e.carro_id
  ),

  -- El equipo es quien haya secado ESE carro, junto. Una persona sola es
  -- un equipo de uno. Se usa el nombre para mostrar; si la asignacion no
  -- trae empleado_id (captura manual o fila vieja), se cae al nombre que
  -- se guardo al momento de asignar.
  equipo_por_carro as (
    select a.carro_id,
           array_agg(distinct coalesce(s.mostrar, a.secador)
                     order by coalesce(s.mostrar, a.secador)) as integrantes
      from public.asignaciones a
      left join public.secadores s on s.id = a.empleado_id
     group by a.carro_id
  ),

  base as (
    select d.id,
           d.estado,
           d.producto,
           d.variante,
           d.placa,
           d.foto_path,
           d.creado_en,
           d.entregado_en,
           sc.segundos as secado_seg,
           case when d.entregado_en is not null
                then extract(epoch from (d.entregado_en - d.creado_en))::int
           end as espera_seg,
           public.lleva_aspirado(d.producto, d.variante) as aspirado,
           ec.integrantes
      from del_dia d
      left join secado sc            on sc.carro_id = d.id
      left join equipo_por_carro ec  on ec.carro_id = d.id
  ),

  por_equipo as (
    select array_to_string(integrantes, ' + ') as equipo,
           array_length(integrantes, 1)        as cuantos,
           count(*)::int                       as carros,
           avg(secado_seg) filter (where secado_seg is not null)::int as secado_promedio_seg
      from base
     where integrantes is not null
     group by integrantes
  )

  select jsonb_build_object(
    'fecha', p_fecha,

    -- Entraron ese dia Y ya salieron. Los que siguen adentro se cuentan
    -- aparte para que el numero no se lea como si se hubieran perdido.
    'vehiculos_lavados', (select count(*)::int from base where estado = 'entregado'),
    'vehiculos_sin_terminar', (select count(*)::int from base where estado <> 'entregado'),

    -- De que paga a que se lo entregan: el tiempo completo del cliente.
    'espera_promedio_seg', (select avg(espera_seg)::int from base where espera_seg is not null),
    'secado_promedio_seg', (select avg(secado_seg)::int from base where secado_seg is not null),

    'aspirado', jsonb_build_object(
      'con',            (select count(*)::int from base where aspirado is true),
      'sin',            (select count(*)::int from base where aspirado is false),
      'sin_clasificar', (select count(*)::int from base where aspirado is null)
    ),

    'equipos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'equipo', equipo,
               'personas', cuantos,
               'carros', carros,
               'secado_promedio_seg', secado_promedio_seg
             ) order by carros desc, equipo)
        from por_equipo
    ), '[]'::jsonb),

    -- Cuantas placas se alcanzaron a leer. Va en el reporte a proposito:
    -- sin este dato, el historial por placa se lee como si fuera el total
    -- de visitas, y no lo es — la foto es opcional.
    'placas', jsonb_build_object(
      'carros',     (select count(*)::int from base),
      'con_foto',   (select count(*)::int from base where foto_path is not null),
      'con_placa',  (select count(*)::int from base where placa is not null)
    ),

    'generado_en', now()
  ) into salida;

  return salida;
end;
$$;

comment on function public.reporte_del_dia(date) is
  'Reporte de un dia (hora de Mexicali). Se calcula al vuelo; el congelado vive en reportes_diarios.';

-- ---------------------------------------------------------------------
-- El historico, congelado
--
-- El reporte se puede recalcular siempre, pero solo mientras existan los
-- carros. Congelarlo lo hace sobrevivir a cualquier depuracion futura, y
-- pesa nada: ~2 KB por dia, unos 700 KB en diez anos.
-- ---------------------------------------------------------------------
create table if not exists public.reportes_diarios (
  fecha        date primary key,
  datos        jsonb not null,
  congelado_en timestamptz not null default now()
);

comment on table public.reportes_diarios is
  'Reporte diario ya calculado. Sobrevive aunque se depuren los carros que lo originaron.';

alter table public.reportes_diarios enable row level security;

-- ---------------------------------------------------------------------
-- El corte de las 10 PM
--
-- pg_cron corre en UTC y Mexicali cambia de horario dos veces al ano, asi
-- que un horario fijo en UTC se desfasa medio ano. Se agenda a las 05:00
-- Y 06:00 UTC (las dos posibilidades) y la funcion solo escribe si la
-- hora LOCAL es 22. Exactamente una de las dos pega cada dia.
--
-- El upsert por fecha lo hace idempotente: correr de mas nunca duplica.
-- ---------------------------------------------------------------------
create or replace function public.congelar_reporte()
returns text
language plpgsql
as $$
declare
  local_ahora timestamp;
  dia         date;
begin
  local_ahora := (now() at time zone 'America/Tijuana');

  if extract(hour from local_ahora)::int <> 22 then
    return 'no son las 10 PM en Mexicali (son las ' ||
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

create extension if not exists pg_cron;

select cron.unschedule('congelar-reporte')
 where exists (select 1 from cron.job where jobname = 'congelar-reporte');

select cron.schedule(
  'congelar-reporte',
  '0 5,6 * * *',
  $$ select public.congelar_reporte(); $$
);
