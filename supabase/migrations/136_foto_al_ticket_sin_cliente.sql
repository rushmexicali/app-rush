-- 136 · "No asignar a cliente": la foto de la caja se le pega al ticket aunque
--        el cliente no quiera registrarse
--
-- Pedido del dueno (24/ago/2026). El flujo que describio:
--
--     Cliente llega -> se toma la foto -> se lee la placa -> "Buscar"
--     -> y ahi, HASTA ARRIBA, un boton "No asignar a cliente"
--     -> se despliegan los tickets recientes -> se escoge el suyo.
--
-- POR QUE, con sus palabras: *"no todos los clientes se quieren registrar o
-- acumular lavados, pero el carro si forma parte de nuestra base de datos
-- porque se tiene que tomar de todos modos la foto el supervisor para asignar
-- a linea y secador. Como le queremos ahorrar tiempo al supervisor de tomar
-- fotos..."*
--
-- O sea que el valor no es del CRM: es OPERATIVO. La camara de la caja ya
-- fotografio el carro y ya se leyo la placa; si esa foto se tira nada mas
-- porque el cliente no quiso dar su nombre, el supervisor tiene que volver a
-- tomarla en el patio. Este camino la conserva y NO crea ninguna visita.
--
-- ---------------------------------------------------------------------------
-- LA REGLA DE PEGAR LA FOTO SE MUDA A UNA SOLA FUNCION
--
-- Ese trabajo -pegar la foto al carro si no trae otra, y guardar lo que leyo
-- la camara con el candado de la placa repetida- ya existia, pero escrito
-- ADENTRO de `registrar_visita_con_carro`. Con el camino nuevo habrian
-- quedado dos copias de la misma regla, que es el patron #1 de
-- `pruebas/README.md` y el error que este proyecto ya cometio seis veces.
--
-- Asi que se muda a `pegar_foto_de_caja()` y las dos le preguntan.
--
-- ⚠️ Los tres candados que traia se conservan TAL CUAL, y cada uno costo:
--   1. La foto solo se pega si el carro NO trae ya una -- no se pisa la del
--      supervisor.
--   2. La lectura solo se guarda si la foto de veras se pego a ESE carro. Sin
--      esto, la placa leida por la caja pisaba la del supervisor en un carro
--      que ya tenia su propia foto.
--   3. Solo si HUBO lectura (`p_hubo_lectura`, migracion 104). Sin eso,
--      `placa_en` quedaba estampado como "se intento y no se pudo" y el carro
--      NUNCA entraba a la cola de relectura.

-- ---------------------------------------------------------------------------
-- 1) La regla, en un solo lugar
create or replace function public.pegar_foto_de_caja(
  p_carro        bigint,
  p_foto_path    text,
  p_placa        text    default null,
  p_marca        text    default null,
  p_submarca     text    default null,
  p_tipo         text    default null,
  p_hubo_lectura boolean default true
) returns jsonb
language plpgsql
as $function$
declare
  c        record;
  v_foto   text;
  v_pego   boolean := false;
  v_dudosa boolean := false;
begin
  select * into c from public.carros where id = p_carro;
  if c.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado ya no existe');
  end if;
  if c.cancelado_en is not null or coalesce(c.es_prueba, false) then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado está cancelado');
  end if;

  v_foto := nullif(btrim(coalesce(p_foto_path, '')), '');

  -- Candado 1: la foto de la caja pasa a ser la del carro para que el
  -- supervisor la vea en la cola, pero SOLO si el carro no trae ya una. No se
  -- pisa la del supervisor.
  if v_foto is not null then
    update public.carros
       set foto_path       = v_foto,
           foto_url        = null,
           foto_url_expira = null
     where id = p_carro and foto_path is null;
    v_pego := found;
  end if;

  -- Lo que la camara leyo se guarda con `guardar_datos_de_foto`, la MISMA que
  -- usa el supervisor: ahi viven el candado de la placa repetida del dia (100)
  -- y el ligado placa->cliente.
  --
  -- Candados 2 y 3: solo si la foto de veras se pego a ESTE carro, y solo si
  -- hubo lectura. Ver el encabezado.
  if v_foto is not null and v_pego and coalesce(p_hubo_lectura, true) then
    select coalesce((public.guardar_datos_de_foto(
             p_carro, p_placa, null, p_marca, p_submarca, p_tipo
           ) ->> 'placa_dudosa')::boolean, false) into v_dudosa;
  end if;

  return jsonb_build_object('ok', true, 'pego', v_pego, 'placa_dudosa', v_dudosa);
end;
$function$;

comment on function public.pegar_foto_de_caja(bigint, text, text, text, text, text, boolean) is
  'Le pega al carro la foto que tomo la camara de la caja y guarda lo que leyo. Unico dueno de esa regla: la consultan registrar_visita_con_carro y la ruta /foto-al-ticket ("No asignar a cliente").';

-- ---------------------------------------------------------------------------
-- 2) Que `registrar_visita_con_carro` le pregunte a ella.
--
-- La funcion son ~110 lineas de reglas con sus razones escritas, asi que NO se
-- copia: se le pide su propia definicion y se le reemplaza el bloque entre dos
-- marcas comprobadas. Patron de las migraciones 117, 130, 132 y 133.
do $do$
declare
  def   text;
  m_ini text := '  -- La foto de la caja pasa a ser la del carro';
  m_fin text := '  return jsonb_build_object(''ok'', true, ''visita''';
  i     int;
  j     int;
  nuevo text;
begin
  select pg_get_functiondef(
    'public.registrar_visita_con_carro(bigint, bigint, boolean, text, text, text, text, text, text, boolean)'::regprocedure
  ) into def;

  i := position(m_ini in def);
  j := position(m_fin in def);
  if i = 0 then raise exception 'registrar_visita_con_carro: no aparece la marca de inicio del bloque de la foto'; end if;
  if j = 0 then raise exception 'registrar_visita_con_carro: no aparece la marca de fin (el return)'; end if;
  if i >= j then raise exception 'registrar_visita_con_carro: las marcas salieron al reves (i=%, j=%)', i, j; end if;

  nuevo :=
'  -- La foto se pega con `pegar_foto_de_caja`, que es la MISMA funcion que usa
  -- el camino de "No asignar a cliente" (136). Antes esto estaba escrito aqui
  -- adentro; al aparecer el segundo camino habrian quedado dos copias de la
  -- misma regla, con sus tres candados, y se habrian desfasado.
  select coalesce((public.pegar_foto_de_caja(
           p_carro, p_foto_path, p_placa, p_marca, p_submarca, p_tipo, p_hubo_lectura
         ) ->> ''placa_dudosa'')::boolean, false) into v_dudosa;

';

  execute left(def, i - 1) || nuevo || substr(def, j);
  raise notice 'registrar_visita_con_carro: ahora usa pegar_foto_de_caja';
end
$do$;

-- ---------------------------------------------------------------------------
-- Comprobacion de SOLO LECTURA.
do $do$
declare
  def text;
begin
  select pg_get_functiondef(
    'public.registrar_visita_con_carro(bigint, bigint, boolean, text, text, text, text, text, text, boolean)'::regprocedure
  ) into def;

  if position('pegar_foto_de_caja' in def) = 0 then
    raise exception 'registrar_visita_con_carro no quedo llamando a pegar_foto_de_caja';
  end if;
  -- Y ya no debe traer su propia copia del bloque.
  if position('foto_url_expira = null' in def) > 0 then
    raise exception 'registrar_visita_con_carro conserva su copia de la regla de la foto';
  end if;
  if position('guardar_datos_de_foto' in def) > 0 then
    raise exception 'registrar_visita_con_carro sigue llamando a guardar_datos_de_foto por su cuenta';
  end if;
  -- Lo que SI tiene que conservar: la visita se sigue insertando con su foto.
  if position('v_foto := nullif' in def) = 0 then
    raise exception 'registrar_visita_con_carro perdio el calculo de v_foto que usa la visita';
  end if;

  raise notice 'foto al ticket sin cliente: comprobado';
end
$do$;
