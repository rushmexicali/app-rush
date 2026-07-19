-- =====================================================================
-- RUSH Car Wash — Reconocer donde acaba el color aunque falte el guion
--
-- Las cajeras deben separar con guion ("PU NEGRA - LUIS GONZALEZ"), pero
-- se les va a olvidar. Con una lista de colores conocidos se puede saber
-- donde termina el color sin necesidad del guion.
--
-- La trampa: HAY NOMBRES DE PERSONA QUE SON COLORES. "PU NEGRA ROSA
-- MARTINEZ" no es un carro negro-rosa, es un carro negro de Rosa
-- Martinez. Por eso hay dos listas separadas:
--
--   COLORES BASE  - un carro tiene UNO. Al encontrarlo, el color termina.
--   MODIFICADORES - solo valen DESPUES de un color base (azul MARINO,
--                   verde OLIVO, azul REY). Nunca arrancan un color.
--
-- Asi "NEGRA ROSA" corta en NEGRA (ROSA es color base, no modificador)
-- mientras que "AZUL MARINO" si se lee completo.
-- =====================================================================

-- Las notas se escriben a mano: con acentos, sin acentos, como salga.
create or replace function public.sin_acentos(t text)
returns text
language sql
immutable
as $$
  select translate(upper(coalesce(t, '')), 'ÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑÇ', 'AAAAEEEEIIIIOOOOUUUUNC');
$$;

create or replace function public.interpretar_nota(p_nota text, p_gratis boolean default false)
returns jsonb
language plpgsql
immutable
as $$
declare
  -- Un carro tiene UN color base. Al toparse con uno, el color termina.
  colores_base text[] := array[
    'BLANCO','BLANCA','NEGRO','NEGRA','GRIS','PLATA','PLATEADO','PLATEADA',
    'ROJO','ROJA','AZUL','VERDE','AMARILLO','AMARILLA','NARANJA','ANARANJADO',
    'CAFE','MARRON','BEIGE','ARENA','CREMA','MARFIL','HUESO',
    'DORADO','DORADA','ORO','BRONCE','COBRE','PERLA','CHAMPAGNE','CHAMPANA',
    'MORADO','MORADA','VIOLETA','LILA','ROSA','ROSADO','ROSADA',
    'VINO','GUINDA','TINTO','TURQUESA','AQUA','CELESTE','TITANIO','GRAFITO',
    'PLOMO','ACERO','HUMO','MOSTAZA','OCRE','CORAL'
  ];

  -- Solo cuentan DESPUES de un color base. Nunca inician un color.
  modificadores text[] := array[
    'MARINO','REY','CIELO','CLARO','OSCURO','FUERTE','BAJITO','PASTEL',
    'METALICO','METALICA','MATE','BRILLANTE','PERLADO','PERLADA',
    'OLIVO','MILITAR','BANDERA','LIMON','BOTELLA','ESMERALDA','MENTA',
    'CEREZO','QUEMADO','ELECTRICO','FLUORESCENTE','NEON','SECO','ITALIA',
    -- Estas tambien son colores base, pero se aceptan como modificador
    -- para que "VINO TINTO" y "ROJO VINO" se lean completos. Una palabra
    -- puede estar en las dos listas. No se agrega ROSA a proposito:
    -- ahi la proteccion del nombre vale mas que el color compuesto.
    'VINO','TINTO'
  ];

  limpia   text;
  trozos   text[];
  partes   text[];
  n        int;
  i        int;
  tipo     text;
  color    text;
  cliente  text;
  corte    int;
begin
  if p_nota is null or btrim(p_nota) = '' then
    return jsonb_build_object('tipo_unidad', null, 'color', null, 'cliente', null);
  end if;

  limpia := sin_acentos(btrim(p_nota));

  -- --- 1) El guion manda. Si esta, no hay nada que adivinar. -----------
  -- Se parte con espacios o sin ellos: una cajera con prisa escribe
  -- "BLANCA-JUAN" de corrido.
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

  if n < 2 then
    return jsonb_build_object('tipo_unidad', tipo, 'color', null, 'cliente', cliente);
  end if;

  -- --- 2) Con guion: todo lo que queda a la izquierda es color --------
  if cliente is not null then
    color := array_to_string(partes[2:n], ' ');
    return jsonb_build_object('tipo_unidad', tipo, 'color', color, 'cliente', cliente);
  end if;

  -- --- 3) Sin guion: buscar donde acaba el color ----------------------
  if partes[2] = any(colores_base) then
    corte := 2;
    -- Se extiende solo con modificadores. Otro color base corta aqui,
    -- que es lo que salva a "NEGRA ROSA MARTINEZ".
    i := 3;
    while i <= n and partes[i] = any(modificadores) loop
      corte := i;
      i := i + 1;
    end loop;

    color := array_to_string(partes[2:corte], ' ');
    if corte < n then
      cliente := array_to_string(partes[corte+1:n], ' ');
    end if;

    return jsonb_build_object('tipo_unidad', tipo, 'color', color, 'cliente', cliente);
  end if;

  -- --- 4) Color desconocido: respaldo de antes ------------------------
  -- Si el color no esta en la lista no se puede saber donde acaba, asi
  -- que se usa lo que ya se sabia: solo las ventas gratis llevan nombre.
  if p_gratis and n >= 3 then
    color   := partes[2];
    cliente := array_to_string(partes[3:n], ' ');
  else
    color := array_to_string(partes[2:n], ' ');
  end if;

  return jsonb_build_object('tipo_unidad', tipo, 'color', color, 'cliente', cliente);
end;
$$;

-- Releer las notas que no haya corregido el supervisor.
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
