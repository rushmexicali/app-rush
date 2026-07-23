-- =====================================================================
-- 058 — El reporte deja de escanear TODA la historia para leer un dia
--
-- EL PROBLEMA: dentro de reporte_del_rango, dos CTEs no filtraban por
-- fecha. Agrupaban la tabla COMPLETA y hasta despues hacian left join
-- contra los carros del dia:
--
--   secado           -> sum(segundos) de TODAS las etapas de secado que
--                       existen, para usar las de un dia.
--   equipo_por_carro -> array_agg de TODAS las asignaciones que existen,
--                       para usar las de un dia.
--
-- Medido el 22/jul/2026: agrupaba 318 filas de etapas para usar 87, y
-- 291 asignaciones para usar 91. O sea que casi tres cuartas partes del
-- trabajo se tiraba a la basura.
--
-- Hoy tarda medio milisegundo y da igual. Pero crece LINEAL con el
-- historico: a 90 carros por dia son ~33,000 carros al ano y ~100,000
-- filas escaneadas EN CADA CARGA de la pagina del dueno — que ademas
-- llama a este mismo reporte una vez por dia consultado. Con un rango de
-- un mes, treinta veces.
--
-- Se arregla con dos 'where ... in (select id from del_dia)'. El
-- resultado es identico; se comprueba abajo dia por dia.
--
-- ADEMAS: el orden de 'equipos' no era determinista. El jsonb_agg
-- ordenaba por (carros desc, equipo), y cuando UN MISMO equipo aparece
-- con la MISMA cantidad de carros en dos tipos distintos, las dos filas
-- empatan y Postgres las devuelve en el orden que se le antoje.
--
-- Paso de verdad: Pablo Cruz secó el 20/jul un encerado y un express, un
-- carro de cada uno. Los dos renglones se intercambiaban solos entre
-- recargas. Se descubrio comparando la salida del reporte antes y
-- despues de un cambio que no tenia NADA que ver — dos renglones
-- barajados que parecian un dato cambiado. Ahora desempata por tipo.
-- =====================================================================

create or replace function public.reporte_del_rango(p_desde date, p_hasta date)
returns jsonb
language plpgsql stable as $function$
declare
  arranca timestamptz;
  termina timestamptz;
  salida  jsonb;
begin
  arranca := (p_desde::text || ' 00:00:00')::timestamp at time zone 'America/Tijuana';
  termina := ((p_hasta + 1)::text || ' 00:00:00')::timestamp at time zone 'America/Tijuana';

  with
  del_dia as (
    select c.*
      from public.carros c
     where not c.es_prueba
       and c.cancelado_en is null
       and not c.tiempo_imposible
       and c.creado_en >= arranca
       and c.creado_en <  termina
  ),

  -- Solo las etapas de los carros del rango. Antes agrupaba la tabla
  -- entera; ver el encabezado de esta migracion.
  secado as (
    select e.carro_id, sum(e.segundos)::int as segundos
      from public.etapas e
     where e.etapa = 'secando'
       and e.segundos is not null
       and e.carro_id in (select id from del_dia)
     group by e.carro_id
  ),

  -- Idem: solo las asignaciones de los carros del rango.
  equipo_por_carro as (
    select a.carro_id,
           array_agg(distinct coalesce(s.mostrar, a.secador)
                     order by coalesce(s.mostrar, a.secador)) as integrantes
      from public.asignaciones a
      left join public.secadores s on s.id = a.empleado_id
     where a.carro_id in (select id from del_dia)
     group by a.carro_id
  ),

  -- Los MISMOS filtros que del_dia. Sin esto, un carro de prueba no
  -- contaba como lavado pero sus rechazos si se le anotaban a una
  -- persona real, y una devolucion cancelaba el carro pero le dejaba el
  -- rechazo puesto.
  rechazos_dia as (
    select r.*
      from public.rechazos r
      join public.carros c on c.id = r.carro_id
     where r.creado_en >= arranca
       and r.creado_en <  termina
       and not c.es_prueba
       and c.cancelado_en is null
  ),

  rechazos_por_carro as (
    select carro_id, count(distinct grupo)::int as cuantos
      from rechazos_dia
     group by carro_id
  ),

  base as (
    select d.id, d.estado, d.producto, d.variante, d.placa, d.foto_path,
           d.creado_en, d.entregado_en, d.cerrado_automaticamente,
           sc.segundos as secado_seg,
           case when d.entregado_en is not null
                then extract(epoch from (d.entregado_en - d.creado_en))::int
           end as espera_seg,
           public.lleva_aspirado(d.producto, d.variante) as aspirado,
           public.tipo_de_servicio(d.producto, d.variante, d.categoria) as tipo,
           ec.integrantes,
           coalesce(rc.cuantos, 0) as rechazos
      from del_dia d
      left join secado sc             on sc.carro_id = d.id
      left join equipo_por_carro ec   on ec.carro_id = d.id
      left join rechazos_por_carro rc on rc.carro_id = d.id
  ),

  -- Se agrupa por equipo Y por tipo de servicio. Un mismo equipo que
  -- seco completos y express aparece DOS veces, una en cada seccion —
  -- que es justo el punto: sus tiempos de express no deben promediarse
  -- con los de completo.
  por_equipo as (
    select array_to_string(integrantes, ' + ') as equipo,
           coalesce(tipo, 'sin_clasificar')    as tipo,
           array_length(integrantes, 1)        as cuantos,
           count(*)::int                       as carros,
           -- Los cerrados solos NO entran: su hora de fin es fabricada.
           -- Un carro olvidado desde las 3 PM meteria 5 horas y hundiria
           -- el promedio de un equipo que no hizo nada mal.
           avg(secado_seg) filter (
             where secado_seg is not null and cerrado_automaticamente is null
           )::int as secado_promedio_seg,
           sum(rechazos)::int                  as rechazos
      from base
     where integrantes is not null
     group by integrantes, coalesce(tipo, 'sin_clasificar')
  ),

  -- Un renglon por rechazo, por persona Y por motivo, ya con el nombre
  -- resuelto. Trae el 'grupo' para poder contar EVENTOS por persona (un
  -- rechazo con tres motivos son tres filas pero un solo grupo).
  rechazos_persona as (
    select coalesce(r.empleado_id, r.secador) as llave,
           coalesce(s.mostrar, r.secador)     as nombre,
           r.grupo,
           r.motivo
      from rechazos_dia r
      left join public.secadores s on s.id = r.empleado_id
  ),

  por_secador as (
    select rp.llave,
           max(rp.nombre)::text          as nombre,
           -- count(distinct grupo), NO count(*): con motivos multiples una
           -- persona tiene varias filas por el MISMO rechazo. Contar filas
           -- inflaria su total. Es la misma trampa del join que multiplica
           -- (migracion 036), ahora del lado de los motivos.
           count(distinct rp.grupo)::int as rechazos,
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
    'desde', p_desde,
    'hasta', p_hasta,
    'dias', (p_hasta - p_desde) + 1,
    'fecha', p_desde,

    'vehiculos_lavados', (select count(*)::int from base where estado = 'entregado'),
    'vehiculos_sin_terminar', (select count(*)::int from base where estado <> 'entregado'),

    -- Reemplaza la senal que se pierde: al cerrar todo al final del dia,
    -- vehiculos_sin_terminar sera SIEMPRE 0 y dejaria de delatar donde se
    -- traba la operacion. Si aqui salen ocho, el supervisor no esta
    -- cerrando carros y hay que ir a ver por que.
    'cerrados_automaticamente', (select count(*)::int from base
                                  where cerrado_automaticamente is not null),

    -- Los que se descartaron por tiempo imposible. Se cuentan FUERA de
    -- base, porque base ya los excluyo. Si un dia salen ocho, no es que
    -- la regla este mal: es que algo raro paso y hay que ir a ver.
    'descartados_por_tiempo', (
      select count(*)::int from public.carros c
       where not c.es_prueba
         and c.cancelado_en is null
         and c.tiempo_imposible
         and c.creado_en >= arranca and c.creado_en < termina
    ),

    -- Que no desaparezcan en silencio: si un dia se cancelan cinco, el
    -- dueno tiene que poder verlo y preguntar por que.
    'cancelados', (
      select count(*)::int from public.carros c
       where not c.es_prueba
         and c.cancelado_en is not null
         and c.creado_en >= arranca and c.creado_en < termina
    ),

    -- Mismo motivo: los cerrados solos quedan fuera de los promedios.
    'espera_promedio_seg', (select avg(espera_seg)::int from base
                             where espera_seg is not null and cerrado_automaticamente is null),
    'secado_promedio_seg', (select avg(secado_seg)::int from base
                             where secado_seg is not null and cerrado_automaticamente is null),

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
               'equipo', equipo, 'tipo', tipo, 'personas', cuantos, 'carros', carros,
               'secado_promedio_seg', secado_promedio_seg, 'rechazos', rechazos
             -- El 'tipo' al final NO es adorno: sin el, un mismo equipo
             -- con la misma cantidad de carros en dos tipos distintos
             -- empata, y los dos renglones se barajan solos entre
             -- recargas. Ver el encabezado de esta migracion.
             ) order by carros desc, equipo, tipo)
        from por_equipo
    ), '[]'::jsonb),

    -- Cuantos carros hubo de cada tipo. Sirve para que la pagina pueda
    -- decir "esta seccion es el 78% del trabajo" sin recalcularlo, y para
    -- ver de un vistazo si algo cayo en "sin clasificar".
    'por_tipo', coalesce((
      select jsonb_object_agg(t, n)
        from (select coalesce(tipo, 'sin_clasificar') as t, count(*)::int as n
                from base group by 1) x
    ), '{}'::jsonb),

    'placas', jsonb_build_object(
      'carros',     (select count(*)::int from base),
      'con_foto',   (select count(*)::int from base where foto_path is not null),
      'con_placa',  (select count(*)::int from base where placa is not null)
    ),

    'generado_en', now()
  ) into salida;

  return salida;
end;
$function$;

comment on function public.reporte_del_rango(date, date) is
  'El reporte, para un dia o un rango. reporte_del_dia() delega aqui: hay '
  'UNA sola implementacion y el dia es el caso particular. Las CTEs '
  'filtran por los carros del rango (058) para no escanear el historico.';
