-- =====================================================================
-- RUSH Car Wash — el detalle dice cual etapa esta ABIERTA y desde cuando
--
-- Punto 5 del dueno (20/jul/2026): al tocar el boton de info de un carro
-- que TODAVIA se esta trabajando, quiere ver el desglose (prelavado,
-- tunel) y el cronometro de secado CORRIENDO, mas los secadores.
--
-- detalle_del_carro ya da prelavado_seg y tunel_seg (etapas cerradas),
-- pero secando_seg y total_seg salen NULOS mientras el carro no se
-- entrega: la etapa de secado esta abierta y la columna generada
-- 'segundos' es nula sin 'fin'. Para el contador en vivo, la app necesita
-- desde CUANDO corre la etapa abierta y cual es.
--
-- Se agregan dos campos y no se toca nada mas de la funcion. El resto es
-- identico a la 049.
-- =====================================================================

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
    -- que lleva corriendo (secado en un carro que todavia se trabaja, o
    -- prelavado en uno que aun no se asigna). Nula si ya no hay ninguna
    -- abierta (el carro ya se entrego).
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
  'Desglose de un carro: segundos por etapa (cerradas), total, etapa abierta + su inicio (para contar en vivo), y quienes lo secaron.';
