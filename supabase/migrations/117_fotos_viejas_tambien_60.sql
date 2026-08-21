-- =====================================================================
-- 117 - El otro default de la retencion
--
-- La 115 dejo `olvidar_fotos_viejas` en 60 dias, pero `fotos_viejas` —la
-- que ELIGE cuales borrar— se quedo en 90. Hoy no cambia nada porque la
-- Edge Function siempre manda su propia constante (DIAS = 60), pero dejar
-- dos numeros distintos para la misma regla es exactamente como se
-- desfasan las cosas en este proyecto: el dia que alguien llame a la
-- funcion sin argumento, va a borrar con el criterio viejo y no se va a
-- enterar nadie.
--
-- El cuerpo se saco de la base con `pg_get_functiondef`; solo cambia el
-- default.
-- =====================================================================

create or replace function public.fotos_viejas(
  p_dias integer default 60,
  p_tope integer default 1000
) returns text[]
language sql
security definer
set search_path to 'public', 'storage'
as $func$
  select coalesce(array_agg(nombre), array[]::text[])
    from (
      select o.name as nombre
        from storage.objects o
       where o.bucket_id = 'fotos'
         and o.created_at < now() - make_interval(days => p_dias)
       -- Las mas viejas primero: si el tope corta, lo que queda es lo mas
       -- nuevo, que es lo que todavia puede servir.
       order by o.created_at
       limit greatest(1, coalesce(p_tope, 1000))
    ) t;
$func$;

comment on function public.fotos_viejas(integer, integer) is
  'Los archivos del bucket con mas de p_dias, los mas viejos primero. Retencion 60 dias desde la 117, igual que olvidar_fotos_viejas y que la constante de limpiar-fotos.';
