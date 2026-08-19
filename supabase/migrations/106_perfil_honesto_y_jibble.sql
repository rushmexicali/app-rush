-- =====================================================================
-- 106 — El perfil del trabajador deja de mentir, y Jibble deja de poder
--       vaciar la plantilla
--
-- Auditoria del 19/ago, hallazgos C5, K5 y B4.
-- =====================================================================

-- --------------------------------------------------------------------
-- 1) Los minutos fabricados se marcan como lo que son
--
-- Todo el reporte excluye de sus promedios los carros que cerro el cron a las
-- 20:30 (su hora de entrega es FICCION) y los secados de menos de 3 minutos
-- (olvidos registrados tarde). El perfil del trabajador no aplicaba ninguna de
-- las dos y los imprimia crudos, sin marca: 298 minutos a nombre de Saul
-- Ramirez y 180 a nombre de Jaime Gallegos, de carros que nadie entrego. Y del
-- otro lado, 99 carros historicos de menos de 3 min salen como "0" o "1
-- minuto", como si alguien hubiera secado un carro en un minuto.
--
-- Es la pantalla donde se evalua a UNA PERSONA CON NOMBRE, y era la unica
-- vista del proyecto que rompia las dos reglas que el resto respeta.
--
-- No se esconden ni se borran: se devuelven con su bandera para que la
-- pantalla los presente como lo que son. El numero crudo sigue ahi por si
-- alguien quiere verlo.
--
-- 2) Y de paso, los rechazos se cuentan como EVENTOS
--
-- `count(*)` sobre `rechazos` cuenta una fila por (persona x motivo): un
-- rechazo con dos motivos le contaba DOS a la misma persona. El reporte del
-- dueno ya usa `count(distinct grupo)` con el comentario que explica por que
-- (es la trampa del join que multiplica, migracion 036); el arreglo se aplico
-- ahi y no aqui. Ademas no se unia a `carros`, asi que contaba rechazos de
-- carros de prueba y cancelados — que es justo lo que la 065 arreglo en el
-- reporte, con la razon escrita: "un carro de prueba no contaba como lavado
-- pero sus rechazos si se le anotaban a una persona real".
-- --------------------------------------------------------------------
create or replace function public.perfil_de_secador(p_empleado text)
returns jsonb
language sql
stable
as $function$
  with mis_carros as (
    select distinct a.carro_id
      from public.asignaciones a
      join public.carros c on c.id = a.carro_id
     where a.empleado_id = p_empleado
       and not c.es_prueba and c.cancelado_en is null
  ),
  hist as (
    select
      c.id, c.creado_en, c.entregado_en, c.cerrado_automaticamente,
      coalesce(c.placa_display, c.placa) as placa,
      c.color, c.marca, c.submarca, c.tipo_unidad,
      c.producto, c.variante, c.linea,
      (select min(e.inicio)        from public.etapas e where e.carro_id = c.id and e.etapa = 'secando') as secado_inicio,
      (select max(e.fin)           from public.etapas e where e.carro_id = c.id and e.etapa = 'secando') as secado_fin,
      (select sum(e.segundos)::int from public.etapas e where e.carro_id = c.id and e.etapa = 'secando') as secado_seg,
      coalesce((
        select jsonb_agg(rz.motivo order by rz.creado_en)
          from public.rechazos rz
         where rz.carro_id = c.id and rz.empleado_id = p_empleado
      ), '[]'::jsonb) as rechazos
    from public.carros c
    where c.id in (select carro_id from mis_carros)
  )
  select jsonb_build_object(
    'id',              s.id,
    'nombre',          s.mostrar,
    'nombre_completo', s.nombre_completo,
    'iniciales',       s.iniciales,
    'color',           s.color,
    'rol',             s.rol,
    'estado',          s.estado,
    'lavados',         (select count(*) from hist),
    -- EVENTOS, no filas, y solo de carros que cuentan. Mismo criterio que el
    -- reporte del dueno, para que los dos numeros no se contradigan.
    'rechazos', coalesce((
      select count(distinct rz.grupo)::int
        from public.rechazos rz
        join public.carros c2 on c2.id = rz.carro_id
       where rz.empleado_id = p_empleado
         and not c2.es_prueba and c2.cancelado_en is null), 0),
    'historial', coalesce((
      select jsonb_agg(jsonb_build_object(
        'carro_id',      h.id,
        'fecha',         h.creado_en,
        'placa',         h.placa,
        'color',         h.color,
        'marca',         h.marca,
        'submarca',      h.submarca,
        'tipo',          h.tipo_unidad,
        'producto',      h.producto,
        'variante',      h.variante,
        'linea',         h.linea,
        'secado_inicio', h.secado_inicio,
        'secado_fin',    h.secado_fin,
        'secado_seg',    h.secado_seg,
        'entregado',     h.entregado_en is not null,
        -- Las dos banderas que faltaban. La pantalla las usa para NO pintar
        -- un numero que no se midio.
        'cerrado_solo',  h.cerrado_automaticamente is not null,
        'secado_corto',  (h.secado_seg is not null and h.secado_seg < 180),
        'rechazos',      h.rechazos
      ) order by h.creado_en desc)
      from hist h
    ), '[]'::jsonb)
  )
  from public.secadores s
  where s.id = p_empleado;
$function$;

create or replace function public.trabajadores()
returns jsonb
language sql
stable
as $function$
  with lav as (
    select a.empleado_id, count(distinct a.carro_id) as lavados
      from public.asignaciones a
      join public.carros c on c.id = a.carro_id
     where a.empleado_id is not null
       and not c.es_prueba and c.cancelado_en is null
     group by a.empleado_id
  ),
  rech as (
    -- count(distinct grupo) y join a carros: ver el encabezado de esta
    -- migracion. Antes contaba filas y contaba carros de prueba.
    select rz.empleado_id, count(distinct rz.grupo) as rechazos
      from public.rechazos rz
      join public.carros c on c.id = rz.carro_id
     where rz.empleado_id is not null
       and not c.es_prueba and c.cancelado_en is null
     group by rz.empleado_id
  )
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'id',              s.id,
      'nombre',          s.mostrar,
      'nombre_completo', s.nombre_completo,
      'iniciales',       s.iniciales,
      'color',           s.color,
      'rol',             s.rol,
      'estado',          s.estado,
      'lavados',         coalesce(l.lavados, 0),
      'rechazos',        coalesce(r.rechazos, 0)
    )
    order by s.orden, coalesce(l.lavados, 0) desc, s.mostrar
  ), '[]'::jsonb)
  from public.secadores s
  left join lav  l on l.empleado_id = s.id
  left join rech r on r.empleado_id = s.id;
$function$;


-- --------------------------------------------------------------------
-- 3) Jibble no puede vaciar la plantilla
--
-- `sincronizar_empleados` marca 'fuera' a todo el que no venga en la lista.
-- Con una lista VACIA eso significa TODOS fuera, y la grilla del supervisor se
-- queda sin nadie a quien asignar con el taller lleno de gente. El Edge
-- Function solo se protege del fallo duro (`!rGente.ok`); un 200 con
-- `{"value":[]}` — por ejemplo si se reorganizan los grupos de Jibble, que
-- estan escritos a mano en el codigo — pasa de largo.
--
-- ⚠️ Y hay un segundo defecto, mas silencioso y en la direccion contraria:
-- `id <> all(vistos)` devuelve NULL —no true— si el arreglo trae UN SOLO
-- nulo, asi que NADIE se marcaria fuera y la grilla mostraria gente que ya se
-- fue del taller. Comprobado en la base: `'a' <> all(array['b', null])` da
-- NULL. Los nulos se quitan y se usa `not (id = any(...))`.
--
-- La guarda va aqui ADEMAS de en el Edge Function: es la ultima linea, y la
-- funcion tambien se puede llamar desde otro lado.
--
-- Lo demas del cuerpo queda IGUAL que antes (los colores los sigue repartiendo
-- `asignar_colores_libres`, la caducidad de los manuales sigue en su lugar).
-- --------------------------------------------------------------------
create or replace function public.sincronizar_empleados(p_gente jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  vistos    text[];
  buenos    jsonb;
  cuantos   int;
  caducados int;
begin
  if p_gente is null or jsonb_typeof(p_gente) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'se esperaba una lista');
  end if;

  -- ⚠️ Se filtra UNA sola vez, arriba, y esa lista limpia alimenta TANTO el
  -- insert como la barrida. El primer intento solo limpiaba `vistos` y dejaba
  -- el insert tal cual: un miembro sin id reventaba la funcion entera por el
  -- not-null de `empleados.id`, o sea que una respuesta rara de Jibble tumbaba
  -- la sincronizacion completa en vez de saltarse a esa persona. Lo cacho la
  -- prueba, no la lectura.
  select coalesce(jsonb_agg(g) filter (where nullif(btrim(g ->> 'id'), '') is not null),
                  '[]'::jsonb)
    into buenos
    from jsonb_array_elements(p_gente) g;

  select coalesce(array_agg(g ->> 'id'), array[]::text[])
    into vistos
    from jsonb_array_elements(buenos) g;

  -- Lista vacia (o toda sin id) = no se toca a NADIE. Vale mas una grilla con
  -- datos de hace un minuto que una grilla vacia con el taller lleno.
  if coalesce(array_length(vistos, 1), 0) = 0 then
    return jsonb_build_object('ok', false,
                              'error', 'lista vacia; no se toco a nadie',
                              'recibidos', jsonb_array_length(p_gente));
  end if;

  insert into public.empleados
    (id, nombre, nombre_corto, estado, desde, rol, actualizado_en)
  select
    g ->> 'id',
    g ->> 'nombre',
    nombre_corto_de(g ->> 'nombre'),
    coalesce(g ->> 'estado', 'fuera'),
    (g ->> 'desde')::timestamptz,
    coalesce(nullif(g ->> 'rol', ''), 'secador'),
    now()
  from jsonb_array_elements(buenos) g
  on conflict (id) do update set
    nombre         = excluded.nombre,
    nombre_corto   = excluded.nombre_corto,
    estado         = excluded.estado,
    -- El rol se refresca desde Jibble: si al tunelero lo pasan al grupo
    -- de secadores, la app se entera sola.
    rol            = excluded.rol,
    desde          = case when public.empleados.estado is distinct from excluded.estado
                          then excluded.desde else public.empleados.desde end,
    actualizado_en = now();
    -- OJO: el color NO se toca aqui. Si se tocara, cada minuto le
    -- cambiaria el color a la gente y el reconocimiento visual se
    -- perderia. Lo reparte asignar_colores_libres(), abajo, y solo a
    -- quien llegue sin color.

  -- Quien ya no viene de Jibble se marca fuera. Los manuales siguen
  -- exentos de esta barrida: Jibble no sabe que existen.
  update public.empleados
     set estado = 'fuera', actualizado_en = now()
   where not manual
     and not (id = any(vistos))
     and estado <> 'fuera';

  -- Caducidad de los manuales de un turno. Se compara por DIA de
  -- Mexicali, no por 24 horas: alguien agregado a las 11 PM tiene que
  -- durar ese dia, no hasta las 11 PM del siguiente.
  update public.empleados
     set estado = 'fuera', actualizado_en = now()
   where manual
     and not permanente
     and estado <> 'fuera'
     and (desde at time zone 'America/Tijuana')::date
         < (now() at time zone 'America/Tijuana')::date;

  get diagnostics caducados = row_count;

  -- El unico lugar donde se reparte color.
  perform public.asignar_colores_libres();

  select count(*) into cuantos from public.empleados where estado in ('activo','descanso');

  return jsonb_build_object(
    'ok', true,
    'recibidos', jsonb_array_length(p_gente),
    'disponibles', cuantos,
    'caducados', caducados
  );
end;
$function$;

revoke execute on function public.sincronizar_empleados(jsonb) from public, anon, authenticated;
