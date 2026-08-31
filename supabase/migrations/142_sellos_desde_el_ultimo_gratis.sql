-- =====================================================================
-- 142 — El contador de sellos arranca de CERO en el ultimo gratis usado,
--        y se corrigen las notas de "GRATIS PENDIENTE" del import.
--
-- Decision del dueno, 31/ago/2026. Nacio de dos reportes de la caja: lo que
-- decia el ClientNoteTracker (MRT) no cuadraba con la app.
--
-- SON TRES COSAS Y LAS TRES SE NECESITAN. Comprobado: quitando cualquiera de
-- las tres, los 7 clientes que el dueno verifico a mano dejan de cuadrar.
--
--   1. `GRATIS PENDIENTE` SIN numero de ticket NO ES UN LAVADO. Es una nota
--      que la cajera dejaba al lado del lavado real para no perder un gratis
--      que el cliente se gano y no quiso usar ese dia. 28 de 30 traen un
--      lavado real del mismo cliente ESE MISMO DIA: son anotaciones. El
--      import las metia como visita PAGADA y le regalaban un sello.
--
--   2. "pendiente" CON numero de ticket SI ES UN CANJE. Textual del dueno:
--      "Cuando dice Gratis pendiente y aparte tiene un numero de ticket, es
--      que se habia utilizado ese lavado gratis acumulado con anterioridad."
--      El import las metia como PAGADAS: doble error, sumaban sello y no
--      restaban el gratis.
--
--   3. LOS SELLOS SE CUENTAN DESDE EL ULTIMO CANJE, no como
--      floor(total_pagados/5) - canjes. Textual: "el contador empieza desde 0
--      desde que utilizo el ultimo gratis". Es una regla que puso el gerente:
--      lo acumulado se pierde al momento de canjear.
--
-- ⚠️ LA REGLA 3 NO ES "YA NO SE ACUMULAN". Un cliente que nunca ha canjeado
--    sigue acumulando igual que antes (10 pagados = 2 gratis). Lo que cambia
--    es el momento del canje: antes conservaba el excedente, ahora se borra.
--
-- IMPACTO MEDIDO en toda la base antes de aplicar: 245 -> 226 lavados gratis
-- por honrar. 20 clientes pierden uno, 2 lo ganan. Los 2 que ganan no son un
-- error: canjearon mas de lo que tenian y hoy arrastran la deuda con
-- `greatest(0, ...)`; al reiniciar en el ultimo canje se les perdona.
--
-- COMPROBADO CONTRA LOS 7 QUE EL DUENO VERIFICO A MANO EN EL MRT:
--   Karla Mora Melchor 3/5 · Gabriela Benitez 0/5 · Ignacio Lozoya 3/5
--   Manuel Parra Salazar 4/5 · Norma L. Gutierrez 1/5 · Sara G. Reyes 0/5
--   Victor M. Hernandez 3/5   — los siete con 0 gratis. 7 de 7.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Respaldo. Antes de tocar nada: la lealtad de todos, y las filas exactas
--    que se van a cambiar. Esto es lo que permite deshacerlo.
-- ---------------------------------------------------------------------
drop table if exists public.bak_lealtad_0831;
create table public.bak_lealtad_0831 as
select l.persona_id, p.nombre, l.lavados_pagados, l.canjes, l.sellos,
       l.ganados, l.disponibles, l.visitas_totales
from public.lealtad_por_persona l join public.personas p on p.id = l.persona_id;

-- ---------------------------------------------------------------------
-- 2) Las 46 notas del export, con su clase. Salen del PDF del 30/ago (el
--    ultimo), leyendo el texto del ticket:
--      contiene "pendiente" y NO trae numero  -> MARCADOR (no es lavado)
--      contiene "pendiente" y SI trae numero  -> CANJE
--    Van escritas aqui a proposito y no calculadas: el PDF no vive en la
--    base, y esta lista ES el registro de lo que se cambio.
--
-- ⚠️ Se casan por (nombre normalizado + minuto). Cuando hay dos visitas en
--    el mismo minuto —que es el caso tipico: la nota va pegada a su lavado—
--    el MARCADOR es el que NO trae ticket y el CANJE el que SI.
-- ---------------------------------------------------------------------
drop table if exists public.bak_visitas_pendientes_0831;
create table public.bak_visitas_pendientes_0831 as
with pdf(nombre, dt, clase) as (values
  ('Sara gabriela Reyes', '2026-08-14 10:28:00', 'CANJE'),
  ('liliana cabrero', '2026-04-06 16:14:00', 'CANJE'),
  ('LUZ DEL CARMEN CRAWSTON', '2026-04-06 11:06:00', 'MARCADOR'),
  ('ricardo sanchez pineda', '2026-04-05 12:12:00', 'MARCADOR'),
  ('Eder Preciado', '2026-04-04 13:19:00', 'MARCADOR'),
  ('NORMA LETICIA GUTIERREZ ORTIZ', '2026-04-04 12:33:00', 'MARCADOR'),
  ('KARLA MORA MECHOR', '2026-04-01 14:49:00', 'MARCADOR'),
  ('reyes perez', '2026-03-30 11:59:00', 'MARCADOR'),
  ('enrique gomez arevalo', '2026-03-29 09:41:00', 'MARCADOR'),
  ('Yolanda Rodriguez', '2026-03-26 11:38:00', 'CANJE'),
  ('PARKA MORENO', '2026-03-25 11:44:00', 'MARCADOR'),
  ('Jorge Sardin lopez', '2026-03-19 14:20:00', 'MARCADOR'),
  ('TOMAS PONCE LATIN', '2026-03-18 14:20:00', 'MARCADOR'),
  ('Hector Tapia norsagraral', '2026-03-13 09:16:00', 'MARCADOR'),
  ('CINTIA MENDOZA ORDUÑO', '2026-03-11 12:34:00', 'MARCADOR'),
  ('marta gabriela alvarez paez', '2026-03-01 11:37:00', 'MARCADOR'),
  ('sandra inzunza', '2026-02-28 16:10:00', 'CANJE'),
  ('ROBERTO ROBLES SOTO', '2026-02-27 08:01:00', 'MARCADOR'),
  ('Sara gabriela Reyes', '2026-02-25 13:21:00', 'MARCADOR'),
  ('gabriela garcia VALENZUELA', '2026-02-21 15:08:00', 'CANJE'),
  ('jesus cardenas', '2026-02-21 12:27:00', 'MARCADOR'),
  ('Kevin Campos', '2026-02-21 10:31:00', 'MARCADOR'),
  ('primitibo avila villarino', '2026-02-20 17:54:00', 'CANJE'),
  ('Jorge Gutierrez', '2026-02-17 13:28:00', 'CANJE'),
  ('ANETE GALVAN NORIEGA', '2026-02-15 16:55:00', 'CANJE'),
  ('Ignacio Lozoya', '2026-02-14 12:20:00', 'MARCADOR'),
  ('PABLO CAMACHO VEGA', '2026-02-09 14:46:00', 'CANJE'),
  ('CESAR BARRAZA MONTOYA', '2026-02-06 16:39:00', 'CANJE'),
  ('RICARDO LEON CAMPOS', '2026-02-04 09:48:00', 'MARCADOR'),
  ('DANIELA ONTIVEROS RAMIREZ', '2026-01-31 10:58:00', 'MARCADOR'),
  ('Gabriela Benitez', '2026-01-27 12:36:00', 'MARCADOR'),
  ('Manuel Parra Salazar', '2026-01-26 08:16:00', 'MARCADOR'),
  ('ARMANDO FIMBRES CHELY', '2026-01-17 13:47:00', 'CANJE'),
  ('Jose Luis Siono alegria', '2026-01-15 17:50:00', 'CANJE'),
  ('victor manuel hernandez', '2026-01-15 11:12:00', 'MARCADOR'),
  ('MARICRUZ GARCIA GUZMAN', '2026-01-11 15:19:00', 'CANJE'),
  ('enrique gomez arevalo', '2026-01-05 14:01:00', 'CANJE'),
  ('RODOLFO TOLENTINO DE LAS CAZAS', '2025-12-03 13:23:00', 'MARCADOR'),
  ('NORMA LETICIA GUTIERREZ ORTIZ', '2025-12-03 11:50:00', 'MARCADOR'),
  ('KARLA MORA MECHOR', '2025-12-02 11:25:00', 'MARCADOR'),
  ('Gabriel Rodriguez Valdez', '2025-11-28 08:30:00', 'MARCADOR'),
  ('OSCAR PONCE GAMEZ', '2025-11-11 10:07:00', 'MARCADOR'),
  ('Gonzalo Franco Cardenas', '2025-11-09 10:59:00', 'MARCADOR'),
  ('Sergio Rodriguez valdez', '2025-11-07 10:00:00', 'MARCADOR'),
  ('Hector Tapia norsagraral', '2025-10-16 12:58:00', 'MARCADOR'),
  ('Pedro Salcido', '2025-09-18 14:24:00', 'CANJE')
),
m as (select public.normalizar_nombre(nombre) nn, dt::timestamp dt, clase from pdf)
select distinct on (m.nn, m.dt, m.clase)
       v.id visita_id, v.persona_id, p.nombre, m.clase,
       v.es_gratis es_gratis_antes, v.estado estado_antes, v.ticket
from public.visitas v
join public.personas p on p.id = v.persona_id
join m on m.nn = p.nombre_norm
      and m.dt = (v.creado_en at time zone 'America/Tijuana')::timestamp
where v.caja = 'import' and v.estado = 'activa'
  and ((m.clase = 'MARCADOR' and v.ticket is null)
    or (m.clase = 'CANJE'    and v.ticket is not null))
order by m.nn, m.dt, m.clase, v.id;

-- Guarda: si el casado no encuentra lo que el PDF dice, algo cambio y hay
-- que revisarlo ANTES de escribir, no despues.
do $$
declare n_marc int; n_canje int;
begin
  select count(*) filter (where clase='MARCADOR'), count(*) filter (where clase='CANJE')
    into n_marc, n_canje from public.bak_visitas_pendientes_0831;
  if n_marc <> 31 or n_canje <> 15 then
    raise exception 'FALLO: se esperaban 31 marcadores y 15 canjes; se encontraron % y %', n_marc, n_canje;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3) Aplicar. La FILA SE CONSERVA siempre — es el principio de §11.35:
--    quitar el LAVADO no es lo mismo que quitar la VISITA. Aqui el marcador
--    ni siquiera fue una visita, asi que se descarta; el canje si ocurrio y
--    solo se reclasifica.
-- ---------------------------------------------------------------------
update public.visitas v
   set estado = 'descartada'
  from public.bak_visitas_pendientes_0831 b
 where b.visita_id = v.id and b.clase = 'MARCADOR';

update public.visitas v
   set es_gratis = true, es_cortesia = false
  from public.bak_visitas_pendientes_0831 b
 where b.visita_id = v.id and b.clase = 'CANJE';

-- ---------------------------------------------------------------------
-- 4) La regla nueva del contador.
--
-- 🔑 EL CAMBIO ES `desde`: los pagados POSTERIORES al ultimo canje. Todo lo
--    demas de la vista queda igual (lavados_pagados y canjes siguen siendo de
--    por vida, que es lo que se muestra como historial).
--
-- ⚠️ `ganados` y `disponibles` ahora son LO MISMO, y es a proposito: al
--    reiniciar el contador en cada canje ya no hay nada que restar. Antes
--    `disponibles = ganados - canjes`; esa resta es justamente la que se va.
--
-- ⚠️ `sellos_iniciales` solo aplica a quien NUNCA ha canjeado. En cuanto hay
--    un canje el contador arranca de cero y la semilla dejaria de tener
--    sentido. Hoy son 0 en las 5,071 personas; queda escrito para el dia que
--    alguien la use.
-- ---------------------------------------------------------------------
create or replace view public.lealtad_por_persona as
with act as (
  select v.persona_id, v.creado_en, v.es_gratis, v.es_cortesia
  from public.visitas v
  where v.estado = 'activa' and not v.es_prueba
),
ult as (
  select persona_id,
         max(creado_en) filter (where es_gratis and not es_cortesia) as ultimo_canje
  from act group by persona_id
),
agg as (
  select p.id                              as persona_id,
         p.sellos_iniciales, p.visitas_seed, u.ultimo_canje,
         count(a.persona_id) filter (where not a.es_gratis and not a.es_cortesia) as pagados,
         count(a.persona_id) filter (where     a.es_gratis and not a.es_cortesia) as canjes,
         count(a.persona_id)                                                       as total,
         max(a.creado_en)                                                          as ultima,
         count(a.persona_id) filter (
           where not a.es_gratis and not a.es_cortesia
             and (u.ultimo_canje is null or a.creado_en > u.ultimo_canje))         as desde
  from public.personas p
  left join act a on a.persona_id = p.id
  left join ult u on u.persona_id = p.id
  group by p.id, p.sellos_iniciales, p.visitas_seed, u.ultimo_canje
),
base as (
  select agg.*,
         (case when ultimo_canje is null then sellos_iniciales else 0 end) + desde as cuenta
  from agg
)
select persona_id,
       pagados::int                        as lavados_pagados,
       canjes::int                          as canjes,
       (cuenta % 5)::int                    as sellos,
       (visitas_seed + total)::int          as visitas_totales,
       ultima                               as ultima_visita,
       (cuenta / 5)::int                    as ganados,
       (cuenta / 5)::int                    as disponibles,
       desde::int                           as pagados_desde_el_ultimo_gratis
from base;

-- ---------------------------------------------------------------------
-- 5) Comprobacion contra los 7 que el dueno verifico a mano en el MRT.
--    Si esto no da, la migracion entera se revierte.
-- ---------------------------------------------------------------------
do $$
declare
  r record; malos text := '';
begin
  for r in
    select * from (values
      ('KARLA MORA MECHOR', 3), ('Gabriela Benitez', 0), ('Ignacio Lozoya', 3),
      ('Manuel Parra Salazar', 4), ('NORMA LETICIA GUTIERREZ ORTIZ', 1),
      ('Sara gabriela Reyes', 0), ('victor manuel hernandez', 3)
    ) t(nombre, sellos_esperados)
  loop
    declare s int; d int;
    begin
      select l.sellos, l.disponibles into s, d
        from public.lealtad_por_persona l join public.personas p on p.id = l.persona_id
       where p.nombre = r.nombre;
      if s is distinct from r.sellos_esperados or d is distinct from 0 then
        malos := malos || format(' %s(%s/5,%s gratis; se esperaba %s/5,0)',
                                 r.nombre, coalesce(s,-1), coalesce(d,-1), r.sellos_esperados);
      end if;
    end;
  end loop;
  if malos <> '' then
    raise exception 'FALLO 142 — no cuadra con lo que el dueno verifico:%', malos;
  end if;
  raise notice '142 OK: los 7 cuadran con el MRT';
end $$;
