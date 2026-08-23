-- 129 · La regla de cortesia por fin llega al import del ClientNoteTracker
--
-- Hallazgo de la auditoria del 21/ago, confirmado por sus dos refutadores.
-- `visitas.es_cortesia` era `true` en 1 de 15,068 filas: la prueba del dueno
-- del 15/ago. Todas las demas cortesias del ano estaban contadas como CANJE.
--
-- El `CLAUDE.md §11.70` dice que una cortesia (`Gratis` + variante que NO empieza
-- con `6to`) "ni suma sello ni consume gratis", y esa regla vive en
-- `clase_de_gratis()`. El camino de la CAJA la consulta; el del IMPORT no. Es el
-- patron de siempre en este proyecto: **el camino que no llama a la funcion se
-- brinca la regla**, igual que paso con "un lavado, un cliente" (migracion 114).
--
-- LO QUE CUESTA, MEDIDO Y CON NOMBRE (23/ago/2026):
--   11 visitas de 7 personas contadas como canje siendo cortesia. La peor,
--   `reynaldo inojosa ramirez`: 33 lavados pagados = 6 gratis ganados, pero
--   9 canjes registrados y 0 disponibles. Cuatro de esos 9 son cortesias. Sin
--   ellas son 5 y le queda 1 gratis disponible: el negocio le debe un lavado.
--   `lealtad_por_persona` lo tapaba con `greatest(0, ...)`, y por eso nunca se vio.
--
-- DONDE SE PONE LA REGLA, Y POR QUE AHI
--
-- No en los tres scripts del import (import.sql, import-incremental.sql y el
-- dryrun): copiarla tres veces es exactamente como se desfasan las cosas aqui.
-- Va dentro de `ligar_visitas_de_import()` -- la funcion que la migracion 118
-- creo justamente porque los tres la llamaban copiada, y que los tres YA llaman.
-- Es el unico cuello por el que pasa todo import, presente y futuro.
--
-- La funcion NO se reescribe: son ~90 lineas de reglas con sus razones escritas
-- y rehacerlas para agregar una linea es el movimiento que ya salio mal aqui
-- (§11.45). Se le pide a Postgres su propia definicion, se le inserta UNA linea
-- en un ancla comprobada, y se vuelve a crear. Si el ancla no aparece, la
-- migracion se cae en vez de aplicar algo a medias.

-- ---------------------------------------------------------------------------
-- 1) De que clase es el gratis de este ticket. UNA sola funcion.
--
-- Dos fuentes, las dos de Zettle y en este orden:
--   a) `ventas`          -- lo que llego por webhook (del 19/jul en adelante).
--                           El payload viene envuelto o plano, asi que se
--                           desarma con `detalle_venta()` y no a mano: es la
--                           mina que las migraciones 115 y 118 ya desactivaron
--                           en otras cuatro funciones.
--   b) `zettle_compras`  -- el historico traido por REST para el CRM. Su payload
--                           tiene OTRA forma (`productos[].nombre/variante`, en
--                           espanol), no la del webhook. Medido: de 14,474
--                           visitas con ticket, 12,713 cruzan aqui.
--
-- Devuelve NULL cuando el ticket no se resuelve o el lavado no es gratis. Ese
-- NULL es la respuesta correcta y quien la use NO debe tocar nada: 41 visitas
-- traen `es_gratis` del ClientNoteTracker sin ticket que lo respalde, y
-- desmarcarlas a ciegas seria quitarle un lavado a alguien por falta de dato.
create or replace function public.clase_de_gratis_del_ticket(p_ticket text)
returns text
language sql
stable
as $function$
  with t as (
    select case when btrim(coalesce(p_ticket,'')) ~ '^[0-9]+$'
                then btrim(p_ticket)::int end as num
  )
  select coalesce(
    (select max(public.clase_de_gratis(pr->>'name', pr->>'variantName'))
       from public.ventas ve
       join t on ve.ticket_num = t.num
       cross join lateral jsonb_array_elements(
         coalesce(public.detalle_venta(ve.payload) -> 'products', '[]'::jsonb)) pr),
    (select max(public.clase_de_gratis(pr->>'nombre', pr->>'variante'))
       from public.zettle_compras z
       join t on z.purchase_number = t.num
       cross join lateral jsonb_array_elements(
         coalesce(z.payload -> 'productos', '[]'::jsonb)) pr)
  );
$function$;

comment on function public.clase_de_gratis_del_ticket(text) is
  'Canje / cortesia / NULL segun el ticket de Zettle. Consulta ventas (webhook, '
  'con detalle_venta) y zettle_compras (historico REST, payload en espanol). '
  'NULL = no se pudo resolver o no es gratis: quien la use no debe tocar nada.';

-- ---------------------------------------------------------------------------
-- 2) Aplicar la regla a las visitas del import. EL TICKET MANDA, igual que en la
--    caja (`CLAUDE.md §11.70`): si el ticket dice cortesia, es cortesia aunque
--    el ClientNoteTracker la haya anotado como gratis, y al reves.
create or replace function public.aplicar_clase_de_gratis_del_import()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_cort  int := 0;
  v_canje int := 0;
begin
  -- Cortesia: ni suma sello ni consume gratis.
  update public.visitas vi
     set es_gratis = false, es_cortesia = true
   where vi.caja = 'import'
     and vi.estado = 'activa'
     and (vi.es_gratis or not vi.es_cortesia)
     and public.clase_de_gratis_del_ticket(vi.ticket) = 'cortesia';
  get diagnostics v_cort = row_count;

  -- Canje: consume un gratis y NO es cortesia.
  update public.visitas vi
     set es_gratis = true, es_cortesia = false
   where vi.caja = 'import'
     and vi.estado = 'activa'
     and (not vi.es_gratis or vi.es_cortesia)
     and public.clase_de_gratis_del_ticket(vi.ticket) = 'canje';
  get diagnostics v_canje = row_count;

  return jsonb_build_object('cortesias', v_cort, 'canjes', v_canje);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Que TODO import la aplique, sin que nadie tenga que acordarse.
--    Cirugia sobre la definicion viva, no una reescritura.
do $do$
declare
  def   text;
  ancla text;
  nuevo text;
begin
  ancla := chr(10) || '  return jsonb_build_object(';
  nuevo := chr(10)
        || '  -- La clase del gratis (canje vs cortesia) sale del TICKET, no de lo' || chr(10)
        || '  -- que anoto el ClientNoteTracker. Va aqui y no en los tres scripts' || chr(10)
        || '  -- del import por la misma razon por la que este ligado vive aqui:' || chr(10)
        || '  -- copiada tres veces se desfasa. Ver migracion 129.' || chr(10)
        || '  perform public.aplicar_clase_de_gratis_del_import();' || chr(10)
        || chr(10) || '  return jsonb_build_object(';

  select pg_get_functiondef('public.ligar_visitas_de_import()'::regprocedure) into def;

  if position('aplicar_clase_de_gratis_del_import' in def) > 0 then
    raise notice 'ligar_visitas_de_import ya la llamaba; no se toca';
  elsif position(ancla in def) = 0 then
    raise exception 'El ancla no aparece en ligar_visitas_de_import: la funcion cambio, revisar a mano';
  else
    execute replace(def, ancla, nuevo);
    raise notice 'ligar_visitas_de_import: paso de clase de gratis insertado';
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- 4) Corregir lo ya guardado, y comprobar que no queda nada.
do $do$
declare
  r      jsonb;
  quedan int;
begin
  r := public.aplicar_clase_de_gratis_del_import();
  raise notice 'Corregidas -> %', r;

  select count(*) into quedan
    from public.visitas vi
   where vi.caja = 'import' and vi.estado = 'activa'
     and public.clase_de_gratis_del_ticket(vi.ticket) = 'cortesia'
     and (vi.es_gratis or not vi.es_cortesia);
  if quedan > 0 then
    raise exception 'Quedaron % cortesias contadas como canje', quedan;
  end if;

  select count(*) into quedan
    from public.visitas vi
   where vi.caja = 'import' and vi.estado = 'activa'
     and public.clase_de_gratis_del_ticket(vi.ticket) = 'canje'
     and (not vi.es_gratis or vi.es_cortesia);
  if quedan > 0 then
    raise exception 'Quedaron % canjes sin marcar', quedan;
  end if;

  -- Y el caso con nombre del hallazgo: si esto no se cumple, no se arreglo nada.
  select disponibles into quedan
    from public.lealtad_por_persona where persona_id = 49;
  if coalesce(quedan,0) < 1 then
    raise exception 'reynaldo inojosa ramirez sigue con % gratis disponibles: el arreglo no sirvio', quedan;
  end if;

  raise notice 'OK: la cortesia ya no consume gratis, y reynaldo recupero su lavado';
end
$do$;
