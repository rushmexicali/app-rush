-- =====================================================================
-- 088 — El detalle de ticket SIEMPRE actualizado (lee ventas en vivo)
-- 29/jul/2026
--
-- Problema: zettle_compras se llenó UNA vez con pull-zettle-compras.ps1
-- (backfill histórico, ~25,256 compras hasta el 27/jul). Las compras nuevas
-- NO entran ahí, así que un ticket reciente (p.ej. 25463 del 29/jul) salía
-- "No se encontró en Zettle" en el modal del reporte.
--
-- PERO el webhook YA guarda cada venta completa en ventas.payload. Así que en
-- vez de re-pullear o meter un proceso nuevo en el camino del dinero, se hace
-- que ticket_detalle:
--   1) use zettle_compras si el ticket está en el archivo (rápido, por PK), o
--   2) lo arme AL VUELO desde ventas.payload si no está (compras nuevas).
-- Misma forma de salida en los dos casos, así el front no cambia.
--
-- La hora sale de ventas.creado_en (timestamptz correcto), NO del timestamp
-- del payload del webhook, que viene en milisegundos (la trampa del §7).
-- No se toca el webhook, ni zettle_compras, ni el insert de ventas.
-- =====================================================================

create or replace function public.ticket_detalle(p_num integer)
returns jsonb
language sql
stable
as $fn$
  -- 1) Archivo estructurado (histórico). Rápido: purchase_number es PK.
  select jsonb_build_object(
    'ticket', purchase_number, 'hora', hora, 'cajero', cajero, 'monto', monto,
    'productos', payload->'productos', 'descuentos', payload->'descuentos', 'pago', payload->>'pago'
  )
  from public.zettle_compras
  where purchase_number = p_num

  union all

  -- 2) En vivo desde ventas (webhook), SOLO si el archivo no lo tiene. Se
  -- transforma el payload crudo a la misma forma { productos, descuentos, pago }.
  (select jsonb_build_object(
    'ticket',    p_num,
    'hora',      v.creado_en,
    'cajero',    x.pj->>'userDisplayName',
    'monto',     round((x.pj->>'amount')::numeric / 100, 2),
    'productos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre',   pr->>'name',
        'variante', pr->>'variantName',
        'cantidad', pr->>'quantity',
        'precio',   round((pr->>'unitPrice')::numeric / 100, 2)
      ))
      from jsonb_array_elements(x.pj->'products') pr), '[]'::jsonb),
    'descuentos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nombre', d->>'name',
        'monto',  round((d->>'amount')::numeric / 100, 2)
      ))
      from jsonb_array_elements(x.pj->'discounts') d), '[]'::jsonb),
    'pago', (select string_agg(pay->>'type', ', ') from jsonb_array_elements(x.pj->'payments') pay)
  )
  from public.ventas v
  cross join lateral (select (v.payload->>'payload')::jsonb as pj) x
  where not exists (select 1 from public.zettle_compras zc where zc.purchase_number = p_num)
    and x.pj->>'purchaseNumber' = p_num::text
  order by v.creado_en desc
  limit 1);
$fn$;

-- Para que la búsqueda por purchaseNumber en ventas (rama 2) sea instantánea
-- en vez de escanear la tabla. Expresión inmutable (jsonb ops), verificada
-- segura sobre las 966 ventas actuales.
create index if not exists ventas_purchase_number_idx
  on public.ventas ((((payload->>'payload')::jsonb)->>'purchaseNumber'));

comment on function public.ticket_detalle(integer) is
  'Detalle de un ticket. Usa zettle_compras (archivo histórico) y, si el '
  'ticket no está, lo arma al vuelo desde ventas.payload (compras nuevas del '
  'webhook). Siempre actualizado sin re-pullear.';
