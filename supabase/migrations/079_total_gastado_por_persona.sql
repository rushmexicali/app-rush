-- =====================================================================
-- RUSH — "Total gastado" por persona en el reporte · 27/jul/2026
--
-- Con la migracion de ClientNoteTracker cada visita trae su monto (de Zettle).
-- Se expone la suma por persona (persona_json.gastado) y el monto por visita
-- (historial_de_persona[].monto) para mostrarlo en la seccion Clientes del
-- reporte del dueno. Aditivo: caja.html ignora los campos nuevos.
-- =====================================================================

-- persona_json + gastado (suma de visitas activas de esa persona)
create or replace function public.persona_json(p_persona bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id',       p.id,
    'nombre',   p.nombre,
    'telefono', p.telefono,
    'notas',    p.notas,
    'lealtad',  public.lealtad_de(p.id),
    'gastado',  coalesce((
      select sum(v.monto) from public.visitas v
       where v.persona_id = p.id and v.estado = 'activa'
    ), 0),
    'placas',   coalesce((
      select jsonb_agg(coalesce(pp.placa_como_se_lee, pp.placa_norm) order by pp.creado_en)
        from public.persona_placas pp
       where pp.persona_id = p.id
    ), '[]'::jsonb)
  )
  from public.personas p
  where p.id = p_persona;
$$;

-- historial_de_persona + monto por visita
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
