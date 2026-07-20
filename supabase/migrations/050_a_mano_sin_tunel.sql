-- =====================================================================
-- RUSH Car Wash — un lavado a mano NO pasa por el tunel
--
-- Lo noto el dueno el 20/jul/2026 viendo el desglose: a un carro Manual
-- la app le decia "Prelavado + Tunel" y le fabricaba 4 minutos de tunel.
-- Ese carro nunca entro al tunel — por eso se llama lavado a mano.
--
-- Dos consecuencias, y la segunda es la que importa:
--
--   1. La etiqueta decia algo falso.
--   2. Se le ROBABAN 4 minutos al prelavado para dárselos a una etapa
--      que no ocurrio. El tiempo total quedaba bien, pero el desglose
--      mentia, y el promedio de prelavado de los lavados a mano salia
--      4 minutos corto.
--
-- El arreglo va en asignar_carro, que es donde se fabrica el tunel: si
-- el carro es a mano, se cierra el prelavado en "ahora" y no se inventa
-- ninguna etapa de tunel. El desglose entonces no muestra el "(+4
-- Tunel)" solo, porque ya lee el tunel real y no hay ninguno.
--
-- Se aprovecha es_lavado_a_mano(), la misma funcion que decide la
-- banderita cian. Una sola regla para la misma pregunta — que es la
-- leccion que este proyecto lleva repitiendo todo el dia.
--
-- Lo demas es identico a la 024.
-- =====================================================================

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
  a_mano    boolean;
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

  -- Un lavado a mano no entra al tunel. Se lee de la columna generada,
  -- que sale de es_lavado_a_mano() — la MISMA regla que pinta la
  -- banderita cian, no una copia.
  select c.a_mano into a_mano from public.carros c where c.id = p_carro;

  if a_mano then
    -- No se fabrica tunel: el prelavado cubre todo hasta que se asigna.
    -- Si se le fabricara, se le quitarian 4 minutos al prelavado para
    -- darselos a una etapa que nunca ocurrio.
    update public.etapas set fin = now() where carro_id = p_carro and fin is null;

  elsif ya_tunel or arranque is null then
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
