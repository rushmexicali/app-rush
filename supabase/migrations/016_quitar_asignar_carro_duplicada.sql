-- =====================================================================
-- RUSH Car Wash — Quitar la version vieja de asignar_carro
--
-- Al agregar el parametro p_empleados en la migracion 014, Postgres NO
-- reemplazo la funcion: creo una segunda con distinta firma. Quedaron
-- conviviendo:
--
--   asignar_carro(bigint, smallint, text[], text)           <- vieja
--   asignar_carro(bigint, smallint, text[], text, text[])   <- nueva
--
-- La app nunca fallo porque llama con parametros NOMBRADOS y los cinco
-- argumentos, asi que Postgres resuelve sin ambiguedad. Pero cualquier
-- llamada con cuatro argumentos sueltos truena con "is not unique".
--
-- Leccion: "create or replace function" solo reemplaza si la firma es
-- identica. Cambiar los parametros crea una funcion nueva y deja la
-- anterior viva.
-- =====================================================================

drop function if exists public.asignar_carro(bigint, smallint, text[], text);
