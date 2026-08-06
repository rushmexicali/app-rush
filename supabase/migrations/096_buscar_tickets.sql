-- =====================================================================
-- 096 — buscar_tickets(q): busca tickets por SUBSTRING del número.
-- Alimenta el buscador en vivo de la pestaña "Tickets" del reporte (como el
-- buscador de clientes): al teclear 2+ dígitos salen todos los tickets cuyo
-- número contiene esos dígitos, clicables directo (abren ticket_detalle).
--
-- Dos fuentes, igual que ticket_detalle (088): el archivo estructurado
-- `zettle_compras` (histórico, PK = purchase_number) y, para lo que el archivo
-- aún no tiene, `ventas` en vivo (webhook). strpos (no LIKE) para tratar el
-- texto tecleado como literal, sin comodines. Orden: ticket más reciente
-- primero; tope de p_limite (el front pide 50).
-- =====================================================================
create or replace function public.buscar_tickets(p_q text, p_limite int default 50)
returns jsonb
language sql
stable
as $$
  with matches as (
    select zc.purchase_number as ticket, zc.hora, zc.monto, zc.cajero,
           (select string_agg(
                     btrim((pr->>'nombre') || ' ' || coalesce(pr->>'variante','')), ', ')
              from jsonb_array_elements(zc.payload->'productos') pr) as descripcion
    from public.zettle_compras zc
    where strpos(zc.purchase_number::text, p_q) > 0

    union all

    select (x.pj->>'purchaseNumber')::int as ticket, v.creado_en as hora,
           round((x.pj->>'amount')::numeric / 100, 2) as monto,
           x.pj->>'userDisplayName' as cajero,
           (select string_agg(
                     btrim((pr->>'name') || ' ' || coalesce(pr->>'variantName','')), ', ')
              from jsonb_array_elements(x.pj->'products') pr) as descripcion
    from public.ventas v
    cross join lateral (select (v.payload->>'payload')::jsonb as pj) x
    where x.pj->>'purchaseNumber' ~ '^[0-9]+$'
      and strpos(x.pj->>'purchaseNumber', p_q) > 0
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
  ) t;
$$;
