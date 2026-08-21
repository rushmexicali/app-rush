-- =====================================================================
-- 114 - Un lavado, un cliente (y el candado para que siga asi)
--
-- Regla del dueno, 19/ago/2026:
--   "La placa si puede estar ligada a dos personas diferentes, pero cada
--    visita solo se asigna una vez a una persona."
--
-- Habia 14 lavados reclamados por dos clientes distintos, todos del import
-- del ClientNoteTracker, que liga `carro_id` sin pasar por
-- `enlazar_visita_a_carro` — o sea sin la comprobacion que esa funcion si
-- hace. Este archivo los resuelve y despues pone el candado.
--
-- ⚠️ EL PRINCIPIO, que es lo que hay que entender si esto se vuelve a tocar:
--
--   Quitar el LAVADO no es lo mismo que quitar la VISITA.
--
-- Las dos personas si vinieron: cada una tiene su visita real y su sello.
-- Lo que no puede ser es que las dos reclamen el MISMO cobro. Asi que lo
-- que se quita es el `carro_id` —el reclamo sobre ese lavado—, no la
-- visita. Nadie pierde un sello ni un lavado gratis por esta limpieza.
--
-- Y donde NO hay evidencia, no se le adjudica a ninguna de las dos. Es la
-- regla del proyecto aplicada a personas: "un dato inventado es peor que
-- uno faltante, porque el que lo ve confia en el". Adivinar al 50% y
-- dejarlo escrito como un hecho es peor que dejar el lavado sin dueno.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Respaldo: quien reclamaba que, antes de tocar nada.
-- ---------------------------------------------------------------------
create table if not exists public.bak_visitas_lavado_0819 as
select v.id as visita, v.persona_id, v.carro_id, v.ticket, v.enlazada_en, v.estado,
       now() as respaldado_en
  from public.visitas v
 where v.estado = 'activa' and v.carro_id in (
   select carro_id from public.visitas
    where estado = 'activa' and carro_id is not null
    group by carro_id having count(*) > 1
 );

comment on table public.bak_visitas_lavado_0819 is
  'Quien reclamaba cada uno de los 14 lavados con dos clientes, antes de la 114. Para poder revertir cualquier caso.';


-- ---------------------------------------------------------------------
-- 1. Las dos visitas de PRUEBA del dueno (26 y 27/jul/2026)
--
-- Son las unicas dos del grupo que entraron por `caja = 'principal'` y las
-- unicas con `enlazada_en`: se registraron con la app de la caja los dos
-- dias en que se estaba estrenando, a nombre del dueno, sobre lavados de
-- clientes reales. Mismo caso que la prueba de la camara Reolink que se
-- deshizo el 19/ago, y mismo trato.
--
-- Se deshacen con `desenlazar_visita`, la funcion de siempre —ya corregida
-- por la 111 para que solo quite lo que ESE enlace puso— en vez de con
-- updates a mano.
-- ---------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select v.id
      from public.visitas v
     where v.estado = 'activa'
       and v.caja = 'principal'
       and v.enlazada_en is not null
       and v.carro_id in (select carro_id from public.bak_visitas_lavado_0819)
  loop
    perform public.desenlazar_visita(r.id);
    update public.visitas set estado = 'descartada', es_prueba = true where id = r.id;
  end loop;
end $$;


-- ---------------------------------------------------------------------
-- 2. Donde SI hay evidencia, gana la evidencia
--
-- Dos pruebas, en este orden:
--
--   a) La PLACA de ese lavado ya esta ligada a esa persona. Es la mas
--      fuerte que hay: la placa sale de la foto del carro y el enlace se
--      construyo por otro camino.
--   b) Solo una de las dos trae el ticket REAL del lavado (el de Zettle).
--      La otra viene sin ticket, o sea sin nada que la ate a ese cobro.
--
-- La que gana conserva el lavado; a la otra se le quita el `carro_id` y
-- CONSERVA SU VISITA.
-- ---------------------------------------------------------------------
with grupos as (
  select carro_id from public.visitas
   where estado = 'activa' and carro_id is not null
   group by carro_id having count(*) > 1
),
puntos as (
  select v.id as visita, v.carro_id, v.persona_id,
         exists (select 1 from public.persona_placas pp
                  where pp.persona_id = v.persona_id
                    and pp.placa_norm = public.normalizar_placa(c.placa)) as tiene_la_placa,
         (v.ticket is not null and vt.ticket_num is not null
          and v.ticket = vt.ticket_num::text) as tiene_el_ticket
    from public.visitas v
    join public.carros c on c.id = v.carro_id
    left join public.ventas vt on vt.id = c.venta_id
   where v.estado = 'activa' and v.carro_id in (select carro_id from grupos)
),
ganadora as (
  -- Gana por placa si es la UNICA del grupo que la tiene; si no, por
  -- ticket, con la misma condicion de unicidad. "La unica" importa: si las
  -- dos la tienen, no desempata nada.
  select carro_id,
         (array_agg(visita) filter (where tiene_la_placa))[1] as por_placa,
         count(*) filter (where tiene_la_placa)  as cuantas_placa,
         (array_agg(visita) filter (where tiene_el_ticket))[1] as por_ticket,
         count(*) filter (where tiene_el_ticket) as cuantas_ticket
    from puntos group by carro_id
)
update public.visitas v
   set carro_id = null
  from ganadora g
 where v.carro_id = g.carro_id
   and v.estado = 'activa'
   and (
     -- Hay ganadora por placa y esta no es
     (g.cuantas_placa = 1 and v.id <> g.por_placa)
     -- No hay por placa, pero si por ticket, y esta no es
     or (g.cuantas_placa <> 1 and g.cuantas_ticket = 1 and v.id <> g.por_ticket)
     -- No hay ninguna evidencia: el lavado no queda a nombre de nadie
     or (g.cuantas_placa <> 1 and g.cuantas_ticket <> 1)
   );


-- ---------------------------------------------------------------------
-- 3. El nombre que quedo escrito en el carro
--
-- Los dos lavados de la prueba del dueno tenian `cliente = 'Luis Gonzalez'`
-- escrito por el enlace. `desenlazar_visita` ya lo quito (por la 111, que
-- solo borra el nombre si es el que puso ese enlace). Ahora se pone el del
-- cliente que si se quedo con el lavado, que es lo que haria el enlace
-- normal.
-- ---------------------------------------------------------------------
update public.carros c
   set cliente = p.nombre
  from public.visitas v
  join public.personas p on p.id = v.persona_id
 where v.carro_id = c.id
   and v.estado = 'activa'
   and c.id in (select carro_id from public.bak_visitas_lavado_0819)
   and c.cliente is null
   and p.nombre is not null;


-- ---------------------------------------------------------------------
-- 4. El candado, que es el punto de todo esto
--
-- Un lavado no puede tener dos visitas activas. Hasta hoy la regla vivia
-- SOLO dentro de `enlazar_visita_a_carro` (un `if exists ... return error`),
-- asi que cualquier otro camino que escriba `carro_id` —el import, una
-- consulta suelta, la proxima funcion que alguien escriba— se la brincaba
-- sin enterarse. Eso es justo lo que paso: los 14 casos entraron todos por
-- el import.
--
-- En la base, el que se la brinca es rechazado.
-- ---------------------------------------------------------------------
create unique index if not exists visitas_un_lavado_un_cliente
  on public.visitas (carro_id)
  where estado = 'activa' and carro_id is not null;

comment on index public.visitas_un_lavado_un_cliente is
  'Un lavado, un cliente (114). La regla estaba solo en enlazar_visita_a_carro y el import se la brincaba; aqui no se la brinca nadie.';
