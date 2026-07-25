-- =====================================================================
-- 064 — Un secado imposiblemente corto no entra al promedio de secado
--
-- El hallazgo del 22/jul/2026: carros con ~6 segundos de "secado". Es el
-- mismo evento visto de un lado: el supervisor olvido el carro y, al
-- acordarse, lo asigno y lo entrego de un jalon. Ese tiempo falso-rapidisimo
-- BAJA el promedio de quien se lo acreditaron y lo hace ver mas rapido de lo
-- que es (Jose Manuel salio con "1 completo a 0.1 min"). Fueron 0 casos el
-- 20/jul, 5 el 21 y 3 el 22 — es un patron, no un accidente.
--
-- Regla del dueño (24/jul): un carro con secado de menos de 3 MINUTOS
-- (fisicamente imposible de secar) SIGUE contando como vehiculo lavado,
-- pero su tiempo de SECADO no entra a los promedios (general y por equipo).
--
-- OJO — solo se saca del SECADO, NO de la espera. A diferencia de un cierre
-- automatico (cuya hora de entrega es INVENTADA, asi que su espera es falsa),
-- aqui el carro SI se entrego de verdad: su espera de pago-a-entrega es una
-- espera real que el cliente vivio (los olvidados tienen esperas de 42-64
-- min, reales). Esconderla taparia una mala experiencia de verdad. Lo unico
-- imposible es el secado de 6 segundos.
--
-- Se surface 'secados_descartados' para que no desaparezca en silencio: si
-- un dia salen ocho, el supervisor esta olvidando carros y hay que ir a ver.
-- Mismo criterio que 'cerrados_automaticamente' y 'descartados_por_tiempo'.
--
-- Base: la 058. Cambia SOLO los dos promedios de secado y agrega el conteo.
-- Todo lo demas es identico (verificado dia por dia contra la 058).
-- =====================================================================

create or replace function public.reporte_del_rango(p_desde date, p_hasta date)
returns jsonb
language plpgsql stable as $function$
declare
  arranca timestamptz;
  termina timestamptz;
  -- 3 min. Menos que esto es imposible de secar, ni con el taller vacio: es
  -- un olvido registrado tarde, no trabajo. Vive aqui, en un solo lugar.
  secado_min constant int := 180;
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
  -- entera; ver el encabezado de la 058.
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
           -- Fuera de este promedio: los cerrados solos (hora de fin
           -- fabricada) Y los secados imposiblemente cortos (< 3 min, un
           -- olvido registrado tarde). Los dos ensucian el numero que mide
           -- que tan rapido seca la persona. Siguen contando como carro.
           avg(secado_seg) filter (
             where secado_seg is not null
               and secado_seg >= secado_min
               and cerrado_automaticamente is null
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

    -- Carros con secado imposiblemente corto (< 3 min): olvidos registrados
    -- tarde. Cuentan como lavado, pero su secado quedo fuera de los
    -- promedios. Si un dia salen ocho, el supervisor esta olvidando carros.
    'secados_descartados', (select count(*)::int from base
                             where secado_seg is not null and secado_seg < secado_min),

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

    -- La espera SI incluye los de secado corto: su espera de pago-a-entrega
    -- es real (el cliente la vivio), a diferencia de los cerrados solos, cuya
    -- hora de entrega es fabricada. Solo esos ultimos quedan fuera.
    'espera_promedio_seg', (select avg(espera_seg)::int from base
                             where espera_seg is not null and cerrado_automaticamente is null),
    -- El secado SI saca los cortos (ademas de los cerrados solos): ver
    -- por_equipo arriba, es el mismo criterio.
    'secado_promedio_seg', (select avg(secado_seg)::int from base
                             where secado_seg is not null
                               and secado_seg >= secado_min
                               and cerrado_automaticamente is null),

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
             -- recargas. Ver el encabezado de la 058.
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
  'El reporte, para un dia o un rango. reporte_del_dia() delega aqui. Un '
  'secado < 3 min (secado_min) queda fuera del promedio de secado por ser un '
  'olvido registrado tarde; su espera si cuenta, es real (064).';
