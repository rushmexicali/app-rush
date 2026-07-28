-- =====================================================================
-- RUSH — Historial completo de Zettle en la base + detalle de ticket
-- 27/jul/2026
--
-- Backfill de TODAS las compras de Zettle (~25k, purchases/v2) para que la
-- consulta de un ticket sea instantanea (sin ir a la API ni paginar). En el
-- reporte, el numero de ticket es clicable y abre la venta completa.
--
-- La tabla se LLENA con scripts/importar-clientnotetracker/pull-zettle-
-- compras.ps1 (via PostgREST, payload ya estructurado: productos/descuentos/
-- pago). Idempotente (ignore-duplicates por purchase_number).
-- =====================================================================

create table if not exists public.zettle_compras (
  purchase_number integer primary key,   -- = ticket = purchaseNumber
  purchase_uuid   text,
  monto           numeric,               -- pesos
  cajero          text,
  hora            timestamptz,
  payload         jsonb not null          -- { productos:[{nombre,variante,cantidad,precio}], descuentos:[{nombre,monto}], pago }
);
alter table public.zettle_compras enable row level security;

-- Detalle legible de un ticket (lo consume /ticket en la Edge Function app).
create or replace function public.ticket_detalle(p_num integer)
returns jsonb language sql stable as $fn$
  select jsonb_build_object(
    'ticket', purchase_number, 'hora', hora, 'cajero', cajero, 'monto', monto,
    'productos', payload->'productos', 'descuentos', payload->'descuentos', 'pago', payload->>'pago'
  ) from public.zettle_compras where purchase_number = p_num;
$fn$;
