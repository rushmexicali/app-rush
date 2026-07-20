-- =====================================================================
-- RUSH Car Wash — datos_de_nota solo se apaga si el valor CAMBIA
--
-- El bug (encontrado el 20/jul/2026 midiendo, no leyendo): la columna
-- carros.datos_de_nota mide que tan seguido la cajera llena la nota. Pero
-- editar_carro la apagaba en cuanto le llegaba un tipo o un color NO NULO,
-- sin fijarse si eran los MISMOS que ya tenia.
--
-- La pantalla de asignar viene prellenada con el tipo y el color que puso
-- la nota. El supervisor no los toca —solo escoge linea y secadores— y al
-- confirmar, /asignar reenvia esos mismos valores a editar_carro. La
-- version vieja los tomaba como "el supervisor capturo datos" y apagaba la
-- bandera. Resultado: el 20/jul la columna decia 1 nota cuando en realidad
-- las 25 ventas traian nota. Medir el habito de las cajeras con esa columna
-- daba lo contrario de la verdad.
--
-- Arreglo: solo cuenta como captura del supervisor si el valor que llega es
-- DISTINTO al que ya estaba. Reenviar el mismo valor no la apaga. Aplica
-- igual a /asignar y a /editar (Corregir), que las dos pasan por aqui.
--
-- Lo unico que cambia respecto a la 025 es como se calcula toco_datos; el
-- resto de la funcion es identica.
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
  actual        text;
  express       boolean;
  actual_tipo   text;
  actual_color  text;
  nuevo_tipo    text;
  nuevo_color   text;
  toco_datos    boolean;
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

  -- Los valores que llegan, ya limpios igual que en el update de abajo, para
  -- poder compararlos con lo que ya hay guardado.
  nuevo_tipo  := nullif(btrim(coalesce(p_tipo_unidad, '')), '');
  nuevo_color := nullif(btrim(upper(coalesce(p_color, ''))), '');

  -- datos_de_nota mide si el tipo/color vinieron de la nota. Solo se apaga
  -- si el supervisor CAMBIA algo: un valor nuevo distinto al que ya estaba.
  -- Reenviar el mismo (lo que hace la pantalla de asignar al confirmar sin
  -- tocar nada) no la apaga — ese era el bug de la 025. 'is distinct from'
  -- trata bien los nulos: agregar un dato donde no habia tambien cuenta como
  -- captura del supervisor.
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

  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.editar_carro(bigint, text, text, text, smallint) is
  'Corrige tipo/color/marca (y linea si ya esta secando). Nulo = no tocar ese campo. datos_de_nota solo se apaga si el valor cambia (051).';
