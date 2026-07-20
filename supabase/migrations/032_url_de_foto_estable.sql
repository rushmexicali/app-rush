-- =====================================================================
-- RUSH Car Wash — la direccion de la foto deja de cambiar cada 3 segundos
--
-- EL PEOR BUG DEL DIA, y lo introduje yo al construir la foto.
--
-- El bucket es privado, asi que /cola generaba un enlace firmado para
-- cada foto. El problema: createSignedUrls arma un token nuevo CADA VEZ,
-- asi que la direccion cambiaba en cada consulta — o sea cada 3 segundos.
--
-- Para el navegador una direccion distinta es una imagen distinta: volvia
-- a bajar la foto COMPLETA cada 3 segundos.
--
--   foto real medida ...... 93 KB
--   5 carros con foto ..... 465 KB cada 3 s = 155 KB/s
--   jornada de 10 horas ... ~5.6 GB
--
-- En el wifi del taller, que el CLAUDE.md describe como flojo, eso es
-- reventarlo. Y encima cada consulta pegaba al Storage a firmar de nuevo.
--
-- Arreglo: se firma UNA vez al subir la foto, con 24 horas de vigencia, y
-- se guarda la direccion. /cola la reusa. Solo se vuelve a firmar cuando
-- de verdad vencio.
-- =====================================================================

alter table public.carros add column if not exists foto_url         text;
alter table public.carros add column if not exists foto_url_expira  timestamptz;

comment on column public.carros.foto_url is
  'Enlace firmado de la foto, ya generado. Se reusa para que la direccion NO cambie en cada consulta.';
comment on column public.carros.foto_url_expira is
  'Cuando vence foto_url. Solo entonces se vuelve a firmar.';
