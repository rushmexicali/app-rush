-- =====================================================================
-- 119 - Limpieza de la auditoria del 20/ago: lo que borra, lo que sobra
--       y un candado que no candaba
--
-- Cuatro cosas independientes, todas de la lista de hallazgos:
--
--  1. `enlazar_visita_a_carro` BORRABA marca/submarca con un nulo. Es la
--     misma regla que la migracion `109` le puso a `guardar_datos_de_foto`
--     ("un nulo no borra") y que aqui nunca se aplico. La cajera casi nunca
--     captura marca, asi que enlazar una visita a un carro le borraba la
--     marca que la foto SI habia leido.
--
--  2. `registrar_visita` se BORRA. Es la version vieja de la caja, la de
--     antes del rediseno del 15/ago: registra una visita SIN lavado ligado,
--     que es exactamente la fuga de lealtad que ese rediseno cerro. Ninguna
--     pantalla la llama y ninguna otra funcion la menciona (verificado). Y
--     de paso desaparece el hallazgo de "la regla de cortesia vive en una
--     sola de las dos funciones que registran visitas": ahora hay UNA.
--
--  3. `importar_personas()` se BORRA. Un arma cargada que nadie llama:
--     siembra `personas` desde `carros.cliente` con `visitas_seed` y
--     `sellos_iniciales` calculados a mano. Correrla hoy, con el CRM ya
--     cargado desde el ClientNoteTracker, le inventaria sellos a medio
--     padron. El camino bueno es el import, que ya esta probado.
--
--  4. El candado de `sincronizar_jibble_si_toca` ERA INERTE.
--     `pg_try_advisory_xact_lock` dura lo que dura la transaccion, y
--     `net.http_get` es ASINCRONO: devuelve en cuanto encola la peticion.
--     O sea que el lock se soltaba antes de que la Edge Function siquiera
--     empezara — no podia impedir el solape que decia impedir. Se cambia
--     por una marca de tiempo en una tabla, que si sobrevive entre
--     transacciones.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Un nulo no borra (enlazar_visita_a_carro)
--
-- La funcion son ~90 lineas de reglas con sus razones escritas. NO se copia:
-- se le pide a Postgres su propia definicion, se cambian las dos lineas y se
-- vuelve a crear. Es el patron de la migracion `116`; reescribir de memoria
-- una funcion larga ya salio mal una vez en este proyecto (§11.45).
-- ---------------------------------------------------------------------
do $$
declare
  d      text;
  viejo  text := E'        marca         = nullif(btrim(upper(coalesce(v.marca, \'\'))), \'\'),\n'
                 || E'        submarca      = v_sub,';
  nuevo  text := E'        -- Un nulo NO borra: si la cajera no capturo marca, se queda la que\n'
                 || E'        -- ya tenia el carro (leida de la foto). Misma regla que la 109 le\n'
                 || E'        -- puso a guardar_datos_de_foto.\n'
                 || E'        -- EXCEPCION, tambien igual que alla: si el carro YA tenia placa y la\n'
                 || E'        -- nueva es DISTINTA, lo guardado era de otro carro y se reemplaza el\n'
                 || E'        -- juego completo, nulos incluidos. Ojo: se pide `placa is not null`\n'
                 || E'        -- a proposito. Sin eso, un carro cuya foto leyo la marca pero no la\n'
                 || E'        -- placa (caso normal, §9) perderia la marca en cuanto la cajera\n'
                 || E'        -- tecleara una.\n'
                 || E'        marca         = case when placa is not null and placa is distinct from v_norm\n'
                 || E'                             then nullif(btrim(upper(coalesce(v.marca, \'\'))), \'\')\n'
                 || E'                             else coalesce(nullif(btrim(upper(coalesce(v.marca, \'\'))), \'\'), marca) end,\n'
                 || E'        submarca      = case when placa is not null and placa is distinct from v_norm\n'
                 || E'                             then v_sub\n'
                 || E'                             else coalesce(v_sub, submarca) end,';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname = 'enlazar_visita_a_carro';

  if d is null then
    raise exception 'No existe public.enlazar_visita_a_carro';
  end if;
  if position(viejo in d) = 0 then
    raise exception 'El ancla no aparece en enlazar_visita_a_carro: alguien ya la cambio. Revisar a mano.';
  end if;

  execute replace(d, viejo, nuevo);
end $$;

-- ---------------------------------------------------------------------
-- 2 y 3) Lo que sobra
-- ---------------------------------------------------------------------
drop function if exists public.registrar_visita(bigint, text, text, text, text, text, text, boolean, text);
drop function if exists public.importar_personas();

-- ---------------------------------------------------------------------
-- 4) El candado de Jibble, ahora de verdad
-- ---------------------------------------------------------------------
create table if not exists public.jibble_disparos (
  uno            boolean primary key default true check (uno),
  ultimo_disparo timestamptz
);
insert into public.jibble_disparos (uno, ultimo_disparo) values (true, null)
on conflict (uno) do nothing;

create or replace function public.sincronizar_jibble_si_toca()
returns text
language plpgsql
as $function$
declare
  local_ahora timestamp;
  h           int;
  -- El taller abre a las 8 y cierra a las 8. La ventana lleva dos horas
  -- de margen de cada lado, por si un turno se alarga.
  desde_hora  int := 6;
  hasta_hora  int := 22;   -- exclusivo: la ultima corrida es a las 21:59
  -- La Edge Function corta a los 20 s. Con 60 no queda hueco ni aunque el
  -- cron se adelante. El cron corre cada 5 min, asi que en operacion normal
  -- esto no rechaza nada: es la red por si alguien lo dispara a mano.
  espera      interval := interval '60 seconds';
  ultimo      timestamptz;
begin
  local_ahora := (now() at time zone 'America/Tijuana');
  h := extract(hour from local_ahora)::int;

  if h < desde_hora or h >= hasta_hora then
    return 'taller cerrado (son las ' || to_char(local_ahora, 'HH24:MI') ||
           ' en Mexicali), no se llamo a Jibble';
  end if;

  -- ⚠️ Aqui vivia `pg_try_advisory_xact_lock`, y NO SERVIA DE NADA: ese lock
  -- dura lo que dura la transaccion, y `net.http_get` es asincrono (devuelve
  -- en cuanto encola). El lock se soltaba antes de que la Edge Function
  -- empezara siquiera, asi que jamas pudo impedir el solape que decia
  -- impedir. Una marca de tiempo en una tabla si sobrevive entre
  -- transacciones, que es lo unico que sirve cuando el trabajo ocurre
  -- afuera de la base.
  --
  -- El `update ... where` hace las dos cosas de un golpe —comprobar y
  -- apartar—, asi que dos corridas simultaneas no pueden pasar las dos:
  -- la segunda no encuentra fila que actualizar.
  update public.jibble_disparos
     set ultimo_disparo = now()
   where uno
     and (ultimo_disparo is null or now() - ultimo_disparo >= espera)
  returning ultimo_disparo into ultimo;

  if ultimo is null then
    return 'la corrida anterior es de hace menos de ' || espera || ', esta se salta';
  end if;

  perform net.http_get(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/sincronizar-jibble',
    timeout_milliseconds := 20000
  );

  return 'sincronizado (' || to_char(local_ahora, 'HH24:MI') || ' en Mexicali)';
end;
$function$;
