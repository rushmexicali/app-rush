-- =====================================================================
-- RUSH — Cron diario que borra las fotos de mas de 3 meses · 29/jul/2026
--
-- Llama al Edge Function limpiar-fotos una vez al dia. El token que lo
-- autoriza sale de Vault (nunca de Git): aqui solo se referencia por
-- nombre. El valor se guardo aparte con vault.create_secret y con
-- 'supabase secrets set LIMPIEZA_TOKEN=...'; los dos tienen el mismo valor.
--
-- La hora exacta no importa (es mantenimiento): 09:15 UTC ~ 01-02 AM en
-- Mexicali, taller cerrado. Como no es un corte que dependa del dia local,
-- NO necesita la guardia de zona horaria que si llevan congelar_reporte o
-- sincronizar_jibble — un nightly puede correr una hora antes o despues por
-- el cambio de horario sin ninguna consecuencia.
-- =====================================================================

-- Idempotente: si ya existe el job (por re-correr la migracion), se quita
-- primero. cron.unschedule truena si no existe, por eso el filtro.
select cron.unschedule('limpiar-fotos')
  from cron.job where jobname = 'limpiar-fotos';

select cron.schedule('limpiar-fotos', '15 9 * * *', $cmd$
  select net.http_post(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/limpiar-fotos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-tarea', (select decrypted_secret from vault.decrypted_secrets where name = 'limpieza_token')
    ),
    timeout_milliseconds := 120000
  );
$cmd$);
