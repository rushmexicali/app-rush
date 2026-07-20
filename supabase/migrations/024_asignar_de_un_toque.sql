-- =====================================================================
-- RUSH Car Wash — un solo toque antes de secar
--
-- El supervisor no alcanza a marcar "termino prelavado" ni "salio del
-- tunel": esta ocupado asignando lineas y secadores, que es lo unico que
-- de verdad tiene que hacer. Le pediamos TRES toques por carro. Ahora es
-- UNO.
--
--     antes:  prelavado -> tunel -> por_asignar -> secando -> entregado
--     ahora:  prelavado ------(Asignar)--------> secando -> entregado
--
-- Las etapas no se pierden: se reconstruyen hacia atras al asignar,
-- porque el tunel dura lo mismo siempre (es una maquina).
--
--     corte = max(inicio_prelavado, ahora - 4 min)
--
--     prelavado:  inicio -> corte   (cerrada)
--     tunel:      corte  -> ahora   (cerrada, fabricada)
--     secando:    ahora  -> abierta
--
-- LOS 4 MINUTOS ESTAN MEDIDOS, no supuestos: 29 mediciones reales del
-- 19/jul/2026 dan un promedio de 242 s = 4.03 min.
--
-- Lo que se pierde, dicho de frente: "por asignar" duraba 59 s en
-- promedio, y ese minuto ahora se le suma al prelavado calculado. O sea
-- el prelavado va a salir ~1 min mas largo que el real. Es el precio de
-- quitarle dos toques por carro al supervisor.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Cuanto dura el tunel
--
-- En una sola funcion para poder ajustarlo sin tocar nada mas. Si algun
-- dia cambia la maquina, se cambia aqui y ya.
-- ---------------------------------------------------------------------
create or replace function public.segundos_de_tunel()
returns int
language sql
immutable
as $$ select 240; $$;

comment on function public.segundos_de_tunel() is
  'Duracion del tunel. Medido el 19/jul/2026: promedio de 242 s sobre 29 carros reales.';

-- ---------------------------------------------------------------------
-- El orden nuevo
-- ---------------------------------------------------------------------
create or replace function public.orden_etapas()
returns text[]
language sql
immutable
as $$ select array['prelavado','secando','entregado']; $$;

-- ---------------------------------------------------------------------
-- Los carros que venian en camino
--
-- Cuando cambio el flujo habia carros en 'tunel' y en 'por_asignar'. Esos
-- estados ya no existen en el orden, asi que array_position les daria
-- nulo y quedarian IMPOSIBLES DE MOVER: avanzar diria "ya fue entregado"
-- y regresar diria "apenas va empezando".
--
-- En vez de migrarles los datos (y arriesgar sus mediciones reales), los
-- tres estados previos al secado se tratan como uno solo.
-- ---------------------------------------------------------------------
create or replace function public.etapa_efectiva(p_estado text)
returns text
language sql
immutable
as $$
  select case
    when p_estado in ('prelavado', 'tunel', 'por_asignar') then 'prelavado'
    else p_estado
  end;
$$;

-- ---------------------------------------------------------------------
-- Avanzar
--
-- Ya solo sirve para una cosa: secando -> entregado. Antes de secar no se
-- "avanza", se ASIGNA, porque hace falta decidir linea y secadores.
-- ---------------------------------------------------------------------
create or replace function public.avanzar_etapa(p_carro bigint)
returns jsonb
language plpgsql
as $$
declare
  actual   text;
  efectiva text;
begin
  -- for update: sin esto, dos toques rapidos saltan una etapa.
  select estado into actual from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  efectiva := etapa_efectiva(actual);

  if efectiva = 'entregado' then
    return jsonb_build_object('ok', false, 'error', 'El carro ya fue entregado');
  end if;

  -- La pantalla intercepta este caso y abre la asignacion. Si algo llega
  -- hasta aqui, se dice claro en vez de adivinar una etapa.
  if efectiva = 'prelavado' then
    return jsonb_build_object('ok', false, 'error', 'Primero asignale linea y secador');
  end if;

  update public.etapas set fin = now() where carro_id = p_carro and fin is null;

  update public.carros
     set estado = 'entregado',
         entregado_en = now()
   where id = p_carro;

  return jsonb_build_object('ok', true, 'estado', 'entregado');
end;
$$;

-- ---------------------------------------------------------------------
-- Asignar: el unico toque
--
-- Aqui es donde se reconstruyen las etapas hacia atras.
-- ---------------------------------------------------------------------
create or replace function public.asignar_carro(
  p_carro      bigint,
  p_linea      smallint,
  p_secadores  text[],
  p_marca      text default null,
  p_empleados  text[] default null
)
returns jsonb
language plpgsql
as $$
declare
  actual    text;
  express   boolean;
  cuantos   int;
  i         int;
  arranque  timestamptz;
  corte     timestamptz;
  ya_tunel  boolean;
begin
  select estado, es_express into actual, express
    from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- Se aceptan los TRES estados previos al secado. Los dos viejos siguen
  -- aqui solo por los carros que venian en camino cuando cambio el flujo.
  if actual not in ('prelavado', 'tunel', 'por_asignar') then
    return jsonb_build_object('ok', false, 'error', 'Ese carro ya esta secando o entregado');
  end if;

  if p_linea is null or p_linea < 1 or p_linea > 6 then
    return jsonb_build_object('ok', false, 'error', 'Escoge una linea del 1 al 6');
  end if;

  select array_agg(x) into p_secadores
    from unnest(coalesce(p_secadores, array[]::text[])) x
   where btrim(coalesce(x, '')) <> '';

  cuantos := coalesce(array_length(p_secadores, 1), 0);

  if cuantos = 0 then
    return jsonb_build_object('ok', false, 'error', 'Escoge al menos un secador');
  end if;
  if cuantos > 4 then
    return jsonb_build_object('ok', false, 'error', 'Maximo 4 secadores por carro');
  end if;

  -- La linea 1 es exclusiva de express. Se valida aqui ademas de en la
  -- app: la app puede tener un bug, la base no deja pasar el error.
  if p_linea = 1 and not express then
    return jsonb_build_object('ok', false, 'error', 'La linea 1 es solo para express');
  end if;
  if p_linea <> 1 and express then
    return jsonb_build_object('ok', false, 'error', 'Los express van a la linea 1');
  end if;

  -- --- Reconstruir las etapas ----------------------------------------
  select inicio into arranque
    from public.etapas
   where carro_id = p_carro and fin is null
   order by inicio desc
   limit 1;

  select exists (
    select 1 from public.etapas where carro_id = p_carro and etapa = 'tunel'
  ) into ya_tunel;

  if ya_tunel or arranque is null then
    -- Carro del flujo viejo: ya tiene su tunel MEDIDO de verdad. No se le
    -- fabrica otro encima.
    update public.etapas set fin = now() where carro_id = p_carro and fin is null;
  else
    -- El greatest() no es cosmetico: si el carro se asigna en menos de 4
    -- minutos, sin el, fin quedaria ANTES que inicio y la columna
    -- generada "segundos" saldria negativa. No hay CHECK que lo impida.
    corte := greatest(arranque, now() - make_interval(secs => segundos_de_tunel()));

    update public.etapas set fin = corte where carro_id = p_carro and fin is null;

    insert into public.etapas (carro_id, etapa, inicio, fin)
    values (p_carro, 'tunel', corte, now());
  end if;

  update public.carros
     set estado = 'secando',
         linea  = p_linea,
         -- Una marca en blanco nunca borra la que ya estaba.
         marca  = coalesce(nullif(btrim(coalesce(p_marca, '')), ''), marca)
   where id = p_carro;

  insert into public.etapas (carro_id, etapa, inicio)
  values (p_carro, 'secando', now());

  -- Una fila por persona: un carro puede tener hasta 4 secadores.
  for i in 1 .. cuantos loop
    insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
    values (
      p_carro, p_linea, btrim(p_secadores[i]),
      case when p_empleados is not null and array_length(p_empleados, 1) >= i
           then p_empleados[i] else null end,
      now()
    );
  end loop;

  return jsonb_build_object('ok', true, 'estado', 'secando', 'linea', p_linea);
end;
$$;

-- ---------------------------------------------------------------------
-- Regresar (el boton "Regresar")
--
-- Se reescribio explicita en vez de generica, y la razon importa:
--
-- La version vieja funcionaba DE CASUALIDAD. Al regresar desde 'secando',
-- la etapa anterior resultaba ser 'por_asignar', y era ESA rama la que
-- ponia linea = null y cerraba las asignaciones. Con el orden nuevo la
-- anterior es 'prelavado', asi que las dos ramas habrian dejado de
-- dispararse EN SILENCIO: el carro regresaria conservando su linea y con
-- asignaciones abiertas, y al reasignarlo se insertaria un SEGUNDO juego
-- de filas — contando doble a los secadores en las estadisticas.
-- ---------------------------------------------------------------------
create or replace function public.regresar_etapa(p_carro bigint)
returns jsonb
language plpgsql
as $$
declare
  actual        text;
  inicio_secado timestamptz;
begin
  select estado into actual from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- --- entregado -> secando ------------------------------------------
  if actual = 'entregado' then
    update public.carros set estado = 'secando', entregado_en = null where id = p_carro;

    update public.etapas set fin = null
     where id = (select id from public.etapas
                  where carro_id = p_carro and etapa = 'secando'
                  order by inicio desc limit 1);

    return jsonb_build_object('ok', true, 'estado', 'secando');
  end if;

  -- --- secando -> prelavado (deshacer la asignacion) ------------------
  if actual = 'secando' then
    select inicio into inicio_secado
      from public.etapas
     where carro_id = p_carro and etapa = 'secando' and fin is null
     order by inicio desc limit 1;

    -- 1) La etapa de secado abierta.
    delete from public.etapas where carro_id = p_carro and fin is null;

    -- 2) La fila de tunel FABRICADA en esa asignacion.
    --
    -- Se reconoce porque termina exactamente cuando empezo el secado —
    -- las dos se escribieron con el mismo now(). Un tunel MEDIDO de
    -- verdad (flujo viejo) tenia un 'por_asignar' en medio, asi que su
    -- fin no coincide y sobrevive. Sin esto quedaria un tunel fantasma
    -- de 4 minutos en un carro que nunca paso por ahi.
    if inicio_secado is not null then
      delete from public.etapas
       where carro_id = p_carro and etapa = 'tunel' and fin = inicio_secado;
    end if;

    -- 3) Cerrar las asignaciones. Explicito, no como efecto secundario.
    update public.asignaciones set fin = now()
     where carro_id = p_carro and fin is null;

    -- 4) Soltar la linea.
    update public.carros set estado = 'prelavado', linea = null where id = p_carro;

    -- Reabrir el prelavado para que el reloj siga contando desde el pago.
    update public.etapas set fin = null
     where id = (select id from public.etapas
                  where carro_id = p_carro and etapa = 'prelavado'
                  order by inicio desc limit 1);

    return jsonb_build_object('ok', true, 'estado', 'prelavado');
  end if;

  return jsonb_build_object('ok', false, 'error', 'El carro apenas va empezando');
end;
$$;
