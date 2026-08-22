-- =====================================================================
-- 124 - Un lugar donde los avisos de fondo SE VEAN
--
-- La auditoria encontro el mismo patron dos veces, y las dos con el mismo
-- final: algo se rompe en una tarea de fondo, el codigo lo escribe con
-- `console.error`, y NADIE lo lee nunca. Los logs de Edge Functions duran un
-- dia y hay que ir a buscarlos al panel.
--
--   * Si un grupo de Jibble se vacia, 3 de 15 personas desaparecen de la
--     grilla del supervisor sin un solo error visible.
--   * El outbox de fotos se rendia tras 35 minutos y lo decia en la consola
--     del telefono, o sea en ningun lado.
--
-- El primero se arregla aqui. El segundo ya se arreglo en la tarjeta del
-- carro, que es donde el supervisor lo puede atender.
--
-- 🔑 SE DEDUPLICA A 24 HORAS, y no es un detalle: la sincronizacion de Jibble
-- corre cada 5 minutos. Sin deduplicar, un grupo vacio escribiria 288
-- renglones al dia y el aviso se volveria ruido — que es la otra forma de no
-- avisar. Un mismo (origen, motivo, detalle) se anota UNA vez al dia y
-- despues solo cuenta las veces que volvio a pasar.
--
-- No es una alarma que despierte a nadie: es un renglon en el reporte del
-- dueno, junto a las otras alertas, que sale solo cuando no esta vacio.
-- =====================================================================

create table if not exists public.avisos_del_sistema (
  id          bigint generated always as identity primary key,
  creado_en   timestamptz not null default now(),
  ultimo_en   timestamptz not null default now(),
  veces       int         not null default 1,
  origen      text        not null,
  motivo      text        not null,
  detalle     text
);

-- Un aviso "vivo" es el del mismo dia local. El indice unico hace que el
-- upsert de abajo no pueda duplicar aunque dos tareas escriban a la vez.
create unique index if not exists avisos_del_dia_idx
  on public.avisos_del_sistema
     (origen, motivo, coalesce(detalle,''), ((creado_en at time zone 'America/Tijuana')::date));

create index if not exists avisos_recientes_idx
  on public.avisos_del_sistema (creado_en desc);

create or replace function public.anotar_aviso(p_origen text, p_motivo text, p_detalle text default null)
returns void
language sql
security definer
set search_path = public
as $function$
  insert into public.avisos_del_sistema (origen, motivo, detalle)
  values (p_origen, p_motivo, nullif(btrim(coalesce(p_detalle,'')), ''))
  on conflict (origen, motivo, coalesce(detalle,''), ((creado_en at time zone 'America/Tijuana')::date))
  do update set veces = public.avisos_del_sistema.veces + 1,
                ultimo_en = now();
$function$;

create or replace function public.avisos_recientes(p_dias int default 7)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'origen',  a.origen,
    'motivo',  a.motivo,
    'detalle', a.detalle,
    'veces',   a.veces,
    'desde',   a.creado_en,
    'hasta',   a.ultimo_en
  ) order by a.ultimo_en desc), '[]'::jsonb)
  from public.avisos_del_sistema a
  where a.creado_en >= now() - make_interval(days => greatest(p_dias, 1));
$function$;

revoke execute on function public.anotar_aviso(text, text, text) from public;
revoke execute on function public.avisos_recientes(int) from public;
alter table public.avisos_del_sistema enable row level security;
