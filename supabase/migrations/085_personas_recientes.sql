-- =====================================================================
-- 085 — Las ultimas personas con visita (para el buscador de clientes)
--
-- En el reporte, seccion Clientes, antes de escribir no habia nada util
-- ("escribe 2 letras"). Ahora se muestran los perfiles de las ultimas 10
-- personas que tuvieron una visita registrada, para que el dueno vea de
-- quien fue lo mas reciente sin tener que buscar.
--
-- Devuelve lo MISMO que buscar_personas (persona_json por persona), asi que
-- la pantalla las pinta con el mismo formato de tarjeta (lealtad, placas,
-- telefono) sin codigo nuevo.
--
-- Una persona sale UNA vez, por su visita mas reciente (group by persona).
-- Se excluyen las de prueba (persona o visita) y solo cuentan visitas
-- 'activa' — una visita descartada no es una visita.
-- =====================================================================

create or replace function public.personas_recientes(p_limite int default 10)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(public.persona_json(x.persona_id) order by x.ultima desc), '[]'::jsonb)
  from (
    select v.persona_id, max(v.creado_en) as ultima
      from public.visitas v
      join public.personas p on p.id = v.persona_id
     where v.estado = 'activa'
       and v.persona_id is not null
       and not coalesce(v.es_prueba, false)
       and not coalesce(p.es_prueba, false)
     group by v.persona_id
     order by ultima desc
     limit greatest(p_limite, 0)
  ) x;
$function$;

comment on function public.personas_recientes(int) is
  'Las N personas con la visita mas reciente (persona_json c/u), para el '
  'buscador de clientes antes de escribir. Una persona una vez, por su '
  'ultima visita activa. Excluye pruebas.';
