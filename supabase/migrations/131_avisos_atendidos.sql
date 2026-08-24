-- 131 · Los avisos del sistema se pueden marcar como ATENDIDOS
--
-- Decision del dueno (23/ago/2026), sobre la pregunta que dejo abierta el
-- critico de completitud de la auditoria del 22/ago.
--
-- El canal de avisos (migracion 124) existe para que lo que antes moria en un
-- `console.error` se pueda ver. Pero no habia forma de apagarlos: solo
-- caducaban a los 7 dias. Consecuencia inmediata y medida: el PRIMER aviso que
-- existio ya era falso -- pedia autorizar el borrado de 176 fotos huerfanas que
-- se habian borrado esa misma noche, y se iba a quedar en pantalla una semana.
--
-- Un canal de alertas que muestra cosas ya resueltas se deja de leer, y
-- entonces no avisa de nada. Es la regla 3 de `pruebas/README.md` aplicada a la
-- pantalla del dueno: un falso positivo mata el canal.
--
-- 🔑 LA DECISION QUE HAY QUE RESPETAR SI ESTO SE TOCA
--
-- Marcar atendido NO puede tapar una ocurrencia NUEVA. `anotar_aviso` deduplica
-- por (origen, motivo, detalle, dia local): si el mismo problema vuelve a pasar
-- ESE MISMO DIA, cae sobre la misma fila y solo sube `veces`. Sin cuidado, un
-- aviso marcado atendido a las 10 AM esconderia el mismo fallo de las 6 PM.
--
-- Por eso el `do update` limpia `atendido_en`: **una ocurrencia nueva reabre el
-- aviso.** Atendido significa "ya lo vi y lo resolvi", no "no me lo vuelvas a
-- decir".
--
-- No se borra la fila: el historico de que algo fallo es dato, igual que en
-- todo este proyecto. Solo se saca de la lista.

alter table public.avisos_del_sistema
  add column if not exists atendido_en timestamptz;

comment on column public.avisos_del_sistema.atendido_en is
  'Cuando el dueno lo marco como resuelto. La fila NO se borra: solo sale de '
  'avisos_recientes. Si el mismo aviso vuelve a ocurrir, anotar_aviso lo vuelve '
  'a poner en null -- una ocurrencia nueva REABRE el aviso.';

-- --------------------------------------------------------------------------
-- Una ocurrencia nueva reabre el aviso.
create or replace function public.anotar_aviso(
  p_origen text, p_motivo text, p_detalle text default null
)
returns void
language sql
security definer
set search_path to 'public'
as $function$
  insert into public.avisos_del_sistema (origen, motivo, detalle)
  values (p_origen, p_motivo, nullif(btrim(coalesce(p_detalle,'')), ''))
  on conflict (origen, motivo, coalesce(detalle,''), ((creado_en at time zone 'America/Tijuana')::date))
  do update set veces = public.avisos_del_sistema.veces + 1,
                ultimo_en = now(),
                -- Reabre: ver el encabezado. Marcar atendido no silencia lo que
                -- vuelve a pasar.
                atendido_en = null;
$function$;

-- --------------------------------------------------------------------------
-- La lista deja fuera los atendidos, y ahora entrega el `id` para poder
-- marcarlos.
create or replace function public.avisos_recientes(p_dias integer default 7)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',      a.id,
    'origen',  a.origen,
    'motivo',  a.motivo,
    'detalle', a.detalle,
    'veces',   a.veces,
    'desde',   a.creado_en,
    'hasta',   a.ultimo_en
  ) order by a.ultimo_en desc), '[]'::jsonb)
  from public.avisos_del_sistema a
  where a.creado_en >= now() - make_interval(days => greatest(p_dias, 1))
    and a.atendido_en is null;
$function$;

-- --------------------------------------------------------------------------
-- Marcar / desmarcar. Es reversible a proposito: si se toca por error, el
-- aviso se recupera. Idempotente.
create or replace function public.marcar_aviso_atendido(
  p_id bigint, p_atendido boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_existe boolean;
begin
  select true into v_existe from public.avisos_del_sistema where id = p_id;
  if not coalesce(v_existe,false) then
    return jsonb_build_object('ok', false, 'error', 'Ese aviso ya no existe');
  end if;

  update public.avisos_del_sistema
     set atendido_en = case when coalesce(p_atendido,true) then now() else null end
   where id = p_id;

  return jsonb_build_object('ok', true, 'id', p_id, 'atendido', coalesce(p_atendido,true));
end;
$function$;

-- --------------------------------------------------------------------------
-- Comprobacion.
--
-- ⚠️ ESTE BLOQUE ESCRIBE, y la primera version no se limpiaba: al aplicar la
-- migracion de verdad (no el ensayo, que revierte con `raise`) dejo un aviso
-- `zz-prueba` VISIBLE en el panel del dueno. O sea que la comprobacion de que
-- los avisos falsos se pueden apagar produjo un aviso falso. Se neutralizo
-- marcandolo atendido -- con la funcion que esta misma migracion crea -- y
-- ahora el bloque borra su propia fila al terminar.
--
-- La leccion, para el resto de las migraciones: una comprobacion que LLAMA a
-- algo que escribe tiene que limpiar lo que escribio, o solo puede vivir en el
-- ensayo. Las de las migraciones 128 y 130 no tenian este problema (crean y
-- tiran su propia funcion, o solo leen).
do $do$
declare
  v_id  bigint;
  n0    int;
  n1    int;
  r     jsonb;
begin
  perform public.anotar_aviso('zz-prueba', 'zz-motivo-131', 'detalle de prueba');
  select id into v_id from public.avisos_del_sistema
   where origen='zz-prueba' and motivo='zz-motivo-131';

  select jsonb_array_length(public.avisos_recientes(7)) into n0;

  r := public.marcar_aviso_atendido(v_id);
  if not (r->>'ok')::boolean then
    raise exception 'FALLO: no se pudo marcar (%)', r;
  end if;

  select jsonb_array_length(public.avisos_recientes(7)) into n1;
  if n1 <> n0 - 1 then
    raise exception 'FALLO: marcar atendido no lo saco de la lista (% -> %)', n0, n1;
  end if;

  -- LO QUE IMPORTA: una ocurrencia NUEVA lo reabre.
  perform public.anotar_aviso('zz-prueba', 'zz-motivo-131', 'detalle de prueba');
  select jsonb_array_length(public.avisos_recientes(7)) into n1;
  if n1 <> n0 then
    raise exception 'FALLO: una ocurrencia nueva NO reabrio el aviso (% en vez de %)', n1, n0;
  end if;

  -- Y desmarcar es reversible.
  perform public.marcar_aviso_atendido(v_id, true);
  perform public.marcar_aviso_atendido(v_id, false);
  select jsonb_array_length(public.avisos_recientes(7)) into n1;
  if n1 <> n0 then
    raise exception 'FALLO: desmarcar no devolvio el aviso a la lista';
  end if;

  -- Un id que no existe no revienta: contesta que no existe.
  r := public.marcar_aviso_atendido(-1);
  if (r->>'ok')::boolean then
    raise exception 'FALLO: marcar un aviso inexistente dijo que si';
  end if;

  -- La comprobacion se lleva su propia basura. Solo su fila, por id.
  delete from public.avisos_del_sistema where id = v_id;

  raise notice 'OK: se marca, se saca de la lista, una ocurrencia nueva lo reabre, y se puede deshacer';
end
$do$;
