-- =====================================================================
-- RUSH Car Wash — Nombre corto: nombre + primer apellido
--
-- Los nombres mexicanos no se parten con una regla perfecta:
--
--   "Luis Alberto Coronado Calderon"  -> nombre nombre paterno materno
--   "Mario Alexander Hernandez"       -> nombre nombre paterno
--   "Jose Cruz Encino"                -> nombre paterno materno
--
-- Con 3 palabras es imposible saber si la segunda es segundo nombre o
-- apellido. La regla acierta en la mayoria; para los demas existe
-- "nombre_display", que el dueno corrige a mano y la sincronizacion
-- respeta.
-- =====================================================================

-- Sobrescribible a mano. Si tiene valor, gana sobre lo calculado.
alter table public.empleados add column if not exists nombre_display text;

comment on column public.empleados.nombre_display is
  'Nombre puesto a mano. Si existe, gana sobre el calculado de Jibble.';

create or replace function public.nombre_corto_de(p_nombre text)
returns text
language plpgsql
immutable
as $$
declare
  partes text[];
  n int;
begin
  partes := regexp_split_to_array(btrim(coalesce(p_nombre, '')), '\s+');
  n := coalesce(array_length(partes, 1), 0);

  if n = 0 then return ''; end if;
  if n = 1 then return partes[1]; end if;

  -- 4 o mas: nombre(s) + paterno + materno. El paterno es el 3o.
  if n >= 4 then return partes[1] || ' ' || partes[3]; end if;

  -- 3 palabras: se toma la 2a como apellido. Es lo mas comun cuando la
  -- gente se registra con un solo nombre de pila.
  return partes[1] || ' ' || partes[2];
end;
$$;

-- Las iniciales salen del nombre corto, no del completo. Asi los tres
-- Luis dejan de compartir iniciales.
create or replace function public.iniciales_de(p_nombre text)
returns text
language sql
immutable
as $$
  select upper(
    coalesce(substr((regexp_split_to_array(nombre_corto_de(p_nombre), '\s+'))[1], 1, 1), '') ||
    coalesce(substr((regexp_split_to_array(nombre_corto_de(p_nombre), '\s+'))[2], 1, 1), '')
  );
$$;

-- La sincronizacion ya no pisa el nombre puesto a mano.
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

  insert into public.empleados (id, nombre, nombre_corto, iniciales, color, estado, desde, actualizado_en)
  select
    g ->> 'id',
    g ->> 'nombre',
    nombre_corto_de(g ->> 'nombre'),
    iniciales_de(g ->> 'nombre'),
    color_de(g ->> 'id'),
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

-- Vista que usa la app: ya resuelve cual nombre mostrar.
create or replace view public.secadores as
select
  id,
  coalesce(nombre_display, nombre_corto, nombre) as mostrar,
  nombre as nombre_completo,
  iniciales,
  color,
  estado,
  desde,
  manual
from public.empleados;

comment on view public.secadores is 'Lo que la app muestra. Ya aplica el nombre corregido a mano.';
