-- =====================================================================
-- ClientNoteTracker -> INCREMENTAL (agrega solo lo que falta, NO borra).
-- Para el flujo EN VIVO: el dueño sube un export de los días nuevos, y esto
-- agrega solo las visitas que aún no están, sin duplicar ni re-importar todo.
-- Requiere public.stg_cnt cargado con el export nuevo (RUNBOOK paso 4).
--
-- Dedup: una visita YA está si hay un import con el mismo ticket, o con la
-- misma persona + misma hora (creado_en). Cubre notas sin ticket.
--
-- ⚠️ TODO SE GUARDA EN HORA DE TIJUANA. Siempre: el negocio está en Mexicali
-- y no hay un solo dato de este proyecto que viva en otra zona.
--
-- Pero las horas del export no siempre VIENEN en Tijuana: el
-- ClientNoteTracker las escribe con la zona del TELÉFONO del dueño, y el
-- 21/ago/2026 se le descompuso el horario — el PDF salió en
-- America/Ciudad_Juarez, una hora adelante. Medido contra las ventas de
-- Zettle de esos mismos tickets: 235 de 239 notas caían exactas 60 minutos
-- adelante.
--
-- Por eso `stg_cnt.tz` guarda la zona en que RESULTARON estar escritas las
-- horas —medida contra Zettle, no leída del encabezado del PDF, que no es
-- fuente confiable—. Sin `tz`, se asume Tijuana. Clavar Tijuana cuando no lo
-- es guardaría cada visita una hora tarde y rompería el dedup del siguiente
-- import, que compara `creado_en` al segundo.
--
-- Cotejo gratis después de importar: SIEMPRE se cierra a las 8 PM, así que
-- una nota pasada de las 20:00 hora de Tijuana significa desfase mal puesto.
--
-- El LIGADO a los carros vive en public.ligar_visitas_de_import()
-- (migración 118), no aquí: los tres scripts del import lo llamaban copiado.
--
-- Para DRY-RUN (ver cuántas agregaría sin escribir), correr import-incremental-
-- dryrun.sql (mismo cuerpo + raise al final).
-- =====================================================================
alter table public.stg_cnt add column if not exists tz text;

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

  -- Overlap: ligar a su carro real por ticket == purchaseNumber.
  perform public.ligar_visitas_de_import();
end $$;
