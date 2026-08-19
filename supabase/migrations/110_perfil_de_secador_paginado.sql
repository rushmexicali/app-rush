-- =====================================================================
-- 110 - El perfil de un trabajador se pagina y se puede filtrar
--
-- Hallazgo #1 de lo que quedaba del reporte del dueno (19/ago).
--
-- Hoy `perfil_de_secador` devuelve el historial COMPLETO de la persona en
-- una sola respuesta. Medido: Pablo Cruz, 346 carros = 128 kB, y crece
-- lineal para siempre (a un ano, ~1.5 MB). El dueno abre este perfil desde
-- el telefono.
--
-- Y falta lo que de verdad querria preguntar: "sus completos de ESTA
-- semana". Sin filtro por fecha ni por tipo de servicio, el unico modo es
-- recorrer con el dedo un historial de meses mezclando express con
-- completos - que es justo la comparacion que el resto del reporte prohibe
-- (peras con manzanas, §12.1).
--
-- Decisiones:
--
--   * Los contadores de arriba (lavados, rechazos) RESPETAN el filtro. Si
--     dijeran el total historico mientras la tabla muestra una semana, la
--     pantalla se contradiria sola - que es el defecto que la 107 acaba de
--     arreglar en el reporte del dia. Sin filtro dan exactamente lo mismo
--     que antes.
--   * Se devuelve `total` para poder decir "50 de 346" y ofrecer ver mas.
--     Un "mostrando 50" a secas no dice si falta algo.
--   * `p_limite = 0` trae todo. Sirve para una consulta suelta sin tener
--     que adivinar un tope, y para que esto NO se convierta en un limite
--     silencioso (§ "no silent caps").
--
-- Cambia la firma, asi que hay que DROPEAR la vieja: un parametro nuevo
-- crea una SOBRECARGA, no un reemplazo, y dos funciones con el mismo
-- nombre vuelven ambigua la llamada. Es la leccion de la 052 y de la 098.
-- =====================================================================

drop function if exists public.perfil_de_secador(text);

create or replace function public.perfil_de_secador(
  p_empleado text,
  p_desde    date default null,
  p_hasta    date default null,
  p_tipo     text default null,   -- con_aspirado | sin_aspirado | encerado
  p_limite   int  default 50,     -- 0 = todo
  p_saltar   int  default 0
) returns jsonb
language sql
stable
as $func$
  with mis_carros as (
    select distinct a.carro_id
      from public.asignaciones a
      join public.carros c on c.id = a.carro_id
     where a.empleado_id = p_empleado
       and not c.es_prueba and c.cancelado_en is null
  ),
  -- El filtro vive en UN solo lugar y de aqui salen las tres cosas: el
  -- conteo, los rechazos y la tabla. Si el conteo filtrara por su cuenta,
  -- serian dos reglas para la misma pregunta.
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
      -- El dia es el LOCAL de Mexicali, como en todo el reporte. Con UTC,
      -- un carro de las 6 de la tarde caeria en el dia siguiente.
      and (p_desde is null
           or (c.creado_en at time zone 'America/Tijuana')::date >= p_desde)
      and (p_hasta is null
           or (c.creado_en at time zone 'America/Tijuana')::date <= p_hasta)
      and (p_tipo is null
           or public.tipo_de_servicio(c.producto, c.variante, c.categoria) = p_tipo)
  ),
  pagina as (
    select * from hist
     order by creado_en desc
     limit  case when coalesce(p_limite, 0) > 0 then p_limite else null end
    offset greatest(coalesce(p_saltar, 0), 0)
  )
  select jsonb_build_object(
    'id',              s.id,
    'nombre',          s.mostrar,
    'nombre_completo', s.nombre_completo,
    'iniciales',       s.iniciales,
    'color',           s.color,
    'rol',             s.rol,
    'estado',          s.estado,
    -- Lo que hay bajo el filtro vigente. Sin filtro es el total de siempre.
    'lavados',         (select count(*) from hist),
    'total',           (select count(*) from hist),
    'mostrados',       (select count(*) from pagina),
    'saltados',        greatest(coalesce(p_saltar, 0), 0),
    'limite',          coalesce(p_limite, 0),
    'filtro', jsonb_build_object('desde', p_desde, 'hasta', p_hasta, 'tipo', p_tipo),
    -- EVENTOS, no filas, y solo de carros que cuentan. Mismo criterio que el
    -- reporte del dueno, para que los dos numeros no se contradigan. Ahora
    -- ademas dentro del mismo filtro que la tabla de abajo.
    'rechazos', coalesce((
      select count(distinct rz.grupo)::int
        from public.rechazos rz
       where rz.empleado_id = p_empleado
         and rz.carro_id in (select id from hist)), 0),
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
        -- Las dos banderas que faltaban (106). La pantalla las usa para NO
        -- pintar un numero que no se midio.
        'cerrado_solo',  h.cerrado_automaticamente is not null,
        'secado_corto',  (h.secado_seg is not null and h.secado_seg < 180),
        'rechazos',      h.rechazos
      ) order by h.creado_en desc)
      from pagina h
    ), '[]'::jsonb)
  )
  from public.secadores s
  where s.id = p_empleado;
$func$;

comment on function public.perfil_de_secador(text, date, date, text, int, int) is
  'Perfil de un secador: contadores e historial de secado. PAGINADO y filtrable por rango de dias (local de Mexicali) y por tipo de servicio (110). Los contadores respetan el filtro para que la pantalla no se contradiga. p_limite = 0 trae todo.';
