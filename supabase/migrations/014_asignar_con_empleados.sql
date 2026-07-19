-- =====================================================================
-- RUSH Car Wash — Asignar guardando QUIEN, no solo el nombre escrito
--
-- Se guardan las dos cosas a proposito:
--   empleado_id -> para medir eficiencia por persona aunque cambie de
--                  nombre o lo corrijamos a mano.
--   secador     -> el nombre tal como se veia el dia que se asigno. Si
--                  alguien sale de Jibble, el historial sigue diciendo
--                  quien seco ese carro.
-- =====================================================================

create or replace function public.asignar_carro(
  p_carro     bigint,
  p_linea     smallint,
  p_secadores text[],
  p_marca     text default null,
  p_empleados text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actual  text;
  express boolean;
  cuantos int;
  i       int;
begin
  select estado, es_express into actual, express
    from carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;
  if actual <> 'por_asignar' then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no esta esperando asignacion');
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

  update etapas set fin = now() where carro_id = p_carro and fin is null;

  update carros
     set estado = 'secando',
         linea  = p_linea,
         marca  = coalesce(nullif(btrim(coalesce(p_marca, '')), ''), marca)
   where id = p_carro;

  insert into etapas (carro_id, etapa, inicio) values (p_carro, 'secando', now());

  for i in 1 .. cuantos loop
    insert into asignaciones (carro_id, linea, secador, empleado_id, inicio)
    values (
      p_carro,
      p_linea,
      btrim(p_secadores[i]),
      case when p_empleados is not null and array_length(p_empleados, 1) >= i
           then p_empleados[i] else null end,
      now()
    );
  end loop;

  return jsonb_build_object('ok', true, 'estado', 'secando', 'linea', p_linea, 'secadores', cuantos);
end;
$$;

-- ---------------------------------------------------------------------
-- Respaldo manual: agregar a alguien que no aparece en Jibble
--
-- El CLAUDE.md lo exige: la app nunca se debe quedar bloqueada porque
-- una integracion externa fallo. Si Jibble se cae o alguien no checo,
-- el supervisor lo agrega y sigue trabajando.
--
-- Los manuales no los toca la sincronizacion: Jibble no sabe de ellos.
-- ---------------------------------------------------------------------
create or replace function public.agregar_secador_manual(p_nombre text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  limpio text;
  nuevo  text;
begin
  limpio := btrim(coalesce(p_nombre, ''));
  if length(limpio) < 2 then
    return jsonb_build_object('ok', false, 'error', 'Escribe el nombre');
  end if;

  nuevo := 'manual-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.empleados
    (id, nombre, nombre_corto, nombre_display, iniciales, estado, desde, manual, actualizado_en)
  values
    (nuevo, limpio, nombre_corto_de(limpio), limpio, iniciales_de(limpio), 'activo', now(), true, now());

  perform public.asignar_colores_libres();

  return jsonb_build_object('ok', true, 'id', nuevo, 'nombre', limpio);
end;
$$;
