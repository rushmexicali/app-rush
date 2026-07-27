-- =====================================================================
-- RUSH — El historial del cliente trae TODO el vehiculo y la linea
-- 26/jul/2026
--
-- Se agregan al historial: la linea donde se seco (del carro, la asigna el
-- supervisor) y toda la info del vehiculo que tenemos de esa visita
-- (placa, color, marca, submarca, tipo). Para las visitas ya ligadas a un
-- carro manda el dato del carro; para las que no, cae a lo que la caja
-- capturo en la visita (coalesce), asi nunca se pierde lo poco que haya.
-- =====================================================================

create or replace function public.historial_de_persona(p_persona bigint)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'fecha',     coalesce(c.creado_en, vi.creado_en),
      'placa',     coalesce(c.placa_display, c.placa, vi.placa),
      'color',     coalesce(c.color, vi.color),
      'marca',     coalesce(c.marca, vi.marca),
      'submarca',  coalesce(c.submarca, vi.submarca),
      'tipo',      coalesce(c.tipo_unidad, vi.tipo_unidad),
      'producto',  c.producto,
      'variante',  c.variante,
      'linea',     c.linea,
      'entrada',   c.creado_en,
      'salida',    c.entregado_en,
      'es_gratis', vi.es_gratis,
      'enlazado',  vi.carro_id is not null,
      'secadores', coalesce((
        select jsonb_agg(distinct coalesce(s.mostrar, a.secador))
          from public.asignaciones a
          left join public.secadores s on s.id = a.empleado_id
         where a.carro_id = c.id
      ), '[]'::jsonb)
    ) order by coalesce(c.creado_en, vi.creado_en) desc
  ), '[]'::jsonb)
  from public.visitas vi
  left join public.carros c on c.id = vi.carro_id
  where vi.persona_id = p_persona and vi.estado = 'activa';
$$;
