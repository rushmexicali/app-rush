-- =====================================================================
-- 109 - Dos correcciones del backend de la auditoria del 19/ago
--
--   #17  editar_carro ESCRIBE ANTES DE VALIDAR.
--   #18  guardar_datos_de_foto BORRA LO QUE NO LEYO.
--
-- Van juntas porque las dos son la misma clase de error: una escritura que
-- ocurre antes de saber si debia ocurrir.
-- =====================================================================


-- ---------------------------------------------------------------------
-- #17 - editar_carro: primero se valida todo, despues se escribe
--
-- El `update` de tipo/color/marca/linea iba ANTES de los tres checks de
-- secadores, y en plpgsql un `return` NO revierte lo ya escrito (no abre
-- subtransaccion; solo un `exception` lo haria). Resultado real: el
-- supervisor abre Corregir de un carro secando, cambia el color, quita
-- todos los secadores y guarda. La app le dice "Deja al menos un secador"
-- y el cree que no guardo nada... pero el color YA quedo cambiado en la
-- base, y las asignaciones ya se apuntaron a la linea nueva.
--
-- Es de las peores formas de fallar: la pantalla dice una cosa y la base
-- guarda otra, sin que nadie pueda notarlo desde afuera.
--
-- El arreglo no cambia ninguna regla: son las MISMAS validaciones y las
-- MISMAS escrituras, reordenadas. Todo lo que valida va arriba; nada se
-- escribe hasta que paso el ultimo check.
-- ---------------------------------------------------------------------
create or replace function public.editar_carro(
  p_carro       bigint,
  p_tipo_unidad text     default null,
  p_color       text     default null,
  p_marca       text     default null,
  p_linea       smallint default null,
  p_secadores   text[]   default null,
  p_empleados   text[]   default null
) returns jsonb
language plpgsql
as $func$
declare
  actual        text;
  express       boolean;
  actual_tipo   text;
  actual_color  text;
  nuevo_tipo    text;
  nuevo_color   text;
  toco_datos    boolean;
  ln            smallint;
  cuantos       int;
  i             int;
begin
  -- ================= VALIDAR ==========================================
  -- De aqui para abajo NO se escribe nada hasta la seccion ESCRIBIR.

  select estado, es_express, tipo_unidad, color
    into actual, express, actual_tipo, actual_color
    from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  if p_tipo_unidad is not null
     and p_tipo_unidad not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    return jsonb_build_object('ok', false, 'error', 'Tipo de unidad invalido');
  end if;

  -- La linea solo tiene sentido cuando el carro ya esta secando. Antes de
  -- eso se asigna con asignar_carro, que ademas pide secadores.
  if p_linea is not null then
    if actual <> 'secando' then
      return jsonb_build_object('ok', false, 'error', 'La linea se cambia cuando el carro ya esta secando');
    end if;
    if p_linea < 1 or p_linea > 6 then
      return jsonb_build_object('ok', false, 'error', 'Escoge una linea del 1 al 6');
    end if;
    if p_linea = 1 and not express then
      return jsonb_build_object('ok', false, 'error', 'La linea 1 es solo para express');
    end if;
    if p_linea <> 1 and express then
      return jsonb_build_object('ok', false, 'error', 'Los express van a la linea 1');
    end if;
  end if;

  -- Nulo = no tocar los secadores (asi lo llama /asignar, que ya los puso
  -- con asignar_carro). Si vienen, se reemplaza el conjunto ABIERTO del
  -- carro.
  if p_empleados is not null then
    if actual <> 'secando' then
      return jsonb_build_object('ok', false, 'error', 'Los secadores se cambian cuando el carro ya esta secando');
    end if;

    -- Se limpian aqui, en la validacion, porque de esta lista sale el
    -- conteo que decide si el guardado procede.
    select array_agg(x) into p_secadores
      from unnest(coalesce(p_secadores, array[]::text[])) x
     where btrim(coalesce(x, '')) <> '';

    cuantos := coalesce(array_length(p_secadores, 1), 0);
    if cuantos = 0 then
      return jsonb_build_object('ok', false, 'error', 'Deja al menos un secador');
    end if;
    if cuantos > 4 then
      return jsonb_build_object('ok', false, 'error', 'Maximo 4 secadores por carro');
    end if;
  end if;

  -- ================= ESCRIBIR =========================================
  -- Ya no hay forma de salir con error: de aqui en adelante todo procede.

  nuevo_tipo  := nullif(btrim(coalesce(p_tipo_unidad, '')), '');
  nuevo_color := nullif(btrim(upper(coalesce(p_color, ''))), '');

  -- datos_de_nota solo se apaga si el supervisor CAMBIA algo (051).
  -- Reenviar el mismo valor no la apaga.
  toco_datos := (nuevo_tipo  is not null and nuevo_tipo  is distinct from actual_tipo)
             or (nuevo_color is not null and nuevo_color is distinct from actual_color);

  update public.carros
     set tipo_unidad   = coalesce(nuevo_tipo, tipo_unidad),
         color         = coalesce(nuevo_color, color),
         marca         = coalesce(nullif(btrim(upper(coalesce(p_marca, ''))), ''), marca),
         linea         = coalesce(p_linea, linea),
         datos_de_nota = case when toco_datos then false else datos_de_nota end
   where id = p_carro;

  -- Que la asignacion no se quede apuntando a la linea vieja.
  if p_linea is not null then
    update public.asignaciones set linea = p_linea
     where carro_id = p_carro and fin is null;
  end if;

  if p_empleados is not null then
    -- La linea vigente (ya con el posible cambio de arriba), para las
    -- filas nuevas.
    select linea into ln from public.carros where id = p_carro;

    -- Se BORRAN las asignaciones abiertas: eran la captura equivocada que
    -- se esta corrigiendo, no un hecho que conservar. Las que ya tienen
    -- fin (de un Regresar anterior) no se tocan. Las etapas NO se tocan,
    -- asi que el tiempo de secado no se pierde ni se reinicia.
    delete from public.asignaciones
     where carro_id = p_carro and fin is null;

    for i in 1 .. cuantos loop
      insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
      values (
        p_carro, ln, btrim(p_secadores[i]),
        case when array_length(p_empleados, 1) >= i then p_empleados[i] else null end,
        now()
      );
    end loop;
  end if;

  return jsonb_build_object('ok', true);
end;
$func$;

comment on function public.editar_carro(bigint, text, text, text, smallint, text[], text[]) is
  'Corregir del supervisor. VALIDA TODO ANTES DE ESCRIBIR (109): un return en plpgsql no revierte, asi que un check tardio dejaba el dato a medio guardar mientras la pantalla decia que fallo.';


-- ---------------------------------------------------------------------
-- #18 - guardar_datos_de_foto: un campo que no se leyo ya no borra el que si
--
-- La 063 hizo la foto AUTORITATIVA (sobrescribe en vez de coalesce) por una
-- razon buena: re-tomar una foto buena tenia que poder limpiar el dato de un
-- carro fotografiado por error, y marca/submarca no se editan a mano. Pero
-- quedo mas ancha de lo necesario: escribe el nulo igual que el valor, asi
-- que una lectura que NO alcanzo a ver la marca borra la marca que otra
-- lectura si vio.
--
-- Y eso ya no es teorico: desde la 103 el supervisor tiene el boton "Tomar
-- foto otra vez" para las pickups grandes cuya placa no se deja leer. Ese
-- flujo dispara justo este caso, y es de todos los dias.
--
-- Las dos reglas que quedan, cada una con su razon:
--
--   1. Un campo se escribe cuando la lectura nueva TRAJO algo. Un nulo no
--      borra. (Es la "aceptacion parcial POR CAMPO" que el CLAUDE.md §9 ya
--      declara y que esta funcion no estaba cumpliendo.)
--
--   2. EXCEPCION: si la lectura nueva trae una placa DISTINTA a la guardada,
--      se reemplaza el juego completo, nulos incluidos. Dos placas distintas
--      significan dos carros distintos: lo que estaba guardado era de otro
--      carro y no hay nada que conservar. Ahi es donde la 063 tenia razon, y
--      ese camino queda intacto.
--
-- Lo que NO cubre, dicho de frente: un carro con datos de otro carro cuya
-- foto nueva tampoco alcanza a leer la placa se queda como estaba. No se
-- limpia solo. Se prefiere asi porque el otro extremo -borrar en cada
-- lectura muda- es el que estaba costando datos a diario.
--
-- `tipo_unidad` no cambia: ya venia con coalesce y nunca borraba. Ese campo
-- tambien lo pone la cajera en la nota, y la foto solo lo corrige cuando
-- reconocio el modelo (063).
-- ---------------------------------------------------------------------
create or replace function public.guardar_datos_de_foto(
  p_carro    bigint,
  p_placa    text default null,
  p_org      text default null,
  p_marca    text default null,
  p_submarca text default null,
  p_tipo     text default null
) returns jsonb
language plpgsql
as $func$
declare
  nueva_marca    text;
  nueva_submarca text;
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

  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;
  end if;

  v_raw  := nullif(btrim(upper(coalesce(p_placa, ''))), '');
  v_norm := public.normalizar_placa(p_placa);

  select placa into v_placa_vieja from public.carros where id = p_carro;

  -- La lectura nueva es de OTRO carro: lo guardado no es de este vehiculo y
  -- se reemplaza entero (regla 2 de arriba).
  v_otro_carro := (v_norm is not null
                   and v_placa_vieja is not null
                   and v_norm is distinct from v_placa_vieja);

  -- La placa leida ya esta en otro carro no cancelado del mismo dia local?
  if v_norm is not null then
    select exists (
      select 1
      from public.carros c2, public.carros c1
      where c1.id = p_carro
        and c2.id <> p_carro
        and c2.cancelado_en is null
        and not coalesce(c2.es_prueba, false)
        and c2.placa = v_norm
        and (c2.creado_en at time zone 'America/Tijuana')::date
          = (c1.creado_en at time zone 'America/Tijuana')::date
    ) into v_colision;
  end if;

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
$func$;

comment on function public.guardar_datos_de_foto(bigint, text, text, text, text, text) is
  'Guarda lo que la foto leyo. Un campo nulo NO borra lo que otra lectura si vio (109); salvo que la placa leida sea distinta a la guardada, que significa que lo guardado era de otro carro y se reemplaza entero.';
