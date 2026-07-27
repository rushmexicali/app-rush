-- =====================================================================
-- RUSH — persona_json incluye sus placas · 26/jul/2026
--
-- Al seleccionar un cliente, la cajera quiere ver las placas que ya tiene
-- asignadas (para confirmar que es el correcto y ver sus carros). Se agrega
-- el arreglo `placas` a persona_json, que ya alimenta la busqueda y la
-- pantalla del cliente. Las placas salen limpias (la caja las guarda sin
-- guiones); si algun dia una trajera "como se lee", se prefiere esa.
-- =====================================================================

create or replace function public.persona_json(p_persona bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id',       p.id,
    'nombre',   p.nombre,
    'telefono', p.telefono,
    'notas',    p.notas,
    'lealtad',  public.lealtad_de(p.id),
    'placas',   coalesce((
      select jsonb_agg(coalesce(pp.placa_como_se_lee, pp.placa_norm) order by pp.creado_en)
        from public.persona_placas pp
       where pp.persona_id = p.id
    ), '[]'::jsonb)
  )
  from public.personas p
  where p.id = p_persona;
$$;
