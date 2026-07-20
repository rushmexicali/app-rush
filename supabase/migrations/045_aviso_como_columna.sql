-- =====================================================================
-- RUSH Car Wash — el aviso es una columna generada, no codigo repetido
--
-- La 044 dejo la regla en SQL. La tentacion inmediata fue volver a
-- escribirla en TypeScript dentro de la Edge Function para poder
-- mandarla en /cola. Eso habria creado DOS reglas para la misma
-- pregunta — exactamente el error que este proyecto ya cometio dos veces
-- (express contra aspirado, y rechazos_dia contra del_dia) y que el
-- CLAUDE.md documenta las dos veces.
--
-- Como columna generada, la regla vive en un solo lugar, la base la
-- mantiene sola y ademas se puede consultar:
--
--   select count(*) from carros where aviso = 'LAVADO A MANO';
--
-- Se puede hacer generada porque aviso_de_servicio es IMMUTABLE: depende
-- solo de las tres columnas del propio renglon.
-- =====================================================================

alter table public.carros
  add column if not exists aviso text
  generated always as (
    public.aviso_de_servicio(producto, variante, categoria)
  ) stored;

comment on column public.carros.aviso is
  'Banderita de servicio especial (ENCERADO MANUAL, SUPER BRILLO, LAVADO A MANO). NULL = lavado normal. Generada.';
