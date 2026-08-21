-- =====================================================================
-- 112 - Dos limpiezas del import, ninguna con juicio sobre nadie
--
--   1. Cinco visitas DUPLICADAS: la misma persona, el mismo ticket, el
--      mismo minuto. Son dos sellos por un solo lavado.
--   2. El campo `ticket` con valores 0 a 5, que no son tickets.
--
-- Las dos salieron de la regla que dio el dueno el 19/ago/2026:
--   "La placa si puede estar ligada a dos personas diferentes, pero cada
--    visita solo se asigna una vez a una persona."
--
-- ⚠️ Lo que este archivo NO toca: los ~164 tickets que tienen dos visitas
-- de personas DISTINTAS. Ahi hay que decidir cual de las dos se queda con
-- el lavado, son personas con nombre, y aplica la regla de "1000% o nada".
-- Eso espera decision del dueno.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Respaldo primero. Nada de esto se puede reconstruir del import: `stg_cnt`
-- solo conserva las 195 filas de la ultima tanda, no el ano de historia.
-- Es el mismo patron de los otros `bak_*`, que la auditoria decidio
-- conservar justamente por esto.
-- ---------------------------------------------------------------------
create table if not exists public.bak_visitas_ticket_0819 as
select id, persona_id, ticket, estado, creado_en, now() as respaldado_en
  from public.visitas
 where ticket is not null
   and ticket ~ '^[0-9]+$'
   and ticket::int <= 5;

comment on table public.bak_visitas_ticket_0819 is
  'Respaldo del campo ticket antes de la 112: valores 0 a 5, que no eran tickets. Para poder deshacerlo.';


-- ---------------------------------------------------------------------
-- 1. Las cinco visitas duplicadas
--
-- La misma persona, el mismo numero de ticket y el mismo minuto, con ids
-- consecutivos: son dos renglones del import por un solo lavado, y le dan
-- DOS sellos a la persona por una sola venta.
--
-- Se conserva el de id mas chico (el primero que entro) y se DESCARTA el
-- otro. Descartar no borra la fila: `estado = 'descartada'` la saca de
-- `lealtad_por_persona` (que une por `estado = 'activa'`) y se puede
-- revertir con un update. Mismo trato que se le dio a las visitas de la
-- prueba de la camara el 19/ago.
-- ---------------------------------------------------------------------
create table if not exists public.bak_visitas_duplicadas_0819 as
with dup as (
  select ticket
    from public.visitas
   where estado = 'activa' and ticket is not null and not es_prueba
   group by ticket
  having count(*) > 1 and count(distinct persona_id) = 1
),
ordenadas as (
  select v.id, v.persona_id, v.ticket, v.creado_en,
         row_number() over (partition by v.ticket, v.persona_id order by v.id) as n
    from public.visitas v
   where v.estado = 'activa' and not v.es_prueba
     and v.ticket in (select ticket from dup)
)
select id, persona_id, ticket, creado_en, now() as respaldado_en
  from ordenadas where n > 1;

comment on table public.bak_visitas_duplicadas_0819 is
  'Las visitas que la 112 descarto por duplicadas (misma persona, mismo ticket, mismo minuto). Para poder revertirlas una por una.';

update public.visitas
   set estado = 'descartada'
 where id in (select id from public.bak_visitas_duplicadas_0819);


-- ---------------------------------------------------------------------
-- 2. Los tickets que no son tickets
--
-- Los seis valores mas repetidos del campo son literalmente 0, 1, 2, 3, 4
-- y 5: **440 visitas de 404 personas distintas, repartidas entre agosto de
-- 2025 y julio de 2026**. Un ticket es UNA venta de UN dia; un numero que
-- aparece en 280 dias distintos y a nombre de 250 personas no es un ticket.
--
-- No afectan la lealtad (la visita de cada persona es real; lo inservible
-- es el numero), pero ensucian cualquier consulta que busque tickets
-- repetidos — de hecho hicieron que este mismo hallazgo se viera tres veces
-- mas grande de lo que era.
--
-- Se pone en nulo, que es lo que significan: "no se sabe el ticket". El
-- valor viejo queda en el respaldo de arriba.
-- ---------------------------------------------------------------------
update public.visitas
   set ticket = null
 where ticket is not null
   and ticket ~ '^[0-9]+$'
   and ticket::int <= 5;
