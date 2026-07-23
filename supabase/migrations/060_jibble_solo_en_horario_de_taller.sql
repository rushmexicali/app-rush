-- =====================================================================
-- 060 — Jibble se sincroniza solo de 6 AM a 10 PM, hora de Mexicali
--
-- EL PROBLEMA: el cron corria cada minuto, 24 horas al dia, los 7 dias.
-- Son 1,440 invocaciones diarias de Edge Function y, como cada una pide
-- token + 3 grupos + timesheets, unas 7,200 llamadas diarias a la API de
-- Jibble. El taller opera de 8:00 a 20:30. De madrugada se estaba
-- preguntando "quien esta checado" a un taller cerrado, cada minuto.
--
-- Ahora corre de 6 AM a 10 PM hora local: 960 invocaciones en vez de
-- 1,440 (-33%) y ~4,800 llamadas a Jibble en vez de 7,200. La ventana la
-- escogio el dueno con margen a proposito — dos horas antes de abrir y
-- dos despues de cerrar — para que ningun turno que se alargue se quede
-- sin lista de secadores.
--
-- POR QUE LA GUARDIA VA EN LA FUNCION Y NO EN EL HORARIO DEL CRON
--
-- pg_cron corre en UTC. Poner "13-5 * * *" en el cron seria clavar el
-- desfase a mano, y Mexicali cambia de horario dos veces al ano: la
-- ventana se recorreria una hora cada temporada, y el dia que el
-- Congreso cambie la ley del horario de verano — como ya paso en Mexico
-- en 2022 — quedaria mal para siempre sin que nadie se entere.
--
-- Asi que el cron sigue disparando cada minuto (cuesta practicamente
-- nada: es un 'select' que ni sale de la base) y quien decide es
-- Postgres, preguntandole a 'America/Tijuana' en ese momento. Si cambia
-- la legislacion, Supabase actualiza su tabla de zonas horarias y la
-- ventana sigue siendo 6 AM - 10 PM SIN TOCAR NADA.
--
-- Es el mismo patron que ya usa congelar_reporte() para el corte de las
-- 8:30 PM (migracion 035), y por la misma razon.
--
-- La llamada que se ahorra es la CARA: la invocacion de la Edge Function
-- y las 5 peticiones HTTP a Jibble.
-- =====================================================================

create or replace function public.sincronizar_jibble_si_toca()
returns text
language plpgsql as $$
declare
  local_ahora timestamp;
  h           int;
  -- El taller abre a las 8 y cierra a las 8. La ventana lleva dos horas
  -- de margen de cada lado, por si un turno se alarga.
  desde_hora  int := 6;
  hasta_hora  int := 22;   -- exclusivo: la ultima corrida es a las 21:59
begin
  local_ahora := (now() at time zone 'America/Tijuana');
  h := extract(hour from local_ahora)::int;

  if h < desde_hora or h >= hasta_hora then
    return 'taller cerrado (son las ' || to_char(local_ahora, 'HH24:MI') ||
           ' en Mexicali), no se llamo a Jibble';
  end if;

  perform net.http_get(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/sincronizar-jibble',
    timeout_milliseconds := 20000
  );

  return 'sincronizado (' || to_char(local_ahora, 'HH24:MI') || ' en Mexicali)';
end;
$$;

comment on function public.sincronizar_jibble_si_toca() is
  'Llama a la Edge Function de Jibble solo entre las 6 AM y las 10 PM '
  'hora de Mexicali. La hora la resuelve Postgres con America/Tijuana, '
  'no un desfase escrito a mano, para que un cambio de horario de verano '
  '(o de la ley) no recorra la ventana.';

-- cron.schedule con el mismo nombre reemplaza el trabajo existente.
select cron.schedule(
  'sincronizar-jibble',
  '* * * * *',
  'select public.sincronizar_jibble_si_toca();'
);
