-- =====================================================================
-- RUSH — El buscador de clientes entiende nombre O placa · 26/jul/2026
--
-- El dueno: un solo buscador. Si escribo "12345" y esa placa la tienen dos
-- personas, salen las dos; si escribo un nombre, sale por nombre. Se agrega
-- el match por placa (contra persona_placas, normalizada) al buscar_personas
-- que ya alimenta el buscador en vivo. El endpoint /personas?q= no cambia.
-- =====================================================================

create or replace function public.buscar_personas(p_q text)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(j order by nombre), '[]'::jsonb)
  from (
    select public.persona_json(p.id) as j, p.nombre
    from public.personas p
    where
      -- por nombre
      (public.normalizar_nombre(p_q) is not null
        and p.nombre_norm like '%' || public.normalizar_nombre(p_q) || '%')
      -- o por placa (una placa puede ligar a varias personas: salen todas)
      or (public.normalizar_placa(p_q) is not null
        and exists (
          select 1 from public.persona_placas pp
          where pp.persona_id = p.id
            and pp.placa_norm like '%' || public.normalizar_placa(p_q) || '%'))
    order by p.nombre
    limit 25
  ) s;
$$;
