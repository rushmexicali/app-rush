-- =====================================================================
-- RUSH Car Wash — cerrar solos los carros que quedaron abiertos
--
-- El autolavado cierra a las 8 PM. Lo que quede sin entregar se cierra
-- solo, para que la cola amanezca limpia y el supervisor no llegue a
-- carros de ayer.
--
-- ---------------------------------------------------------------------
-- POR QUE A LAS 8:30 Y NO A LAS 8:00
-- ---------------------------------------------------------------------
-- Cierran a las 8, pero a las 8:00 en punto todavia hay carros
-- LEGITIMAMENTE secandose — el 19/jul la ultima entrega real fue a las
-- 20:14. Cerrarlos a las 8:00 les cortaria el cronometro a mitad y
-- fabricaria un tiempo de secado falso para un carro que si se estaba
-- trabajando bien.
--
-- A las 8:30 se aprovecha el corte del reporte que ya existe: media hora
-- de gracia despues de cerrar, y con los datos del 19/jul no habria
-- alcanzado a ningun carro real (todo estaba entregado a las 20:14).
--
-- Va DENTRO de congelar_reporte y antes de congelar, no en un cron
-- aparte. Si fueran dos crones y el de cerrar se retrasara, el reporte se
-- congelaria con carros sin terminar y el numero quedaria mal para
-- siempre. Asi el orden es correcto por construccion, no por suerte.
--
-- ---------------------------------------------------------------------
-- LO IMPORTANTE: LOS TIEMPOS DE UN CIERRE AUTOMATICO SON FICCION
-- ---------------------------------------------------------------------
-- Un carro que nadie cerro no tiene hora real de entrega. Si se le pone
-- las 20:30 y ese tiempo entra a los promedios, un solo carro olvidado
-- desde las 3 PM mete 5 horas de "secado" y destruye el promedio del
-- equipo que lo seco. Ese equipo se veria pesimo por un descuido del
-- supervisor, no por su trabajo.
--
-- Es exactamente el mismo problema que la migracion 008 (es_prueba):
-- mediciones que PARECEN datos y no lo son.
--
-- Por eso:
--   - se marcan con cerrado_automaticamente
--   - sus tiempos NO entran en los promedios (ni secado ni espera)
--   - SI cuentan como vehiculo lavado: la venta existio y el carro vino
--   - el reporte dice CUANTOS se cerraron solos
--
-- Ese ultimo punto no es adorno. Hoy "vehiculos_sin_terminar" delata
-- donde se traba la operacion; al cerrar todo automaticamente ese numero
-- seria SIEMPRE cero y la señal se perderia en silencio. El conteo de
-- cierres automaticos es lo que la reemplaza: si un dia salen ocho, el
-- supervisor no esta cerrando carros y hay que ir a ver por que.
-- =====================================================================

alter table public.carros
  add column if not exists cerrado_automaticamente timestamptz;

comment on column public.carros.cerrado_automaticamente is
  'Se entrego solo al cierre del dia, no lo cerro una persona. Sus tiempos son ficcion: no entran en promedios.';

-- ---------------------------------------------------------------------
-- Cerrar lo que quedo abierto
--
-- No usa avanzar_etapa a proposito: esa funcion RECHAZA los carros en
-- prelavado ("primero asignale linea y secador"), y justamente esos son
-- los que hay que poder cerrar — un carro que se pago y nunca se asigno
-- es el que se queda atorado para siempre.
-- ---------------------------------------------------------------------
create or replace function public.cerrar_pendientes(p_fecha date default null)
returns jsonb
language plpgsql
as $$
declare
  dia      date;
  arranca  timestamptz;
  termina  timestamptz;
  cerrados int;
  detalle  jsonb;
begin
  dia := coalesce(p_fecha, (now() at time zone 'America/Tijuana')::date);
  arranca := (dia::text || ' 00:00:00')::timestamp at time zone 'America/Tijuana';
  termina := arranca + interval '1 day';

  -- Que quedaba abierto y en que etapa. Se guarda ANTES de cerrarlos,
  -- porque despues todos diran 'entregado'.
  select coalesce(jsonb_object_agg(estado, cuantos), '{}'::jsonb)
    into detalle
    from (
      select estado, count(*)::int as cuantos
        from public.carros
       where not es_prueba
         and cancelado_en is null
         and estado <> 'entregado'
         and creado_en >= arranca and creado_en < termina
       group by estado
    ) x;

  -- Cerrar las etapas abiertas. segundos es columna generada, asi que se
  -- calcula solo al poner fin.
  update public.etapas e
     set fin = now()
   where e.fin is null
     and e.carro_id in (
       select c.id from public.carros c
        where not c.es_prueba
          and c.cancelado_en is null
          and c.estado <> 'entregado'
          and c.creado_en >= arranca and c.creado_en < termina
     );

  update public.carros
     set estado = 'entregado',
         entregado_en = now(),
         cerrado_automaticamente = now()
   where not es_prueba
     and cancelado_en is null
     and estado <> 'entregado'
     and creado_en >= arranca and creado_en < termina;

  get diagnostics cerrados = row_count;

  -- Las asignaciones tambien se cierran, igual que en una entrega normal
  -- (migracion 030). Si no, quedarian abiertas para siempre.
  update public.asignaciones a
     set fin = now()
   where a.fin is null
     and a.carro_id in (
       select c.id from public.carros c
        where c.cerrado_automaticamente is not null
          and c.creado_en >= arranca and c.creado_en < termina
     );

  return jsonb_build_object('ok', true, 'fecha', dia, 'cerrados', cerrados, 'estaban', detalle);
end;
$$;

comment on function public.cerrar_pendientes(date) is
  'Entrega sola lo que quedo abierto al cierre. Los marca: sus tiempos no son medibles.';

-- ---------------------------------------------------------------------
-- El corte: primero cerrar, luego congelar. En ese orden.
-- ---------------------------------------------------------------------
create or replace function public.congelar_reporte()
returns text
language plpgsql
as $$
declare
  local_ahora timestamp;
  dia         date;
  cerrados    jsonb;
begin
  local_ahora := (now() at time zone 'America/Tijuana');

  if extract(hour from local_ahora)::int <> 20 then
    return 'no son las 8:30 PM en Mexicali (son las ' ||
           to_char(local_ahora, 'HH24:MI') || '), no se hizo nada';
  end if;

  dia := local_ahora::date;

  -- ANTES de congelar: si se hiciera despues, el reporte guardaria
  -- carros sin terminar que un minuto mas tarde ya no lo estan.
  cerrados := public.cerrar_pendientes(dia);

  insert into public.reportes_diarios (fecha, datos, congelado_en)
  values (dia, public.reporte_del_dia(dia), now())
  on conflict (fecha) do update
    set datos = excluded.datos,
        congelado_en = excluded.congelado_en;

  return 'congelado el reporte del ' || dia ||
         ' (cerrados solos: ' || coalesce(cerrados ->> 'cerrados', '0') || ')';
end;
$$;

comment on function public.congelar_reporte() is
  'Cierra los pendientes y congela el reporte. Solo actua si en Mexicali son las 20:xx.';

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
           d.creado_en, d.entregado_en, d.cerrado_automaticamente,
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
           -- Los cerrados solos NO entran: su hora de fin es fabricada.
           -- Un carro olvidado desde las 3 PM metería 5 horas y hundiría
           -- el promedio de un equipo que no hizo nada mal.
           avg(secado_seg) filter (
             where secado_seg is not null and cerrado_automaticamente is null
           )::int as secado_promedio_seg,
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
