-- =====================================================================
-- ClientNoteTracker -> INCREMENTAL (agrega solo lo que falta, NO borra).
-- Para el flujo EN VIVO: el dueño sube un export de los días nuevos, y esto
-- agrega solo las visitas que aún no están, sin duplicar ni re-importar todo.
-- Requiere public.stg_cnt cargado con el export nuevo (RUNBOOK paso 4).
--
-- Dedup: una visita YA está si hay un import con el mismo ticket, o con la
-- misma persona + misma hora (creado_en). Cubre notas sin ticket.
--
-- Para DRY-RUN (ver cuántas agregaría sin escribir), correr import-incremental-
-- dryrun.sql (mismo cuerpo + raise al final).
-- =====================================================================
do $$
begin
  -- Personas: alta de las nuevas (idempotente); no toca el seed de las que ya
  -- tienen historia importada (solo refresca el nombre a mostrar).
  insert into public.personas (nombre, nombre_norm, visitas_seed, sellos_iniciales, origen)
  select (array_agg(nombre order by dt_local desc))[1], public.normalizar_nombre(nombre), 0, 0, 'import'
  from public.stg_cnt where public.normalizar_nombre(nombre) is not null
  group by public.normalizar_nombre(nombre)
  on conflict (nombre_norm) where origen='import'
  do update set nombre = excluded.nombre, actualizado_en = now();

  -- Visitas: solo las que NO existen ya (por ticket, o por persona+hora).
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, monto, ticket)
  select p.id, s.es_gratis, 'activa', 'import', false,
         (s.dt_local::timestamp at time zone 'America/Tijuana'), (s.monto_cent::numeric/100), s.ticket
  from public.stg_cnt s
  join public.personas p on p.nombre_norm = public.normalizar_nombre(s.nombre) and p.origen='import'
  where not exists (
    select 1 from public.visitas v where v.caja='import'
      and ( (s.ticket is not null and v.ticket = s.ticket)
         or (v.persona_id = p.id and v.creado_en = (s.dt_local::timestamp at time zone 'America/Tijuana')) )
  );

  -- Overlap: ligar a su carro real por ticket == purchaseNumber (solo las
  -- que aún no estén ligadas).
  update public.visitas vi set carro_id = m.carro_id
  from (select c.id as carro_id, ((v.payload->>'payload')::jsonb->>'purchaseNumber') as recibo
        from public.carros c join public.ventas v on v.purchase_uuid = c.purchase_uuid
        where not c.es_prueba and c.cancelado_en is null) m
  where vi.caja='import' and vi.ticket = m.recibo and vi.carro_id is null;
end $$;
