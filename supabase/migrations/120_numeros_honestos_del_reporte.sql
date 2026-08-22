-- =====================================================================
-- 120 - Los numeros del reporte dejan de mentir en tres lugares
--
--  1. "Devoluciones" no eran devoluciones. La pantalla restaba
--     `cancelados - borrados` y le ponia ese nombre. Medido el 21/ago: de
--     esas 31 cancelaciones, solo **6** tenian un reembolso de Zettle
--     detras; las otras **25** son cancelaciones a mano (los carros
--     atorados del 24/jul, limpiezas de prueba). Llamarles devolucion es
--     inventar una falla de servicio que no ocurrio.
--
--  2. La devolucion DESPUES de entregar no existia. El §13 la describe como
--     la senal de calidad mas cara que hay —"algo salio mal y le regresamos
--     su dinero para no perder al cliente"— y dice textualmente que hoy es
--     invisible. Ya no: hay **1** en toda la historia (el carro 70 del
--     19/jul, un Completo Cera de $270 devuelto un minuto despues de
--     entregarse; el mismo que §12.1 ya senalaba por otro camino).
--
--  3. `trabajadores()` y `perfil_de_secador()` no aplicaban el filtro de
--     `tiempo_imposible` (37 carros en la base). El reporte los descarta de
--     sus promedios por ser ficcion, pero las dos pantallas donde se evalua
--     a una persona CON NOMBRE se los contaban como lavados. Es la misma
--     clase que la `106` ya corrigio con los rechazos: la regla existia y no
--     habia llegado a estas dos.
--
-- Solo se AGREGAN campos al reporte; ningun valor viejo cambia, asi que los
-- dias ya congelados siguen siendo validos y la pantalla cae de pie si no
-- los trae (mismo criterio que la `107`).
--
-- ⚠️ La llave del reembolso es `refundsPurchaseUuid`. Se comprobo contra las
-- 2,860 ventas: 7 la traen y CERO traen `refundsPurchaseUUID1`. Se lee con
-- `detalle_venta()`, no desarmando el payload a mano — Zettle manda el aviso
-- envuelto unas veces y plano otras, y esa es la trampa que ya costo la 115
-- y la 118.
--
-- Las tres funciones son largas y llenas de razones escritas. NO se copian:
-- se le pide a Postgres su definicion, se cambia lo justo y se vuelve a
-- crear (patron de la `116`). Si el ancla no aparece, se cae con un mensaje
-- claro en vez de aplicar algo a medias.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1 y 2) El reporte: dos campos nuevos
-- ---------------------------------------------------------------------
do $$
declare
  d         text;
  ancla_cte text := E'  with\n  del_dia as (';
  cte_nuevo text := E'  with\n'
    || E'  -- Las ventas que son un REEMBOLSO de otra. Se calcula UNA vez aqui y\n'
    || E'  -- no por carro: el reporte se llama una vez por dia consultado.\n'
    || E'  devueltas as (\n'
    || E'    select distinct public.detalle_venta(v.payload)->>''refundsPurchaseUuid'' as purchase_uuid\n'
    || E'      from public.ventas v\n'
    || E'     where public.detalle_venta(v.payload) ? ''refundsPurchaseUuid''\n'
    || E'  ),\n'
    || E'  del_dia as (';
  ancla_campo text := E'    ''borrados'', (\n'
    || E'      select count(*)::int from public.carros c\n'
    || E'       where not c.es_prueba\n'
    || E'         and c.cancelado_motivo = ''borrado_supervisor''\n'
    || E'         and c.creado_en >= arranca and c.creado_en < termina\n'
    || E'    ),';
  campo_nuevo text := E'    ''borrados'', (\n'
    || E'      select count(*)::int from public.carros c\n'
    || E'       where not c.es_prueba\n'
    || E'         and c.cancelado_motivo = ''borrado_supervisor''\n'
    || E'         and c.creado_en >= arranca and c.creado_en < termina\n'
    || E'    ),\n'
    || E'\n'
    || E'    -- NUEVO (120): una DEVOLUCION de verdad es una venta de Zettle que\n'
    || E'    -- apunta a otra. La pantalla venia restando `cancelados - borrados` y\n'
    || E'    -- llamandole asi; de 31, solo 6 tenian reembolso detras.\n'
    || E'    ''devoluciones'', (\n'
    || E'      select count(*)::int from public.carros c\n'
    || E'       where not c.es_prueba\n'
    || E'         and c.cancelado_en is not null\n'
    || E'         and c.creado_en >= arranca and c.creado_en < termina\n'
    || E'         and exists (select 1 from devueltas dv where dv.purchase_uuid = c.purchase_uuid)\n'
    || E'    ),\n'
    || E'\n'
    || E'    -- NUEVO (120): la senal del §13 que nunca se construyo. Devolver\n'
    || E'    -- DESPUES de entregar no cancela el carro (el trabajo existio y se\n'
    || E'    -- cuenta), pero es la falla de servicio mas cara: el rechazo se ataja\n'
    || E'    -- antes de que el cliente se vaya; esto, cuando ya se fue molesto.\n'
    || E'    ''devoluciones_tras_entregar'', (\n'
    || E'      select count(*)::int from public.carros c\n'
    || E'       where not c.es_prueba\n'
    || E'         and c.cancelado_en is null\n'
    || E'         and c.entregado_en is not null\n'
    || E'         and c.creado_en >= arranca and c.creado_en < termina\n'
    || E'         and exists (select 1 from devueltas dv where dv.purchase_uuid = c.purchase_uuid)\n'
    || E'    ),';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname = 'reporte_del_rango';
  if d is null then raise exception 'No existe public.reporte_del_rango'; end if;
  -- Re-correr este archivo no puede meter los campos DOS veces: el ancla
  -- `borrados` sigue existiendo despues de aplicarlo, asi que un segundo
  -- `replace` los duplicaria. Se sale antes.
  if position('devoluciones_tras_entregar' in d) > 0 then
    raise notice 'reporte_del_rango ya trae los campos nuevos, no se toca';
    return;
  end if;
  if position(ancla_cte in d) = 0 then
    raise exception 'No aparece el arranque de las CTEs en reporte_del_rango. Revisar a mano.';
  end if;
  if position(ancla_campo in d) = 0 then
    raise exception 'No aparece el bloque `borrados` en reporte_del_rango. Revisar a mano.';
  end if;
  d := replace(d, ancla_cte, cte_nuevo);
  d := replace(d, ancla_campo, campo_nuevo);
  execute d;
end $$;

-- ---------------------------------------------------------------------
-- 3) tiempo_imposible fuera de las dos pantallas de personas
-- ---------------------------------------------------------------------
do $$
declare
  d text;
  -- En `trabajadores` la linea `and not c.es_prueba and c.cancelado_en is null`
  -- aparece DOS veces (lavados y rechazos), asi que cada ancla lleva la linea
  -- de arriba, que si las distingue.
  a_lav  text := E'     where a.empleado_id is not null\n       and not c.es_prueba and c.cancelado_en is null';
  n_lav  text := E'     where a.empleado_id is not null\n       and not c.es_prueba and c.cancelado_en is null\n'
                 || E'       -- Un carro con tiempo imposible es un error de captura, no trabajo:\n'
                 || E'       -- el reporte ya lo descarta y aqui se le contaba a una persona con\n'
                 || E'       -- nombre. Misma clase que la 106 con los rechazos.\n'
                 || E'       and not coalesce(c.tiempo_imposible, false)';
  a_rech text := E'     where rz.empleado_id is not null\n       and not c.es_prueba and c.cancelado_en is null';
  n_rech text := E'     where rz.empleado_id is not null\n       and not c.es_prueba and c.cancelado_en is null\n'
                 || E'       and not coalesce(c.tiempo_imposible, false)';
  a_perf text := E'     where a.empleado_id = p_empleado\n       and not c.es_prueba and c.cancelado_en is null';
  n_perf text := E'     where a.empleado_id = p_empleado\n       and not c.es_prueba and c.cancelado_en is null\n'
                 || E'       -- Ver `trabajadores`: el filtro vive aqui, en el unico lugar del que\n'
                 || E'       -- salen el conteo, los rechazos y la tabla.\n'
                 || E'       and not coalesce(c.tiempo_imposible, false)';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname = 'trabajadores';
  if d is null then raise exception 'No existe public.trabajadores'; end if;
  if position(a_lav in d) = 0 or position(a_rech in d) = 0 then
    raise exception 'No aparecen las anclas en trabajadores(). Revisar a mano.';
  end if;
  d := replace(d, a_lav, n_lav);
  d := replace(d, a_rech, n_rech);
  execute d;

  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname = 'perfil_de_secador';
  if d is null then raise exception 'No existe public.perfil_de_secador'; end if;
  if position(a_perf in d) = 0 then
    raise exception 'No aparece el ancla en perfil_de_secador(). Revisar a mano.';
  end if;
  execute replace(d, a_perf, n_perf);
end $$;

-- ---------------------------------------------------------------------
-- 4) Y el indice que hace que lo de arriba no cueste caro
--
-- Sin esto, cada llamada al reporte recorre las 2,860 ventas desenvolviendo
-- el payload de cada una para encontrar 7 reembolsos: 156 ms medidos, y el
-- reporte se llama UNA VEZ POR DIA CONSULTADO — un rango de un mes serian
-- casi 5 segundos de puro buscar devoluciones.
--
-- Es un indice de expresion PARCIAL, y las dos cosas importan: la expresion
-- porque el dato vive dentro del jsonb, y parcial porque solo 7 de 2,860
-- filas son un reembolso. Se puede porque `detalle_venta` es IMMUTABLE
-- (verificado); si algun dia dejara de serlo, este indice no se podria
-- crear y habria que volver al recorrido.
-- ---------------------------------------------------------------------
create index if not exists ventas_reembolso_idx
  on public.ventas ((public.detalle_venta(payload) ->> 'refundsPurchaseUuid'))
  where public.detalle_venta(payload) ? 'refundsPurchaseUuid';
