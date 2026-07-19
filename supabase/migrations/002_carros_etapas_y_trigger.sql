-- =====================================================================
-- RUSH Car Wash — Fase 2: la cola de carros
--
-- Convierte cada venta en un carro que el supervisor puede seguir a lo
-- largo del proceso, y guarda cuanto duro cada etapa.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Helper: sacar el detalle de la venta sin importar como entro
--
-- El payload llega de dos formas distintas:
--   - Por webhook: el detalle viene como TEXTO dentro de payload->'payload'
--   - Rescatada con scripts/4-recuperar-venta.ps1: viene en la raiz
-- Esta funcion devuelve el detalle en ambos casos.
-- ---------------------------------------------------------------------
create or replace function public.detalle_venta(p jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  d jsonb;
begin
  begin
    d := (p ->> 'payload')::jsonb;
  exception when others then
    d := null;
  end;

  if d is null or d -> 'products' is null then
    d := p;
  end if;

  return d;
end;
$$;

-- ---------------------------------------------------------------------
-- carros — un carro por venta
-- ---------------------------------------------------------------------
create table if not exists public.carros (
  id            bigint generated always as identity primary key,
  venta_id      bigint not null references public.ventas(id) on delete cascade,
  purchase_uuid text   not null unique,

  -- Donde va el carro ahora mismo.
  estado        text   not null default 'prelavado',

  -- Linea de secado (1 a 6). Null mientras no se le asigne.
  linea         smallint,

  -- Bandera del express: la linea 1 es exclusiva para ellos.
  es_express    boolean not null default false,

  -- Del catalogo de Zettle. La variante distingue carro normal de grande.
  producto      text,
  variante      text,
  monto         numeric(10,2),

  creado_en     timestamptz not null default now(),
  entregado_en  timestamptz,

  constraint carros_estado_valido
    check (estado in ('prelavado','tunel','por_asignar','secando','entregado')),
  constraint carros_linea_valida
    check (linea is null or linea between 1 and 6)
);

-- La regla "linea 1 solo express" se aplica en la app, NO aqui a proposito.
-- Si una noche la linea 1 es la unica libre y hay que meter un carro normal,
-- el supervisor no se puede quedar trabado por una regla de la base de datos.
-- El CLAUDE.md pide que siempre exista un respaldo manual.

create index if not exists carros_estado_idx    on public.carros (estado);
create index if not exists carros_creado_en_idx on public.carros (creado_en desc);

-- ---------------------------------------------------------------------
-- etapas — cuanto duro cada tramo del proceso
-- Este es EL dato que al final mide la eficiencia.
-- ---------------------------------------------------------------------
create table if not exists public.etapas (
  id       bigint generated always as identity primary key,
  carro_id bigint not null references public.carros(id) on delete cascade,
  etapa    text   not null,
  inicio   timestamptz not null default now(),
  fin      timestamptz,

  -- Se calcula sola al cerrar la etapa. Nadie la puede capturar mal.
  segundos integer generated always as (
    case when fin is null then null
         else extract(epoch from (fin - inicio))::int end
  ) stored,

  constraint etapas_etapa_valida
    check (etapa in ('prelavado','tunel','por_asignar','secando'))
);

create index if not exists etapas_carro_idx on public.etapas (carro_id);

-- ---------------------------------------------------------------------
-- asignaciones — quien seco que carro
-- Un carro puede tener hasta 4 secadores, por eso es una fila por persona.
-- ---------------------------------------------------------------------
create table if not exists public.asignaciones (
  id       bigint generated always as identity primary key,
  carro_id bigint not null references public.carros(id) on delete cascade,
  linea    smallint not null,
  secador  text     not null,
  inicio   timestamptz not null default now(),
  fin      timestamptz
);

create index if not exists asignaciones_carro_idx on public.asignaciones (carro_id);

-- ---------------------------------------------------------------------
-- El disparador: cada venta nueva se vuelve un carro, sola
--
-- Vive en la base y no en la Edge Function para que las ventas rescatadas
-- a mano tambien creen su carro, sin duplicar la logica en dos lados.
-- ---------------------------------------------------------------------
create or replace function public.crear_carro_desde_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  producto  jsonb;
  nuevo_id  bigint;
  arranque  timestamptz;
begin
  producto := detalle_venta(new.payload) -> 'products' -> 0;
  arranque := coalesce(new.recibido_en, new.creado_en, now());

  insert into public.carros
    (venta_id, purchase_uuid, monto, producto, variante, es_express, creado_en)
  values (
    new.id,
    new.purchase_uuid,
    new.monto,
    producto ->> 'name',
    producto ->> 'variantName',
    coalesce(producto ->> 'name', '') ilike 'express%',
    arranque
  )
  on conflict (purchase_uuid) do nothing
  returning id into nuevo_id;

  -- El carro nace en prelavado, y el cronometro arranca desde que se pago.
  if nuevo_id is not null then
    insert into public.etapas (carro_id, etapa, inicio)
    values (nuevo_id, 'prelavado', arranque);
  end if;

  return new;
end;
$$;

drop trigger if exists ventas_crear_carro on public.ventas;
create trigger ventas_crear_carro
  after insert on public.ventas
  for each row execute function public.crear_carro_desde_venta();

-- ---------------------------------------------------------------------
-- Rellenar los carros de las ventas que ya existian
-- ---------------------------------------------------------------------
insert into public.carros
  (venta_id, purchase_uuid, monto, producto, variante, es_express, creado_en)
select
  v.id,
  v.purchase_uuid,
  v.monto,
  detalle_venta(v.payload) -> 'products' -> 0 ->> 'name',
  detalle_venta(v.payload) -> 'products' -> 0 ->> 'variantName',
  coalesce(detalle_venta(v.payload) -> 'products' -> 0 ->> 'name', '') ilike 'express%',
  coalesce(v.recibido_en, v.creado_en)
from public.ventas v
on conflict (purchase_uuid) do nothing;

insert into public.etapas (carro_id, etapa, inicio)
select c.id, 'prelavado', c.creado_en
from public.carros c
where not exists (
  select 1 from public.etapas e where e.carro_id = c.id and e.etapa = 'prelavado'
);

-- ---------------------------------------------------------------------
-- Candado: nadie entra desde fuera. La app pasa por la Edge Function,
-- que es la unica que tiene la llave secreta.
-- ---------------------------------------------------------------------
alter table public.carros       enable row level security;
alter table public.etapas       enable row level security;
alter table public.asignaciones enable row level security;

comment on table public.carros       is 'Un carro por venta. Lo que ve el supervisor en la cola.';
comment on table public.etapas       is 'Duracion de cada tramo del proceso. Base de la analitica.';
comment on table public.asignaciones is 'Que secadores atendieron cada carro, y en que linea.';
