-- =====================================================================
-- 126 - Contar las fotos huerfanas, bien
--
-- Huerfana = archivo en el bucket `fotos` que ya no apunta ningun carro ni
-- ninguna visita. Las deja el boton "Tomar foto otra vez" (migracion 103):
-- la foto nueva reemplaza el `foto_path` del carro y la vieja se queda.
--
-- ⚠️ El primer intento las conto desde la Edge Function con
-- `storage.from('fotos').list('')` y dio **36**, que resulto ser el numero de
-- CARPETAS: las fotos viven en `AAAA-MM-DD/carro-N-....jpg` y `list('')` sin
-- prefijo devuelve el primer nivel, o sea un renglon por dia. Contar mal por
-- abajo es la peor forma de contar basura: da la impresion de que casi no hay.
-- El numero de verdad es **174** (2,801 en el bucket contra 2,625 apuntadas).
--
-- Aqui se cuenta contra `storage.objects`, que es la lista real y exacta, en
-- una sola consulta.
--
-- ⚠️ ESTO NO BORRA NADA, a proposito. Borrar datos es una de las cuatro cosas
-- que este proyecto pregunta antes de hacer, y la lista sale de cruzar dos
-- fuentes: si el cruce se equivoca, se borra la foto de un carro real y no hay
-- vuelta. Se cuenta y se anota; el dia que el dueno lo autorice, el borrado
-- usa esta misma lista — y tiene que ir por la API de Storage, porque borrar
-- la fila de `storage.objects` NO libera el espacio.
-- =====================================================================

create or replace function public.fotos_huerfanas()
returns jsonb
language sql
stable
security definer
set search_path = public, storage
as $function$
  with huerfanas as (
    select o.name, coalesce((o.metadata->>'size')::bigint, 0) as bytes
      from storage.objects o
     where o.bucket_id = 'fotos'
       and not exists (select 1 from public.carros  c where c.foto_path = o.name)
       and not exists (select 1 from public.visitas v where v.foto_path = o.name)
  )
  select jsonb_build_object(
    'cuantas',      (select count(*) from huerfanas),
    'bytes',        (select coalesce(sum(bytes), 0) from huerfanas),
    'en_el_bucket', (select count(*) from storage.objects where bucket_id = 'fotos'),
    'apuntadas',    (select count(distinct foto_path) from public.carros where foto_path is not null),
    -- Una muestra para poder revisar a ojo antes de autorizar un borrado.
    'muestra',      (select coalesce(jsonb_agg(name order by name desc), '[]'::jsonb)
                       from (select name from huerfanas order by name desc limit 5) m)
  );
$function$;

revoke execute on function public.fotos_huerfanas() from public;
