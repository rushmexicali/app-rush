-- =====================================================================
-- 099 — Indexar `ventas` para que buscar_tickets sea RÁPIDO (incl. q vacío).
-- El cuello de la 097/098 era el lado de ventas: re-parseaba el payload jsonb
-- completo ((payload->>'payload')::jsonb) de las ~1600 filas en CADA búsqueda
-- (~440 ms). Aquí se precalcula lo necesario en columnas, con un trigger que se
-- llena solo al llegar cada venta del webhook (transparente: el webhook no
-- cambia). Así el escaneo de ventas lee columnas, sin parsear jsonb.
-- =====================================================================
alter table public.ventas
  add column if not exists ticket_num int,
  add column if not exists cajero     text,
  add column if not exists prods      jsonb,
  add column if not exists busqueda   text;

create or replace function public.ventas_indexar()
returns trigger language plpgsql as $$
declare pj jsonb;
begin
  begin pj := (NEW.payload->>'payload')::jsonb; exception when others then pj := null; end;
  if pj is not null then
    NEW.ticket_num := case when pj->>'purchaseNumber' ~ '^[0-9]+$'
                           then (pj->>'purchaseNumber')::int end;
    NEW.cajero := pj->>'userDisplayName';
    NEW.prods  := pj->'products';
    NEW.busqueda := lower(unaccent(
      coalesce(pj->>'purchaseNumber','') || ' ' || coalesce(pj->>'userDisplayName','') || ' ' ||
      coalesce((select string_agg(
                  coalesce(p->>'name','') || ' ' || coalesce(p->>'variantName',''), ' ')
                from jsonb_array_elements(pj->'products') p), '')
    ));
  end if;
  return NEW;
end $$;

drop trigger if exists ventas_indexar on public.ventas;
create trigger ventas_indexar before insert or update on public.ventas
  for each row execute function public.ventas_indexar();

-- Backfill de lo existente (dispara el trigger).
update public.ventas set payload = payload;

create index if not exists ventas_ticket_num_idx on public.ventas(ticket_num);

-- buscar_tickets: lado ventas ahora lee columnas (sin parsear payload).
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

    select v.ticket_num as ticket, v.creado_en as hora, v.monto, v.cajero,
           null::jsonb as prods_z, v.prods as prods_v
    from public.ventas v, q
    where v.ticket_num is not null
      and strpos(coalesce(v.busqueda, ''), q.needle) > 0
      and not exists (
        select 1 from public.zettle_compras zc where zc.purchase_number = v.ticket_num)
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
