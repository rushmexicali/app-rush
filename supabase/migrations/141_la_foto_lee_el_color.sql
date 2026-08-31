-- =====================================================================
-- 141 — La foto tambien lee el COLOR, y la foto manda.
--
-- Decision del dueno, 30/ago/2026. Contexto: la cajera dejo de poner la nota
-- de venta el fin de semana porque penso que con el sistema nuevo de cobro ya
-- no hacia falta. Se midio quien tenia razon (§11.001):
--
--                      sin nota (106)   con nota (203)
--     tipo de unidad        96%             100%
--     marca                 96%              85%
--     placa                 96%              74%
--     cliente               88%              70%
--     COLOR                  1%              95%   <- lo unico que se perdia
--
-- O sea que tenia razon en todo menos en el color, y el color se perdia
-- ENTERO. Importa por dos cosas: es como el supervisor encuentra el carro en
-- el patio ("BLANCO" se ve a veinte metros, "TOYOTA COROLLA" no), y es el
-- testigo independiente que delata una foto pegada al carro equivocado
-- (§12.1).
--
-- La salida que escogio el dueno: que la FOTO lea el color, y que la foto
-- SOBREESCRIBA lo que ponga la caja. Textual: "La cajera seguira poniendo la
-- nota de venta solo en caso de que haya algun fallo en la lectura, pero la
-- lectura de la foto sobreescribe lo que ponga la caja. La nota es meramente
-- una red de apoyo."
--
-- 🔑 EL COLOR SIGUE LA MISMA REGLA QUE MARCA Y SUBMARCA (la de la 109), no
--    una nueva:
--      · se escribe cuando la lectura trajo algo;
--      · un NULO NO BORRA — asi la nota sigue siendo la red de apoyo cuando la
--        foto no alcanza a ver el color;
--      · si la placa leida es DISTINTA a la guardada, se reemplaza el juego
--        completo (nulos incluidos): son dos carros distintos.
--    Copiar una regla nueva para el color habria sido el error que este
--    proyecto ya cometio varias veces.
--
-- ⚠️ LO QUE ESTO CUESTA, DICHO DE FRENTE: el color de la nota era el testigo
--    independiente que delataba una foto mal pegada. Ahora la foto lo pisa.
--    El testigo NO se pierde —`carros.nota` se conserva siempre y
--    `interpretar_nota` sabe releerlo—, pero deja de estar a la vista. Queda
--    apuntado que con eso se puede construir un detector automatico:
--    "color de la foto != color de la nota" es candidato a foto mal pegada,
--    igual que `placa_dudosa`.
--
-- ⚠️ CAMBIAN TRES FIRMAS, asi que hay `drop function` antes de cada una: un
--    parametro nuevo crea una SOBRECARGA, no un reemplazo, y dos funciones con
--    el mismo nombre vuelven ambigua la llamada. Es la leccion de la 052, la
--    098 y la 104.
-- =====================================================================

drop function if exists public.guardar_datos_de_foto(bigint, text, text, text, text, text);

create or replace function public.guardar_datos_de_foto(
  p_carro    bigint,
  p_placa    text default null,
  p_org      text default null,
  p_marca    text default null,
  p_submarca text default null,
  p_tipo     text default null,
  p_color    text default null)
returns jsonb
language plpgsql
as $function$
declare
  nueva_marca    text;
  nueva_submarca text;
  nuevo_color    text;
  tipo_limpio    text;
  v_raw          text;
  v_norm         text;
  v_placa_vieja  text;
  v_otro_carro   boolean := false;
  v_colision     boolean := false;
  r              record;
begin
  nueva_marca    := nullif(btrim(upper(coalesce(p_marca, ''))), '');
  nueva_submarca := nullif(btrim(upper(coalesce(p_submarca, ''))), '');
  -- En MAYUSCULAS como el color de la nota, para que los dos se puedan comparar.
  nuevo_color    := nullif(btrim(upper(coalesce(p_color, ''))), '');

  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;
  end if;

  v_raw  := nullif(btrim(upper(coalesce(p_placa, ''))), '');
  v_norm := public.normalizar_placa(p_placa);

  select placa into v_placa_vieja from public.carros where id = p_carro;

  -- La lectura nueva es de OTRO carro: lo guardado no es de este vehiculo y
  -- se reemplaza entero (regla 2 de la 109).
  v_otro_carro := (v_norm is not null
                   and v_placa_vieja is not null
                   and v_norm is distinct from v_placa_vieja);

  -- Una sola regla, la de la 111.
  v_colision := public.placa_repetida_hoy(p_carro, v_norm);

  if v_colision then
    -- Choque: se marca para revision, no se ensucia el carro.
    update public.carros
       set placa_dudosa = coalesce(v_raw, v_norm),
           placa_en     = now()
     where id = p_carro;
  else
    update public.carros set
      -- La placa se escribe cuando se leyo. Una lectura muda no la borra.
      placa              = coalesce(v_norm, placa),
      placa_display      = case
                             when v_norm is not null
                               then case when v_raw is distinct from v_norm then v_raw else null end
                             else placa_display
                           end,
      -- La organizacion pertenece a la lectura de la placa: se escribe (y se
      -- limpia) junto con ella, nunca por su cuenta.
      placa_organizacion = case
                             when v_norm is not null
                               then nullif(btrim(coalesce(p_org, '')), '')
                             else placa_organizacion
                           end,
      placa_dudosa       = case when v_norm is not null then null else placa_dudosa end,
      placa_en           = now(),
      marca              = case when v_otro_carro then nueva_marca
                                else coalesce(nueva_marca, marca) end,
      submarca           = case when v_otro_carro then nueva_submarca
                                else coalesce(nueva_submarca, submarca) end,
      -- El COLOR va exactamente como marca y submarca (141): la foto manda
      -- cuando leyo algo, y un nulo NO borra lo que puso la nota.
      color              = case when v_otro_carro then nuevo_color
                                else coalesce(nuevo_color, color) end,
      tipo_unidad        = case
                             when nueva_submarca is not null
                               then coalesce(tipo_limpio, tipo_unidad)
                             else coalesce(tipo_unidad, tipo_limpio)
                           end
    where id = p_carro;
  end if;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- Ligar la placa al cliente SOLO si no hubo choque.
  if v_norm is not null and not v_colision then
    for r in select persona_id from public.visitas
              where carro_id = p_carro and estado = 'activa' and persona_id is not null loop
      perform public.ligar_placa_a_persona(r.persona_id, coalesce(v_raw, v_norm), 'foto', false);
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'placa_dudosa', v_colision);
end;
$function$;

-- ---------------------------------------------------------------------
-- El camino de la CAJA: le pasa el color a la misma funcion de arriba.
-- ---------------------------------------------------------------------
drop function if exists public.pegar_foto_de_caja(bigint, text, text, text, text, text, boolean);

create or replace function public.pegar_foto_de_caja(
  p_carro bigint, p_foto_path text,
  p_placa text default null, p_marca text default null, p_submarca text default null,
  p_tipo text default null, p_hubo_lectura boolean default true,
  p_color text default null)
returns jsonb
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
  -- usa el supervisor: ahi viven el candado de la placa repetida del dia (100),
  -- el ligado placa->cliente y la regla del color (141).
  --
  -- Candados 2 y 3: solo si la foto de veras se pego a ESTE carro, y solo si
  -- hubo lectura. Ver el encabezado.
  if v_foto is not null and v_pego and coalesce(p_hubo_lectura, true) then
    select coalesce((public.guardar_datos_de_foto(
             p_carro, p_placa, null, p_marca, p_submarca, p_tipo, p_color
           ) ->> 'placa_dudosa')::boolean, false) into v_dudosa;
  end if;

  return jsonb_build_object('ok', true, 'pego', v_pego, 'placa_dudosa', v_dudosa);
end;
$function$;

-- ---------------------------------------------------------------------
-- `registrar_visita_con_carro` solo tiene que DEJAR PASAR el color hasta
-- `pegar_foto_de_caja`. Son dos cambios de una linea cada uno sobre ~100
-- lineas de reglas con sus razones escritas (el ticket manda sobre el switch,
-- el canje sin saldo, el candado del ticket ya usado...).
--
-- 🔑 POR ESO NO SE COPIA LA FUNCION: se le pide a Postgres su propia
--    definicion, se le insertan las dos piezas y se vuelve a crear. Reescribir
--    de memoria una funcion larga para cambiar una linea es el movimiento que
--    ya salio mal en este proyecto (§11.45), y copiarla a mano aqui pondria en
--    riesgo el camino por donde la caja registra el dinero. Mismo patron de la
--    migracion 116.
--
-- Si alguna de las dos anclas no aparece, esto se cae con un mensaje claro en
-- vez de aplicar algo a medias.
-- ---------------------------------------------------------------------
do $$
declare
  d text;
  ancla_firma text := 'p_hubo_lectura boolean DEFAULT true';
  ancla_llam  text := 'p_carro, p_foto_path, p_placa, p_marca, p_submarca, p_tipo, p_hubo_lectura';
begin
  select pg_get_functiondef(p.oid) into d
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'registrar_visita_con_carro';

  if d is null then
    raise exception 'FALLO: no existe registrar_visita_con_carro';
  end if;
  if position(ancla_firma in d) = 0 then
    raise exception 'FALLO: no se encontro el ancla de la FIRMA (%). La funcion cambio; revisa la 141.', ancla_firma;
  end if;
  if position(ancla_llam in d) = 0 then
    raise exception 'FALLO: no se encontro el ancla de la LLAMADA a pegar_foto_de_caja. La funcion cambio; revisa la 141.';
  end if;

  d := replace(d, ancla_firma, ancla_firma || ', p_color text DEFAULT NULL::text');
  d := replace(d, ancla_llam,  ancla_llam  || ', p_color');

  -- La firma vieja se va: un parametro nuevo crea una SOBRECARGA, no un
  -- reemplazo, y dos funciones con el mismo nombre vuelven ambigua la llamada.
  execute 'drop function if exists public.registrar_visita_con_carro'
       || '(bigint,bigint,boolean,text,text,text,text,text,text,boolean)';
  execute d;
end $$;

