-- =====================================================================
-- ⛔ RETIRADO EL 28/ago/2026 POR DECISION DEL DUENO. NO SE CORRE.
--
--    Textual: "Cada import de ahora en adelante sera borron y cuenta nueva
--    siempre. Nada de actualizar la base de datos actual. Asi nos evitamos
--    problema."
--
-- POR QUE, con el numero que lo motivo: el 28/ago la app de la caja se uso
-- por primera vez en operacion real (16 visitas) Y la cajera siguio llenando
-- el ClientNoteTracker en paralelo. El dedup de este archivo solo compara
-- contra `v.caja = 'import'`:
--
--     where v.caja='import' and ( v.ticket = s.ticket or ... )
--
-- o sea que una visita registrada por la CAJA es invisible para el, y el
-- import metia una SEGUNDA visita por el mismo lavado -> sello doble. Es el
-- mismo bug de lealtad que ya se limpio a mano en §11.35.
--
-- El reset lo resuelve de raiz porque `delete from public.visitas` no lleva
-- `where`: la actividad de caja se borra y el CNT queda como unica fuente.
--
--     bash scripts/releer-fotos/q.sh scripts/importar-clientnotetracker/reset-total.sql
--
-- El cuerpo viejo vive en el historial de Git (commit 09ca75b y anteriores).
-- Documenta como se dedupeaba; si algun dia el CNT deja de llenarse en
-- paralelo, ahi esta el punto de partida — pero entonces hay que arreglarle
-- el dedup ANTES de revivirlo.
-- =====================================================================
do $candado$
begin
  raise exception E'IMPORT INCREMENTAL RETIRADO (28/ago/2026).\n'
    '  Cada import es borron y cuenta nueva. Corre reset-total.sql.\n'
    '  Razon: el dedup de este archivo no ve las visitas de la caja\n'
    '  (`where v.caja=''import''`) y duplicaria los sellos.';
end $candado$;
