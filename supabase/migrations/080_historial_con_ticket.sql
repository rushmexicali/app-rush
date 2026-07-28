-- =====================================================================
-- RUSH — El historial del cliente trae el numero de ticket · 27/jul/2026
--
-- visitas.ticket (= purchaseNumber de Zettle, de la migracion de
-- ClientNoteTracker) se expone por visita para mostrarlo en la seccion
-- Clientes del reporte. Aditivo.
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
      'monto',     vi.monto,
      'ticket',    vi.ticket,
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
