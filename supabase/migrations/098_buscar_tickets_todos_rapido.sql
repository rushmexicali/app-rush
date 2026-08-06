-- =====================================================================
-- 098 — buscar_tickets: soportar q vacío ("ver todos") y hacerlo RÁPIDO.
-- Con q vacío la pestaña Tickets lista TODO (más nuevo → más viejo, infinite
-- scroll). El problema de la 097: la descripción (string_agg sobre los
-- productos) se armaba para TODAS las filas que hacían match y hasta después
-- se recortaba a la página → con q vacío eran 26k filas y tardaba ~550 ms.
--
-- Arreglo: primero se pagina (distinct on + order + limit/offset) cargando solo
-- ticket/hora/monto/cajera + el ARRAY de productos (referencia jsonb, barato);
-- la descripción (string_agg) se arma únicamente para las 30 filas de la página.
-- =====================================================================
create or replace function public.buscar_tickets(
  p_q text, p_limite int default 30, p_offset int default 0)
returns jsonb
language sql
stable
as $$
  with q as (select lower(unaccent(coalesce(p_q, ''))) as needle),
  base as (
    select zc.purchase_number as ticket, zc.hora, zc.monto, zc.cajero,
           zc.payload->'productos' as prods_z, null::jsonb as prods_v
    from public.zettle_compras zc, q
    where zc.busqueda is not null and strpos(zc.busqueda, q.needle) > 0

    union all

    select (x.pj->>'purchaseNumber')::int as ticket, v.creado_en as hora,
           round((x.pj->>'amount')::numeric / 100, 2) as monto,
           x.pj->>'userDisplayName' as cajero,
           null::jsonb as prods_z, x.pj->'products' as prods_v
    from public.ventas v, q
    cross join lateral (select (v.payload->>'payload')::jsonb as pj) x
    where x.pj->>'purchaseNumber' ~ '^[0-9]+$'
      and strpos(
            lower(unaccent(
              (x.pj->>'purchaseNumber') || ' ' || coalesce(x.pj->>'userDisplayName','') || ' ' ||
              coalesce((select string_agg(
                          coalesce(pr->>'name','') || ' ' || coalesce(pr->>'variantName',''), ' ')
                        from jsonb_array_elements(x.pj->'products') pr), '')
            )),
            q.needle) > 0
      and not exists (
        select 1 from public.zettle_compras zc
         where zc.purchase_number = (x.pj->>'purchaseNumber')::int)
  ),
  pagina as (
    select distinct on (ticket) ticket, hora, monto, cajero, prods_z, prods_v
    from base
    order by ticket desc, hora desc
    limit greatest(p_limite, 0)
    offset greatest(p_offset, 0)
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.ticket desc), '[]'::jsonb)
  from (
    select ticket, hora, monto, cajero,
           coalesce(
             (select string_agg(
                       btrim((pr->>'nombre') || ' ' || coalesce(pr->>'variante','')), ', ')
                from jsonb_array_elements(prods_z) pr),
             (select string_agg(
                       btrim((pr->>'name') || ' ' || coalesce(pr->>'variantName','')), ', ')
                from jsonb_array_elements(prods_v) pr)
           ) as descripcion
    from pagina
  ) t;
$$;
