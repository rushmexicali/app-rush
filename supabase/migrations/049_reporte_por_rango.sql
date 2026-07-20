-- =====================================================================
-- RUSH Car Wash — reporte por RANGO de dias, y detalle de un carro
--
-- Dos cosas que pidio el dueno el 20/jul/2026:
--
--   1. En la pagina del reporte, poder escoger dia inicial y dia final
--      (como lo maneja Zettle) y ver el reporte de ese intervalo.
--   2. En la lista de finalizados, poder tocar un carro y ver su
--      desglose: prelavado, secado, tiempo total y quienes lo secaron.
--
-- ---------------------------------------------------------------------
-- El reporte de UN dia pasa a ser un caso del reporte de RANGO
-- ---------------------------------------------------------------------
-- Se pudo haber escrito una funcion nueva al lado de reporte_del_dia.
-- Seria el mismo error que este proyecto ya cometio cuatro veces hoy:
-- dos implementaciones de la misma pregunta que tarde o temprano se
-- desfasan (express vs aspirado, rechazos_dia vs del_dia, el nombre del
-- producto vs la categoria, y el aviso tapando al lavado a mano).
--
-- Asi que reporte_del_dia AHORA DELEGA en reporte_del_rango con la misma
-- fecha de los dos lados. Solo hay una implementacion; el dia es el caso
-- particular. Nada de lo que ya llamaba a reporte_del_dia se entera
-- (congelar_reporte, la Edge Function, los reportes congelados).
--
-- Se agregan 'desde', 'hasta' y 'dias' a la salida. Se conserva 'fecha'
-- para no romper lo que ya lee ese campo.
--
-- OJO con lo que un rango NO puede hacer: los reportes congelados son
-- POR DIA. Un rango se calcula al vuelo sobre los carros, no sumando
-- filas congeladas. Eso es correcto —los promedios hay que ponderarlos
-- por carro, no promediar promedios— pero significa que un rango largo
-- recorre mas datos. Con 200 carros al dia y rangos de un mes son 6,000
-- renglones: nada para Postgres.
-- =====================================================================

create or replace function public.reporte_del_rango(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
as $$
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
       -- Entregado mas rapido de lo fisicamente posible: casi seguro un
       -- error o una prueba. Sale de TODAS las cuentas, no solo de los
       -- promedios — el dueno lo pidio asi ("no deberia ser
       -- contabilizada"). Se cuenta aparte mas abajo para que no
       -- desaparezca en silencio. Ver migracion 047.
       and not c.tiempo_imposible
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
           -- Un carro olvidado desde las 3 PM metería 5 horas y hundiría
           -- el promedio de un equipo que no hizo nada mal.
           avg(secado_seg) filter (
             where secado_seg is not null and cerrado_automaticamente is null
           )::int as secado_promedio_seg,
           sum(rechazos)::int                  as rechazos
      from base
     where integrantes is not null
     group by integrantes, coalesce(tipo, 'sin_clasificar')
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
    'desde', p_desde,
    'hasta', p_hasta,
    'dias', (p_hasta - p_desde) + 1,
    'fecha', p_desde,

    'vehiculos_lavados', (select count(*)::int from base where estado = 'entregado'),
    'vehiculos_sin_terminar', (select count(*)::int from base where estado <> 'entregado'),

    -- Reemplaza la señal que se pierde: al cerrar todo al final del día,
    -- vehiculos_sin_terminar será SIEMPRE 0 y dejaría de delatar dónde se
    -- traba la operación. Si aquí salen ocho, el supervisor no está
    -- cerrando carros y hay que ir a ver por qué.
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
             ) order by carros desc, equipo)
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
$$;

comment on function public.reporte_del_rango(date, date) is
  'El reporte de un intervalo de dias (hora de Mexicali), ambos extremos incluidos.';

-- ---------------------------------------------------------------------
-- Un dia es un rango de un dia. UNA sola implementacion.
-- ---------------------------------------------------------------------
create or replace function public.reporte_del_dia(p_fecha date)
returns jsonb
language sql
stable
as $$
  select public.reporte_del_rango(p_fecha, p_fecha);
$$;

comment on function public.reporte_del_dia(date) is
  'Atajo: el reporte de un solo dia. Delega en reporte_del_rango.';

-- ---------------------------------------------------------------------
-- El desglose de un carro, para tocarlo en la lista de finalizados
--
-- Se devuelve YA SUMADO por etapa: un carro puede tener VARIAS filas de
-- la misma etapa porque "Corregir" borra la etapa abierta y reabre la
-- anterior. Sumar aqui evita que cada pantalla tenga que acordarse.
--
-- El total es de PAGO A ENTREGA (lo que el cliente espero), no la suma
-- de las etapas: entre etapas hay huecos y el cliente los vive igual.
-- ---------------------------------------------------------------------
create or replace function public.detalle_del_carro(p_carro bigint)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'id',           c.id,
    'producto',     c.producto,
    'variante',     c.variante,
    'monto',        c.monto,
    'placa',        c.placa,
    'tipo_unidad',  c.tipo_unidad,
    'color',        c.color,
    'marca',        c.marca,
    'cliente',      c.cliente,
    'linea',        c.linea,
    'aviso',        c.aviso,
    'a_mano',       c.a_mano,
    'es_express',   c.es_express,
    'creado_en',    c.creado_en,
    'entregado_en', c.entregado_en,
    'cerrado_automaticamente', c.cerrado_automaticamente is not null,
    'tiempo_imposible',        c.tiempo_imposible,

    -- Segundos por etapa, ya sumados.
    'prelavado_seg', (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'prelavado'),
    'tunel_seg',     (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'tunel'),
    'secando_seg',   (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'secando'),

    'total_seg', case when c.entregado_en is not null
                      then extract(epoch from (c.entregado_en - c.creado_en))::int end,

    -- Quien lo seco. Se usa el nombre guardado en la asignacion y no el
    -- de empleados: asi el historial sigue diciendo quien seco aunque
    -- esa persona ya no este en Jibble.
    'secadores', coalesce((
      select jsonb_agg(distinct coalesce(s.mostrar, a.secador))
        from public.asignaciones a
        left join public.secadores s on s.id = a.empleado_id
       where a.carro_id = c.id
    ), '[]'::jsonb)
  )
  from public.carros c
  where c.id = p_carro;
$$;

comment on function public.detalle_del_carro(bigint) is
  'Desglose de un carro: segundos por etapa (ya sumados), total de pago a entrega, y quienes lo secaron.';
