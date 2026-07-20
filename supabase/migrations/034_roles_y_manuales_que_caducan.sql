-- =====================================================================
-- RUSH Car Wash — Quien mas puede secar, y los manuales que caducan
--
-- Dos cosas que salieron del uso real el 20/jul/2026.
--
-- ---------------------------------------------------------------------
-- 1) No solo los secadores secan
-- ---------------------------------------------------------------------
-- La sincronizacion traia UNICAMENTE el grupo "Secador" de Jibble. El
-- comentario en la Edge Function decia "no tiene caso traer supervisores,
-- tuneleros ni cajeras". Resulto falso: cuando hay mucho trabajo, el
-- tunelero y los supervisores se ponen a secar tambien.
--
-- Ahora se traen tres grupos de Jibble:
--   Secador     -> rol 'secador'
--   Tunelero    -> rol 'tunelero'
--   Supervisor  -> rol 'supervisor'
--
-- La CAJERA se queda fuera a proposito: no seca, y meterla solo alargaria
-- la lista que el supervisor tiene que recorrer con el pulgar.
--
-- El rol NO cambia lo que la persona puede hacer — cualquiera de estos
-- puede secar. Solo sirve para AGRUPARLOS en la pantalla, porque el caso
-- comun sigue siendo elegir un secador y esos deben salir primero.
--
-- ---------------------------------------------------------------------
-- 2) "manual" significaba dos cosas distintas
-- ---------------------------------------------------------------------
-- El boton "No aparece" crea un empleado con manual=true. La
-- sincronizacion los respeta (`where not manual`) para que Jibble no los
-- tumbe. Efecto secundario: se quedan 'activo' PARA SIEMPRE y no habia
-- forma de quitarlos desde la app.
--
-- El 20/jul/2026 ya habia uno ("eri") que iba a salir en la grilla todos
-- los dias del resto del ano.
--
-- Pero el mismo mecanismo es el que necesita Guillermo Lara, el gerente:
-- no esta en Jibble, no tiene horario, y SIEMPRE debe poder asignarse.
--
-- Son dos necesidades opuestas, asi que se separan:
--
--   manual + permanente=false  -> parche de un turno. Caduca al terminar
--                                 el dia en que se agrego.
--   manual + permanente=true   -> gente de planta fuera de Jibble.
--                                 Nunca caduca. Hoy: Guillermo Lara.
--
-- Se prefirio que caduquen solos en vez de poner un boton de "quitar":
-- el supervisor agrega a alguien a mano en el unico momento en que tiene
-- prisa, y pedirle que se acuerde de limpiarlo despues es pedirle algo
-- que no va a pasar. Caducar no necesita que nadie se acuerde.
--
-- Ojo: caducar NO borra a la persona ni sus asignaciones. Solo la saca de
-- la lista de disponibles. Quien seco un carro sigue siendo dato de
-- eficiencia y no se toca nunca.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Columnas nuevas
-- ---------------------------------------------------------------------
alter table public.empleados
  add column if not exists rol text not null default 'secador';

alter table public.empleados
  add column if not exists permanente boolean not null default false;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'empleados_rol_valido'
  ) then
    alter table public.empleados
      add constraint empleados_rol_valido
      check (rol in ('secador', 'tunelero', 'supervisor', 'gerente'));
  end if;
end $$;

comment on column public.empleados.rol is
  'Grupo de Jibble: secador, tunelero, supervisor. O gerente (manual). Solo agrupa en pantalla; todos pueden secar.';

comment on column public.empleados.permanente is
  'Manual que NUNCA caduca (gente de planta fuera de Jibble). Los manuales normales caducan al terminar su dia.';

-- ---------------------------------------------------------------------
-- Guillermo Lara — gerente, no esta en Jibble, siempre disponible
--
-- Se busco en las 38 personas de Jibble el 20/jul/2026 y no aparece, tal
-- como dijo el dueno: no tiene horario. Por eso entra a mano y permanente.
-- Id fijo (no aleatorio) para que si esto se vuelve a correr no se
-- duplique.
-- ---------------------------------------------------------------------
insert into public.empleados
  (id, nombre, nombre_corto, nombre_display, iniciales, estado, desde,
   manual, permanente, rol, actualizado_en)
values
  ('manual-guillermo-lara', 'Guillermo Lara', nombre_corto_de('Guillermo Lara'),
   'Guillermo Lara', iniciales_de('Guillermo Lara'), 'activo', now(),
   true, true, 'gerente', now())
on conflict (id) do update set
  permanente = true,
  rol        = 'gerente',
  estado     = 'activo';

select public.asignar_colores_libres();

-- ---------------------------------------------------------------------
-- La sincronizacion, ahora con rol y con caducidad
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
  caducados int;
begin
  if p_gente is null or jsonb_typeof(p_gente) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'se esperaba una lista');
  end if;

  insert into public.empleados
    (id, nombre, nombre_corto, iniciales, color, estado, desde, rol, actualizado_en)
  select
    g ->> 'id',
    g ->> 'nombre',
    nombre_corto_de(g ->> 'nombre'),
    iniciales_de(g ->> 'nombre'),
    color_de(g ->> 'id'),
    coalesce(g ->> 'estado', 'fuera'),
    (g ->> 'desde')::timestamptz,
    coalesce(nullif(g ->> 'rol', ''), 'secador'),
    now()
  from jsonb_array_elements(p_gente) g
  on conflict (id) do update set
    nombre         = excluded.nombre,
    nombre_corto   = excluded.nombre_corto,
    iniciales      = excluded.iniciales,
    estado         = excluded.estado,
    -- El rol se refresca desde Jibble: si al tunelero lo pasan al grupo
    -- de secadores, la app se entera sola.
    rol            = excluded.rol,
    desde          = case when public.empleados.estado is distinct from excluded.estado
                          then excluded.desde else public.empleados.desde end,
    actualizado_en = now();

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

  select count(*) into cuantos from public.empleados where estado in ('activo','descanso');

  return jsonb_build_object(
    'ok', true,
    'recibidos', jsonb_array_length(p_gente),
    'disponibles', cuantos,
    'caducados', caducados
  );
end;
$$;

comment on function public.sincronizar_empleados(jsonb) is
  'Guarda quien esta checado (con su rol) y caduca los manuales de dias anteriores.';

-- ---------------------------------------------------------------------
-- El boton "No aparece" sigue creando manuales de un turno
--
-- Se le agrega el rol: quien se agrega a mano en la pantalla de asignar
-- se esta agregando para SECAR, asi que sale con los secadores y no en
-- la seccion de abajo.
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
    (id, nombre, nombre_corto, nombre_display, iniciales, estado, desde,
     manual, permanente, rol, actualizado_en)
  values
    (nuevo, limpio, nombre_corto_de(limpio), limpio, iniciales_de(limpio),
     'activo', now(), true, false, 'secador', now());

  perform public.asignar_colores_libres();

  return jsonb_build_object('ok', true, 'id', nuevo, 'nombre', limpio);
end;
$$;

-- ---------------------------------------------------------------------
-- La vista que usa la app, ahora con rol
--
-- "orden" existe para que la pantalla no tenga que saber la jerarquia:
-- 0 = secadores (el caso comun, van arriba), 1 = los demas.
-- ---------------------------------------------------------------------
create or replace view public.secadores as
select
  id,
  coalesce(nombre_display, nombre_corto, nombre) as mostrar,
  nombre as nombre_completo,
  iniciales_de(coalesce(nombre_display, nombre_corto, nombre)) as iniciales,
  color,
  estado,
  desde,
  manual,
  permanente,
  rol,
  case when rol = 'secador' then 0 else 1 end as orden
from public.empleados;

comment on view public.secadores is
  'Quien puede secar. orden=0 secadores, orden=1 tunelero/supervisor/gerente (tambien secan cuando hay carga).';
