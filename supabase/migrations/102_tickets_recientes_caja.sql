-- =====================================================================
-- 102 — Caja: los últimos tickets de Zettle, en vivo.
--
-- La cajera elige el TICKET antes de registrar la visita. Esta función le da
-- los últimos N tickets **que todavía no se le asignaron a nadie**, con lo
-- que necesita para reconocerlo de un vistazo: número, monto, contenido y
-- hora exacta.
--
-- Decisiones que importan:
--
--  * Sale de `ventas` (lo que Zettle cobró), NO de `carros`. Así la lista es
--    exactamente lo que la cajera acaba de ver en su pantalla de cobro. Un
--    ticket de puro producto (Pinito, tapetes) NO crea carro — ése aparece
--    igual, pero DESHABILITADO y con el motivo, para que nunca haya un
--    ticket "que no está" (pedido del dueño, 15/ago/2026).
--  * Se excluyen los ya asignados (tienen visita activa), las devoluciones y
--    los carros cancelados o de prueba.
--  * `clase` viene de clase_de_gratis(): la pantalla la usa para pintar en
--    rojo cuando la cajera pidió lavado gratis y el ticket no es un 6to.
--    Es la MISMA función que valida el registro — una sola regla.
-- =====================================================================
create or replace function public.tickets_recientes(p_limite integer default 5)
returns jsonb language sql stable as $$
  with base as (
    select v.id,
           (v.payload->>'payload')::jsonb as p,
           v.creado_en,
           c.id            as carro_id,
           c.producto, c.variante, c.monto as carro_monto,
           c.cancelado_en, c.es_prueba, c.placa, c.aviso
    from public.ventas v
    left join public.carros c on c.purchase_uuid = v.purchase_uuid
    -- Una devolución no es un lavado que asignar.
    where not ((v.payload->>'payload')::jsonb ? 'refundsPurchaseUuid')
      -- Ya se lo llevó otro cliente.
      and not exists (select 1 from public.visitas vi
                      where vi.carro_id = c.id and vi.estado = 'activa')
    order by v.creado_en desc
    limit greatest(1, least(coalesce(p_limite, 5), 20))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'venta_id',  b.id,
    'ticket',    b.p->>'purchaseNumber',
    'monto',     round((coalesce((b.p->>'amount')::numeric, 0)) / 100.0, 2),
    'hora',      b.creado_en,
    'carro_id',  case when b.cancelado_en is null and not coalesce(b.es_prueba,false)
                      then b.carro_id else null end,
    'producto',  b.producto,
    'variante',  b.variante,
    'placa',     b.placa,
    'aviso',     nullif(b.aviso, ''),
    'clase',     public.clase_de_gratis(b.producto, b.variante),
    -- El contenido tal cual salió en el ticket: "Completo Grande ×1 · Pinito ×2"
    'contenido', (
      select string_agg(
               btrim(concat_ws(' ', pr->>'name', nullif(pr->>'variantName',''))) ||
               case when coalesce((pr->>'quantity')::numeric, 1) > 1
                    then ' x' || trim(trailing '.' from trim(trailing '0' from (pr->>'quantity')))
                    else '' end,
               ' · ' order by ord)
      from jsonb_array_elements(b.p->'products') with ordinality as t(pr, ord)
    ),
    -- Por qué no se puede elegir. NULL = sí se puede.
    'motivo',    case
                   when b.carro_id is null then 'Este ticket no trae lavado'
                   when b.cancelado_en is not null then 'Lavado cancelado'
                   when coalesce(b.es_prueba,false) then 'Venta de prueba'
                   else null
                 end
  ) order by b.creado_en desc), '[]'::jsonb)
  from base b;
$$;

comment on function public.tickets_recientes(integer) is
  'Caja: ultimos N tickets de Zettle sin asignar, con contenido y hora. Los que no traen lavado salen con motivo y sin carro_id (no seleccionables).';
