-- =====================================================================
-- 115 - Lo que el dueno decidio el 19/ago, y tres de la auditoria
--
--   * Retencion de fotos a 60 dias (decision del dueno).
--   * #22  ventas_indexar desarma el payload a mano y deja ventas invisibles.
--   * #25  las busquedas no tienen indice: 898 ms la de tickets.
--   * #25  sincronizar-jibble sin candado, y cada minuto.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Retencion de fotos: 90 -> 60 dias
--
-- Decision del dueno (19/ago/2026), sobre el hallazgo #8: a 90 dias el
-- Storage llega al 77% del limite de 1 GB en regimen; a 60 baja al 51%. Es
-- la unica palanca real, y las fotos viejas no le sirven para nada.
--
-- Medido hoy: la foto mas vieja tiene 33 dias, asi que a 60 dias NO se
-- borra nada todavia. La primera corrida real se adelanta de ~17/oct a
-- ~17/sep. El tope de 1,000 por corrida (105) sigue puesto.
--
-- ⚠️ El otro lado del numero vive en `supabase/functions/limpiar-fotos`
-- (const DIAS). Los dos se cambian juntos o el default de aqui no sirve de
-- nada, porque la Edge Function siempre manda el suyo.
-- ---------------------------------------------------------------------
--
-- ⚠️ El cuerpo NO se reescribio: se saco de la base con
-- `pg_get_functiondef` y se le cambio UNICAMENTE el default. Escribir una
-- funcion viva de memoria ya salio mal una vez en este proyecto (la
-- `sincronizar_empleados` de la segunda tanda, §11.45).
create or replace function public.olvidar_fotos_viejas(
  p_dias integer default 60,
  p_borradas text[] default null::text[]
) returns integer
language plpgsql
security definer
set search_path to 'public'
as $func$
declare
  cuantos int;
begin
  update public.carros
     set foto_path = null, foto_url = null, foto_url_expira = null
   where foto_path is not null
     -- `coalesce` con creado_en: hay 2 carros con foto y sin `foto_en`, y con
     -- el `is not null` de antes su liga se quedaba muerta para siempre.
     and coalesce(foto_en, creado_en) < now() - make_interval(days => p_dias)
     -- Si se pasa la lista de lo que de verdad se borro, solo esos.
     and (p_borradas is null or foto_path = any(p_borradas));
  get diagnostics cuantos = row_count;
  return cuantos;
end;
$func$;

comment on function public.olvidar_fotos_viejas(int, text[]) is
  'Despunta las fotos que la Edge Function ya borro del almacen. Retencion 60 dias desde la 115 (decision del dueno); el numero que manda es el de limpiar-fotos.';


-- ---------------------------------------------------------------------
-- #22 - ventas_indexar desarmaba el payload a mano, y por eso hay ventas
--       que la caja no puede encontrar
--
-- Miraba UNA sola forma del aviso:
--
--     pj := (NEW.payload->>'payload')::jsonb
--
-- O sea que solo funciona cuando Zettle manda el evento envuelto en una
-- llave `payload`. Cuando llega sin envolver, `pj` queda nulo y NO se
-- indexa NADA: ni `ticket_num`, ni `cajero`, ni `prods`, ni `busqueda`.
-- La venta se guarda —el dinero no se pierde— pero se vuelve invisible
-- para `buscar_tickets`, `tickets_recientes` y `ticket_detalle`: la cajera
-- no la encuentra aunque el cliente tenga el ticket en la mano.
--
-- `detalle_venta()` ya sabe desenvolver las dos formas y es la que usa el
-- trigger que crea el carro — por eso el CARRO si se creaba y el ticket no
-- aparecia. Era la misma pregunta contestada de dos maneras distintas en
-- dos lugares, que es el patron que la auditoria conto seis veces.
-- ---------------------------------------------------------------------
create or replace function public.ventas_indexar()
returns trigger
language plpgsql
as $func$
declare pj jsonb;
begin
  -- UNA sola regla para desenvolver el aviso, la de siempre.
  pj := public.detalle_venta(NEW.payload);

  if pj is not null then
    NEW.ticket_num := case when pj->>'purchaseNumber' ~ '^[0-9]+$'
                           then (pj->>'purchaseNumber')::int end;
    NEW.cajero := pj->>'userDisplayName';
    NEW.prods  := pj->'products';
    NEW.busqueda := lower(unaccent(
      coalesce(pj->>'purchaseNumber','') || ' ' || coalesce(pj->>'userDisplayName','') || ' ' ||
      coalesce((select string_agg(
                  coalesce(p->>'name','') || ' ' || coalesce(p->>'variantName',''), ' ')
                from jsonb_array_elements(pj->'products') p), '')
    ));
  end if;
  return NEW;
end;
$func$;

comment on function public.ventas_indexar() is
  'Llena ticket_num/cajero/prods/busqueda al guardar una venta. Usa detalle_venta (115): antes desarmaba el payload a mano de UNA forma, y las ventas que llegaban con la otra quedaban invisibles para la caja.';

-- Y las que ya entraron torcidas se enderezan. `update ... set payload =
-- payload` dispara el trigger BEFORE sin cambiar el dato.
update public.ventas
   set payload = payload
 where ticket_num is null
   and (public.detalle_venta(payload))->>'purchaseNumber' is not null;


-- ---------------------------------------------------------------------
-- #25 - las busquedas no tenian indice
--
-- Medido antes: `buscar_tickets('completo')` **898 ms**, `buscar_personas
-- ('gonz')` **251 ms**. La cajera teclea y espera casi un segundo por
-- ronda, y el dueno acaba de decir que la caja SI se va a usar.
--
-- Las cuatro busquedas son de subcadena (`%algo%`), que ningun indice
-- normal puede servir: hay que usar trigramas.
--
-- ⚠️ Y para que el indice se pueda usar hay que cambiar `strpos(x, q) > 0`
-- por `x like '%q%'`. Son equivalentes SALVO que la busqueda traiga `%` o
-- `_`, que en LIKE son comodines: sin escaparlos, una cajera buscando
-- "50%" cambiaria el significado de la consulta. Por eso se escapan.
-- ---------------------------------------------------------------------
create extension if not exists pg_trgm;

create index if not exists personas_nombre_trgm
  on public.personas using gin (nombre_norm gin_trgm_ops);

create index if not exists persona_placas_trgm
  on public.persona_placas using gin (placa_norm gin_trgm_ops);

create index if not exists zettle_compras_busqueda_trgm
  on public.zettle_compras using gin (busqueda gin_trgm_ops);

create index if not exists ventas_busqueda_trgm
  on public.ventas using gin (busqueda gin_trgm_ops);

-- Escapa los comodines de LIKE para que una busqueda con `%` o `_` se
-- busque literal. Vive en una funcion porque la usan los dos lados de la
-- union de abajo.
create or replace function public.como_literal(p_texto text)
returns text
language sql
immutable
as $func$
  select replace(replace(replace(coalesce(p_texto, ''), '\', '\\'), '%', '\%'), '_', '\_');
$func$;

comment on function public.como_literal(text) is
  'Escapa los comodines de LIKE (%, _ y la propia barra) para poder buscar subcadenas con indice trigram sin que la busqueda del usuario cambie el significado.';

create or replace function public.buscar_tickets(
  p_q text, p_limite integer default 30, p_offset integer default 0
) returns jsonb
language sql
stable
as $func$
  with q as (
    select lower(unaccent(coalesce(p_q, ''))) as needle,
           '%' || public.como_literal(lower(unaccent(coalesce(p_q, '')))) || '%' as patron
  ),
  base as (
    select zc.purchase_number as ticket, zc.hora, zc.monto, zc.cajero,
           zc.payload->'productos' as prods_z, null::jsonb as prods_v
    from public.zettle_compras zc, q
    where zc.busqueda is not null and zc.busqueda like q.patron

    union all

    select v.ticket_num as ticket, v.creado_en as hora, v.monto, v.cajero,
           null::jsonb as prods_z, v.prods as prods_v
    from public.ventas v, q
    where v.ticket_num is not null
      and coalesce(v.busqueda, '') like q.patron
      and not exists (
        select 1 from public.zettle_compras zc where zc.purchase_number = v.ticket_num)
  ),
  pagina as (
    select distinct on (ticket) ticket, hora, monto, cajero, prods_z, prods_v
    from base
    order by ticket desc, hora desc
    limit greatest(p_limite, 0)
    offset greatest(p_offset, 0)
  )
  select coalesce(jsonb_agg(to_jsonb(t) order by t.ticket desc), '[]'::jsonb)
  from (
    select ticket, hora, monto, cajero,
           coalesce(
             (select string_agg(
                       btrim((pr->>'nombre') || ' ' || coalesce(pr->>'variante','')), ', ')
                from jsonb_array_elements(prods_z) pr),
             (select string_agg(
                       btrim((pr->>'name') || ' ' || coalesce(pr->>'variantName','')), ', ')
                from jsonb_array_elements(prods_v) pr)
           ) as descripcion
    from pagina
  ) t;
$func$;

comment on function public.buscar_tickets(text, integer, integer) is
  'Busca tickets por numero, cajera o producto. Usa LIKE con comodines escapados para poder apoyarse en el indice trigram (115): con strpos eran 898 ms.';


-- ---------------------------------------------------------------------
-- #25 - sincronizar-jibble no tenia candado
--
-- `limpiar-fotos` si lo tiene y esta no. Si una corrida se atora (la API de
-- Jibble tarda, el timeout son 20 s pero el cron dispara cada minuto), la
-- siguiente entra encima: dos barridas simultaneas marcando `fuera` y
-- `activo` sobre la misma tabla.
--
-- El candado es de sesion y NO bloquea: si no lo consigue, se sale y ya.
-- La proxima corrida lo intenta. Es lo correcto para algo que se repite
-- solo: esperar seria encolar corridas que ya no sirven.
-- ---------------------------------------------------------------------
create or replace function public.sincronizar_jibble_si_toca()
returns text
language plpgsql
as $func$
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

  -- try, no wait: si otra corrida sigue adentro, esta se va.
  if not pg_try_advisory_xact_lock(hashtext('sincronizar-jibble')) then
    return 'ya hay una sincronizacion corriendo, esta se salta';
  end if;

  perform net.http_get(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/sincronizar-jibble',
    timeout_milliseconds := 20000
  );

  return 'sincronizado (' || to_char(local_ahora, 'HH24:MI') || ' en Mexicali)';
end;
$func$;

comment on function public.sincronizar_jibble_si_toca() is
  'Llama a la sincronizacion de Jibble solo dentro del horario local de Mexicali, y solo si no hay otra corriendo (115).';


-- ---------------------------------------------------------------------
-- Y el cron pasa de cada minuto a cada 5
--
-- Refrescar quien esta checado son 19 personas; cada minuto es refrescar
-- un dato que cambia dos o tres veces al dia. De ~960 corridas diarias a
-- ~192, y de ~4,800 llamadas a Jibble a ~960.
--
-- ⚠️ `calentar-webhook` se queda en CADA MINUTO, a proposito, aunque la
-- auditoria proponia moverlo tambien. Su unico trabajo es que la funcion
-- del webhook no este fria cuando Zettle avise una venta, y las ventas
-- llegan a cualquier hora. El ahorro es de $0 —el plan gratis aguanta de
-- sobra: son ~29 mil invocaciones al mes contra un limite de 500 mil— y a
-- cambio se arriesga un 502 en el camino por donde entra el dinero. Mal
-- trato. Su guardia de horario ya le quita las 8 horas de la noche.
-- ---------------------------------------------------------------------
select cron.schedule('sincronizar-jibble', '*/5 * * * *',
                     'select public.sincronizar_jibble_si_toca();');
