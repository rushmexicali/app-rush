-- =====================================================================
-- RUSH Car Wash — Un color distinto para cada secador
--
-- El color es el sustituto de la foto: el supervisor reconoce "el verde"
-- como reconoceria una cara. Si dos personas comparten color, no
-- sustituye nada.
--
-- La version anterior calculaba el color con un hash del id, y chocaba:
-- Edgar Reyes y Luis Luna quedaron del mismo rojo, Jose y Pablo Cruz del
-- mismo morado.
--
-- Ahora cada quien recibe el primer color libre al darse de alta, y ese
-- color YA NO CAMBIA. No se reparten por orden alfabetico a proposito:
-- eso le cambiaria el color a todos cada vez que entre alguien nuevo, y
-- el supervisor tendria que reaprender la paleta completa.
-- =====================================================================

alter table public.empleados add column if not exists color_idx int;

create or replace function public.paleta()
returns text[]
language sql
immutable
as $$
  select array[
    '#2f81f7',  -- azul
    '#3fb950',  -- verde
    '#e3b341',  -- amarillo
    '#a371f7',  -- morado
    '#ff7b72',  -- rojo claro
    '#39c5cf',  -- turquesa
    '#db61a2',  -- rosa
    '#f0883e',  -- naranja
    '#7ee787',  -- verde menta
    '#79c0ff',  -- azul cielo
    '#ffa657',  -- durazno
    '#d2a8ff',  -- lila
    '#56d364',  -- verde brillante
    '#e9967a',  -- salmon
    '#b3b3ff',  -- lavanda
    '#ffd400'   -- amarillo fuerte
  ];
$$;

-- Reparte colores libres a quien no tenga, respetando los ya asignados.
create or replace function public.asignar_colores_libres()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  fila record;
  libre int;
  total int := array_length(paleta(), 1);
begin
  for fila in
    select id from public.empleados where color_idx is null order by nombre
  loop
    select coalesce(min(n), 1) into libre
      from generate_series(1, total) n
     where n not in (select color_idx from public.empleados where color_idx is not null);

    update public.empleados
       set color_idx = libre,
           color = (paleta())[libre]
     where id = fila.id;
  end loop;
end;
$$;

-- Los que ya existen: se les reparte ahora.
update public.empleados set color_idx = null, color = null;
select public.asignar_colores_libres();

-- La sincronizacion reparte color solo a los nuevos.
create or replace function public.sincronizar_empleados(p_gente jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  vistos text[];
  cuantos int;
begin
  if p_gente is null or jsonb_typeof(p_gente) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'se esperaba una lista');
  end if;

  insert into public.empleados (id, nombre, nombre_corto, iniciales, estado, desde, actualizado_en)
  select
    g ->> 'id',
    g ->> 'nombre',
    nombre_corto_de(g ->> 'nombre'),
    iniciales_de(g ->> 'nombre'),
    coalesce(g ->> 'estado', 'fuera'),
    (g ->> 'desde')::timestamptz,
    now()
  from jsonb_array_elements(p_gente) g
  on conflict (id) do update set
    nombre         = excluded.nombre,
    nombre_corto   = excluded.nombre_corto,
    iniciales      = excluded.iniciales,
    estado         = excluded.estado,
    desde          = case when public.empleados.estado is distinct from excluded.estado
                          then excluded.desde else public.empleados.desde end,
    actualizado_en = now();

  -- Solo los nuevos reciben color; los demas conservan el suyo.
  perform public.asignar_colores_libres();

  select array_agg(g ->> 'id') into vistos from jsonb_array_elements(p_gente) g;

  update public.empleados
     set estado = 'fuera', actualizado_en = now()
   where not manual
     and id <> all(coalesce(vistos, array[]::text[]))
     and estado <> 'fuera';

  select count(*) into cuantos from public.empleados where estado in ('activo','descanso');
  return jsonb_build_object('ok', true, 'recibidos', jsonb_array_length(p_gente), 'disponibles', cuantos);
end;
$$;

-- ---------------------------------------------------------------------
-- Los tres nombres que la regla automatica no pudo acertar.
-- Son los de 3 palabras, donde no hay forma de saber si la segunda es
-- segundo nombre o apellido. "AntonioLuna" viene sin espacio de Jibble.
-- ---------------------------------------------------------------------
update public.empleados set nombre_display = 'Mario Hernández'  where nombre like 'Mario Alexander%';
update public.empleados set nombre_display = 'Walter Rodríguez' where nombre like 'Walter Armando%';
update public.empleados set nombre_display = 'Jorge Luna'       where nombre like 'Jorge Antonio%';
