-- =====================================================================
-- RUSH Car Wash — el reporte separa por tipo de servicio
--
-- Pedido del dueno el 20/jul/2026: "no vale la pena comparar equipos que
-- secaron completos con los que secaron express, es como comparar peras
-- con manzanas". Y aparte, los encerados manuales y el superbrillo llevan
-- mas tiempo POR NATURALEZA, asi que tampoco se comparan con lo demas.
--
-- Se parte en tres:
--
--   con_aspirado  -> los paquetes completos. LA MAYORIA y lo que de
--                    verdad hay que medir. Va primero.
--   sin_aspirado  -> los express. Menos trabajo, tiempos mas cortos.
--   encerado      -> encerado manual y superbrillo. Tardan mas y no se
--                    comparan contra nada de lo anterior.
--
-- ---------------------------------------------------------------------
-- UNA sola funcion, montada sobre la que ya existia
-- ---------------------------------------------------------------------
-- El CLAUDE.md ya documenta el error de tener DOS reglas para la misma
-- pregunta (fue lo que desfaso express de aspirado, y otra vez hoy con
-- rechazos_dia). Asi que tipo_de_servicio NO reimplementa "que es
-- express": llama a es_lavado_express, que sigue siendo la unica
-- autoridad sobre eso. Solo agrega encima la categoria de encerado.
--
-- ---------------------------------------------------------------------
-- OJO CON EL SUPERBRILLO: no esta verificado
-- ---------------------------------------------------------------------
-- El dueno lo nombro, pero al 20/jul/2026 NO aparece en ninguna venta
-- (solo hay un dia de datos) y el catalogo de Zettle no se puede leer:
-- la API key tiene unicamente el scope READ:PURCHASE, a proposito.
--
-- O sea que NO SE CONOCE su nombre exacto en el catalogo. Se busca por
-- patron '%brillo%' sin acentos ni mayusculas, que atrapa "Superbrillo",
-- "Super Brillo" y "Encerado Superbrillo". Si en Zettle se llama de otra
-- forma, NO va a caer aqui.
--
-- Por eso lo que no se reconoce devuelve NULL y sale en el reporte como
-- "sin clasificar", visible. Nunca se mete a la fuerza en una seccion:
-- un servicio mal clasificado ensucia justo el promedio que este cambio
-- existe para limpiar, y en silencio. Mejor que se vea.
--
-- El encerado MANUAL si esta confirmado: hay una venta real de
-- "Manual"/"Completo Grande" por $500 el 19/jul.
--
-- CUIDADO al tocar esto: "Manual" cae de los dos lados segun su variante.
-- Manual + Express = express (es la trampa que ya documenta el CLAUDE.md
-- en la seccion 12.1). Solo el Manual que NO es express es encerado.
-- =====================================================================

create or replace function public.tipo_de_servicio(p_producto text, p_variante text)
returns text
language sql
immutable
as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then null

    -- Encerado: tarda mas por naturaleza, no se compara con nada.
    -- El Manual express NO entra aqui: ese es un express.
    when (lower(btrim(p_producto)) like 'manual%'
          and public.es_lavado_express(p_producto, p_variante) is not true)
      or translate(lower(btrim(p_producto)),
                   'áéíóúü', 'aeiouu') like '%brillo%'
      then 'encerado'

    when public.es_lavado_express(p_producto, p_variante) is true  then 'sin_aspirado'
    when public.es_lavado_express(p_producto, p_variante) is false then 'con_aspirado'

    -- Producto que no se reconoce. NULL a proposito: sale como "sin
    -- clasificar" en el reporte en vez de contaminar un promedio.
    else null
  end;
$$;

comment on function public.tipo_de_servicio(text, text) is
  'Agrupa para el reporte: con_aspirado (paquetes), sin_aspirado (express), encerado (manual/superbrillo). NULL = no reconocido, se muestra aparte.';

-- ---------------------------------------------------------------------
-- El reporte, con los equipos separados por tipo de servicio
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
           public.tipo_de_servicio(d.producto, d.variante) as tipo,
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
    'fecha', p_fecha,

    'vehiculos_lavados', (select count(*)::int from base where estado = 'entregado'),
    'vehiculos_sin_terminar', (select count(*)::int from base where estado <> 'entregado'),

    -- Reemplaza la señal que se pierde: al cerrar todo al final del día,
    -- vehiculos_sin_terminar será SIEMPRE 0 y dejaría de delatar dónde se
    -- traba la operación. Si aquí salen ocho, el supervisor no está
    -- cerrando carros y hay que ir a ver por qué.
    'cerrados_automaticamente', (select count(*)::int from base
                                  where cerrado_automaticamente is not null),

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
