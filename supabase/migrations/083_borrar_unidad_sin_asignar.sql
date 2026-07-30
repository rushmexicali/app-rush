-- =====================================================================
-- 083 — "Borrar unidad" para carros SIN ASIGNAR (informacion basura)
--
-- El supervisor a veces deja carros en prelavado que nunca se van a
-- trabajar (se cancelo el servicio, se fue el cliente, o de plano lo
-- olvido). Esos carros olvidados ensucian los promedios y el conteo. Este
-- boton (en la app) los saca de la cola SIN borrar la fila.
--
-- MECANISMO: se reusa cancelado_en, el MISMO campo que ya saca un carro de
-- /cola y del reporte (filtro cancelado_en is null, ya probado). NO se crea
-- una segunda regla de exclusion — ese es el error que este proyecto ya
-- cometio varias veces. Lo unico nuevo es cancelado_motivo, un DESCRIPTOR
-- para separar en el reporte "borrado por el supervisor" de "devolucion".
--
-- Que pasa con un borrado, textual del dueno:
--   - se saca de la lista                     -> cancelado_en = now()
--   - NO se consideran sus tiempos de secado  -> cancelado_en lo excluye del reporte
--   - toda la demas informacion se graba      -> la fila queda intacta
--   - solo la hora de entrada, no la de salida-> entregado_en NUNCA se toca
--
-- CANDADOS (para que el supervisor no borre por accidente uno bueno):
--   1. Solo carros SIN ASIGNAR (estado = 'prelavado'). Uno que ya seca
--      lleva trabajo real y tiempos que si cuentan: jamas se borra por aqui.
--   2. Debe llevar 30 min sin asignar. El front ya lo pinta apagado antes de
--      eso; aqui se revalida para que una llamada suelta no borre un carro
--      recien entrado.
-- Es REVERSIBLE: cancelado_en = null lo regresa (igual que las devoluciones).
-- =====================================================================

-- Descriptor del porque se cancelo. NULL = devolucion o cancelacion vieja
-- (no rompe nada: el reporte solo separa el valor explicito nuevo).
alter table public.carros add column if not exists cancelado_motivo text;

comment on column public.carros.cancelado_motivo is
  'Por que se puso cancelado_en. "borrado_supervisor" = el supervisor lo saco '
  'de la cola por basura. NULL = devolucion o cancelacion manual vieja.';


create or replace function public.borrar_unidad(p_carro bigint)
returns jsonb
language plpgsql
as $function$
declare
  c public.carros%rowtype;
begin
  select * into c from public.carros where id = p_carro for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no existe el carro');
  end if;

  -- Idempotente: si ya salio de la cola, no es un error volver a pedirlo
  -- (dos toques con wifi flojo no deben tronar la pantalla).
  if c.cancelado_en is not null then
    return jsonb_build_object('ok', true, 'carro', p_carro, 'ya_estaba', true);
  end if;

  -- Candado 1: solo unidades sin asignar.
  if c.estado <> 'prelavado' then
    return jsonb_build_object('ok', false,
      'error', 'Solo se puede borrar una unidad sin asignar');
  end if;

  -- Candado 2: 30 min sin asignar. Un carro sin asignar arranca en prelavado
  -- al crearse, asi que el tiempo sin asignar = now() - creado_en.
  if now() - c.creado_en < interval '30 minutes' then
    return jsonb_build_object('ok', false,
      'error', 'La unidad debe llevar 30 min sin asignar');
  end if;

  update public.carros
     set cancelado_en = now(),
         cancelado_motivo = 'borrado_supervisor'
   where id = p_carro;

  return jsonb_build_object('ok', true, 'carro', p_carro);
end;
$function$;

comment on function public.borrar_unidad(bigint) is
  'Saca de la cola un carro SIN ASIGNAR (prelavado, 30+ min). Pone '
  'cancelado_en + cancelado_motivo=borrado_supervisor. No toca entregado_en '
  'ni las etapas. Reversible con cancelado_en=null.';


-- El reporte, IGUAL que la 065 pero con un campo nuevo: 'borrados'. Se
-- reproduce completo porque create or replace necesita el cuerpo entero.
-- Unico cambio: se agrega 'borrados' junto a 'cancelados'. Todo lo demas es
-- byte por byte lo de la 065 (verificado contra la linea base).
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
  'El reporte, para un dia o un rango. reporte_del_dia() delega aqui. Secado '
  'saca cerrados-solos y cortos (<3 min). 083: agrega "borrados" (unidades '
  'que el supervisor saco de la cola por basura), subconjunto de cancelados.';
