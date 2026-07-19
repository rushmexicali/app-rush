-- =====================================================================
-- RUSH Car Wash — Fase 2, Paso 5: asignar linea, secadores y marca
--
-- Reparto de quien captura que:
--   Cajera    -> tipo de unidad y color (en la nota de Zettle)
--   Gerente   -> marca, linea y secadores (en esta pantalla)
--
-- La marca se pide aqui y no en caja porque la cajera esta cobrando y no
-- ve el carro; el gerente si lo tiene enfrente cuando lo asigna.
-- =====================================================================

alter table public.carros add column if not exists marca text;

-- ---------------------------------------------------------------------
-- Asignar: guarda marca, linea y secadores, y arranca el secado.
--
-- Es una sola funcion (y no varios pasos desde la app) para que sea
-- atomica: o queda todo asignado, o no queda nada. Un carro con linea
-- pero sin secadores seria peor que uno sin asignar, porque se ve
-- resuelto en la pantalla y nadie lo esta trabajando.
-- ---------------------------------------------------------------------
create or replace function public.asignar_carro(
  p_carro     bigint,
  p_linea     smallint,
  p_secadores text[],
  p_marca     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  actual  text;
  express boolean;
  s       text;
  cuantos int;
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

  -- Se limpian vacios por si la app manda algun hueco.
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

  -- La linea 1 es exclusiva de express. Se valida aqui ADEMAS de en la
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

  foreach s in array p_secadores loop
    insert into asignaciones (carro_id, linea, secador, inicio)
    values (p_carro, p_linea, btrim(s), now());
  end loop;

  return jsonb_build_object('ok', true, 'estado', 'secando', 'linea', p_linea, 'secadores', cuantos);
end;
$$;

comment on column public.carros.marca is 'Marca del carro. La captura el gerente al asignar, no la cajera.';
