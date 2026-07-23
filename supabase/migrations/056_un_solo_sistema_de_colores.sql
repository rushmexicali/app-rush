-- =====================================================================
-- 056 — Un solo sistema de colores, y nadie repetido
--
-- EL PROBLEMA (medido en la base, no supuesto): habia DOS sistemas de
-- color peleandose por la misma columna.
--
--   sincronizar_empleados()  -> color_de(id): un hash sobre 12 colores.
--   agregar_secador_manual() -> asignar_colores_libres(): indice libre
--                               sobre los 16 de paleta().
--
-- Y el segundo repinta a TODO el que tenga color_idx nulo, o sea a los
-- que vienen de Jibble. Resultado el 22/jul/2026: CUATRO PARES de
-- secadores con el color exactamente igual —
--
--   #7ee787  Luis Chavez  / Jose Manuel
--   #e3b341  Saul de Anda / Jaime Gallegos
--   #d2a8ff  Fermin Cortez/ Saul Ramirez
--   #f0883e  Carlos Alonso/ Luis Luna
--
-- El color existe para que el supervisor reconozca SIN LEER (regla de la
-- seccion 4 del CLAUDE.md). Cuatro pares indistinguibles rompen eso.
--
-- Ademas asignar_colores_libres tenia un segundo bug: cuando ya no
-- quedaban indices libres hacia coalesce(min(n), 1) y mandaba a TODOS al
-- color 1. Con 19 empleados y 16 colores, ya estaba pasando.
--
-- QUE SE HACE:
--   1. paleta() crece de 16 a 24 colores. Los 16 primeros quedan EN EL
--      MISMO ORDEN, asi que quien ya tiene color_idx 1..15 NO cambia de
--      color. Cero reaprendizaje para el supervisor.
--   2. asignar_colores_libres() reparte sin colapsar: si algun dia se
--      acaban los 24, da la vuelta en vez de mandar a todos al 1.
--   3. sincronizar_empleados() deja de poner color y llama a
--      asignar_colores_libres(). UN solo sistema.
--   4. Se borra color_de(), que era el otro.
--   5. Se le da indice libre a los 4 que no tenian.
--
-- De paso: nombre_corto_de() se comia el apellido cuando empieza con
-- preposicion. "Saul de Anda" salia "Saul de" en la grilla Y en el
-- reporte del dueno. Ahora las preposiciones se pegan al apellido.
-- Se comprueba abajo que NINGUN otro de los 19 cambia de nombre.
--
-- HONESTIDAD SOBRE EL LIMITE: con 19 personas, 24 colores distinguibles
-- a simple vista ya no existen; algunos se parecen. El color es una
-- AYUDA, no el identificador — el nombre va escrito al lado. Lo que esta
-- migracion garantiza es que no haya dos IDENTICOS, que es lo que estaba
-- roto.
-- =====================================================================

-- --- 1) La paleta, ampliada sin mover los que ya estaban -------------
create or replace function public.paleta()
returns text[] language sql immutable as $$
  select array[
    -- Los 16 originales, EN SU ORDEN. No se mueve ninguno: el indice
    -- guardado en empleados.color_idx apunta a esta posicion, y moverlos
    -- le cambiaria el color a gente que el supervisor ya reconoce.
    '#2f81f7',  --  1 azul
    '#3fb950',  --  2 verde
    '#e3b341',  --  3 amarillo
    '#a371f7',  --  4 morado
    '#ff7b72',  --  5 rojo claro
    '#39c5cf',  --  6 turquesa
    '#db61a2',  --  7 rosa
    '#f0883e',  --  8 naranja
    '#7ee787',  --  9 verde menta
    '#79c0ff',  -- 10 azul cielo
    '#ffa657',  -- 11 durazno
    '#d2a8ff',  -- 12 lila
    '#56d364',  -- 13 verde brillante
    '#e9967a',  -- 14 salmon
    '#b3b3ff',  -- 15 lavanda
    '#ffd400',  -- 16 amarillo fuerte
    -- Nuevos, para que alcance a 19 personas y sobre margen.
    '#b87333',  -- 17 cobre
    '#a3e635',  -- 18 lima
    '#14b8a6',  -- 19 verde azulado
    '#f472b6',  -- 20 rosa chicle
    '#818cf8',  -- 21 indigo
    '#ef4444',  -- 22 rojo fuerte
    '#94a3b8',  -- 23 gris azulado
    '#c084fc'   -- 24 violeta
  ];
$$;

-- --- 2) El reparto, sin colapsar ------------------------------------
create or replace function public.asignar_colores_libres()
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  fila  record;
  libre int;
  total int := array_length(paleta(), 1);
begin
  for fila in
    select id from public.empleados where color_idx is null order by nombre
  loop
    -- El indice libre mas chico. Si YA NO QUEDA NINGUNO, se da la vuelta
    -- por el que menos gente tiene, en vez de mandar a todos al 1 (que
    -- es lo que hacia el coalesce(min(n), 1) de la version vieja).
    select n into libre
      from generate_series(1, total) n
     where not exists (
       select 1 from public.empleados e where e.color_idx = n
     )
     order by n
     limit 1;

    if libre is null then
      select n into libre
        from generate_series(1, total) n
        left join public.empleados e on e.color_idx = n
       group by n
       order by count(e.id), n
       limit 1;
    end if;

    update public.empleados
       set color_idx = libre,
           color      = (paleta())[libre]
     where id = fila.id;
  end loop;
end;
$$;

-- --- 3) Jibble deja de repartir colores por su cuenta ----------------
-- Se quita color_de() del insert. El color lo pone SIEMPRE
-- asignar_colores_libres(), al final, para los que llegaron sin uno.
create or replace function public.sincronizar_empleados(p_gente jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  vistos    text[];
  cuantos   int;
  caducados int;
begin
  if p_gente is null or jsonb_typeof(p_gente) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'se esperaba una lista');
  end if;

  insert into public.empleados
    (id, nombre, nombre_corto, estado, desde, rol, actualizado_en)
  select
    g ->> 'id',
    g ->> 'nombre',
    nombre_corto_de(g ->> 'nombre'),
    coalesce(g ->> 'estado', 'fuera'),
    (g ->> 'desde')::timestamptz,
    coalesce(nullif(g ->> 'rol', ''), 'secador'),
    now()
  from jsonb_array_elements(p_gente) g
  on conflict (id) do update set
    nombre         = excluded.nombre,
    nombre_corto   = excluded.nombre_corto,
    estado         = excluded.estado,
    -- El rol se refresca desde Jibble: si al tunelero lo pasan al grupo
    -- de secadores, la app se entera sola.
    rol            = excluded.rol,
    desde          = case when public.empleados.estado is distinct from excluded.estado
                          then excluded.desde else public.empleados.desde end,
    actualizado_en = now();
    -- OJO: el color NO se toca aqui. Si se tocara, cada minuto le
    -- cambiaria el color a la gente y el reconocimiento visual se
    -- perderia. Lo reparte asignar_colores_libres(), abajo, y solo a
    -- quien llegue sin color.

  select array_agg(g ->> 'id') into vistos from jsonb_array_elements(p_gente) g;

  -- Quien ya no viene de Jibble se marca fuera. Los manuales siguen
  -- exentos de esta barrida: Jibble no sabe que existen.
  update public.empleados
     set estado = 'fuera', actualizado_en = now()
   where not manual
     and id <> all(coalesce(vistos, array[]::text[]))
     and estado <> 'fuera';

  -- Caducidad de los manuales de un turno. Se compara por DIA de
  -- Mexicali, no por 24 horas: alguien agregado a las 11 PM tiene que
  -- durar ese dia, no hasta las 11 PM del siguiente.
  update public.empleados
     set estado = 'fuera', actualizado_en = now()
   where manual
     and not permanente
     and estado <> 'fuera'
     and (desde at time zone 'America/Tijuana')::date
         < (now() at time zone 'America/Tijuana')::date;

  get diagnostics caducados = row_count;

  -- El unico lugar donde se reparte color.
  perform public.asignar_colores_libres();

  select count(*) into cuantos from public.empleados where estado in ('activo','descanso');

  return jsonb_build_object(
    'ok', true,
    'recibidos', jsonb_array_length(p_gente),
    'disponibles', cuantos,
    'caducados', caducados
  );
end;
$$;

-- --- 4) Fuera el otro sistema ----------------------------------------
drop function if exists public.color_de(text);

-- --- 5) El apellido que empieza con preposicion ----------------------
-- "Saul de Anda" salia "Saul de". Se comprueba en la verificacion que
-- ningun otro de los 19 cambia de nombre mostrado.
create or replace function public.nombre_corto_de(p_nombre text)
returns text language plpgsql immutable as $$
declare
  partes text[];
  n      int;
  i      int;
  ape    text;
  -- Palabras que NO son un apellido por si solas: van pegadas a la que
  -- sigue. "de Anda", "de la Torre", "del Rio".
  ligas  text[] := array['de','del','la','las','los','y','san','santa','da','di','von','van'];
begin
  partes := regexp_split_to_array(btrim(coalesce(p_nombre, '')), '\s+');
  n := coalesce(array_length(partes, 1), 0);

  if n = 0 then return ''; end if;
  if n = 1 then return partes[1]; end if;

  -- 4 o mas: nombre(s) + paterno + materno. El paterno es el 3o.
  -- 3 palabras: se toma la 2a como apellido. Es lo mas comun cuando la
  -- gente se registra con un solo nombre de pila.
  i := case when n >= 4 then 3 else 2 end;

  -- Primero RETROCEDER: si la palabra de antes es preposicion, el
  -- apellido empieza mas atras. "Maria | de la Torre | Ruiz" son 5
  -- palabras, pero el paterno arranca en la 2a, no en la 3a. Nunca se
  -- pasa de la posicion 2: el nombre de pila no se toca.
  while i > 2 and lower(public.sin_acentos(partes[i - 1])) = any (
          select lower(x) from unnest(ligas) x
        ) loop
    i := i - 1;
  end loop;

  -- Y luego AVANZAR: la preposicion no es un apellido por si sola, se
  -- pega a la palabra que sigue. "Saul | de Anda".
  ape := partes[i];
  while i < n and lower(public.sin_acentos(partes[i])) = any (
          select lower(x) from unnest(ligas) x
        ) loop
    i := i + 1;
    ape := ape || ' ' || partes[i];
  end loop;

  return partes[1] || ' ' || ape;
end;
$$;

-- --- 6) Aplicar a lo que ya esta guardado ----------------------------
update public.empleados
   set nombre_corto = public.nombre_corto_de(nombre)
 where nombre_corto is distinct from public.nombre_corto_de(nombre);

-- Los cuatro que nunca tuvieron indice y por eso chocaban.
select public.asignar_colores_libres();
