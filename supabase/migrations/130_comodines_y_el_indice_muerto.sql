-- 130 · Los comodines dejan de cambiar el sentido de la busqueda, y el indice
--       muerto se cambia por el que si sirve
--
-- Dos hallazgos de la auditoria del 21/ago, los dos 🔵 pero con consecuencias
-- distintas: el primero le puede dar a la cajera el cliente equivocado, el
-- segundo solo cuesta tiempo.
--
-- 1) LA REGLA DE ESCAPAR COMODINES VIVE EN `como_literal()` Y SOLO 1 DE LAS 3
--    BUSQUEDAS LA USA.
--
--    `buscar_tickets` la aplica desde la migracion 116, cuando el cambio de
--    `strpos()` a `like` lo hizo necesario. `buscar_personas` y
--    `buscar_vehiculos` se quedaron sin ella. Medido hoy, antes de tocar:
--
--        buscar_personas('%')       -> 25 clientes cualquiera
--        buscar_personas('_')       -> 25 clientes cualquiera
--        buscar_personas('LUIS_G')  -> 7  (el `_` casa con cualquier letra)
--        buscar_vehiculos('%')      -> 50 placas cualquiera
--
--    No es cosmetico: la cajera teclea, ve una lista con cara de resultado
--    bueno, y toca al cliente equivocado -- que es justo lo que el buscador
--    existe para evitar. `buscar_tickets` ya devolvia 0 en los dos casos.
--
--    ⚠️ Se comprobo que `normalizar_nombre` y `normalizar_placa` CONSERVAN el
--    `%` y el `_` (no los limpian), asi que escapar es de verdad el arreglo y
--    no un parche encima de otra cosa.
--
-- 2) `ventas_purchase_number_idx` NO SIRVE A NINGUNA CONSULTA VIVA.
--    Esta construido sobre `(payload->>'payload')::jsonb ->> 'purchaseNumber'`,
--    o sea la forma ENVUELTA del aviso -- exactamente la que la migracion 115
--    declaro equivocada porque Zettle tambien lo manda plano. Ninguna consulta
--    pregunta ya asi (todas pasan por `detalle_venta()`), asi que el indice solo
--    cuesta: se evalua esa expresion en CADA insert de `ventas`.
--
--    Se reemplaza por el mismo indice sobre la expresion QUE SI SE USA, que es
--    la del join de `ligar_visitas_de_import()`. No se borra a secas: ahi hay
--    una consulta real que hoy hace Seq Scan.

-- ---------------------------------------------------------------------------
-- 1a) buscar_personas. Cirugia sobre la definicion viva: la funcion lleva sus
--     comentarios (por que una placa puede ligar a varias personas) y
--     reescribirla los perderia.
do $do$
declare
  def text;
  a1  text := 'p.nombre_norm like ''%'' || public.normalizar_nombre(p_q) || ''%''';
  n1  text := 'p.nombre_norm like ''%'' || public.como_literal(public.normalizar_nombre(p_q)) || ''%''';
  a2  text := 'pp.placa_norm like ''%'' || public.normalizar_placa(p_q) || ''%''';
  n2  text := 'pp.placa_norm like ''%'' || public.como_literal(public.normalizar_placa(p_q)) || ''%''';
begin
  select pg_get_functiondef('public.buscar_personas(text)'::regprocedure) into def;

  if position('como_literal' in def) > 0 then
    raise notice 'buscar_personas ya escapaba; no se toca';
  else
    if position(a1 in def) = 0 or position(a2 in def) = 0 then
      raise exception 'buscar_personas no tiene las anclas esperadas: revisar a mano';
    end if;
    def := replace(replace(def, a1, n1), a2, n2);
    execute def;
    raise notice 'buscar_personas: comodines escapados';
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- 1b) buscar_vehiculos. Aqui el patron se usa en CUATRO lugares, asi que se
--     escapa UNA vez en el CTE `q` y los cuatro quedan cubiertos -- en vez de
--     cuatro parches que se pueden desfasar.
--
--     El `nullif(..., '')` de afuera no es adorno: `como_literal(null)` devuelve
--     cadena vacia (lleva `coalesce` adentro), y sin el, `q.placa_q is not null`
--     seria SIEMPRE cierto y la busqueda por placa se dispararia con cualquier
--     texto.
do $do$
declare
  def text;
  a1  text := 'select nullif(public.normalizar_placa(p_q), '''')  as placa_q,';
  n1  text := 'select nullif(public.como_literal(nullif(public.normalizar_placa(p_q), '''')), '''')  as placa_q,';
  a2  text := 'nullif(public.normalizar_nombre(p_q), '''') as texto_q';
  n2  text := 'nullif(public.como_literal(nullif(public.normalizar_nombre(p_q), '''')), '''') as texto_q';
begin
  select pg_get_functiondef('public.buscar_vehiculos(text)'::regprocedure) into def;

  if position('como_literal' in def) > 0 then
    raise notice 'buscar_vehiculos ya escapaba; no se toca';
  else
    if position(a1 in def) = 0 or position(a2 in def) = 0 then
      raise exception 'buscar_vehiculos no tiene las anclas esperadas: revisar a mano';
    end if;
    def := replace(replace(def, a1, n1), a2, n2);
    execute def;
    raise notice 'buscar_vehiculos: comodines escapados';
  end if;
end
$do$;

-- ---------------------------------------------------------------------------
-- 2) El indice muerto, por el que si sirve.
drop index if exists public.ventas_purchase_number_idx;

create index if not exists ventas_recibo_idx
  on public.ventas (((public.detalle_venta(payload) ->> 'purchaseNumber')));

comment on index public.ventas_recibo_idx is
  'Sirve al join de ligar_visitas_de_import (visita.ticket = recibo de la venta). '
  'Reemplaza a ventas_purchase_number_idx, que estaba sobre la forma ENVUELTA del '
  'aviso -- la que la migracion 115 declaro equivocada -- y no servia a nada vivo.';

-- ---------------------------------------------------------------------------
-- 3) Comprobaciones, dentro de la misma transaccion.
do $do$
declare
  n int;
begin
  -- Los comodines ya no cambian el sentido de la busqueda.
  if jsonb_array_length(public.buscar_personas('%')) <> 0 then
    raise exception 'FALLO: buscar_personas(%%) sigue devolviendo % resultados',
      jsonb_array_length(public.buscar_personas('%'));
  end if;
  if jsonb_array_length(public.buscar_personas('_')) <> 0 then
    raise exception 'FALLO: buscar_personas(_) sigue devolviendo resultados';
  end if;
  if jsonb_array_length(public.buscar_vehiculos('%')) <> 0
     or jsonb_array_length(public.buscar_vehiculos('_')) <> 0 then
    raise exception 'FALLO: buscar_vehiculos sigue tratando los comodines como comodines';
  end if;

  -- Y las busquedas de verdad NO cambian. Si esto se rompe, se rompio el CRM.
  if jsonb_array_length(public.buscar_personas('gonz')) <> 25
     or jsonb_array_length(public.buscar_personas('luis')) <> 25
     or jsonb_array_length(public.buscar_vehiculos('BVJ')) <> 1
     or jsonb_array_length(public.buscar_vehiculos('9XU')) <> 1
     or jsonb_array_length(public.buscar_vehiculos('toyota')) <> 50
     or jsonb_array_length(public.buscar_tickets('completo')) <> 30 then
    raise exception 'FALLO: una busqueda normal cambio de resultado';
  end if;

  -- El indice viejo se fue y el nuevo esta.
  select count(*) into n from pg_indexes
   where schemaname='public' and indexname='ventas_purchase_number_idx';
  if n <> 0 then raise exception 'FALLO: el indice muerto sigue ahi'; end if;

  select count(*) into n from pg_indexes
   where schemaname='public' and indexname='ventas_recibo_idx';
  if n <> 1 then raise exception 'FALLO: no se creo ventas_recibo_idx'; end if;

  raise notice 'OK: comodines literales, busquedas intactas, indice reemplazado';
end
$do$;
