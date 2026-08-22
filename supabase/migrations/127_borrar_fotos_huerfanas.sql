-- =====================================================================
-- 127 - La lista de fotos huerfanas, para poder borrarlas
--
-- El dueño autorizo el borrado el 21/ago/2026, con el numero medido enfrente:
-- 176 archivos, 16 MB (165 de "Tomar foto otra vez" y 11 capturas de la caja
-- que nunca se ligaron a una visita).
--
-- 🔑 GRACIA DE UNA HORA, y no es paranoia: `/foto` sube el archivo a Storage
-- **y despues** escribe `carros.foto_path`. Entre esas dos cosas el archivo
-- existe y no lo apunta nadie — o sea que se ve exactamente igual que un
-- huerfano. Sin la gracia, una corrida a destiempo borra la foto de un carro
-- que se acaba de asignar, y esa no se recupera.
--
-- ⚠️ Borrar la fila de `storage.objects` NO libera el espacio: hay que pasar
-- por la API de Storage. Por eso esto solo DEVUELVE LA LISTA; quien borra es
-- la Edge Function `limpiar-fotos`, con `?huerfanas=1`.
--
-- Y el borrado NO es automatico. El cron sigue borrando solo por EDAD (60
-- dias), que es una regla con fecha y facil de razonar. Barrer huerfanas cada
-- noche es otra decision: la lista sale de cruzar dos fuentes, y si el cruce
-- se equivoca no hay vuelta. Se corre a mano cuando el dueño lo pida.
-- =====================================================================

create or replace function public.fotos_huerfanas_lista(p_tope int default 500)
returns setof text
language sql
stable
security definer
set search_path = public, storage
as $function$
  select o.name
    from storage.objects o
   where o.bucket_id = 'fotos'
     and o.created_at < now() - interval '1 hour'
     and not exists (select 1 from public.carros  c where c.foto_path = o.name)
     and not exists (select 1 from public.visitas v where v.foto_path = o.name)
   order by o.created_at
   limit greatest(p_tope, 0);
$function$;

revoke execute on function public.fotos_huerfanas_lista(int) from public;
