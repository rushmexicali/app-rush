-- =====================================================================
-- RESET TOTAL DEL CRM + IMPORT DESDE CERO.  (RUNBOOK §4)
-- Requiere stg_cnt ya cargada y limpia (cargar-staging.sh).
--
-- 🔑 EL BORRADO Y EL IMPORT VAN EN LA MISMA PETICION A PROPOSITO. La API de
--    administracion corre cada peticion en una transaccion implicita, asi que
--    si el import truena el borrado se revierte solo y el CRM nunca se queda
--    vacio entre dos llamadas.
--
-- ENSAYARLO ES GRATIS Y HAY QUE HACERLO: cambia el `raise notice` final por
-- `raise exception` y manda el mismo archivo. Corre todo, imprime los numeros
-- finales y revierte. Si esos numeros no te cuadran, no lo apliques.
--
-- ⛔ ANTES: respaldar. `bak_personas_<fecha>`, `bak_persona_placas_<fecha>`,
--    `bak_visitas_map_<fecha>` y `bash scripts/bajar-respaldo.sh <carpeta>`.
--
-- ⛔ NO TOCA la operacion: carros, etapas, asignaciones, ventas, empleados,
--    reportes ni las fotos. Borrar `visitas` NO borra carros: es un enlace.
--
-- 💡 DESPUES NO ESPERES QUE stg_cnt Y visitas SEAN IDENTICAS. Las CORTESIAS
--    (`Gratis` + variante que no empieza con `6to`) entran con es_gratis=true y
--    ligar_visitas_de_import() las reclasifica: es_cortesia=true, es_gratis=false
--    — ni suman sello ni consumen gratis, pero si quedan en el historial. El
--    24/ago fueron 11 filas. Es la unica diferencia legitima entre las dos
--    tablas; cualquier otra si es un problema.
-- =====================================================================
alter table public.stg_cnt add column if not exists tz text;

do $$
declare
  d_vis int; d_pp int; d_per int;
  n_per int; n_vis int; n_lig int;
  n_caja int; n_huerf int;
  r jsonb;
begin
  -- 1) EL BORRADO. Sin `where`: la actividad de la CAJA tambien se va.
  --
  --    🔴 LEE ESTO ANTES DE CORRER EL RESET. La razon por la que borrar la
  --       caja era seguro DEJO DE SER CIERTA el 30/ago/2026.
  --
  --         24/ago:  "todo lo que se ha hecho de caja es prueba".
  --         28/ago:  la caja esta en uso REAL, pero la cajera sigue llenando
  --                  el ClientNoteTracker EN PARALELO, asi que cada visita de
  --                  caja viene tambien en el export. Conservarlas seria
  --                  contar el mismo lavado dos veces -> sello doble (§11.35).
  --         30/ago:  el dueno, textual: "A partir de manana el CNT se deja de
  --                  utilizar y nos enfocamos 100% en nuestra app".
  --
  --       O SEA QUE YA NO HAY UNA SEGUNDA FUENTE. El export del 30/ago fue el
  --       ultimo. Desde el 31/ago, la unica copia de la lealtad vive en
  --       `visitas` con `caja <> 'import'`, y este `delete` la borra sin
  --       vuelta: no hay de donde reconstruirla.
  --
  --    🔑 POR ESO EL AVISO SE VOLVIO CANDADO. Hasta el 30/ago esto se contaba
  --       y se REPORTABA al final ("caja sin respaldo en el CNT"), con el
  --       argumento de que una visita registrada despues del corte del export
  --       cae ahi de forma legitima y abortar seria peor que avisar. Ese
  --       argumento valia cuando el CNT respaldaba TODO menos la ultima hora.
  --       Hoy no respalda nada, asi que un aviso que nadie lee al final de una
  --       operacion ya consumada no protege de nada.
  --
  --       Ahora: si hay UNA sola visita de caja que el export no cubra, el
  --       reset se cae y no borra nada. Para hacerlo de todos modos hay que
  --       decir en voz alta cuantas se estan tirando:
  --
  --         select set_config('rush.perdida_aceptada', '<N>', false);
  --
  --       y ESA LINEA VA EN LA MISMA PETICION, arriba del reset (la API de
  --       administracion abre una sesion por peticion, asi que un set_config
  --       suelto en otra llamada no llega). El N tiene que ser EXACTAMENTE el
  --       que el reset calculo: un numero tecleado a ciegas no coincide; uno
  --       tecleado despues de leer el error, si. Esa es toda la proteccion,
  --       y es a proposito.
  --
  --    Se cuenta ANTES de borrar, que es la unica ventana en que se puede.
  select count(*), count(*) filter (
           where v.ticket is null
              or not exists (select 1 from public.stg_cnt s where s.ticket = v.ticket))
    into n_caja, n_huerf
    from public.visitas v
   where v.caja <> 'import' and v.estado = 'activa';

  if n_huerf > 0
     and coalesce(current_setting('rush.perdida_aceptada', true), '') <> n_huerf::text then
    raise exception
      E'RESET ABORTADO — no se borro nada.\n'
      '  % visitas de la caja NO vienen en el export y se perderian para siempre.\n'
      '  (de % que registro la caja en total)\n'
      '\n'
      '  Desde el 31/ago/2026 el ClientNoteTracker ya no se llena, asi que la\n'
      '  caja es la UNICA fuente de la lealtad y esto no se puede reconstruir.\n'
      '\n'
      '  Miralas antes de decidir:\n'
      '    select v.creado_en, v.ticket, p.nombre, v.monto, v.es_gratis\n'
      '      from public.visitas v join public.personas p on p.id = v.persona_id\n'
      '     where v.caja <> ''import'' and v.estado = ''activa''\n'
      '       and (v.ticket is null or not exists\n'
      '            (select 1 from public.stg_cnt s where s.ticket = v.ticket));\n'
      '\n'
      '  Si de verdad las vas a tirar:\n'
      '    select set_config(''rush.perdida_aceptada'', ''%'', false);\n'
      '  pegala ARRIBA del reset, en la MISMA peticion.',
      n_huerf, n_caja, n_huerf;
  end if;

  delete from public.visitas;        get diagnostics d_vis = row_count;
  delete from public.persona_placas; get diagnostics d_pp  = row_count;
  delete from public.personas;       get diagnostics d_per = row_count;

  -- 2) El andamio de la corrida anterior.
  --    🔴 `imp_ligado_conflictos` NO se dropea: ligar_visitas_de_import() le
  --    hace `delete` al empezar pero NO la crea, y sin ella el import entero
  --    truena — la misma forma de falla que dejo el CRM muerto cinco dias el
  --    19/ago/2026. Se limpia sola.
  --    `stg_cnt` tampoco: es el staging que se esta por importar.
  execute 'drop table if exists public.stg_names, public.stg_padron';
  execute 'drop table if exists public.ren_cand, public.ren_cand_ticket_0815,
           public.ren_cand_ticket_descartado, public.ren_desaparecen,
           public.ren_esqueleto, public.ren_nuevas, public.ren_prefijo';
  --    Las `bak_*` se conservan (dueno, 24/ago). Si esto sale mal son lo unico
  --    que queda del CRM viejo.

  -- 3) PERSONAS: una por nombre normalizado. Dos fichas con el mismo nombre se
  --    funden — sin telefono ni placa no hay forma de separarlas.
  insert into public.personas (nombre, nombre_norm, visitas_seed, sellos_iniciales, origen)
  select (array_agg(nombre order by dt_local desc))[1],
         public.normalizar_nombre(nombre), 0, 0, 'import'
  from public.stg_cnt
  where public.normalizar_nombre(nombre) is not null
  group by public.normalizar_nombre(nombre);
  get diagnostics n_per = row_count;

  -- 4) VISITAS. Hora local del export -> UTC; monto en PESOS.
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, monto, ticket)
  select p.id, s.es_gratis, 'activa', 'import', false,
         (s.dt_local::timestamp at time zone coalesce(s.tz, 'America/Tijuana')),
         (s.monto_cent::numeric / 100), s.ticket
  from public.stg_cnt s
  join public.personas p
    on p.nombre_norm = public.normalizar_nombre(s.nombre) and p.origen = 'import';
  get diagnostics n_vis = row_count;

  -- 5) Ligado a los carros reales por ticket == purchaseNumber. Vive en UNA
  --    funcion; lo que no liga queda anotado en imp_ligado_conflictos.
  r := public.ligar_visitas_de_import();
  select count(*) into n_lig from public.visitas where carro_id is not null;

  -- Guardas: si algo de esto no se cumple, la transaccion entera se cae.
  if n_vis <> (select count(*) from public.stg_cnt) then
    raise exception 'FALLO: entraron % visitas y stg_cnt tiene %', n_vis, (select count(*) from public.stg_cnt);
  end if;
  if exists (select 1 from public.visitas where persona_id is null) then
    raise exception 'FALLO: quedaron visitas sin persona';
  end if;

  raise notice E'RESET TOTAL\n'
    '  BORRADO   visitas %  persona_placas %  personas %\n'
    '  IMPORT    personas %  visitas %  ligadas a carro %\n'
    '  ligado    %\n'
    '  gratis a honrar % en % personas\n'
    '  gasto %\n'
    '  CAJA      se borraron % visitas; % sin respaldo en el CNT\n'
    '  INTACTO   carros %  etapas %  asignaciones %  ventas %  reportes %',
    d_vis, d_pp, d_per, n_per, n_vis, n_lig, r,
    (select coalesce(sum(disponibles),0) from public.lealtad_por_persona),
    (select count(*) from public.lealtad_por_persona where disponibles>0),
    (select round(coalesce(sum(monto),0),2) from public.visitas),
    n_caja, n_huerf,
    (select count(*) from public.carros), (select count(*) from public.etapas),
    (select count(*) from public.asignaciones), (select count(*) from public.ventas),
    (select count(*) from public.reportes_diarios);
end $$;
