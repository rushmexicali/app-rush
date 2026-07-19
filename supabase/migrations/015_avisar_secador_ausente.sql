-- =====================================================================
-- RUSH Car Wash — Avisar cuando un secador se poncha con carro asignado
--
-- Escenario real: se asigna un carro a Luis, Luis termina su turno y se
-- va, y el carro se queda con un secador que ya no esta en el taller.
-- Hoy nadie se enteraria hasta que alguien note que ese carro lleva 40
-- minutos sin avanzar.
--
-- No se reasigna solo ni se borra el registro: quien seco ese carro es
-- dato de eficiencia. Solo se MARCA para que el supervisor decida.
-- =====================================================================

-- La llave foranea permite que la app pida el estado del empleado junto
-- con la asignacion, en una sola consulta.
alter table public.asignaciones
  drop constraint if exists asignaciones_empleado_fk;

alter table public.asignaciones
  add constraint asignaciones_empleado_fk
  foreign key (empleado_id) references public.empleados(id)
  on delete set null;

-- ---------------------------------------------------------------------
-- Carros que estan secando con alguien que ya no esta disponible.
-- ---------------------------------------------------------------------
create or replace view public.carros_sin_secador as
select
  c.id as carro_id,
  array_agg(a.secador order by a.secador) as ausentes
from public.carros c
join public.asignaciones a on a.carro_id = c.id and a.fin is null
join public.empleados e on e.id = a.empleado_id
where c.estado = 'secando'
  and e.estado = 'fuera'
group by c.id;

comment on view public.carros_sin_secador is
  'Carros secando cuyo secador ya se ponchó. El supervisor decide que hacer.';
