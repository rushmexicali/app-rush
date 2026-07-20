-- =====================================================================
-- RUSH Car Wash — Corregir tambien puede cambiar los secadores
--
-- Punto 3 del dueno (20/jul/2026), aclarado: al Corregir, los secadores
-- deben venir PRESELECCIONados (como el tipo y el color) y poder
-- editarse libremente. El problema real era que Chuy, ya asignado, salia
-- SIN marcar al abrir Corregir.
--
-- La primera version dejo los secadores de solo lectura ("usa Regresar").
-- Pero Regresar reinicia el cronometro de secado, que es justo lo que no
-- queremos al corregir una captura equivocada. Asi que Corregir ahora SI
-- cambia los secadores, pero SIN tocar las etapas: el reloj sigue igual.
--
-- Se hace dentro de editar_carro para que sea UNA transaccion: si algo
-- falla, ni el tipo/color ni los secadores quedan a medias. La 051 (solo
-- datos_de_nota) queda absorbida aqui; lo unico nuevo es el bloque de
-- secadores al final.
--
-- Se agregan dos parametros, asi que la firma cambia: hay que SOLTAR la
-- vieja primero, o quedarian dos editar_carro y la llamada por nombre
-- seria ambigua.
-- =====================================================================

drop function if exists public.editar_carro(bigint, text, text, text, smallint);

create or replace function public.editar_carro(
  p_carro       bigint,
  p_tipo_unidad text default null,
  p_color       text default null,
  p_marca       text default null,
  p_linea       smallint default null,
  p_secadores   text[] default null,
  p_empleados   text[] default null
)
returns jsonb
language plpgsql
as $$
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

  -- Los valores limpios, para comparar con lo guardado.
  nuevo_tipo  := nullif(btrim(coalesce(p_tipo_unidad, '')), '');
  nuevo_color := nullif(btrim(upper(coalesce(p_color, ''))), '');

  -- datos_de_nota solo se apaga si el supervisor CAMBIA algo (051). Reenviar
  -- el mismo valor no la apaga.
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

  -- --- Secadores (solo si se mandaron) -------------------------------
  -- Nulo = no tocar los secadores (asi lo llama /asignar, que ya los puso
  -- con asignar_carro). Si vienen, se reemplaza el conjunto ABIERTO del
  -- carro. NO se tocan etapas ni estado: el cronometro de secado sigue
  -- igual — esa es la diferencia con Regresar+reasignar.
  if p_empleados is not null then
    if actual <> 'secando' then
      return jsonb_build_object('ok', false, 'error', 'Los secadores se cambian cuando el carro ya esta secando');
    end if;

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

    -- La linea vigente (ya con el posible cambio de arriba), para las filas
    -- nuevas.
    select linea into ln from public.carros where id = p_carro;

    -- Se BORRAN las asignaciones abiertas: eran la captura equivocada que se
    -- esta corrigiendo, no un hecho que conservar. Las que ya tienen fin (de
    -- un Regresar anterior) no se tocan. Las etapas NO se tocan, asi que el
    -- tiempo de secado no se pierde ni se reinicia.
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
$$;

comment on function public.editar_carro(bigint, text, text, text, smallint, text[], text[]) is
  'Corrige tipo/color/marca/linea y, si ya seca, tambien los secadores (sin tocar etapas). datos_de_nota solo se apaga si el valor cambia. Nulo = no tocar ese campo.';
