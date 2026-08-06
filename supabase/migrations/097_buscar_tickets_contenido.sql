-- =====================================================================
-- 097 — buscar_tickets por CONTENIDO (no solo número) + paginación.
-- El dueño quiere buscar tickets por número, cajera ("danithza"), producto
-- ("manual", "pinito", "aroma"...) — todo lo que ya viene en el ticket. Como
-- pueden ser muchísimos, el front hace infinite scroll: pide páginas con
-- offset, del más nuevo al más viejo.
--
-- Diseño: se precalcula una columna `busqueda` (texto plano, minúsculas sin
-- acentos) en el archivo estático `zettle_compras`, con número + cajera +
-- nombres/variantes de producto. Así el filtro es un strpos sobre una columna
-- lista, sin armar texto por fila en cada tecleo (una búsqueda cruda con
-- subconsultas tardaba ~79 ms sobre 25k; con la columna es un escaneo simple).
-- Para lo nuevo (ventas en vivo, ~800 filas post-backfill) se arma el texto en
-- línea: es chico. strpos (no LIKE) trata lo tecleado como literal, sin comodines.
-- =====================================================================

-- 1) Columna de búsqueda en el archivo histórico (estático).
alter table public.zettle_compras add column if not exists busqueda text;

update public.zettle_compras zc set busqueda = lower(unaccent(
  zc.purchase_number::text || ' ' || coalesce(zc.cajero, '') || ' ' ||
  coalesce((select string_agg(
              coalesce(pr->>'nombre','') || ' ' || coalesce(pr->>'variante',''), ' ')
            from jsonb_array_elements(zc.payload->'productos') pr), '')
));

-- 2) buscar_tickets(q, limite, offset) — por contenido, paginado, ticket desc.
create or replace function public.buscar_tickets(
  p_q text, p_limite int default 30, p_offset int default 0)
returns jsonb
language sql
stable
as $$
  with q as (select lower(unaccent(coalesce(p_q, ''))) as needle),
  matches as (
    -- Archivo estructurado (histórico), filtro sobre la columna precalculada.
    select zc.purchase_number as ticket, zc.hora, zc.monto, zc.cajero,
           (select string_agg(
                     btrim((pr->>'nombre') || ' ' || coalesce(pr->>'variante','')), ', ')
              from jsonb_array_elements(zc.payload->'productos') pr) as descripcion
    from public.zettle_compras zc, q
    where zc.busqueda is not null and strpos(zc.busqueda, q.needle) > 0

    union all

    -- En vivo (ventas): texto armado en línea. Solo lo que el archivo no tiene.
    select (x.pj->>'purchaseNumber')::int as ticket, v.creado_en as hora,
           round((x.pj->>'amount')::numeric / 100, 2) as monto,
           x.pj->>'userDisplayName' as cajero,
           (select string_agg(
                     btrim((pr->>'name') || ' ' || coalesce(pr->>'variantName','')), ', ')
              from jsonb_array_elements(x.pj->'products') pr) as descripcion
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
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.ticket desc), '[]'::jsonb)
  from (
    select distinct on (ticket) ticket, hora, monto, cajero, descripcion
    from matches
    order by ticket desc, hora desc
    limit greatest(p_limite, 0)
    offset greatest(p_offset, 0)
  ) t;
$$;
