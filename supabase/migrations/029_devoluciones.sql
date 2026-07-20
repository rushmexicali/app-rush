-- =====================================================================
-- RUSH Car Wash — una devolucion no es un lavado
--
-- El 19/jul/2026 el carro 72 entro con monto -270. Era la DEVOLUCION de
-- un Completo Cera, y el sistema la trato como un lavado nuevo: el
-- supervisor lo proceso completo y quedo inflando "vehiculos lavados".
--
-- Lo bueno es que Zettle si dice a que venta corresponde:
--
--     "refundsPurchaseUuid": "f2c37559-6d5c-4153-8587-fcac4af91c49"
--
-- Con eso NO hay que adivinar cual carro cancelar. (Se verifico: ese uuid
-- era el carro 70, el Completo Cera de las 01:51.)
--
-- Regla del dueno (19/jul/2026): "un monto negativo siempre es devolucion
-- y deberia de eliminar la unidad de la cola".
-- =====================================================================

-- ---------------------------------------------------------------------
-- Cancelar en vez de borrar
--
-- Borrar la fila se llevaria sus etapas, su foto y su placa. El carro SI
-- existio y si ocupo gente; lo que cambio es que la venta se deshizo. Se
-- marca y se esconde, no se destruye.
-- ---------------------------------------------------------------------
alter table public.carros add column if not exists cancelado_en timestamptz;

comment on column public.carros.cancelado_en is
  'Cuando se cancelo por devolucion. No nulo = fuera de la cola y fuera de los conteos.';

create index if not exists carros_cancelado_idx
  on public.carros (cancelado_en) where cancelado_en is null;

-- ---------------------------------------------------------------------
-- El disparador
--
-- Dos cosas cuando llega una devolucion:
--   1) NO se crea carro.
--   2) Se cancela el original, si sigue en la cola.
--
-- Si el original YA se habia entregado no se toca: ese carro si se lavo y
-- si ocupo gente. Devolverle el dinero al cliente no deshace el trabajo,
-- y borrarlo del historial escondería labor que si ocurrio.
-- ---------------------------------------------------------------------
create or replace function public.crear_carro_desde_venta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  detalle   jsonb;
  producto  jsonb;
  nuevo_id  bigint;
  arranque  timestamptz;
  nota      text;
  gratis    boolean;
  leido     jsonb;
  devuelve  text;
begin
  detalle  := detalle_venta(new.payload);
  devuelve := nullif(btrim(coalesce(detalle ->> 'refundsPurchaseUuid', '')), '');

  -- --- Devolucion -----------------------------------------------------
  if devuelve is not null or coalesce(new.monto, 0) < 0 then
    if devuelve is not null then
      update public.carros
         set cancelado_en = now()
       where purchase_uuid = devuelve
         and estado <> 'entregado'
         and cancelado_en is null;
    end if;
    -- La venta queda guardada en ventas; simplemente no genera vehiculo.
    return new;
  end if;

  producto := producto_del_vehiculo(new.payload);

  if producto is null then
    return new;
  end if;

  arranque := coalesce(new.recibido_en, new.creado_en, now());

  gratis := coalesce(new.monto, 0) = 0 or coalesce(producto ->> 'name', '') ilike 'gratis%';
  nota   := nota_de_la_venta(new.payload, gratis);
  leido  := interpretar_nota(nota, gratis);

  insert into public.carros (
    venta_id, purchase_uuid, monto, producto, variante, es_express, creado_en,
    nota, tipo_unidad, color, cliente, datos_de_nota
  )
  values (
    new.id,
    new.purchase_uuid,
    new.monto,
    producto ->> 'name',
    producto ->> 'variantName',
    es_lavado_express(producto ->> 'name', producto ->> 'variantName'),
    arranque,
    nota,
    leido ->> 'tipo_unidad',
    leido ->> 'color',
    leido ->> 'cliente',
    (leido ->> 'tipo_unidad') is not null
  )
  on conflict (purchase_uuid) do nothing
  returning id into nuevo_id;

  if nuevo_id is not null then
    insert into public.etapas (carro_id, etapa, inicio)
    values (nuevo_id, 'prelavado', arranque);
  end if;

  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- Los cancelados salen de todas las cuentas
-- ---------------------------------------------------------------------
create or replace function public.entregados_del_dia(p_fecha date default null)
returns setof public.carros
language sql
stable
as $$
  select c.*
    from public.carros c
   where c.estado = 'entregado'
     and c.cancelado_en is null
     and c.entregado_en >= (
           (coalesce(p_fecha, (now() at time zone 'America/Tijuana')::date)::text || ' 00:00:00')
           ::timestamp at time zone 'America/Tijuana'
         )
     and c.entregado_en < (
           (coalesce(p_fecha, (now() at time zone 'America/Tijuana')::date)::text || ' 00:00:00')
           ::timestamp at time zone 'America/Tijuana' + interval '1 day'
         )
   order by c.entregado_en desc
   limit 400;
$$;

create or replace view public.historial_placas as
select
  public.normalizar_placa(c.placa)          as placa,
  (array_agg(c.placa order by c.creado_en desc))[1] as placa_como_se_lee,
  count(*)::int                             as visitas,
  min(c.creado_en)                          as primera_visita,
  max(c.creado_en)                          as ultima_visita,
  (array_agg(c.tipo_unidad order by c.creado_en desc) filter (where c.tipo_unidad is not null))[1] as tipo_unidad,
  (array_agg(c.color       order by c.creado_en desc) filter (where c.color       is not null))[1] as color,
  (array_agg(c.marca       order by c.creado_en desc) filter (where c.marca       is not null))[1] as marca,
  (array_agg(c.cliente     order by c.creado_en desc) filter (where c.cliente     is not null))[1] as cliente,
  sum(coalesce(c.monto, 0))                 as gastado
from public.carros c
where c.placa is not null
  and not c.es_prueba
  and c.cancelado_en is null
group by public.normalizar_placa(c.placa);

-- ---------------------------------------------------------------------
-- Limpiar lo de hoy
--
-- El carro 72 fue creado por la devolucion y no era un vehiculo. Se marca
-- cancelado para que salga de los conteos. Su original (el 70) NO se
-- toca: ese si se lavo.
-- ---------------------------------------------------------------------
update public.carros c
   set cancelado_en = now()
  from public.ventas v
 where c.venta_id = v.id
   and c.cancelado_en is null
   and (coalesce(c.monto, 0) < 0
        or nullif(btrim(coalesce(detalle_venta(v.payload) ->> 'refundsPurchaseUuid', '')), '') is not null);
