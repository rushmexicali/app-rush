-- =====================================================================
-- RUSH Car Wash — el desglose del carro tambien trae la submarca
--
-- La 061 agrego carros.submarca (el modelo que sale de la foto). El
-- desglose de Finalizados (detalle_del_carro) arma su encabezado con
-- describir(c) en la app, que ahora antepone la submarca ("TOYOTA COROLLA
-- BLANCO" en vez de "AUTO BLANCO"). Para que el desglose lo muestre igual
-- que la tarjeta, la funcion tiene que devolver el campo.
--
-- Base: la 054 (con foto_path). Se agrega SOLO 'submarca'. Todo lo demas
-- es identico.
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
    'submarca',     c.submarca,
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
  'Desglose de un carro: segundos por etapa (cerradas), total, etapa abierta + su inicio, la foto (foto_path), submarca (062) y quienes lo secaron.';
