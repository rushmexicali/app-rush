-- =====================================================================
-- RUSH Car Wash — arreglo: los rechazos por secador salian inflados
--
-- Encontrado el 20/jul/2026 al congelar el reporte del dia y comparar el
-- JSON contra la tabla `rechazos` a mano. El reporte decia que Edgar
-- Reyes tenia 4 rechazos; en la tabla habia 2.
--
-- La causa: `por_secador` unia un `join lateral` que ya venia agrupado
-- por motivo, ANTES del group by. Cada renglon de rechazo se multiplicaba
-- por la cantidad de motivos DISTINTOS de esa persona:
--
--   Edgar: 2 rechazos x 2 motivos distintos -> 4 renglones -> count(*) = 4
--   eri:   1 rechazo  x 1 motivo            -> 1 renglon   -> count(*) = 1
--
-- Por eso nunca se vio: con un solo motivo el numero sale bien. Solo se
-- infla cuando a una persona le rechazan por dos cosas distintas, y hasta
-- hoy no habia pasado.
--
-- Los `motivos` SI estaban bien, y eso ayudo a encontrarlo: las llaves de
-- un objeto JSON se colapsan solas, asi que jsonb_object_agg no se
-- enteraba de la multiplicacion. El conteo decia 4 y el desglose sumaba
-- 2; ese desacuerdo entre dos numeros que salen del mismo dato fue la
-- pista. Vale la pena recordarlo: un total que no cuadra con su propio
-- desglose casi siempre es un join que multiplica.
--
-- Ahora los motivos se calculan en una subconsulta aparte, que no toca
-- los renglones que se cuentan. Lo demas es identico a la 031.
--
-- OJO: las filas ya congeladas en reportes_diarios traen el numero malo.
-- Se regeneran aparte; esta migracion solo arregla la funcion.
-- =====================================================================

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
  del_dia as (
    select c.*
      from public.carros c
     where not c.es_prueba
       and c.cancelado_en is null
       and c.creado_en >= arranca
       and c.creado_en <  termina
  ),

  secado as (
    select e.carro_id, sum(e.segundos)::int as segundos
      from public.etapas e
     where e.etapa = 'secando'
       and e.segundos is not null
     group by e.carro_id
  ),

  equipo_por_carro as (
    select a.carro_id,
           array_agg(distinct coalesce(s.mostrar, a.secador)
                     order by coalesce(s.mostrar, a.secador)) as integrantes
      from public.asignaciones a
      left join public.secadores s on s.id = a.empleado_id
     group by a.carro_id
  ),

  rechazos_dia as (
    select r.*
      from public.rechazos r
     where r.creado_en >= arranca
       and r.creado_en <  termina
  ),

  rechazos_por_carro as (
    select carro_id, count(distinct grupo)::int as cuantos
      from rechazos_dia
     group by carro_id
  ),

  base as (
    select d.id, d.estado, d.producto, d.variante, d.placa, d.foto_path,
           d.creado_en, d.entregado_en,
           sc.segundos as secado_seg,
           case when d.entregado_en is not null
                then extract(epoch from (d.entregado_en - d.creado_en))::int
           end as espera_seg,
           public.lleva_aspirado(d.producto, d.variante) as aspirado,
           ec.integrantes,
           coalesce(rc.cuantos, 0) as rechazos
      from del_dia d
      left join secado sc             on sc.carro_id = d.id
      left join equipo_por_carro ec   on ec.carro_id = d.id
      left join rechazos_por_carro rc on rc.carro_id = d.id
  ),

  por_equipo as (
    select array_to_string(integrantes, ' + ') as equipo,
           array_length(integrantes, 1)        as cuantos,
           count(*)::int                       as carros,
           avg(secado_seg) filter (where secado_seg is not null)::int as secado_promedio_seg,
           sum(rechazos)::int                  as rechazos
      from base
     where integrantes is not null
     group by integrantes
  ),

  -- Un renglon por rechazo y por persona, ya con el nombre resuelto.
  -- Existe para poder CONTAR sin que el calculo de motivos multiplique.
  rechazos_persona as (
    select coalesce(r.empleado_id, r.secador) as llave,
           coalesce(s.mostrar, r.secador)     as nombre,
           r.motivo
      from rechazos_dia r
      left join public.secadores s on s.id = r.empleado_id
  ),

  por_secador as (
    select rp.llave,
           max(rp.nombre)::text as nombre,
           count(*)::int        as rechazos,
           -- Subconsulta y no lateral: el lateral se unia ANTES de
           -- agrupar, y multiplicaba los renglones por la cantidad de
           -- motivos distintos de esa persona.
           (select jsonb_object_agg(x.motivo, x.veces)
              from (select r2.motivo, count(*)::int as veces
                      from rechazos_persona r2
                     where r2.llave = rp.llave
                     group by r2.motivo) x) as motivos
      from rechazos_persona rp
     group by rp.llave
  )

  select jsonb_build_object(
    'fecha', p_fecha,

    'vehiculos_lavados', (select count(*)::int from base where estado = 'entregado'),
    'vehiculos_sin_terminar', (select count(*)::int from base where estado <> 'entregado'),

    -- Que no desaparezcan en silencio: si un dia se cancelan cinco, el
    -- dueno tiene que poder verlo y preguntar por que.
    'cancelados', (
      select count(*)::int from public.carros c
       where not c.es_prueba
         and c.cancelado_en is not null
         and c.creado_en >= arranca and c.creado_en < termina
    ),

    'espera_promedio_seg', (select avg(espera_seg)::int from base where espera_seg is not null),
    'secado_promedio_seg', (select avg(secado_seg)::int from base where secado_seg is not null),

    'aspirado', jsonb_build_object(
      'con',            (select count(*)::int from base where aspirado is true),
      'sin',            (select count(*)::int from base where aspirado is false),
      'sin_clasificar', (select count(*)::int from base where aspirado is null)
    ),

    'rechazos', jsonb_build_object(
      'eventos', (select count(distinct grupo)::int from rechazos_dia),
      'carros',  (select count(distinct carro_id)::int from rechazos_dia)
    ),

    'rechazos_por_secador', coalesce((
      select jsonb_agg(jsonb_build_object(
               'secador', nombre, 'rechazos', rechazos, 'motivos', motivos
             ) order by rechazos desc, nombre)
        from por_secador
    ), '[]'::jsonb),

    'equipos', coalesce((
      select jsonb_agg(jsonb_build_object(
               'equipo', equipo, 'personas', cuantos, 'carros', carros,
               'secado_promedio_seg', secado_promedio_seg, 'rechazos', rechazos
             ) order by carros desc, equipo)
        from por_equipo
    ), '[]'::jsonb),

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
