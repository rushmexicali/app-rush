-- =====================================================================
-- RUSH Car Wash — El guion separa el color del nombre del cliente
--
-- Las cajeras ya tienen la instruccion de escribir la nota asi:
--
--     <CODIGO> <COLOR> - <NOMBRE DEL CLIENTE>
--     PU NEGRA - LUIS GONZALEZ
--
-- El guion vuelve la lectura exacta en vez de adivinada. Antes se usaba
-- el monto para deducir donde acababa el color (solo las ventas gratis
-- llevan nombre); eso se conserva como respaldo para cuando falte el
-- guion, porque la nota la escribe una persona con prisa.
-- =====================================================================

create or replace function public.interpretar_nota(p_nota text, p_gratis boolean default false)
returns jsonb
language plpgsql
immutable
as $$
declare
  limpia   text;
  trozos   text[];
  partes   text[];
  n        int;
  tipo     text;
  color    text;
  cliente  text;
begin
  if p_nota is null or btrim(p_nota) = '' then
    return jsonb_build_object('tipo_unidad', null, 'color', null, 'cliente', null);
  end if;

  limpia := upper(btrim(p_nota));

  -- Se parte en el PRIMER guion, con espacios o sin ellos.
  -- La instruccion a las cajeras es "un guion donde termina el color y
  -- empieza el nombre", asi que el guion significa separador y ya.
  --
  -- El costo: un color compuesto escrito con guion (AZUL-MARINO) se
  -- partiria mal. Se acepta a proposito, porque escribir "BLANCA-JUAN"
  -- de corrido es mucho mas probable que escribir un color con guion, y
  -- perder el nombre del cliente duele mas: es el registro del 6to
  -- lavado gratis. Ademas el supervisor ve el color y lo puede corregir;
  -- el nombre perdido no lo puede adivinar nadie.
  trozos := regexp_split_to_array(limpia, '\s*-\s*');

  if array_length(trozos, 1) >= 2 then
    cliente := nullif(btrim(array_to_string(trozos[2:array_length(trozos,1)], ' ')), '');
    limpia  := btrim(trozos[1]);
  end if;

  partes := regexp_split_to_array(limpia, '\s+');
  n := array_length(partes, 1);

  tipo := case partes[1]
    when 'PU' then 'pickup'
    when 'CA' then 'camioneta'
    when 'AU' then 'automovil'
    when 'PA' then 'pasajeros'
    else null
  end;

  -- Codigo no reconocido: no se adivina nada. Un dato inventado es peor
  -- que uno faltante, porque el supervisor confia en lo que ve.
  if tipo is null then
    return jsonb_build_object('tipo_unidad', null, 'color', null, 'cliente', null);
  end if;

  if n >= 2 then
    if cliente is not null then
      -- Con guion: todo lo de la izquierda despues del codigo es color.
      color := array_to_string(partes[2:n], ' ');
    elsif p_gratis and n >= 3 then
      -- Sin guion, respaldo: solo las gratis llevan nombre de cliente.
      color   := partes[2];
      cliente := array_to_string(partes[3:n], ' ');
    else
      color := array_to_string(partes[2:n], ' ');
    end if;
  end if;

  return jsonb_build_object('tipo_unidad', tipo, 'color', color, 'cliente', cliente);
end;
$$;

-- Releer las notas de los carros que el supervisor no haya corregido.
update public.carros c
set tipo_unidad   = leido ->> 'tipo_unidad',
    color         = leido ->> 'color',
    cliente       = leido ->> 'cliente',
    datos_de_nota = (leido ->> 'tipo_unidad') is not null
from (
  select id, interpretar_nota(nota, coalesce(monto, 0) = 0) as leido
  from public.carros
  where nota is not null
) recalculado
where c.id = recalculado.id
  and c.datos_de_nota;
