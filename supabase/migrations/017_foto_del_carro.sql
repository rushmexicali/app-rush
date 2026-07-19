-- =====================================================================
-- RUSH Car Wash — Fase 4: la foto del carro (opcional)
--
-- El bucket "fotos" es PRIVADO: en las fotos se ven placas. Se sirven
-- con enlaces firmados que caducan en una hora, no con una direccion
-- publica permanente.
--
-- foto_path en null es el caso NORMAL, no un error. El dueno lo pidio
-- explicito: "hay veces que habra demasiado trabajo y no se dara abasto
-- para llenar todos los recuadros".
-- =====================================================================
-- Ruta de la foto dentro del almacen privado. Null = sin foto, que es
-- perfectamente valido: la foto es opcional y nunca bloquea el flujo.
alter table public.carros add column if not exists foto_path text;
alter table public.carros add column if not exists foto_en   timestamptz;

comment on column public.carros.foto_path is
  'Ruta en el bucket privado "fotos". Null = sin foto (caso normal en dia pesado).';
