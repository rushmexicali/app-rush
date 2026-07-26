-- =====================================================================
-- RUSH Car Wash — CRM / Lealtad (app de la cajera) · 26/jul/2026
--
-- Arranca la fase del CRM: una app para la CAJERA que lleva el programa
-- "6to lavado gratis" y guarda datos de clientes. Modelo persona-centrico
-- (correccion del dueno el 26/jul):
--   - La lealtad es de la PERSONA, no del carro. Un cliente acumula visitas
--     aunque traiga 4 carros distintos.
--   - La placa NO es dueña de un cliente: es un FACILITADOR de busqueda. Una
--     placa puede ligarse a VARIAS personas (el carro que comparten esposo/
--     hijo) y una persona a varias placas -> N-a-N (persona_placas).
--   - Al leer una placa ligada a, p.ej., Maria Perez, la pantalla lo dice; la
--     cajera pregunta "¿asigno a Maria o registro nuevo?". "Nuevo" agrega otra
--     persona a esa misma placa.
--
-- PRINCIPIO (igual que historial_placas es vista sobre carros, y 063
-- sobrescribe en vez de coalescer): el libro de visitas es la AUTORIDAD y la
-- lealtad es una VISTA derivada por persona. La lealtad cuenta al REGISTRAR la
-- visita (no al amarrar el carro), asi nunca se subcuenta si la cajera no
-- alcanza a enlazar, y un lavado reembolsado sigue contando (§13). Solo
-- DESCARTAR una visita (no hubo venta) la saca.
--
-- Siembra: se importan personas de carros.cliente (texto libre) para armar y
-- probar; un dia antes de lanzar se re-importa el archivo actualizado del
-- dueno (misma forma: nombre + visitas). El importador es re-ejecutable.
--
-- RLS: activado sin politicas. Solo la Edge Function (service-role) toca estas
-- tablas; PostgREST anonimo queda afuera. Aqui vive PII (telefono, notas).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Normalizador de nombre: mayusculas, sin acentos, espacios colapsados.
-- Para busqueda y para agrupar la siembra. NO se usa como llave unica
-- global (dos personas distintas pueden llamarse igual); solo la siembra
-- exige unicidad, via un indice PARCIAL (ver abajo).
-- ---------------------------------------------------------------------
-- Quita acentos con unaccent (extension estandar; ya instalada). A PROPOSITO
-- no se usan literales acentuados en el SQL: el transporte de SQL a la base
-- mutila los bytes UTF-8 crudos (probado: un literal 'E' llega corrupto). El
-- codigo aqui es ASCII puro. unaccent es STABLE -> esta funcion es STABLE, y
-- no se usa en ningun indice ni columna generada, asi que esta bien.
create extension if not exists unaccent;

create or replace function public.normalizar_nombre(p_nombre text)
returns text language sql stable as $$
  select nullif(
    btrim(regexp_replace(
      upper(public.unaccent(coalesce(p_nombre, ''))),
      '\s+', ' ', 'g')),
    '');
$$;

-- ---------------------------------------------------------------------
-- personas — dueña de la lealtad + PII.
-- ---------------------------------------------------------------------
create table if not exists public.personas (
  id               bigint generated always as identity primary key,
  nombre           text not null,
  nombre_norm      text,
  telefono         text,
  notas            text,
  sellos_iniciales smallint not null default 0,   -- offset de siembra (0-4)
  visitas_seed     int      not null default 0,   -- conteo historico importado (piso)
  origen           text     not null default 'caja',  -- 'import' (siembra) | 'caja'
  es_prueba        boolean  not null default false,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now()
);

create index if not exists personas_nombre_norm_idx on public.personas (nombre_norm);
-- Unicidad SOLO para las filas sembradas, para que la siembra sea
-- idempotente (upsert por nombre) sin impedir que la cajera cree dos
-- personas distintas con el mismo nombre.
create unique index if not exists personas_import_nombre_uq
  on public.personas (nombre_norm) where origen = 'import';

alter table public.personas enable row level security;

-- ---------------------------------------------------------------------
-- persona_placas — enlace N-a-N. La placa como facilitador de busqueda.
-- ---------------------------------------------------------------------
create table if not exists public.persona_placas (
  id               bigint generated always as identity primary key,
  persona_id       bigint not null references public.personas(id) on delete cascade,
  placa_norm       text not null,
  placa_como_se_lee text,
  creado_en        timestamptz not null default now(),
  unique (persona_id, placa_norm)
);

create index if not exists persona_placas_placa_idx on public.persona_placas (placa_norm);

alter table public.persona_placas enable row level security;

-- ---------------------------------------------------------------------
-- visitas — libro de visitas (autoridad de lealtad) + staging del amarre.
-- ---------------------------------------------------------------------
create table if not exists public.visitas (
  id           bigint generated always as identity primary key,
  persona_id   bigint not null references public.personas(id) on delete cascade,
  placa        text,
  placa_norm   text generated always as (public.normalizar_placa(placa)) stored,
  marca        text,
  submarca     text,
  tipo_unidad  text,
  color        text,
  foto_path    text,                 -- null = captura manual (sin foto)
  es_gratis    boolean not null default false,   -- esta visita es el 6to canjeado
  estado       text not null default 'activa'
               check (estado in ('activa', 'descartada')),
  carro_id     bigint references public.carros(id) on delete set null,
  caja         text not null default 'principal',
  es_prueba    boolean not null default false,
  creado_en    timestamptz not null default now(),
  enlazada_en  timestamptz
);

create index if not exists visitas_persona_idx on public.visitas (persona_id);
create index if not exists visitas_estado_idx  on public.visitas (estado);
create index if not exists visitas_carro_idx   on public.visitas (carro_id);
create index if not exists visitas_placa_idx   on public.visitas (placa_norm);

alter table public.visitas enable row level security;

-- ---------------------------------------------------------------------
-- lealtad_por_persona — VISTA derivada. "compra 5, el 6to gratis".
-- Cuenta solo visitas activas y no de prueba. Incluye a las personas sin
-- visitas (left join) para que una sembrada muestre su offset.
-- ---------------------------------------------------------------------
create or replace view public.lealtad_por_persona as
select
  p.id as persona_id,
  coalesce(count(*) filter (where v.id is not null and not v.es_gratis), 0)::int as lavados_pagados,
  coalesce(count(*) filter (where v.id is not null and v.es_gratis), 0)::int      as canjes,
  greatest(0,
    p.sellos_iniciales
    + coalesce(count(*) filter (where v.id is not null and not v.es_gratis), 0)::int
    - 5 * coalesce(count(*) filter (where v.id is not null and v.es_gratis), 0)::int
  ) as sellos,
  (p.visitas_seed
    + coalesce(count(*) filter (where v.id is not null), 0)::int) as visitas_totales,
  max(v.creado_en) as ultima_visita
from public.personas p
left join public.visitas v
  on v.persona_id = p.id and v.estado = 'activa' and not v.es_prueba
group by p.id, p.sellos_iniciales, p.visitas_seed;

-- Envoltura escalar para adjuntar la lealtad de UNA persona como jsonb, con
-- los campos derivados (faltan, elegible) ya calculados.
create or replace function public.lealtad_de(p_persona bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sellos',          l.sellos,
    'faltan',          greatest(0, 5 - l.sellos),
    'elegible',        l.sellos >= 5,
    'lavados_pagados', l.lavados_pagados,
    'canjes',          l.canjes,
    'visitas_totales', l.visitas_totales,
    'ultima_visita',   l.ultima_visita
  )
  from public.lealtad_por_persona l
  where l.persona_id = p_persona;
$$;

-- Arma el jsonb completo de una persona (datos + lealtad).
create or replace function public.persona_json(p_persona bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id',       p.id,
    'nombre',   p.nombre,
    'telefono', p.telefono,
    'notas',    p.notas,
    'lealtad',  public.lealtad_de(p.id)
  )
  from public.personas p
  where p.id = p_persona;
$$;

-- =====================================================================
-- RPCs
-- =====================================================================

-- 1) Buscar personas ligadas a una placa (0/1/varias). La cajera confirma.
create or replace function public.personas_por_placa(p_placa text)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(public.persona_json(pp.persona_id)
                            order by pp.creado_en), '[]'::jsonb)
  from public.persona_placas pp
  where pp.placa_norm = public.normalizar_placa(p_placa);
$$;

-- 2) Buscar personas por nombre (via principal al inicio, sin placas).
create or replace function public.buscar_personas(p_q text)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(j order by j->>'nombre'), '[]'::jsonb)
  from (
    select public.persona_json(p.id) as j
    from public.personas p
    where public.normalizar_nombre(p_q) is not null
      and p.nombre_norm like '%' || public.normalizar_nombre(p_q) || '%'
    order by p.nombre
    limit 25
  ) s;
$$;

-- 3) Crear o editar persona. p_id null = crea; con id = edita.
create or replace function public.upsert_persona(
  p_id       bigint default null,
  p_nombre   text   default null,
  p_telefono text   default null,
  p_notas    text   default null
) returns jsonb language plpgsql as $$
declare
  v_id bigint;
begin
  if nullif(btrim(coalesce(p_nombre, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el nombre');
  end if;

  if p_id is null then
    insert into public.personas (nombre, nombre_norm, telefono, notas)
    values (btrim(p_nombre), public.normalizar_nombre(p_nombre),
            nullif(btrim(coalesce(p_telefono,'')),''), nullif(btrim(coalesce(p_notas,'')),''))
    returning id into v_id;
  else
    update public.personas set
      nombre      = btrim(p_nombre),
      nombre_norm = public.normalizar_nombre(p_nombre),
      telefono    = nullif(btrim(coalesce(p_telefono,'')),''),
      notas       = nullif(btrim(coalesce(p_notas,'')),''),
      actualizado_en = now()
    where id = p_id
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'persona', public.persona_json(v_id));
end;
$$;

-- 4) Registrar una visita (CUENTA lealtad ya). Auto-liga la placa a la persona.
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
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
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
     coalesce(p_es_gratis, false), coalesce(nullif(btrim(p_caja),''),'principal'))
  returning id into v_id;

  -- Auto-ligar la placa a la persona (facilitador de futuras busquedas).
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

-- 5) Descartar una visita (no hubo venta): deja de contar lealtad.
create or replace function public.descartar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare v_persona bigint;
begin
  update public.visitas set estado = 'descartada'
  where id = p_visita returning persona_id into v_persona;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;
  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;

-- 6) Enlazar una visita a su carro. Idempotente. Escribe el carro AUTORITATIVO
--    (misma semantica que 063), MAS cliente = nombre de la persona y la foto.
--    Solo pisa placa/marca/submarca/tipo si la visita SI trajo placa (hubo
--    captura); si fue manual sin placa, no borra lo que el carro ya tenga.
--    Nunca toca datos_de_nota.
create or replace function public.enlazar_visita_a_carro(
  p_visita bigint,
  p_carro  bigint
) returns jsonb language plpgsql as $$
declare
  v          record;
  v_nombre   text;
  v_sub      text;
  v_tipo     text;
begin
  select * into v from public.visitas where id = p_visita;
  if v.id is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;
  if not exists (select 1 from public.carros where id = p_carro) then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  select nombre into v_nombre from public.personas where id = v.persona_id;

  -- La foto (si la visita la trae) y el cliente SIEMPRE se ponen.
  update public.carros set
    cliente        = coalesce(v_nombre, cliente),
    foto_path      = coalesce(v.foto_path, foto_path),
    foto_url       = case when v.foto_path is not null then null else foto_url end,
    foto_url_expira= case when v.foto_path is not null then null else foto_url_expira end
  where id = p_carro;

  -- La identidad de la placa solo si la visita capturo una placa. Autoritativo
  -- (sobrescribe), con la regla tipo-atado-a-submarca de la 063.
  if v.placa_norm is not null then
    v_sub  := nullif(btrim(upper(coalesce(v.submarca, ''))), '');
    v_tipo := nullif(btrim(coalesce(v.tipo_unidad, '')), '');
    if v_tipo is not null and v_tipo not in ('pickup','camioneta','automovil','pasajeros') then
      v_tipo := null;
    end if;
    update public.carros set
      placa       = v.placa,
      placa_en    = now(),
      marca       = nullif(btrim(upper(coalesce(v.marca, ''))), ''),
      submarca    = v_sub,
      tipo_unidad = case when v_sub is not null
                         then coalesce(v_tipo, tipo_unidad)
                         else coalesce(tipo_unidad, v_tipo) end
    where id = p_carro;
  end if;

  update public.visitas set carro_id = p_carro, enlazada_en = now()
  where id = p_visita;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v.persona_id));
end;
$$;

-- 7) Desenlazar: suelta el carro (no descuenta lealtad; no borra datos del carro).
create or replace function public.desenlazar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare v_persona bigint;
begin
  update public.visitas set carro_id = null, enlazada_en = null
  where id = p_visita returning persona_id into v_persona;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;
  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;

-- 8) Candidatos para enlazar: carros recien nacidos sin visita enlazada +
--    visitas activas sin carro, para la tarjeta de confirmar.
create or replace function public.candidatos_para_enlazar(
  p_caja    text default 'principal',
  p_minutos int  default 20
) returns jsonb language sql stable as $$
  select jsonb_build_object(
    'carros', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', c.id, 'producto', c.producto, 'variante', c.variante,
               'monto', c.monto, 'creado_en', c.creado_en, 'placa', c.placa,
               'cliente', c.cliente) order by c.creado_en desc)
      from public.carros c
      where c.creado_en > now() - make_interval(mins => p_minutos)
        and c.cancelado_en is null
        and coalesce(c.es_prueba, false) = false
        and not exists (select 1 from public.visitas v
                        where v.carro_id = c.id and v.estado = 'activa')
    ), '[]'::jsonb),
    'visitas', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', v.id, 'persona', p.nombre, 'placa', v.placa,
               'es_gratis', v.es_gratis, 'creado_en', v.creado_en) order by v.creado_en desc)
      from public.visitas v join public.personas p on p.id = v.persona_id
      where v.estado = 'activa' and v.carro_id is null
        and v.caja = coalesce(nullif(btrim(p_caja),''),'principal')
        and v.creado_en > now() - make_interval(mins => p_minutos)
    ), '[]'::jsonb)
  );
$$;

-- =====================================================================
-- Siembra: importar personas desde carros.cliente (texto libre). Idempotente
-- por nombre_norm (indice parcial where origen='import'). NO liga placas.
-- Re-ejecutable: a un dia de lanzar se corre con el archivo actualizado.
-- =====================================================================
create or replace function public.importar_personas()
returns jsonb language plpgsql as $$
declare v_n int;
begin
  insert into public.personas (nombre, nombre_norm, visitas_seed, sellos_iniciales, origen)
  select
    (array_agg(c.cliente order by c.creado_en desc))[1] as nombre,  -- nombre a mostrar mas reciente
    public.normalizar_nombre(c.cliente)                 as nombre_norm,
    count(*)::int                                        as visitas_seed,
    (count(*) % 5)::smallint                             as sellos_iniciales,
    'import'
  from public.carros c
  where nullif(btrim(coalesce(c.cliente,'')),'') is not null
    and coalesce(c.es_prueba, false) = false
    and c.cancelado_en is null
    and public.normalizar_nombre(c.cliente) is not null
  group by public.normalizar_nombre(c.cliente)
  on conflict (nombre_norm) where origen = 'import'
  do update set
    nombre           = excluded.nombre,
    visitas_seed     = excluded.visitas_seed,
    sellos_iniciales = excluded.sellos_iniciales,
    actualizado_en   = now();

  select count(*) into v_n from public.personas where origen = 'import';
  return jsonb_build_object('ok', true, 'personas_sembradas', v_n);
end;
$$;
