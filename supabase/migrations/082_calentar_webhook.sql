-- =====================================================================
-- Migracion 082: calentar la funcion zettle-webhook (evitar 502 por
-- arranque en frio).
--
-- El correo (Your webhook is failing / HTTP 502) de Zettle NO es perdida
-- de ventas ni bug del codigo: es la funcion que despierta de estar
-- dormida (de noche, o tras un hueco largo entre ventas) y tarda mas de
-- lo que Zettle espera. Zettle reintenta y la venta entra igual, pero el
-- correo llega y asusta.
--
-- Este cron le da un GET cada minuto en horario de taller para que el
-- primer aviso real nunca la encuentre fria. El GET pega en la rama que
-- responde {ok:true} SIN tocar la base: cuesta practicamente nada.
--
-- El guardado de horario va DENTRO de la funcion, no en el horario del
-- cron: pg_cron corre en UTC y Mexicali cambia de horario dos veces al
-- anio. Mismo patron que sincronizar_jibble_si_toca() y congelar_reporte().
-- =====================================================================

create or replace function public.calentar_webhook_si_toca()
returns text
language plpgsql
as $func$
declare
  local_ahora timestamp;
  h           int;
  desde_hora  int := 6;   -- el taller abre a las 8; margen de 2h
  hasta_hora  int := 22;  -- exclusivo: la ultima corrida es a las 21:59
begin
  local_ahora := (now() at time zone 'America/Tijuana');
  h := extract(hour from local_ahora)::int;

  if h < desde_hora or h >= hasta_hora then
    return 'taller cerrado, no se calento';
  end if;

  perform net.http_get(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/zettle-webhook',
    timeout_milliseconds := 8000
  );

  return 'webhook calentado (' || to_char(local_ahora, 'HH24:MI') || ' Mexicali)';
end;
$func$;

select cron.schedule('calentar-webhook', '* * * * *', 'select public.calentar_webhook_si_toca();');
