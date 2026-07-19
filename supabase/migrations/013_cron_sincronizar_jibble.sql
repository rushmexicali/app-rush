-- =====================================================================
-- RUSH Car Wash — Que la sincronizacion con Jibble corra sola
--
-- Cada minuto. No hay webhooks en Jibble (probado el 19/jul/2026: los
-- tres endpoints dan 404), asi que preguntar es la unica via.
--
-- Un minuto es suficiente: nadie checa y corre a secar un carro en menos
-- de eso. Y tiene una ventaja sobre los avisos: si una consulta falla,
-- la siguiente corrige. Un aviso perdido, en cambio, deja a alguien
-- fuera de la lista sin que nadie se entere.
-- =====================================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Se borra el anterior por si esta migracion se corre dos veces.
select cron.unschedule('sincronizar-jibble')
 where exists (select 1 from cron.job where jobname = 'sincronizar-jibble');

select cron.schedule(
  'sincronizar-jibble',
  '* * * * *',
  $$
    select net.http_get(
      url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/sincronizar-jibble',
      timeout_milliseconds := 20000
    );
  $$
);
