-- =====================================================================
-- RUSH — La lealtad ACUMULA lavados gratis, y el historial del cliente
-- 26/jul/2026
--
-- El dueno: a veces el cliente llega con su 6to gratis ganado pero prefiere
-- un express rapido y guardar el gratis para despues. Asi que los lavados
-- gratis se ACUMULAN: cada 5 pagados suma uno. La pantalla muestra "tiene N
-- lavados gratis"; la cajera pone "Utilizar Lavado GRATIS" solo cuando lo va
-- a canjear.
--
-- Modelo (sobre el libro de visitas, sigue siendo derivado):
--   ganados      = floor((sellos_iniciales + pagados) / 5)
--   canjes       = visitas con es_gratis = true
--   disponibles  = ganados - canjes   (los que puede usar ahora)
--   sellos       = (sellos_iniciales + pagados) mod 5   (progreso 0-4 al siguiente)
-- La siembra (sellos_iniciales, 0-4) sigue siendo solo el arranque de progreso:
-- nadie estrena con lavados gratis regalados (decision del 26/jul).
--
-- Ademas: historial_de_persona() para la pantalla "Ver Historial".
-- =====================================================================

-- --- La vista, ahora con ganados/disponibles (se agregan al FINAL para poder
-- --- usar create or replace view). `sellos` cambia a progreso 0-4.
create or replace view public.lealtad_por_persona as
select
  p.id as persona_id,
  coalesce(count(*) filter (where v.id is not null and not v.es_gratis), 0)::int as lavados_pagados,
  coalesce(count(*) filter (where v.id is not null and v.es_gratis), 0)::int      as canjes,
  ((p.sellos_iniciales
    + coalesce(count(*) filter (where v.id is not null and not v.es_gratis), 0)::int) % 5) as sellos,
  (p.visitas_seed + coalesce(count(*) filter (where v.id is not null), 0)::int) as visitas_totales,
  max(v.creado_en) as ultima_visita,
  floor((p.sellos_iniciales
    + coalesce(count(*) filter (where v.id is not null and not v.es_gratis), 0)::int) / 5.0)::int as ganados,
  greatest(0,
    floor((p.sellos_iniciales
      + coalesce(count(*) filter (where v.id is not null and not v.es_gratis), 0)::int) / 5.0)::int
    - coalesce(count(*) filter (where v.id is not null and v.es_gratis), 0)::int
  ) as disponibles
from public.personas p
left join public.visitas v
  on v.persona_id = p.id and v.estado = 'activa' and not v.es_prueba
group by p.id, p.sellos_iniciales, p.visitas_seed;

-- --- lealtad_de: expone disponibles y ganados; elegible = tiene disponibles.
create or replace function public.lealtad_de(p_persona bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sellos',          l.sellos,               -- progreso 0-4 al siguiente
    'faltan',          5 - l.sellos,           -- pagados que faltan al siguiente
    'disponibles',     l.disponibles,          -- lavados gratis acumulados
    'ganados',         l.ganados,
    'elegible',        l.disponibles > 0,
    'lavados_pagados', l.lavados_pagados,
    'canjes',          l.canjes,
    'visitas_totales', l.visitas_totales,
    'ultima_visita',   l.ultima_visita
  )
  from public.lealtad_por_persona l
  where l.persona_id = p_persona;
$$;

-- --- registrar_visita: mismo, pero el gratis SOLO se cobra si de verdad tiene
-- --- disponibles (si no, se registra como pagado; evita un canje en falso).
create or replace function public.registrar_visita(
  p_persona   bigint,
  p_placa     text    default null,
  p_marca     text    default null,
  p_submarca  text    default null,
  p_tipo      text    default null,
  p_color     text    default null,
  p_foto_path text    default null,
  p_es_gratis boolean default false,
  p_caja      text    default 'principal'
) returns jsonb language plpgsql as $$
declare
  v_id      bigint;
  v_placa_n text;
  v_gratis  boolean := coalesce(p_es_gratis, false);
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
  end if;

  -- Un gratis solo cuenta si tiene lavados gratis disponibles.
  if v_gratis and not exists (
       select 1 from public.lealtad_por_persona where persona_id = p_persona and disponibles > 0) then
    v_gratis := false;
  end if;

  insert into public.visitas
    (persona_id, placa, marca, submarca, tipo_unidad, color, foto_path, es_gratis, caja)
  values
    (p_persona, nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     nullif(btrim(upper(coalesce(p_color,''))),''),
     nullif(btrim(coalesce(p_foto_path,'')),''),
     v_gratis, coalesce(nullif(btrim(p_caja),''),'principal'))
  returning id into v_id;

  v_placa_n := public.normalizar_placa(p_placa);
  if v_placa_n is not null then
    insert into public.persona_placas (persona_id, placa_norm, placa_como_se_lee)
    values (p_persona, v_placa_n, nullif(btrim(coalesce(p_placa,'')),''))
    on conflict (persona_id, placa_norm) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'visita', v_id,
                            'lealtad', public.lealtad_de(p_persona));
end;
$$;

-- --- Historial detallado de una persona: sus visitas registradas, con el
-- --- carro, la hora de entrada (pago) y de salida (entrega del supervisor) y
-- --- los secadores. Solo hay detalle para las visitas ligadas a un carro;
-- --- las visitas pre-CRM viven solo como conteo (visitas_seed).
create or replace function public.historial_de_persona(p_persona bigint)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'fecha',     coalesce(c.creado_en, vi.creado_en),
      'placa',     coalesce(c.placa_display, c.placa, vi.placa),
      'producto',  c.producto,
      'variante',  c.variante,
      'entrada',   c.creado_en,
      'salida',    c.entregado_en,
      'es_gratis', vi.es_gratis,
      'enlazado',  vi.carro_id is not null,
      'secadores', coalesce((
        select jsonb_agg(distinct coalesce(s.mostrar, a.secador))
          from public.asignaciones a
          left join public.secadores s on s.id = a.empleado_id
         where a.carro_id = c.id
      ), '[]'::jsonb)
    ) order by coalesce(c.creado_en, vi.creado_en) desc
  ), '[]'::jsonb)
  from public.visitas vi
  left join public.carros c on c.id = vi.carro_id
  where vi.persona_id = p_persona and vi.estado = 'activa';
$$;
