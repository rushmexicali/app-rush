-- =====================================================================
-- RUSH Car Wash — Separar los datos de prueba de los reales
--
-- El 19/jul/2026 la app se construyo durante un dia de operacion. Las
-- ventas entraban solas desde temprano, pero la pantalla no existia, asi
-- que los carros se quedaron parados en "prelavado" horas. Al final se
-- cerraron todos de golpe.
--
-- Eso dejo mediciones que PARECEN datos pero no lo son: etapas de 1
-- segundo (los toques seguidos al cerrarlos) y de 2 horas (el tiempo que
-- estuvieron esperando a que existiera la app).
--
-- No se borran: sirven de historia del proyecto y las ventas son reales.
-- Se marcan, para que la analitica de la Fase 5 los excluya.
-- =====================================================================

alter table public.carros add column if not exists es_prueba boolean not null default false;

comment on column public.carros.es_prueba is
  'true = no medir. Carros cuyos tiempos no reflejan la operacion real.';

-- Los 13 carros ya entregados al momento de esta migracion. Se listan
-- por id a proposito, en vez de "where estado = entregado": asi no se
-- marca por accidente alguno de los dos que estaban trabajandose de
-- verdad si se entregaba mientras corria esto.
update public.carros
   set es_prueba = true
 where id in (1, 2, 3, 4, 5, 9, 10, 11, 12, 16, 17, 18, 19);

-- Vista para la Fase 5: solo lo que si se puede medir.
create or replace view public.etapas_medibles as
select e.*, c.producto, c.variante, c.es_express, c.linea, c.tipo_unidad, c.marca
  from public.etapas e
  join public.carros c on c.id = e.carro_id
 where not c.es_prueba
   and e.segundos is not null;

comment on view public.etapas_medibles is
  'Etapas cerradas de carros reales. Base de la analitica de eficiencia.';
