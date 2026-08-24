-- Prueba: los avisos del sistema se pueden marcar como atendidos, y una
-- ocurrencia NUEVA los reabre (migracion 131).
--
-- El grupo 3 es la razon de que esto exista. `anotar_aviso` deduplica por
-- (origen, motivo, detalle, dia local), asi que sin cuidado un aviso marcado
-- atendido a las 10 AM esconderia el MISMO fallo de las 6 PM: el `do update`
-- caeria sobre la fila ya marcada y solo subiria `veces`. Atendido significa
-- "ya lo resolvi", no "no me lo vuelvas a decir".
--
-- Revierte con `raise` al final, asi que se puede correr contra produccion.
do $prueba$
declare
  msg  text := '';
  v_id bigint;
  n0   int;
  n1   int;
  r    jsonb;
begin
  perform public.anotar_aviso('zz-prueba', 'zz-motivo-suite', 'detalle de prueba');
  select id into v_id from public.avisos_del_sistema
   where origen='zz-prueba' and motivo='zz-motivo-suite';
  select jsonb_array_length(public.avisos_recientes(7)) into n0;

  -- 1) La lista entrega el id: sin el no hay a que apuntarle el boton.
  if not exists (
    select 1 from jsonb_array_elements(public.avisos_recientes(7)) a
     where (a->>'id')::bigint = v_id) then
    raise exception 'PRUEBA FALLIDA -> avisos_recientes no entrega el id';
  end if;
  msg := msg || 'la lista trae el id OK. ';

  -- 2) Marcarlo lo saca de la lista, y NO borra la fila.
  r := public.marcar_aviso_atendido(v_id);
  if not (r->>'ok')::boolean then
    raise exception 'PRUEBA FALLIDA -> no se pudo marcar (%)', r;
  end if;
  select jsonb_array_length(public.avisos_recientes(7)) into n1;
  if n1 <> n0 - 1 then
    raise exception 'PRUEBA FALLIDA -> marcar no lo saco de la lista (% -> %)', n0, n1;
  end if;
  if not exists (select 1 from public.avisos_del_sistema where id = v_id) then
    raise exception 'PRUEBA FALLIDA -> marcar BORRO la fila; el historico es dato';
  end if;
  msg := msg || 'se marca y no se borra OK. ';

  -- 3) LO QUE IMPORTA: una ocurrencia NUEVA lo reabre.
  perform public.anotar_aviso('zz-prueba', 'zz-motivo-suite', 'detalle de prueba');
  select jsonb_array_length(public.avisos_recientes(7)) into n1;
  if n1 <> n0 then
    raise exception 'PRUEBA FALLIDA -> una ocurrencia nueva NO reabrio el aviso: marcarlo lo silencia hacia adelante';
  end if;
  msg := msg || 'una ocurrencia nueva lo reabre OK. ';

  -- 4) Es reversible, por si se toca por error.
  perform public.marcar_aviso_atendido(v_id, true);
  perform public.marcar_aviso_atendido(v_id, false);
  select jsonb_array_length(public.avisos_recientes(7)) into n1;
  if n1 <> n0 then
    raise exception 'PRUEBA FALLIDA -> desmarcar no lo devolvio a la lista';
  end if;
  msg := msg || 'se puede deshacer OK. ';

  -- 5) Un id que no existe contesta, no revienta.
  r := public.marcar_aviso_atendido(-1);
  if (r->>'ok')::boolean then
    raise exception 'PRUEBA FALLIDA -> marcar un aviso inexistente dijo que si';
  end if;
  msg := msg || 'un id inexistente contesta OK. ';

  raise exception 'PRUEBA PASADA -> %', msg;
end
$prueba$;
