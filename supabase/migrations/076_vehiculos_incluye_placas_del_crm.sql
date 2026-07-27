-- =====================================================================
-- RUSH — El buscador de vehiculos tambien ve las placas del CRM · 27/jul/2026
--
-- Problema (visto con "AKD"): AKD123 esta ligada a Luis en persona_placas
-- pero NUNCA se lavo con foto (no hay carro con esa placa; su unica visita
-- se descarto). buscar_vehiculos solo miraba historial_placas (carros
-- lavados), asi que AKD123 no aparecia como vehiculo — solo salia como chip
-- dentro del cliente Luis. El dueno quiere poder seleccionar la placa SOLA,
-- sin pasar por el cliente, y ver a su dueno de lealtad desde ahi.
--
-- Arreglo:
--   1. buscar_vehiculos une DOS fuentes de placa: carros lavados
--      (historial_placas, con atributos y visitas) + placas del CRM
--      (persona_placas) que no tengan carro lavado. Marca/submarca solo
--      aplican a la primera; la segunda solo se busca por placa.
--   2. duenos_de_placa(placa): las personas ligadas a esa placa en el CRM
--      (N-a-N). El perfil de la placa las muestra como "Cliente en lealtad",
--      clicables — util cuando la placa no tiene ninguna visita lavada
--      (tabla vacia) pero si tiene dueno.
-- =====================================================================

-- --- 1. buscar_vehiculos: carros lavados UNION placas del CRM ---------
create or replace function public.buscar_vehiculos(p_q text)
returns jsonb language sql stable as $$
  with q as (
    select nullif(public.normalizar_placa(p_q), '')  as placa_q,
           nullif(public.normalizar_nombre(p_q), '') as texto_q
  ),
  matches as (
    -- Placas de carros lavados: con marca/color/visitas. Match por placa,
    -- marca o submarca (normalizado).
    select h.placa, h.placa_como_se_lee, h.visitas, h.marca, h.submarca,
           h.tipo_unidad, h.color, h.cliente, h.gastado
    from public.historial_placas h, q
    where (q.placa_q is not null and h.placa like '%' || q.placa_q || '%')
       or (q.texto_q is not null and h.marca is not null
           and public.normalizar_nombre(h.marca) like '%' || q.texto_q || '%')
       or (q.texto_q is not null and h.submarca is not null
           and public.normalizar_nombre(h.submarca) like '%' || q.texto_q || '%')

    union

    -- Placas del CRM que NO tienen carro lavado: solo se buscan por placa.
    -- group by colapsa una placa con varios duenos en un solo renglon.
    select pp.placa_norm as placa,
           coalesce(max(pp.placa_como_se_lee), pp.placa_norm) as placa_como_se_lee,
           0 as visitas, null::text as marca, null::text as submarca,
           null::text as tipo_unidad, null::text as color,
           null::text as cliente, 0::numeric as gastado
    from public.persona_placas pp, q
    where q.placa_q is not null and pp.placa_norm like '%' || q.placa_q || '%'
      and not exists (select 1 from public.historial_placas h2 where h2.placa = pp.placa_norm)
    group by pp.placa_norm
  )
  select coalesce(jsonb_agg(to_jsonb(m) order by m.visitas desc, m.placa), '[]'::jsonb)
  from (select * from matches order by visitas desc, placa limit 50) m;
$$;

-- --- 2. duenos_de_placa: las personas ligadas a una placa en el CRM ---
create or replace function public.duenos_de_placa(p_placa text)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(
    jsonb_build_object('id', pe.id, 'nombre', pe.nombre) order by pe.nombre
  ), '[]'::jsonb)
  from public.persona_placas pp
  join public.personas pe on pe.id = pp.persona_id
  where pp.placa_norm = public.normalizar_placa(p_placa);
$$;
