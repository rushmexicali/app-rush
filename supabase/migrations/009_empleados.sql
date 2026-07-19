-- =====================================================================
-- RUSH Car Wash — Fase 3: quien esta para secar
--
-- Los datos vienen de Jibble. Se guardan aqui en vez de consultarle a
-- Jibble en cada toque de pantalla, por dos razones: la app responde al
-- instante, y si Jibble se cae el supervisor sigue viendo la ultima
-- lista buena en lugar de una pantalla vacia.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Iniciales para el boton. No hay fotos en Jibble, asi que estas hacen
-- el trabajo de reconocimiento visual.
-- ---------------------------------------------------------------------
create or replace function public.iniciales_de(p_nombre text)
returns text
language sql
immutable
as $$
  select upper(
    coalesce(substr((regexp_split_to_array(btrim(coalesce(p_nombre,'')), '\s+'))[1], 1, 1), '') ||
    coalesce(substr((regexp_split_to_array(btrim(coalesce(p_nombre,'')), '\s+'))[2], 1, 1), '')
  );
$$;

-- ---------------------------------------------------------------------
-- Nombre corto: "Luis Alberto Coronado Calderon" no cabe en un boton.
-- Se queda con nombre y primer apellido.
-- ---------------------------------------------------------------------
create or replace function public.nombre_corto_de(p_nombre text)
returns text
language sql
immutable
as $$
  select btrim(
    coalesce((regexp_split_to_array(btrim(coalesce(p_nombre,'')), '\s+'))[1], '') || ' ' ||
    coalesce((regexp_split_to_array(btrim(coalesce(p_nombre,'')), '\s+'))[2], '')
  );
$$;

-- ---------------------------------------------------------------------
-- Color fijo por persona. Se calcula del id, asi que NUNCA cambia:
-- el supervisor aprende a reconocer "el verde" como reconoceria una
-- cara. Si el color cambiara, ese aprendizaje se perderia.
-- ---------------------------------------------------------------------
create or replace function public.color_de(p_id text)
returns text
language sql
immutable
as $$
  select (array[
    '#2f81f7','#3fb950','#e3b341','#a371f7','#ff7b72','#39c5cf',
    '#db61a2','#f0883e','#7ee787','#79c0ff','#ffa657','#d2a8ff'
  ])[ (abs(hashtext(coalesce(p_id,''))) % 12) + 1 ];
$$;

-- ---------------------------------------------------------------------
-- empleados
-- ---------------------------------------------------------------------
create table if not exists public.empleados (
  -- El id de Jibble. Los manuales llevan uno inventado con prefijo.
  id             text primary key,
  nombre         text not null,
  nombre_corto   text,
  iniciales      text,
  color          text,

  -- activo   = checado y trabajando
  -- descanso = checado pero en break (se muestra en gris, SI se puede
  --            asignar: puede regresar en un minuto)
  -- fuera    = no checo hoy, o ya se fue (no aparece en la pantalla)
  estado         text not null default 'fuera',

  -- Desde cuando esta en ese estado. Sirve para "lleva 40 min en break".
  desde          timestamptz,

  -- true = lo agrego el supervisor a mano porque no aparecia en Jibble.
  -- El CLAUDE.md exige ese respaldo: la app nunca se debe quedar
  -- bloqueada porque una integracion externa fallo.
  manual         boolean not null default false,

  actualizado_en timestamptz not null default now(),

  constraint empleados_estado_valido
    check (estado in ('activo','descanso','fuera'))
);

create index if not exists empleados_estado_idx on public.empleados (estado);

-- Las asignaciones ya guardan el nombre del secador. Se agrega el id
-- para poder medir eficiencia por persona aunque cambie de nombre.
alter table public.asignaciones add column if not exists empleado_id text;

-- ---------------------------------------------------------------------
-- Recibe la lista completa de Jibble y deja la tabla igual a ella.
--
-- Se manda TODA la lista y no solo los cambios: si un aviso se pierde
-- nadie se entera, pero si se manda todo, cada sincronizacion corrige
-- lo que la anterior haya dejado mal.
-- ---------------------------------------------------------------------
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
    -- Solo se mueve "desde" si de verdad cambio de estado, para no
    -- reiniciar el contador en cada sincronizacion.
    desde          = case when public.empleados.estado is distinct from excluded.estado
                          then excluded.desde else public.empleados.desde end,
    actualizado_en = now();

  select array_agg(g ->> 'id') into vistos from jsonb_array_elements(p_gente) g;

  -- Quien ya no viene en la lista de Jibble se marca fuera. A los
  -- manuales no se les toca: Jibble no sabe de ellos.
  update public.empleados
     set estado = 'fuera', actualizado_en = now()
   where not manual
     and id <> all(coalesce(vistos, array[]::text[]))
     and estado <> 'fuera';

  select count(*) into cuantos from public.empleados where estado in ('activo','descanso');
  return jsonb_build_object('ok', true, 'recibidos', jsonb_array_length(p_gente), 'disponibles', cuantos);
end;
$$;

alter table public.empleados enable row level security;

comment on table public.empleados is 'Secadores traidos de Jibble. La app pregunta aqui, no a Jibble.';
comment on column public.empleados.color is 'Fijo por persona. Sustituye a la foto para reconocer de un vistazo.';
