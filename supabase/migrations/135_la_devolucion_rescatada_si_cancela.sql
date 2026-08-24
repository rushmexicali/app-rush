-- 135 · Una devolucion rescatada a mano por fin cancela su carro
--
-- Hallazgo del critico de completitud de la auditoria del 21-22/ago:
-- "`scripts/4-recuperar-venta.ps1` no sirve para rescatar una DEVOLUCION".
--
-- ---------------------------------------------------------------------------
-- EL CRITICO MIDIO BIEN Y CONCLUYO MAL, Y LAS DOS MITADES IMPORTAN
--
-- Su medicion, textual: "las 70 llaves de la respuesta REST no incluyen
-- `refundsPurchaseUuid`". **Es cierto.** Su conclusion -- que el dato no viene
-- y que por eso no hay forma de reconocer la devolucion -- **es falsa**: el
-- dato SI viene, con otro nombre. Comprobado hoy contra la API real, pidiendo
-- una devolucion de verdad (la de $300 del 4/ago):
--
--     webhook :  "refundsPurchaseUuid" : "0b1ef160-7eca-4738-8516-c8f1fdcf70d2"
--     REST v2 :  "refundsPurchaseUUID1": "0b1ef160-7eca-4738-8516-c8f1fdcf70d2"
--                "refundsPurchaseUUID" : "Cx7xYH7KRziFFsjx_c9w0g"
--                "refund": true
--
-- Es EXACTAMENTE la trampa que el CLAUDE.md §7 ya documenta para el otro
-- campo: "el webhook manda `purchaseUUID` con guiones; la API REST llama a ese
-- mismo valor `purchaseUUID1`". La misma trampa, en el campo de al lado, y
-- volvimos a caer.
--
-- ---------------------------------------------------------------------------
-- EL BUG ES REAL AUNQUE LA EXPLICACION FUERA OTRA
--
-- Tres cosas vivas cuelgan del nombre EXACTO `refundsPurchaseUuid`:
-- `crear_carro_desde_venta` (que cancela el carro original) y las dos CTE de
-- devoluciones de `reporte_del_rango`. Con el payload de REST guardado tal
-- cual, ninguna la reconoce:
--
--   * el carro original NO se cancela y se queda en la cola como si el
--     cliente siguiera esperando,
--   * y la devolucion no se cuenta -- justo el numero que la 120 acaba de
--     poner honesto.
--
-- Y el sintoma es MUDO: el monto negativo evita que se cree un carro nuevo,
-- asi que nada truena.
--
-- ---------------------------------------------------------------------------
-- DONDE SE ARREGLA, Y POR QUE AHI
--
-- No en el script. El trabajo del script es guardar lo que Zettle dio, tal
-- cual; interpretarlo es de `detalle_venta()`, que existe PRECISAMENTE para
-- dar una sola respuesta a "que trae esta venta" sin importar la forma. Esa
-- es la leccion de las migraciones 115 y 118: quien desarma el payload por su
-- cuenta entiende una sola forma y devuelve nulo con la otra.
--
-- Asi que `detalle_venta` aprende el alias. Reglas:
--
--   * Solo se agrega `refundsPurchaseUuid` cuando NO viene ya (el webhook
--     manda el suyo y ese siempre gana; nunca se pisa).
--   * Solo desde `refundsPurchaseUUID1`, el de los GUIONES -- el mismo
--     formato que usa `carros.purchase_uuid`. El `refundsPurchaseUUID` corto
--     (base64) es otro formato y compararlo no ligaria nada.
--   * Todo lo demas del payload se devuelve igual. No se inventa nada: es el
--     MISMO valor bajo el nombre que el resto del sistema ya usa.

create or replace function public.detalle_venta(p jsonb)
returns jsonb
language plpgsql
immutable
as $function$
declare
  d jsonb;
begin
  begin
    d := (p ->> 'payload')::jsonb;
  exception when others then
    d := null;
  end;

  if d is null or d -> 'products' is null then
    d := p;
  end if;

  -- La forma REST de la llave de devolucion. Ver el encabezado de la 135: el
  -- webhook la manda como `refundsPurchaseUuid` y la API REST como
  -- `refundsPurchaseUUID1`, con el MISMO valor. Sin esto, una devolucion
  -- rescatada con scripts/4-recuperar-venta.ps1 no cancela su carro y no se
  -- cuenta como devolucion, en silencio.
  if d is not null
     and not (d ? 'refundsPurchaseUuid')
     and nullif(btrim(coalesce(d ->> 'refundsPurchaseUUID1', '')), '') is not null then
    d := d || jsonb_build_object('refundsPurchaseUuid', d ->> 'refundsPurchaseUUID1');
  end if;

  return d;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Comprobacion. Es de solo lectura: no escribe ninguna fila.
do $do$
declare
  rest    jsonb;
  webhook jsonb;
  d       jsonb;
begin
  -- 1) La forma REST ahora se entiende.
  rest := jsonb_build_object(
    'products', jsonb_build_array(jsonb_build_object('name', 'Completo RUSH')),
    'refund', true,
    'refundsPurchaseUUID',  'Cx7xYH7KRziFFsjx_c9w0g',
    'refundsPurchaseUUID1', '0b1ef160-7eca-4738-8516-c8f1fdcf70d2',
    'purchaseUUID1', '8e7e2120-6098-40d2-9a01-ce2663cfd7a0'
  );
  d := public.detalle_venta(rest);
  if d ->> 'refundsPurchaseUuid' is distinct from '0b1ef160-7eca-4738-8516-c8f1fdcf70d2' then
    raise exception 'la forma REST sigue sin reconocerse (dio %)', d ->> 'refundsPurchaseUuid';
  end if;

  -- 2) El del webhook SIEMPRE gana: nunca se pisa lo que ya venia.
  webhook := jsonb_build_object(
    'products', jsonb_build_array(jsonb_build_object('name', 'Completo RUSH')),
    'refundsPurchaseUuid',  'el-bueno',
    'refundsPurchaseUUID1', 'el-otro'
  );
  if public.detalle_venta(webhook) ->> 'refundsPurchaseUuid' is distinct from 'el-bueno' then
    raise exception 'el alias piso la llave del webhook';
  end if;

  -- 3) Una venta normal no gana llaves de la nada.
  if public.detalle_venta(jsonb_build_object(
       'products', jsonb_build_array(jsonb_build_object('name', 'Express'))
     )) ? 'refundsPurchaseUuid' then
    raise exception 'a una venta normal se le invento la llave de devolucion';
  end if;

  -- 4) Y la forma ENVUELTA del aviso sigue desenvolviendose igual.
  if public.detalle_venta(jsonb_build_object('payload', jsonb_build_object(
       'products', jsonb_build_array(jsonb_build_object('name', 'Express')),
       'purchaseUuid', 'abc'
     ))) ->> 'purchaseUuid' is distinct from 'abc' then
    raise exception 'se rompio el desenvuelto del aviso envuelto';
  end if;

  raise notice 'detalle_venta entiende la devolucion rescatada: comprobado';
end
$do$;
