-- =====================================================================
-- RUSH — Columnas monto y ticket en visitas (para la migracion de
-- ClientNoteTracker y el "Total gastado" por cliente) · 27/jul/2026
--
-- Aditivas, nullables, no rompen nada. Las llena el importador
-- (ver scripts/importar-clientnotetracker/). El reporte suma
-- visitas.monto por persona para el "Total gastado".
--   - monto:  lo que pago el cliente en ESA visita, en PESOS (de Zettle,
--             por purchaseNumber == ticket). null si no se pudo conciliar.
--   - ticket: el numero de ticket de ClientNoteTracker (= purchaseNumber de
--             Zettle). Referencia / para re-ligar a la venta.
-- =====================================================================

alter table public.visitas add column if not exists monto  numeric;
alter table public.visitas add column if not exists ticket text;
