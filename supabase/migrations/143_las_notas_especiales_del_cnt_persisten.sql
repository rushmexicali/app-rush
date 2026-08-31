-- =====================================================================
-- 143 — La correccion de "GRATIS PENDIENTE" sobrevive a un reset.
--
-- EL PROBLEMA QUE CIERRA: la migracion 142 arreglo las 46 notas especiales
-- del ClientNoteTracker (31 marcadores que no son lavados, 15 canjes
-- disfrazados de pagados) escribiendo directo sobre `visitas`. Pero
-- `stg_cnt` sigue teniendolas crudas, asi que **el dia que alguien corriera
-- `reset-total.sql` otra vez, el bug volveria** — y en silencio: la cuenta
-- de gratis pasaria de 226 a 224 sin que nadie lo notara. Se vio en el
-- dry-run de la suite, no leyendo el codigo.
--
-- 🔑 UNA SOLA FUENTE. La lista NO se copia en el reset: vive aqui, en una
--    tabla, y tanto la 142 como `reset-total.sql` le preguntan a ella. Una
--    segunda copia de estas 46 filas es exactamente como se desfasan las
--    cosas en este proyecto.
--
-- Se guarda por (nombre normalizado + minuto) y no por `visitas.id` a
-- proposito: el reset BORRA y recrea las visitas, asi que cualquier id que
-- guardaramos apuntaria a la nada. El nombre y el minuto son lo unico que
-- sobrevive al borron.
--
-- ⚠️ Esto es historia CONGELADA del CNT, que se retiro el 31/ago/2026. La
--    tabla no crece nunca mas. Si algun dia se vuelve a llenar, algo esta
--    mal.
-- =====================================================================

create table if not exists public.cnt_notas_especiales (
  nombre_norm text        not null,
  dt_local    timestamp   not null,
  clase       text        not null check (clase in ('MARCADOR','CANJE')),
  primary key (nombre_norm, dt_local, clase)
);

comment on table public.cnt_notas_especiales is
  'Notas "GRATIS PENDIENTE" del ClientNoteTracker. MARCADOR = se le guardaba '
  'el gratis, NO es un lavado. CANJE = uso el gratis guardado. Historia '
  'congelada: el CNT se retiro el 31/ago/2026 y esto no vuelve a crecer.';

-- Se puebla desde lo que la 142 ya resolvió: ahi estan las 46 filas con su
-- persona y su hora, ya casadas contra la base.
insert into public.cnt_notas_especiales (nombre_norm, dt_local, clase)
select p.nombre_norm,
       (v.creado_en at time zone 'America/Tijuana')::timestamp,
       b.clase
from public.bak_visitas_pendientes_0831 b
join public.visitas  v on v.id = b.visita_id
join public.personas p on p.id = v.persona_id
on conflict do nothing;

-- La funcion que aplica la regla. La llaman la 142 (ya aplicada) y el reset.
create or replace function public.aplicar_notas_especiales_del_cnt()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n_marc int := 0;
  n_canje int := 0;
begin
  -- MARCADOR: no fue un lavado. Se descarta (la fila se conserva; es el
  -- principio de §11.35 — quitar el LAVADO no es quitar la VISITA).
  -- Cuando hay dos visitas en el mismo minuto, el marcador es el que NO
  -- trae ticket: la nota va pegada a su lavado real.
  with objetivo as (
    select distinct on (e.nombre_norm, e.dt_local) v.id
    from public.cnt_notas_especiales e
    join public.personas p on p.nombre_norm = e.nombre_norm
    join public.visitas  v on v.persona_id = p.id
                          and (v.creado_en at time zone 'America/Tijuana')::timestamp = e.dt_local
    where e.clase = 'MARCADOR' and v.caja = 'import'
      and v.estado = 'activa' and v.ticket is null
    order by e.nombre_norm, e.dt_local, v.id)
  update public.visitas v set estado = 'descartada'
    from objetivo o where o.id = v.id;
  get diagnostics n_marc = row_count;

  -- CANJE: uso un gratis que traia guardado.
  with objetivo as (
    select distinct on (e.nombre_norm, e.dt_local) v.id
    from public.cnt_notas_especiales e
    join public.personas p on p.nombre_norm = e.nombre_norm
    join public.visitas  v on v.persona_id = p.id
                          and (v.creado_en at time zone 'America/Tijuana')::timestamp = e.dt_local
    where e.clase = 'CANJE' and v.caja = 'import'
      and v.estado = 'activa' and v.ticket is not null and not v.es_gratis
    order by e.nombre_norm, e.dt_local, v.id)
  update public.visitas v set es_gratis = true, es_cortesia = false
    from objetivo o where o.id = v.id;
  get diagnostics n_canje = row_count;

  return jsonb_build_object('marcadores', n_marc, 'canjes', n_canje);
end;
$function$;
-- =====================================================================
-- 143-bis — La funcion se vuelve IDEMPOTENTE.
--
-- 🔴 EL BUG QUE ESTO ARREGLA, y como se encontro: al correr
--    `aplicar_notas_especiales_del_cnt()` una segunda vez descarto UNA visita
--    MAS. La causa: `CINTIA MENDOZA ORDUÑO` tiene DOS visitas sin ticket en el
--    mismo minuto (2026-03-11 12:34) — el marcador `GRATIS PENDIENTE` y un
--    lavado real, el 12358, al que `limpiar-tickets.sql` le quito el numero.
--    El `distinct on` elegia una; ya descartada esa, la siguiente corrida
--    elegia la otra. O sea que cada corrida se comia un lavado bueno.
--
--    Se encontro porque la verificacion corrio la funcion dos veces y comparo,
--    no leyendo el codigo. Es la misma leccion del desempate del import
--    (§11.05): hacerlo bien una vez no prueba que sea reproducible.
--
-- 🔑 EL ARREGLO: si ese minuto YA tiene un marcador descartado, no se toca
--    nada mas. El tope deja de depender del orden y pasa a depender del
--    trabajo ya hecho, que es lo unico que sobrevive entre corridas.
-- =====================================================================
create or replace function public.aplicar_notas_especiales_del_cnt()
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  n_marc int := 0;
  n_canje int := 0;
begin
  with objetivo as (
    select distinct on (e.nombre_norm, e.dt_local) v.id
    from public.cnt_notas_especiales e
    join public.personas p on p.nombre_norm = e.nombre_norm
    join public.visitas  v on v.persona_id = p.id
                          and (v.creado_en at time zone 'America/Tijuana')::timestamp = e.dt_local
    where e.clase = 'MARCADOR' and v.caja = 'import'
      and v.estado = 'activa' and v.ticket is null
      -- ⚠️ El tope: un marcador por minuto y NO MAS. Sin esto, un minuto con
      -- dos visitas sin ticket pierde una de verdad en cada corrida.
      and not exists (
        select 1 from public.visitas d
         where d.persona_id = p.id and d.caja = 'import'
           and d.estado = 'descartada' and d.ticket is null
           and (d.creado_en at time zone 'America/Tijuana')::timestamp = e.dt_local)
    order by e.nombre_norm, e.dt_local, v.id)
  update public.visitas v set estado = 'descartada'
    from objetivo o where o.id = v.id;
  get diagnostics n_marc = row_count;

  -- El canje no necesita tope: reclasificar dos veces la misma fila no hace
  -- nada (`not v.es_gratis` ya la deja fuera en la segunda corrida).
  with objetivo as (
    select distinct on (e.nombre_norm, e.dt_local) v.id
    from public.cnt_notas_especiales e
    join public.personas p on p.nombre_norm = e.nombre_norm
    join public.visitas  v on v.persona_id = p.id
                          and (v.creado_en at time zone 'America/Tijuana')::timestamp = e.dt_local
    where e.clase = 'CANJE' and v.caja = 'import'
      and v.estado = 'activa' and v.ticket is not null and not v.es_gratis
    order by e.nombre_norm, e.dt_local, v.id)
  update public.visitas v set es_gratis = true, es_cortesia = false
    from objetivo o where o.id = v.id;
  get diagnostics n_canje = row_count;

  return jsonb_build_object('marcadores', n_marc, 'canjes', n_canje);
end;
$function$;
