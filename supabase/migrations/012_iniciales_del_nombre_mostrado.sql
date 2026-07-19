-- =====================================================================
-- RUSH Car Wash — Las iniciales salen del nombre que se muestra
--
-- Estaban saliendo del nombre de Jibble, asi que al corregir a mano
-- "Mario Alexander Hernandez" -> "Mario Hernandez", el boton seguia
-- diciendo MA en vez de MH. Las iniciales tienen que coincidir con lo
-- que la persona lee al lado, o estorban en vez de ayudar.
-- =====================================================================

create or replace view public.secadores as
select
  id,
  coalesce(nombre_display, nombre_corto, nombre) as mostrar,
  nombre as nombre_completo,
  -- Se calculan de lo que se muestra, no de lo que manda Jibble.
  iniciales_de(coalesce(nombre_display, nombre_corto, nombre)) as iniciales,
  color,
  estado,
  desde,
  manual
from public.empleados;

-- Nota sobre iniciales repetidas: quedan pares como Jaime Gallegos y
-- Jesus Gil, ambos JG. Se acepta a proposito. Las iniciales son el
-- ancla visual dentro del circulo; quien de verdad distingue es el
-- COLOR, que ya es unico por persona, y el nombre completo va escrito
-- al lado. Forzar tres letras (JGa, JGi) haria el circulo ilegible a
-- un metro, que es la distancia a la que el supervisor lo va a mirar.
