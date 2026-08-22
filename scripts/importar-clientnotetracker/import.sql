-- =====================================================================
-- ClientNoteTracker -> personas + visitas. IDEMPOTENTE.
-- Requiere la tabla public.stg_cnt ya cargada (ver RUNBOOK.md, paso 4).
-- Correr por la API admin (POST .../database/query) o en el panel.
--
-- Un do-$$ para que si algo truena, se revierte TODO (nada a medias).
-- Para probar sin escribir: agregar al final, antes del END,
--     raise exception 'DRY-RUN, revertido';
--
-- ⚠️ La hora sale de la zona que declara el export (stg_cnt.tz); sin ella se
-- asume America/Tijuana. Ver la nota de import-incremental.sql: el export del
-- 21/ago/2026 vino en America/Ciudad_Juarez, una hora adelante.
--
-- El LIGADO a los carros vive en public.ligar_visitas_de_import()
-- (migración 118), no aquí.
-- =====================================================================
alter table public.stg_cnt add column if not exists tz text;

do $$
begin
  -- 1) Idempotencia: borra cualquier import previo (re-corrida limpia).
  delete from public.visitas where caja = 'import';

  -- 2) Personas: una por nombre normalizado, origen='import', SIN seed
  --    (las visitas reales dan el conteo). Reusa/actualiza las que ya existan.
  insert into public.personas (nombre, nombre_norm, visitas_seed, sellos_iniciales, origen)
  select (array_agg(nombre order by dt_local desc))[1],
         public.normalizar_nombre(nombre), 0, 0, 'import'
  from public.stg_cnt
  where public.normalizar_nombre(nombre) is not null
  group by public.normalizar_nombre(nombre)
  on conflict (nombre_norm) where origen = 'import'
  do update set nombre = excluded.nombre, visitas_seed = 0, sellos_iniciales = 0, actualizado_en = now();

  -- 3) Visitas: fecha local del export -> UTC; monto en PESOS.
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, monto, ticket)
  select p.id, s.es_gratis, 'activa', 'import', false,
         (s.dt_local::timestamp at time zone coalesce(s.tz, 'America/Tijuana')),
         (s.monto_cent::numeric / 100), s.ticket
  from public.stg_cnt s
  join public.personas p
    on p.nombre_norm = public.normalizar_nombre(s.nombre) and p.origen = 'import';

  -- 4) Overlap: ligar a su carro REAL por ticket == purchaseNumber de Zettle.
  perform public.ligar_visitas_de_import();
end $$;
