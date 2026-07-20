-- =====================================================================
-- RUSH Car Wash — rechazar una entrega
--
-- Salio del uso real: el secador le avisa al supervisor que ya quedo, el
-- supervisor ve que el tablero esta sucio, y hasta hoy sus unicas
-- opciones eran entregarlo asi o no entregarlo. En ninguno de los dos
-- casos quedaba registro de quien fallo ni en que.
--
-- El objetivo NO es castigar: es saber a quien hay que entrenar y en que.
-- Por eso el rechazo se liga a la PERSONA, no al carro.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Una fila POR SECADOR, no por carro
--
-- Si dos personas secaban ese carro, un rechazo genera dos filas. Asi
-- "cuantos rechazos tiene Juan" es un count() y no una consulta que
-- tenga que desarmar arreglos.
--
-- Se guardan las dos cosas, igual que en asignaciones (migracion 014):
-- empleado_id para contar por persona aunque le cambien el nombre, y
-- secador con el nombre congelado para que el historial siga diciendo
-- quien fue aunque esa persona salga de Jibble.
-- ---------------------------------------------------------------------
-- "grupo" une las filas de UN mismo rechazo. Sin el, contar filas diria
-- que un rechazo de dos personas son dos rechazos: bueno para contar por
-- persona, malo para contar eventos. Con grupo, las dos cuentas salen
-- bien de la misma tabla:
--   por persona -> count(*)
--   por evento  -> count(distinct grupo)
create table if not exists public.rechazos (
  id          bigint generated always as identity primary key,
  grupo       uuid   not null,
  carro_id    bigint not null references public.carros(id) on delete cascade,
  empleado_id text references public.empleados(id) on delete set null,
  secador     text not null,
  motivo      text not null,
  creado_en   timestamptz not null default now()
);

create index if not exists rechazos_carro_idx    on public.rechazos (carro_id);
create index if not exists rechazos_empleado_idx on public.rechazos (empleado_id);
create index if not exists rechazos_creado_idx   on public.rechazos (creado_en desc);

alter table public.rechazos enable row level security;

comment on table public.rechazos is
  'Entregas rechazadas por el supervisor. Una fila por secador, para poder contar por persona.';

-- ---------------------------------------------------------------------
-- Los motivos
--
-- En una sola funcion para que la pantalla los lea de aqui en vez de
-- tenerlos copiados en el HTML. Si manana cambian, se cambian aqui.
--
-- NO hay restriccion en la columna motivo a proposito: si algun dia la
-- lista crece, un CHECK viejo empezaria a rechazar datos buenos. La
-- pantalla manda de esta lista; la base guarda lo que llegue.
-- ---------------------------------------------------------------------
create or replace function public.motivos_de_rechazo()
returns text[]
language sql
immutable
as $$
  select array[
    'Tablero',
    'Vidrios',
    'Rines',
    'Interior',
    'Marcos de puertas',
    'Cajuela',
    'Carroceria mojada',
    'Otro'
  ];
$$;

-- ---------------------------------------------------------------------
-- Rechazar
--
-- NO toca el estado, ni la linea, ni las etapas. El carro se queda
-- exactamente donde estaba, secando, con las mismas personas y con el
-- cronometro corriendo.
--
-- Que el reloj NO se reinicie es a proposito: rehacer algo mal hecho si
-- cuesta tiempo del taller. Si se reiniciara, el promedio de ese equipo
-- escondería el retrabajo, que es justo el dato que se quiere ver.
-- ---------------------------------------------------------------------
create or replace function public.rechazar_entrega(p_carro bigint, p_motivo text)
returns jsonb
language plpgsql
as $$
declare
  actual  text;
  limpio  text;
  cuantos int;
  v_grupo uuid := gen_random_uuid();
begin
  select estado into actual from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  if actual <> 'secando' then
    return jsonb_build_object('ok', false, 'error', 'Solo se puede rechazar un carro que esta secando');
  end if;

  limpio := nullif(btrim(coalesce(p_motivo, '')), '');
  if limpio is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el motivo del rechazo');
  end if;

  -- Una fila por cada persona que lo estaba secando.
  insert into public.rechazos (grupo, carro_id, empleado_id, secador, motivo)
  select v_grupo, p_carro, a.empleado_id, a.secador, limpio
    from public.asignaciones a
   where a.carro_id = p_carro and a.fin is null;

  get diagnostics cuantos = row_count;

  -- Un carro secando SIEMPRE deberia tener asignacion abierta, pero si
  -- por lo que sea no la tiene, el rechazo se registra igual sin persona.
  -- Perder el dato del rechazo por un hueco en la asignacion seria peor:
  -- el supervisor ya hizo su parte al reportarlo.
  if cuantos = 0 then
    insert into public.rechazos (grupo, carro_id, empleado_id, secador, motivo)
    values (v_grupo, p_carro, null, '(sin secador asignado)', limpio);
    cuantos := 1;
  end if;

  return jsonb_build_object('ok', true, 'secadores', cuantos, 'motivo', limpio);
end;
$$;

comment on function public.rechazar_entrega(bigint, text) is
  'Registra un rechazo de entrega. NO cambia el estado del carro: sigue secando con los mismos secadores.';
