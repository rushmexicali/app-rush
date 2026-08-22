-- =====================================================================
-- 122 - La bitacora de pg_cron deja de comerse la base
--
-- `cron.job_run_details` guarda un renglon por CADA corrida de CADA cron y
-- **nunca se limpia sola**. Medido el 21/ago: **80,913 corridas** desde el
-- 19/jul, **14 MB de una base de 81** — el 17%, y es la segunda tabla mas
-- grande despues del archivo de Zettle. Creciendo a ~1,700 corridas al dia
-- (`calentar-webhook` sola son 1,440), en un ano son ~620,000 renglones.
--
-- El plan gratis de Supabase da 500 MB. Que el 17% se lo lleve un log que
-- nadie consulta mas alla de la semana pasada es de las cosas mas baratas
-- de arreglar de toda la auditoria.
--
-- **Se guardan 7 dias.** Es lo que hace falta para investigar "ayer fallo el
-- cron": mas atras nadie ha mirado nunca, y las corridas fallidas se cuentan
-- aparte antes de borrar, para que si alguna vez hay un patron no se vaya en
-- silencio. Hoy hay **0 fallidas en toda la historia**.
--
-- ⚠️ El cron de limpieza corre a las 3:10 AM UTC, que es de madrugada en
-- Mexicali en cualquiera de los dos horarios. A diferencia de
-- `congelar_reporte`, aqui la hora local NO importa —no se esta cortando un
-- dia de negocio, se esta barriendo un log—, asi que no hace falta la
-- guardia de zona horaria de la `060`.
-- =====================================================================

create or replace function public.limpiar_bitacora_del_cron(p_dias int default 7)
returns text
language plpgsql
security definer
set search_path = public, cron
as $function$
declare
  antes    bigint;
  fallidas bigint;
  n        bigint;
begin
  select count(*) into antes from cron.job_run_details;
  -- Se cuentan las fallidas ANTES de borrar. Si un dia hay un patron de
  -- fallos, el numero queda dicho aunque el detalle se vaya.
  select count(*) into fallidas
    from cron.job_run_details
   where status <> 'succeeded'
     and start_time < now() - make_interval(days => p_dias);

  delete from cron.job_run_details
   where start_time < now() - make_interval(days => p_dias);
  get diagnostics n = row_count;

  return 'bitacora del cron: se borraron ' || n || ' de ' || antes ||
         ' corridas (mas de ' || p_dias || ' dias); de las borradas, ' ||
         fallidas || ' habian fallado';
end;
$function$;

revoke execute on function public.limpiar_bitacora_del_cron(int) from public;

-- Agendar (idempotente: si ya existe, se reescribe).
select cron.schedule('limpiar-bitacora-cron', '10 3 * * *',
                     $$select public.limpiar_bitacora_del_cron(7)$$);

-- Y la primera pasada, ahora.
select public.limpiar_bitacora_del_cron(7) as primera_corrida;
