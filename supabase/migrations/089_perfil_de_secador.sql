-- =====================================================================
-- RUSH — Perfiles de trabajador (secador) · 29/jul/2026
--
-- El punto #1 del proyecto es medir la eficiencia por persona. El reporte
-- ya la agrega por EQUIPO y por dia; faltaba poder abrir a UNA persona y
-- ver TODO su historial de secado, aunque hoy este descansando y no
-- aparezca en la grilla de asignar.
--
-- Dos funciones nuevas, ambas de solo lectura:
--
--   trabajadores()            -> la lista de todos los empleados (la vista
--                                'secadores' ya los trae a todos, sin filtro
--                                de estado), con su conteo de lavados y de
--                                rechazos, para pintar la lista clicable.
--   perfil_de_secador(id)     -> el historial completo de esa persona: cada
--                                carro que seco, con placa, inicio/fin de
--                                secado, minutos, y los motivos de rechazo
--                                que le tocaron en ese carro.
--
-- La persona se identifica por asignaciones.empleado_id (la MISMA llave que
-- ya usa el reporte por equipo y los rechazos): asi cuenta por persona
-- aunque le cambien el nombre, y no se inventa una segunda regla.
--
-- Se excluyen es_prueba y cancelado_en (borrados / devoluciones-en-cola),
-- el mismo criterio de historial_placas y del reporte. Una devolucion
-- DESPUES de entregar no cancela el carro, asi que sigue contando (el
-- capital humano si se uso) — es coherente con la decision del dueno.
-- =====================================================================

-- ---------------------------------------------------------------------
-- La lista de trabajadores
--
-- Sale de la vista 'secadores', que NO filtra por estado: incluye a quien
-- hoy esta fuera o en descanso. Justo lo que se pidio — poder entrar al
-- perfil de alguien que no aparece en la grilla porque descansa.
--
-- Orden: primero los secadores (orden=0), y dentro de cada grupo los que
-- mas han secado, para que los que de verdad trabajan salgan arriba.
-- ---------------------------------------------------------------------
create or replace function public.trabajadores()
returns jsonb
language sql
stable
as $$
  with lav as (
    select a.empleado_id, count(distinct a.carro_id) as lavados
      from public.asignaciones a
      join public.carros c on c.id = a.carro_id
     where a.empleado_id is not null
       and not c.es_prueba and c.cancelado_en is null
     group by a.empleado_id
  ),
  rech as (
    select empleado_id, count(*) as rechazos
      from public.rechazos
     where empleado_id is not null
     group by empleado_id
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
$$;

comment on function public.trabajadores() is
  'Lista de todos los empleados (incluye descanso/fuera) con su conteo de lavados y rechazos, para la seccion Trabajadores del reporte.';

-- ---------------------------------------------------------------------
-- El perfil de una persona
--
-- Cada carro que seco, del mas reciente al mas viejo. El inicio/fin de
-- secado sale de la etapa 'secando' del carro (un carro puede tener varias
-- filas de esa etapa si se uso Corregir: se toma min(inicio), max(fin) y
-- sum(segundos), igual que detalle_del_carro). Los minutos los saca el
-- front de secado_seg. secado_seg es NULL mientras la etapa siga abierta
-- (el carro no se ha entregado): el front lo pinta "en curso".
--
-- Los rechazos por carro son SOLO los de esta persona en ese carro (una
-- fila por secador; ver migracion 026), con su motivo.
-- ---------------------------------------------------------------------
create or replace function public.perfil_de_secador(p_empleado text)
returns jsonb
language sql
stable
as $$
  with mis_carros as (
    select distinct a.carro_id
      from public.asignaciones a
      join public.carros c on c.id = a.carro_id
     where a.empleado_id = p_empleado
       and not c.es_prueba and c.cancelado_en is null
  ),
  hist as (
    select
      c.id, c.creado_en, c.entregado_en,
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
    'rechazos',        coalesce((select count(*) from public.rechazos where empleado_id = p_empleado), 0),
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
        'rechazos',      h.rechazos
      ) order by h.creado_en desc)
      from hist h
    ), '[]'::jsonb)
  )
  from public.secadores s
  where s.id = p_empleado;
$$;

comment on function public.perfil_de_secador(text) is
  'Historial completo de secado de una persona: cada carro con placa, inicio/fin de secado, segundos y sus motivos de rechazo.';
