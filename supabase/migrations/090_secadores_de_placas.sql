-- =====================================================================
-- RUSH — Los secadores de la ultima visita de cada placa · 29/jul/2026
--
-- El "Historial por placa" del reporte es una fila POR PLACA (agregada
-- sobre todas sus visitas). El dueno pidio una columna con el/los secador
-- que la secaron, clicable al perfil del secador.
--
-- Como la fila es agregada, se toma la tripulacion de la ULTIMA visita
-- (consistente con "Ultima vez" y "Hora de llegada", que ya son de la
-- ultima visita). Se devuelve el empleado_id ademas del nombre para poder
-- ligar al perfil (que se identifica por empleado_id, no por nombre).
--
-- Una sola funcion que el endpoint /placas usa para las DOS fuentes (la
-- vista historial_placas cuando no hay busqueda, y buscar_vehiculos cuando
-- si): asi no hay dos reglas para la misma pregunta. Recibe la lista de
-- placas (ya normalizadas, como las devuelven ambas fuentes) y regresa un
-- objeto placa_normalizada -> [{id, nombre}, ...].
--
-- Solo lectura, aditiva. Mismo criterio de exclusion del resto del reporte:
-- es_prueba y cancelado_en fuera.
-- =====================================================================
create or replace function public.secadores_de_placas(p_placas text[])
returns jsonb
language sql
stable
as $$
  with pl as (
    select distinct public.normalizar_placa(x) as placa_norm
    from unnest(coalesce(p_placas, array[]::text[])) x
    where nullif(public.normalizar_placa(x), '') is not null
  ),
  ultimo as (
    -- El carro mas reciente de esa placa (la "ultima visita").
    select pl.placa_norm,
      (select c.id
         from public.carros c
        where public.normalizar_placa(c.placa) = pl.placa_norm
          and c.placa is not null and not c.es_prueba and c.cancelado_en is null
        order by c.creado_en desc
        limit 1) as carro_id
    from pl
  )
  select coalesce(jsonb_object_agg(u.placa_norm, s.secs), '{}'::jsonb)
  from ultimo u
  cross join lateral (
    -- La tripulacion de ese carro: id (para ligar al perfil) + nombre. El
    -- id puede venir null en filas viejas sin empleado_id; ahi el front
    -- muestra el nombre sin liga.
    select coalesce(
      jsonb_agg(distinct jsonb_build_object(
        'id',     a.empleado_id,
        'nombre', coalesce(sd.mostrar, a.secador)
      )),
      '[]'::jsonb) as secs
    from public.asignaciones a
    left join public.secadores sd on sd.id = a.empleado_id
    where a.carro_id = u.carro_id
  ) s
  where u.carro_id is not null;
$$;

comment on function public.secadores_de_placas(text[]) is
  'Para el Historial por placa del reporte: por placa (normalizada) devuelve los secadores de la ULTIMA visita, con id para ligar a su perfil.';
