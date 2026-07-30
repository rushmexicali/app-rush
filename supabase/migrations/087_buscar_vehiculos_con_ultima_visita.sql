-- =====================================================================
-- 087 — buscar_vehiculos devuelve ultima_visita (arregla "Invalid Date")
--
-- La tabla "Historial por placa" del reporte pinta la columna "Última vez"
-- con new Date(p.ultima_visita). Con el buscador vacío la fuente es la vista
-- historial_placas (sí trae ultima_visita) y sale bien; pero al ESCRIBIR se
-- usa buscar_vehiculos, que NO devolvía ultima_visita -> "Invalid Date" en
-- cada fila.
--
-- Igual que la 076 pero agregando ultima_visita: real desde historial_placas,
-- y NULL para las placas del CRM sin lavado registrado (el front ya muestra
-- "—" cuando es nula). Sin otros cambios; el resto de columnas queda igual.
-- =====================================================================

create or replace function public.buscar_vehiculos(p_q text)
returns jsonb
language sql
stable
as $function$
  with q as (
    select nullif(public.normalizar_placa(p_q), '')  as placa_q,
           nullif(public.normalizar_nombre(p_q), '') as texto_q
  ),
  matches as (
    -- Placas de carros lavados: con marca/color/visitas. Match por placa,
    -- marca o submarca (normalizado).
    select h.placa, h.placa_como_se_lee, h.visitas, h.marca, h.submarca,
           h.tipo_unidad, h.color, h.cliente, h.gastado, h.ultima_visita
    from public.historial_placas h, q
    where (q.placa_q is not null and h.placa like '%' || q.placa_q || '%')
       or (q.texto_q is not null and h.marca is not null
           and public.normalizar_nombre(h.marca) like '%' || q.texto_q || '%')
       or (q.texto_q is not null and h.submarca is not null
           and public.normalizar_nombre(h.submarca) like '%' || q.texto_q || '%')

    union

    -- Placas del CRM que NO tienen carro lavado: solo se buscan por placa.
    -- group by colapsa una placa con varios duenos en un solo renglon.
    -- No tienen visita lavada, asi que ultima_visita es NULL (el front pinta "—").
    select pp.placa_norm as placa,
           coalesce(max(pp.placa_como_se_lee), pp.placa_norm) as placa_como_se_lee,
           0 as visitas, null::text as marca, null::text as submarca,
           null::text as tipo_unidad, null::text as color,
           null::text as cliente, 0::numeric as gastado,
           null::timestamptz as ultima_visita
    from public.persona_placas pp, q
    where q.placa_q is not null and pp.placa_norm like '%' || q.placa_q || '%'
      and not exists (select 1 from public.historial_placas h2 where h2.placa = pp.placa_norm)
    group by pp.placa_norm
  )
  select coalesce(jsonb_agg(to_jsonb(m) order by m.visitas desc, m.placa), '[]'::jsonb)
  from (select * from matches order by visitas desc, placa limit 50) m;
$function$;
