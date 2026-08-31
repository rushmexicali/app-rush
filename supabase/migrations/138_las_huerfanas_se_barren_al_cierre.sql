-- =====================================================================
-- 138 — Las fotos huerfanas se borran solas al cierre del dia (8:30 PM).
--
-- Regla del dueno, 30/ago/2026, textual: "Borralas. Todas las fotos
-- huerfanas se borran al finalizar el dia (8:30 PM)".
--
-- QUE CAMBIA: hasta hoy el barrido diario (jobid 6) SOLO contaba las
-- huerfanas y dejaba un aviso pidiendo autorizacion; borrarlas era una
-- llamada a mano con `?huerfanas=1`. Eso se acumulaba: el aviso paso de 16
-- a 96 en cinco dias y llego a 151 el mismo 30/ago, porque la caja captura
-- la foto ANTES de ligarla y la que se abandona queda suelta. Con la caja
-- en uso real esto crece ~50 al dia y ya no es razonable pedir permiso cada
-- vez. El dueno lo convirtio en politica permanente.
--
-- 🔑 EL HORARIO VIVE EN LA FUNCION, NO EN EL CRON. `pg_cron` corre en UTC y
--    Mexicali cambia de horario dos veces al ano; escribir la hora local a
--    mano en el schedule la deja mal medio ano sin que nadie se entere. Se
--    dispara a las dos horas UTC posibles (03:30 verano / 04:30 invierno) y
--    quien decide es Postgres preguntandole a America/Tijuana. Exactamente
--    el mismo patron de congelar_reporte (035) y sincronizar_jibble (060).
--
-- ⚠️ LA RED DE SEGURIDAD SIGUE SIENDO LA GRACIA DE UNA HORA de
--    `fotos_huerfanas_lista` (127), y ahora importa mas que antes porque
--    esto ya no lo revisa nadie: `/foto` sube el archivo a Storage y
--    DESPUES escribe `carros.foto_path`. Entre esas dos cosas una foto viva
--    se ve identica a una huerfana. A las 8:30 PM, con el taller cerrado
--    desde las 8, la gracia cubre de sobra la ultima captura del dia.
--
-- ⛔ NO se toca el barrido por EDAD (60 dias). Ese sigue en jobid 6 a su
--    hora; son dos reglas distintas y mezclarlas seria darles un solo
--    horario a dos cosas que no tienen por que compartirlo.
-- =====================================================================

create or replace function public.barrer_huerfanas_si_toca()
returns text
language plpgsql
as $function$
declare
  local_ahora timestamp;
  h           int;
  hora_cierre int := 20;   -- 8 PM local; el cron dispara a las :30
begin
  local_ahora := (now() at time zone 'America/Tijuana');
  h := extract(hour from local_ahora)::int;

  -- Exactamente una de las dos corridas UTC cae en la hora local buena.
  if h <> hora_cierre then
    return 'no toca (' || to_char(local_ahora, 'HH24:MI') || ' Mexicali)';
  end if;

  perform net.http_post(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/limpiar-fotos?huerfanas=1',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-tarea', (select decrypted_secret from vault.decrypted_secrets where name = 'limpieza_token')
    ),
    timeout_milliseconds := 120000
  );

  return 'barrido de huerfanas disparado (' || to_char(local_ahora, 'HH24:MI') || ' Mexicali)';
end;
$function$;

-- Idempotente: si ya existe se reemplaza el horario en vez de duplicar el job.
select cron.unschedule('barrer-huerfanas')
 where exists (select 1 from cron.job where jobname = 'barrer-huerfanas');

select cron.schedule('barrer-huerfanas', '30 3,4 * * *',
                     'select public.barrer_huerfanas_si_toca();');
