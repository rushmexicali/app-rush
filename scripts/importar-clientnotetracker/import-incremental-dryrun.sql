-- =====================================================================
-- DRY-RUN del import incremental. MISMO cuerpo que import-incremental.sql,
-- pero cuenta cuántas visitas/personas AGREGARÍA y termina en `raise` para
-- REVERTIR todo (no escribe nada). Requiere public.stg_cnt ya cargado con el
-- export nuevo (RUNBOOK paso 4b). Corre esto ANTES del import real para ver
-- el número; si cuadra, corre import-incremental.sql.
-- =====================================================================
alter table public.stg_cnt add column if not exists tz text;

do $$
declare v0 int; v1 int; p0 int; p1 int; lig int; r jsonb;
begin
  select count(*) into v0 from public.visitas where caja='import';
  select count(*) into p0 from public.personas where origen='import';

  insert into public.personas (nombre, nombre_norm, visitas_seed, sellos_iniciales, origen)
  select (array_agg(nombre order by dt_local desc))[1], public.normalizar_nombre(nombre), 0, 0, 'import'
  from public.stg_cnt where public.normalizar_nombre(nombre) is not null
  group by public.normalizar_nombre(nombre)
  on conflict (nombre_norm) where origen='import'
  do update set nombre = excluded.nombre, actualizado_en = now();

  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, monto, ticket)
  select p.id, s.es_gratis, 'activa', 'import', false,
         (s.dt_local::timestamp at time zone coalesce(s.tz, 'America/Tijuana')),
         (s.monto_cent::numeric/100), s.ticket
  from public.stg_cnt s
  join public.personas p on p.nombre_norm = public.normalizar_nombre(s.nombre) and p.origen='import'
  where not exists (
    select 1 from public.visitas v where v.caja='import'
      and ( (s.ticket is not null and v.ticket = s.ticket)
         or (v.persona_id = p.id
             and v.creado_en = (s.dt_local::timestamp at time zone coalesce(s.tz, 'America/Tijuana'))) )
  );

  r := public.ligar_visitas_de_import();

  select count(*) into v1 from public.visitas where caja='import';
  select count(*) into p1 from public.personas where origen='import';
  select count(*) into lig from public.visitas where caja='import' and carro_id is not null;

  raise exception 'DRYRUN visitas +% (% -> %) | personas +% (% -> %) | ligadas ahora % | ligado %',
    v1-v0, v0, v1, p1-p0, p0, p1, lig, r;
end $$;
