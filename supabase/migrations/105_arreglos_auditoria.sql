-- =====================================================================
-- 105 — Los arreglos de la auditoria del 19/ago/2026
--
-- Cinco cosas, todas comprobadas contra la base antes de escribirlas:
--   1. El contador de "encimados" dejaba de contar los carros CANCELADOS.
--   2. Un `Gratis` con variante `6to Express` no se contaba como express.
--   3. La caja podia registrar un canje a quien no tiene saldo.
--   4. La llave publica `anon` podia ejecutar funciones destructivas.
--   5. El borrado de fotos no tenia tope por corrida.
--
-- El (1) y el (2) cambian numeros ya congelados: el re-congelado va aparte,
-- despues de comprobar el diff campo por campo.
-- =====================================================================

-- --------------------------------------------------------------------
-- 2) Un 6to lavado gratis de un EXPRESS es un express
--
-- Decision del dueno (19/ago/2026). Llevaba 10 casos: un `Gratis` con
-- variante `6to Express` caia en `lleva_aspirado = true`, se contaba como
-- completo y ensuciaba el promedio de los completos con secados de express.
-- Ademas la base le rechazaba la linea 1, que es justo la suya.
--
-- Es la MISMA trampa de la variante que ya documenta el CLAUDE.md con
-- `Manual`+`Express`: quien decide es la variante, no el nombre del producto.
-- --------------------------------------------------------------------
create or replace function public.es_lavado_express(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_producto, '') ilike 'express%'
      or (coalesce(p_producto, '') ilike 'manual%'
          and coalesce(p_variante, '') ilike 'express%')
      or (coalesce(p_producto, '') ilike 'pasajeros%'
          and coalesce(p_variante, '') ilike '%express%')
      -- Un 6to lavado gratis conserva el tipo de lavado que el cliente compra.
      or (coalesce(p_producto, '') ilike 'gratis%'
          and coalesce(p_variante, '') ilike '%express%');
$$;

-- ⚠️ `carros.tiempo_imposible` es una columna GENERADA sobre
-- `tiempo_minimo_seg(tipo_de_servicio(...))`, que cuelga de `lleva_aspirado`,
-- que cuelga de la funcion de arriba. Reemplazar la funcion NO recalcula lo
-- ya guardado: quedarian dos verdades conviviendo. Se fuerza tocando la fila.
-- (No se puede con `set id = id`: `id` es `generated always as identity`.)
update public.carros set producto = producto
 where coalesce(producto, '') ilike 'gratis%'
   and coalesce(variante, '') ilike '%express%';

-- Y `es_express` es una columna NORMAL que el trigger escribe al crear el
-- carro, asi que los 10 historicos siguen en false. Se rellenan para que la
-- clasificacion guardada y la calculada no se contradigan.
update public.carros
   set es_express = public.es_lavado_express(producto, variante)
 where es_express is distinct from public.es_lavado_express(producto, variante);

-- --------------------------------------------------------------------
-- 3) Un canje sin saldo se RECHAZA
--
-- Decision del dueno (19/ago/2026). Antes pasaba sin verificar nada, y la
-- vista `lealtad_por_persona` escondia el descubierto con `greatest(0, ...)`:
-- el cliente se quedaba ademas sin el gratis que SI iba a ganar, y nadie se
-- enteraba nunca. Hoy hay 26 personas con mas canjes que sellos ganados.
--
-- ⚠️ La regla vivia en DOS lugares y habian divergido: `registrar_visita` (la
-- vieja) si validaba el saldo y `registrar_visita_con_carro` (la que usa la
-- caja desde el 15/ago) no. Ahora las dos preguntan lo mismo, y quien decide
-- es `saldo_de_gratis()`, en un solo lugar.
--
-- ⚠️ CONSECUENCIA ACEPTADA: al rechazar, esa visita NO queda registrada, asi
-- que ese lavado no aparecera en el historial del cliente. El momento real de
-- atajarlo es ANTES, en la caja: la ficha del cliente ya dice "Faltan N", y
-- ahora el ticket se pinta en rojo antes de que la cajera pueda tocarlo.
-- --------------------------------------------------------------------
create or replace function public.saldo_de_gratis(p_persona bigint)
returns int
language sql
stable
as $$
  select coalesce((select l.disponibles
                     from public.lealtad_por_persona l
                    where l.persona_id = p_persona), 0);
$$;

comment on function public.saldo_de_gratis(bigint) is
  'Cuantos lavados gratis puede canjear esta persona HOY. Una sola respuesta para las dos rutas de registro.';

-- --------------------------------------------------------------------
-- 1) El contador de "encimados" deja de contar los carros CANCELADOS
-- (el diff contra la version anterior es SOLO el filtro y su comentario)
-- --------------------------------------------------------------------
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

-- Las dos rutas de registro preguntan lo MISMO y responden lo MISMO.
-- Antes la vieja degradaba el canje en silencio (`v_gratis := false`, el
-- cliente pagaba sin enterarse) y la nueva ni preguntaba. Divergian.
create or replace function public.registrar_visita(
  p_persona bigint, p_placa text default null, p_marca text default null,
  p_submarca text default null, p_tipo text default null, p_color text default null,
  p_foto_path text default null, p_es_gratis boolean default false,
  p_caja text default 'principal')
returns jsonb
language plpgsql
as $function$
declare
  v_id     bigint;
  v_gratis boolean := coalesce(p_es_gratis, false);
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
  end if;

  if v_gratis and public.saldo_de_gratis(p_persona) <= 0 then
    return jsonb_build_object('ok', false,
      'error', 'Este cliente todavia no tiene lavado gratis. Cobralo normal.',
      'motivo', 'sin_saldo',
      'lealtad', public.lealtad_de(p_persona));
  end if;

  insert into public.visitas
    (persona_id, placa, marca, submarca, tipo_unidad, color, foto_path, es_gratis, caja)
  values
    (p_persona, nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     nullif(btrim(upper(coalesce(p_color,''))),''),
     nullif(btrim(coalesce(p_foto_path,'')),''),
     v_gratis, coalesce(nullif(btrim(p_caja),''),'principal'))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'visita', v_id,
                            'lealtad', public.lealtad_de(p_persona));
end;
$function$;

create or replace function public.registrar_visita_con_carro(
  p_persona       bigint,
  p_carro         bigint,
  p_usa_gratis    boolean default false,
  p_caja          text    default 'principal',
  p_foto_path     text    default null,
  p_placa         text    default null,
  p_marca         text    default null,
  p_submarca      text    default null,
  p_tipo          text    default null,
  p_hubo_lectura  boolean default true
)
returns jsonb
language plpgsql
as $function$
declare
  c        record;
  v_clase  text;
  v_gratis boolean;
  v_cort   boolean;
  v_id     bigint;
  v_foto   text;
  v_dudosa boolean := false;
  v_pego   boolean := false;
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
  end if;

  select * into c from public.carros where id = p_carro;
  if c.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado ya no existe');
  end if;
  if c.cancelado_en is not null or coalesce(c.es_prueba,false) then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado está cancelado');
  end if;

  if exists (select 1 from public.visitas v2
             where v2.carro_id = p_carro and v2.estado = 'activa') then
    return jsonb_build_object('ok', false, 'error', 'Ese ticket ya se registró con otro cliente');
  end if;

  -- ⚠️ `is not distinct from` y no `=`: para un lavado normal clase_de_gratis
  -- devuelve NULL, y `null = 'canje'` es NULL — no false.
  v_clase := public.clase_de_gratis(c.producto, c.variante);
  v_cort  := (v_clase is not distinct from 'cortesia');
  -- EL TICKET MANDA sobre el switch de la cajera (ver CLAUDE.md §11.70).
  v_gratis := (v_clase is not distinct from 'canje');

  if coalesce(p_usa_gratis,false) and v_clase is distinct from 'canje' then
    return jsonb_build_object('ok', false,
      'error', 'Selecciona un ticket con lavado gratis',
      'motivo', 'sin_gratis');
  end if;

  -- Y la direccion contraria, que faltaba: un ticket de 6to cobrado a quien
  -- NO tiene lavado gratis disponible. Antes pasaba, y `greatest(0, ...)` de
  -- la vista escondia el descubierto: el cliente ademas perdia el gratis que
  -- si se iba a ganar. Decision del dueno (19/ago/2026): se rechaza.
  if v_gratis and public.saldo_de_gratis(p_persona) <= 0 then
    return jsonb_build_object('ok', false,
      'error', 'Este cliente todavía no tiene lavado gratis. Cóbralo normal.',
      'motivo', 'sin_saldo',
      'lealtad', public.lealtad_de(p_persona));
  end if;

  v_foto := nullif(btrim(coalesce(p_foto_path,'')),'');

  insert into public.visitas
    (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, carro_id, enlazada_en,
     placa, marca, submarca, tipo_unidad, foto_path)
  values
    (p_persona, v_gratis, v_cort, 'activa',
     coalesce(nullif(btrim(p_caja),''),'principal'), false, p_carro, now(),
     nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     v_foto)
  returning id into v_id;

  update public.carros
     set cliente = coalesce((select nombre from public.personas where id = p_persona), cliente)
   where id = p_carro;

  -- La foto de la caja pasa a ser la del carro, para que el supervisor la vea
  -- en la cola. Solo si el carro no trae ya una (no se pisa la del supervisor).
  if v_foto is not null then
    update public.carros
       set foto_path       = v_foto,
           foto_url        = null,
           foto_url_expira = null
     where id = p_carro and foto_path is null;
    v_pego := found;
  end if;

  -- Lo que la cámara leyó se guarda con la MISMA función que usa el supervisor
  -- (`guardar_datos_de_foto`), no con una copia: ahí vive el candado de la
  -- placa repetida del día (migración 100) y el ligado placa→cliente.
  --
  -- ⚠️ SOLO si de verdad HUBO lectura (migración 104), y SOLO si la foto de la
  -- caja de veras se pegó a este carro. Antes bastaba con que hubiera foto, y
  -- como esa RPC es autoritativa, la placa leída por la caja pisaba la del
  -- supervisor en un carro que ya tenía su propia foto — y de paso le ligaba
  -- al cliente una placa ajena, que es lealtad, o sea dinero.
  if v_foto is not null and v_pego and coalesce(p_hubo_lectura, true) then
    select coalesce((public.guardar_datos_de_foto(
             p_carro, p_placa, null, p_marca, p_submarca, p_tipo
           ) ->> 'placa_dudosa')::boolean, false) into v_dudosa;
  end if;

  return jsonb_build_object('ok', true, 'visita', v_id, 'clase', v_clase,
                            'es_gratis', v_gratis, 'es_cortesia', v_cort,
                            'placa_dudosa', v_dudosa,
                            'lealtad', public.lealtad_de(p_persona));
end;
$function$;

-- --------------------------------------------------------------------
-- 5) El borrado de fotos, con tope por corrida
--
-- El cron lleva 21 corridas y NO ha borrado ni un archivo: la foto mas vieja
-- tiene 31 dias y el umbral son 90. La primera corrida de verdad cae alrededor
-- del 17/oct/2026 y va a encontrar TODO el atraso junto (~7,400 archivos, unas
-- 15 tandas de 500 en una sola invocacion, contra el limite de tiempo de la
-- funcion). Si se corta a la mitad, `olvidar_fotos_viejas` no alcanza a correr
-- y quedan cientos de carros apuntando a fotos ya borradas: ligas muertas.
--
-- Con ~85 fotos entrando al dia, un tope de 1,000 drena el atraso inicial en
-- poco mas de una semana y despues el regimen es estable.
-- --------------------------------------------------------------------
-- ⚠️ Se DROPEAN las viejas primero. Agregar un parametro con `create or
-- replace` crea una SOBRECARGA, no un reemplazo, y entonces la llamada de
-- `limpiar-fotos` (que manda solo `p_dias`) se vuelve ambigua y truena con
-- 42725. Es la leccion de la 052, y la auditoria acaba de encontrar que
-- `buscar_tickets` ya cayo en ella.
drop function if exists public.fotos_viejas(integer);
drop function if exists public.olvidar_fotos_viejas(integer);

create or replace function public.fotos_viejas(p_dias integer default 90, p_tope integer default 1000)
returns text[]
language sql
security definer
set search_path to 'public', 'storage'
as $function$
  select coalesce(array_agg(nombre), array[]::text[])
    from (
      select o.name as nombre
        from storage.objects o
       where o.bucket_id = 'fotos'
         and o.created_at < now() - make_interval(days => p_dias)
       -- Las mas viejas primero: si el tope corta, lo que queda es lo mas
       -- nuevo, que es lo que todavia puede servir.
       order by o.created_at
       limit greatest(1, coalesce(p_tope, 1000))
    ) t;
$function$;

-- El apuntador se borra por EDAD, no por "cuales se removieron". Con el tope
-- de arriba eso desincronizaria: se limpiarian apuntadores de archivos que
-- todavia no se alcanzaron a borrar. Ahora recibe la lista real.
create or replace function public.olvidar_fotos_viejas(p_dias integer default 90, p_borradas text[] default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  cuantos int;
begin
  update public.carros
     set foto_path = null, foto_url = null, foto_url_expira = null
   where foto_path is not null
     -- `coalesce` con creado_en: hay 2 carros con foto y sin `foto_en`, y con
     -- el `is not null` de antes su liga se quedaba muerta para siempre.
     and coalesce(foto_en, creado_en) < now() - make_interval(days => p_dias)
     -- Si se pasa la lista de lo que de verdad se borro, solo esos.
     and (p_borradas is null or foto_path = any(p_borradas));
  get diagnostics cuantos = row_count;
  return cuantos;
end;
$function$;

-- --------------------------------------------------------------------
-- 4) La llave publica deja de poder borrar y de poder leer el CRM
--
-- RLS esta bien puesto en las 32 tablas, pero siete funciones `SECURITY
-- DEFINER` y las cinco vistas quedaron abiertas a `anon`, y esas funciones se
-- saltan RLS por diseno. Con la llave publica se alcanzaba, en UNA llamada:
--   olvidar_fotos_viejas(0)  -> deja sin foto a TODOS los carros
--   sincronizar_empleados()  -> reescribe el padron
--   historial_placas         -> placas, clientes y dinero de 2,641 carros
--   lealtad_por_persona      -> los saldos de las 4,919 personas
--
-- La llave `anon` no esta publicada en el repo (verificado), asi que el riesgo
-- era real pero no expuesto. Nada de esto afecta a la app: las Edge Functions
-- usan `service_role`, que no pasa por estos permisos.
-- --------------------------------------------------------------------
-- ⚠️ Hay que quitarselo a PUBLIC, no solo a `anon`. Postgres concede EXECUTE
-- a PUBLIC por omision (se ve como `=X/postgres` al principio del ACL), asi
-- que revocarle a `anon` no cambia NADA: el permiso le sigue llegando por el
-- otro lado. Se comprobo midiendo, no leyendo: tras el primer intento las 7
-- funciones seguian alcanzables.
--
-- `service_role` NO se ve afectado: tiene concesion EXPLICITA
-- (`service_role=X/postgres`), que sobrevive al revoke a PUBLIC. Es la llave
-- que usan las Edge Functions, o sea toda la app.
revoke execute on function public.olvidar_fotos_viejas(integer, text[])  from public, anon, authenticated;
revoke execute on function public.fotos_viejas(integer, integer)          from public, anon, authenticated;
revoke execute on function public.sincronizar_empleados(jsonb)            from public, anon, authenticated;
revoke execute on function public.agregar_secador_manual(text)            from public, anon, authenticated;
revoke execute on function public.asignar_colores_libres()                from public, anon, authenticated;

-- A PROPOSITO no se tocan `crear_carro_desde_venta` ni `rls_auto_enable`:
-- devuelven `trigger`/`event_trigger`, asi que PostgREST ni las expone y no
-- hay por donde llamarlas. La primera es ADEMAS el camino por donde entra el
-- dinero; moverle los permisos por un riesgo que no existe es un mal trato.

-- Las vistas corrian como su dueno (`postgres`) y por eso brincaban el RLS de
-- las tablas que consultan. Con `security_invoker` corren como quien pregunta,
-- asi que `anon` vuelve a chocar con el RLS de `carros`, `visitas` y demas.
alter view public.historial_placas     set (security_invoker = on);
alter view public.lealtad_por_persona  set (security_invoker = on);
alter view public.secadores            set (security_invoker = on);
alter view public.carros_sin_secador   set (security_invoker = on);
alter view public.fotos_por_leer       set (security_invoker = on);

-- --------------------------------------------------------------------
-- 6) Se quita la sobrecarga vieja de `buscar_tickets`
--
-- La 098 AGREGO en vez de reemplazar, asi que quedaron dos: la vieja busca
-- solo por numero de ticket, la nueva sobre la columna `busqueda` y pagina.
-- Llamarla con dos argumentos truena con 42725 (comprobado). Hoy no falla
-- porque el Edge Function siempre manda los tres, pero es una mina: cualquier
-- script o llamada futura sin `p_offset` revienta, y ademas la vieja tiene
-- una regla de busqueda DISTINTA que ya nadie mantiene.
--
-- Se puede quitar sin tocar a nadie: la que queda tiene `p_offset default 0`,
-- asi que una llamada de dos argumentos ahora resuelve sola.
-- --------------------------------------------------------------------
drop function if exists public.buscar_tickets(text, integer);
