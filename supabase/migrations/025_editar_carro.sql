-- =====================================================================
-- RUSH Car Wash — el supervisor puede corregir tipo, color y marca
--
-- La migracion 003 decia: "si la nota falta o viene mal, el supervisor la
-- llena o la corrige en la app". Ese camino NUNCA se construyo. Hasta hoy
-- color, tipo_unidad y cliente se escribian una sola vez en el disparador
-- y no habia forma de tocarlos; la marca solo se podia poner en el
-- momento exacto de asignar.
--
-- Al 19/jul/2026 la mayoria de los carros llegan sin datos porque la nota
-- de caja todavia no es habito. Sin esta funcion, el supervisor ve "Sin
-- datos del carro" y no puede hacer nada al respecto.
-- =====================================================================

create or replace function public.editar_carro(
  p_carro       bigint,
  p_tipo_unidad text default null,
  p_color       text default null,
  p_marca       text default null,
  p_linea       smallint default null
)
returns jsonb
language plpgsql
as $$
declare
  actual     text;
  express    boolean;
  toco_datos boolean;
begin
  select estado, es_express into actual, express
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

  -- datos_de_nota existe para medir que tan seguido la cajera llena la
  -- nota. Si el supervisor captura el tipo o el color, ese dato YA NO
  -- vino de la nota — si no se baja, la correccion del supervisor se
  -- contaria como si la cajera lo hubiera hecho bien, y la medicion
  -- quedaria inservible justo para lo que existe.
  toco_datos := (p_tipo_unidad is not null) or (p_color is not null);

  update public.carros
     set tipo_unidad   = coalesce(nullif(btrim(coalesce(p_tipo_unidad, '')), ''), tipo_unidad),
         color         = coalesce(nullif(btrim(upper(coalesce(p_color, ''))), ''), color),
         marca         = coalesce(nullif(btrim(upper(coalesce(p_marca, ''))), ''), marca),
         linea         = coalesce(p_linea, linea),
         datos_de_nota = case when toco_datos then false else datos_de_nota end
   where id = p_carro;

  -- Que la asignacion no se quede apuntando a la linea vieja.
  if p_linea is not null then
    update public.asignaciones set linea = p_linea
     where carro_id = p_carro and fin is null;
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.editar_carro(bigint, text, text, text, smallint) is
  'Corrige tipo/color/marca (y linea si ya esta secando). Nulo = no tocar ese campo.';
