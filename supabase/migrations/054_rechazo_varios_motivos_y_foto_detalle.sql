-- =====================================================================
-- RUSH Car Wash — rechazar con VARIOS motivos, y la foto en el desglose
--
-- Dos pedidos del dueno (21/jul/2026):
--
--   1. Al rechazar una entrega, poder marcar MAS DE UN motivo y confirmar
--      con un boton "RECHAZAR". Hasta hoy el primer toque a un motivo
--      rechazaba de inmediato con ese unico motivo.
--   2. Que el desglose de un carro (el boton de info y la lista de
--      finalizados) traiga la FOTO del carro para verla en grande.
--
-- =====================================================================


-- ---------------------------------------------------------------------
-- rechazar_entrega ahora recibe un ARREGLO de motivos
-- ---------------------------------------------------------------------
-- Un rechazo sigue siendo UN evento (un grupo), aunque le falten tres
-- cosas al carro. Se guarda una fila por (secador x motivo), todas con el
-- MISMO grupo. Asi las cuentas de evento y de carro no cambian:
--   por evento -> count(distinct grupo)
--   por carro  -> count(distinct grupo)
-- pero el conteo POR PERSONA, que antes era count(*) suponiendo UNA fila
-- por secador, ahora tiene que pasar a count(distinct grupo): si no, un
-- carro rechazado por tres cosas le contaria 3 rechazos a la persona
-- cuando fue UNO. Ese arreglo va en reporte_del_rango, mas abajo.
--
-- Se DROPEA la version vieja (bigint, text) y se crea (bigint, text[]):
-- dejar las dos haria ambigua la llamada por nombre desde PostgREST — el
-- mismo cuidado que la migracion 052 con editar_carro.
-- ---------------------------------------------------------------------
drop function if exists public.rechazar_entrega(bigint, text);

create or replace function public.rechazar_entrega(p_carro bigint, p_motivos text[])
returns jsonb
language plpgsql
as $$
declare
  actual   text;
  limpios  text[];
  cuantos  int;
  personas int;
  v_grupo  uuid := gen_random_uuid();
begin
  select estado into actual from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  if actual <> 'secando' then
    return jsonb_build_object('ok', false, 'error', 'Solo se puede rechazar un carro que esta secando');
  end if;

  -- Se limpian: se quitan vacios y espacios, y se dejan los DISTINTOS. Si
  -- no queda ninguno, es un error: un rechazo sin motivo no sirve para
  -- entrenar a nadie.
  select array_agg(distinct s.m order by s.m) into limpios
    from (
      select nullif(btrim(u), '') as m
        from unnest(coalesce(p_motivos, array[]::text[])) as u
    ) s
   where s.m is not null;

  if limpios is null or array_length(limpios, 1) is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el motivo del rechazo');
  end if;

  -- Una fila por cada persona que lo estaba secando, POR cada motivo.
  -- Todas con el mismo grupo: es un solo rechazo con varias cosas.
  insert into public.rechazos (grupo, carro_id, empleado_id, secador, motivo)
  select v_grupo, p_carro, a.empleado_id, a.secador, m
    from public.asignaciones a
    cross join unnest(limpios) as m
   where a.carro_id = p_carro and a.fin is null;

  get diagnostics cuantos = row_count;

  -- Un carro secando SIEMPRE deberia tener asignacion abierta, pero si no
  -- la tiene, el rechazo se registra igual sin persona (una fila por
  -- motivo). Perder el dato del rechazo seria peor: el supervisor ya hizo
  -- su parte al reportarlo.
  if cuantos = 0 then
    insert into public.rechazos (grupo, carro_id, empleado_id, secador, motivo)
    select v_grupo, p_carro, null, '(sin secador asignado)', m
      from unnest(limpios) as m;
  end if;

  select count(distinct a.empleado_id)::int into personas
    from public.asignaciones a
   where a.carro_id = p_carro and a.fin is null and a.empleado_id is not null;

  return jsonb_build_object(
    'ok', true,
    'secadores', coalesce(personas, 0),
    'motivos', limpios
  );
end;
$$;

comment on function public.rechazar_entrega(bigint, text[]) is
  'Registra un rechazo de entrega con uno o varios motivos (mismo grupo). NO cambia el estado del carro: sigue secando con los mismos secadores.';


-- ---------------------------------------------------------------------
-- reporte_del_rango: el conteo por persona pasa a count(distinct grupo)
-- ---------------------------------------------------------------------
-- Identico a la migracion 049 EXCEPTO por dos cambios en el bloque de
-- rechazos, obligados por los motivos multiples:
--
--   * rechazos_persona ahora arrastra el 'grupo'.
--   * por_secador cuenta count(distinct grupo), no count(*): un rechazo
--     con tres motivos son tres filas por persona pero UN solo rechazo.
--
-- El desglose de motivos NO cambia: con una fila por (grupo x motivo) por
-- persona, count(*) por motivo sigue diciendo en cuantos eventos aparecio
-- esa falla para esa persona, que es justo lo util para saber "en que"
-- entrenar.
-- ---------------------------------------------------------------------
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
  'El reporte de un intervalo de dias (hora de Mexicali), ambos extremos incluidos. Rechazos por persona contados por evento (grupo), no por fila.';


-- ---------------------------------------------------------------------
-- detalle_del_carro: ahora trae la foto (foto_path) para verla en grande
-- ---------------------------------------------------------------------
-- Base: la version de la migracion 053 (con abierta_etapa/abierta_inicio
-- para el cronometro en vivo). Se agrega SOLO 'foto_path'. La Edge
-- Function lo firma al vuelo antes de mandarlo al telefono: el bucket es
-- privado (en las fotos se ven placas), asi que la ruta cruda no sirve
-- sola.
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

    -- La ruta de la foto en el bucket. La firma la Edge Function.
    'foto_path',    c.foto_path,

    -- Segundos por etapa, ya sumados (solo las CERRADAS: la abierta tiene
    -- 'segundos' nulo y no suma).
    'prelavado_seg', (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'prelavado'),
    'tunel_seg',     (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'tunel'),
    'secando_seg',   (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'secando'),

    'total_seg', case when c.entregado_en is not null
                      then extract(epoch from (c.entregado_en - c.creado_en))::int end,

    -- La etapa ABIERTA y desde cuando: con esto la app cuenta en vivo lo
    -- que lleva corriendo. Nula si ya no hay ninguna abierta (ya se entrego).
    'abierta_etapa',  (select e.etapa  from public.etapas e
                        where e.carro_id = c.id and e.fin is null
                        order by e.inicio desc limit 1),
    'abierta_inicio', (select e.inicio from public.etapas e
                        where e.carro_id = c.id and e.fin is null
                        order by e.inicio desc limit 1),

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
  'Desglose de un carro: segundos por etapa (cerradas), total, etapa abierta + su inicio (para contar en vivo), la foto (foto_path, la firma la Edge Function), y quienes lo secaron.';
