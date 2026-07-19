-- =====================================================================
-- RUSH Car Wash — leer la placa de la foto (Claude Sonnet 5)
--
-- Cuando el supervisor sube la foto, la Edge Function "app" se la manda a
-- Claude y guarda aqui lo que se haya podido leer.
--
-- Son DOS columnas, no tres, y la diferencia importa:
--
--   placa_en NULA          -> todavia no se ha intentado (no hay foto, o
--                             la lectura trono y ni siquiera corrio)
--   placa_en CON FECHA
--     y placa NULA         -> si se intento y NO se pudo leer
--   ambas con valor        -> se leyo
--
-- Ese segundo caso es informacion, no un error: sirve para medir que tan
-- seguido las fotos salen ilegibles y decidir si vale la pena insistir.
-- Por eso no hace falta una columna de "confianza".
--
-- Regla de oro (la misma de la nota de caja): si no se lee con certeza,
-- se guarda VACIA. Nunca se adivina un caracter ni se completa el formato.
-- Se probo el 19/jul/2026 tapando los digitos centrales de una placa real
-- dejando visibles solo las letras de los extremos: devolvio vacio las
-- tres veces, teniendo todo para "completarla".
-- =====================================================================

alter table public.carros add column if not exists placa    text;
alter table public.carros add column if not exists placa_en timestamptz;

comment on column public.carros.placa is
  'Placa leida de la foto. Null = no se pudo leer (o no se ha intentado; ver placa_en).';

comment on column public.carros.placa_en is
  'Cuando se intento leer la placa. Con fecha y placa nula = se intento y no se pudo.';
