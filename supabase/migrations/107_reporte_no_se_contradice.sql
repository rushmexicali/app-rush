-- =====================================================================
-- 107 — El reporte deja de contradecirse
--
-- Hallazgos N1, N2 y N3 de la auditoria del 19/ago. Solo AGREGA campos:
-- ninguno de los que ya existian cambia de valor, asi que los reportes ya
-- congelados siguen siendo validos y la pagina cae de pie si no los trae.
-- =====================================================================

CREATE OR REPLACE FUNCTION public.reporte_del_rango(p_desde date, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
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

  -- Carros que ARRANCARON ENCIMADOS: al asignarlos, alguno de sus secadores
  -- ya traia OTRO carro sin entregar. Se compara la hora de asignacion de
  -- este carro contra la del otro y la entrega del otro. Solo cuenta cuando
  -- hay empleado_id (los manuales sin id no se pueden cruzar; se dejan sin
  -- marcar, que es el lado conservador). Es un si/no, no una resta.
  encimados as (
    select distinct a.carro_id
      from public.asignaciones a
      join public.asignaciones a2
        on a2.empleado_id = a.empleado_id
       and a2.carro_id <> a.carro_id
      join public.carros c2 on c2.id = a2.carro_id
     where a.carro_id in (select id from del_dia)
       and a.empleado_id is not null
       and a2.inicio < a.inicio
       and (c2.entregado_en is null or c2.entregado_en > a.inicio)
       -- ⚠️ Un carro CANCELADO conserva `entregado_en` nulo para siempre (asi
       -- lo deja "Borrar unidad" y asi lo deja una devolucion), de modo que
       -- sin este filtro deja a su secador marcado como ocupado el resto de
       -- la historia. Paso de verdad: los carros 515 y 516 del 24/jul dejaron
       -- a Jorge Luna y Jaime Gallegos en 100% de encimados durante 25 dias,
       -- y sobre ese numero se concluyo por escrito que "siempre estaban
       -- saturados". 201 de 935 marcas eran falsas. Auditoria del 19/ago.
       and c2.cancelado_en is null
       and not coalesce(c2.es_prueba, false)
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
           (d.id in (select carro_id from encimados)) as encimado,
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
           -- CONTEXTO (065): cuantos de sus carros arrancaron encimados. NO
           -- cambia el promedio de arriba; solo se muestra al lado para que
           -- el numero no se lea mal (al que mas carga le entran mas
           -- encimados y su promedio se ve peor sin ser mas lento).
           count(*) filter (where encimado)::int as encimados,
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

    -- CONTEXTO (065): cuantos carros en total arrancaron encimados (a la
    -- persona ya le estaba secando otro). No cambia ningun promedio; sirve
    -- para leer el numero de secado con la carga en mente.
    'encimados', (select count(*)::int from base where encimado),

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

    -- NUEVO (083): de esos cancelados, cuantos los BORRO el supervisor por
    -- basura (unidad sin asignar). Se separa de las devoluciones para no
    -- mezclar un dato de calidad con un reembolso. Subconjunto de
    -- 'cancelados'; el resto son devoluciones o cancelaciones viejas.
    'borrados', (
      select count(*)::int from public.carros c
       where not c.es_prueba
         and c.cancelado_motivo = 'borrado_supervisor'
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
               'secado_promedio_seg', secado_promedio_seg,
               'encimados', encimados, 'rechazos', rechazos
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

    -- El secado promedio PARTIDO POR TIPO. El promedio general de arriba
    -- mezcla express con completos, que es justo lo que el resto del reporte
    -- prohibe ("no comparar peras con manzanas"): un express tarda ~4x menos,
    -- asi que ese numero se mueve con la MEZCLA del dia y no con la velocidad
    -- de nadie. Medido: 13/ago 29.8 min con 39% de express contra 17/ago 39.8
    -- min con 24% — los dos extremos se explican por la mezcla, no por el
    -- taller. Mismos filtros que el general: sin cerrados solos, sin cortos.
    'secado_por_tipo', coalesce((
      select jsonb_object_agg(t, prom)
        from (select coalesce(tipo, 'sin_clasificar') as t,
                     avg(secado_seg)::int as prom
                from base
               where secado_seg is not null
                 and secado_seg >= secado_min
                 and cerrado_automaticamente is null
               group by 1) x
       where prom is not null
    ), '{}'::jsonb),

    -- Cuantos carros de cada tipo NO tuvieron secador asignado. La tabla de
    -- equipos solo lista los que SI lo tuvieron, asi que la diferencia contra
    -- `por_tipo` se evaporaba entre el encabezado y la tabla — y esa
    -- diferencia son justo los carros que nadie trabajo. El 11/ago el
    -- encabezado decia 22 y la tabla sumaba 15: los 7 que faltaban eran el
    -- peor dia de abandono del mes, y la pantalla no lo dijo.
    'sin_equipo_por_tipo', coalesce((
      select jsonb_object_agg(t, n)
        from (select coalesce(tipo, 'sin_clasificar') as t, count(*)::int as n
                from base where integrantes is null group by 1) x
    ), '{}'::jsonb),

    -- Cuantos de los del rango YA se entregaron. Sin esto la pagina pone
    -- "vehiculos lavados" (que cuenta solo entregados) junto a "con/sin
    -- aspirado" (que cuentan todos), y en el dia en curso el desglose suma MAS
    -- que el total sin una linea que lo explique: medido hoy, 25 arriba y 29
    -- abajo.
    'entregados', (select count(*)::int from base where estado = 'entregado'),

    'placas', jsonb_build_object(
      'carros',     (select count(*)::int from base),
      'con_foto',   (select count(*)::int from base where foto_path is not null),
      'con_placa',  (select count(*)::int from base where placa is not null)
    ),

    'generado_en', now()
  ) into salida;

  return salida;
end;
$function$

;
