-- Plantilla: preparar-import.sh sustituye @DESDE@ y @HASTA@ y la manda por tandas.
-- Devuelve un solo campo `blob` con lineas "ticket<TAB>centavos<TAB>fecha<TAB>gz".
--
-- 🔑 SON DOS FUENTES Y HACEN FALTA LAS DOS. `zettle_compras` es el archivo
-- historico (ticket 1 en adelante) y `ventas` lo que entro por webhook (desde
-- el 19/jul/2026). Un export de un ano no cabe en ninguna de las dos sola.
--
-- ⚠️ `zettle_compras.monto` viene en PESOS y `ventas.amount` en CENTAVOS.
-- ⚠️ Las llaves del payload tambien difieren: `productos[].nombre` (espanol) en
--    zettle_compras y `products[].name` en el aviso crudo de Zettle.
-- ⚠️ `detalle_venta(payload)` y nunca `payload->>'purchaseNumber'` a secas:
--    Zettle manda el aviso envuelto unas veces y plano otras.
with zc as (
  select purchase_number::bigint n,
         round(monto*100)::bigint cent,
         (hora at time zone 'America/Tijuana')::date f,
         (exists (select 1 from jsonb_array_elements(coalesce(payload->'productos','[]'::jsonb)) p
                  where p->>'nombre' ~* 'gratis'))::int gz
  from public.zettle_compras
),
vt as (
  select (public.detalle_venta(payload)->>'purchaseNumber')::bigint n,
         (public.detalle_venta(payload)->>'amount')::bigint cent,
         (creado_en at time zone 'America/Tijuana')::date f,
         (exists (select 1 from jsonb_array_elements(coalesce(public.detalle_venta(payload)->'products','[]'::jsonb)) p
                  where p->>'name' ~* 'gratis'))::int gz
  from public.ventas
  where public.detalle_venta(payload)->>'purchaseNumber' ~ '^[0-9]+@FIN@'
),
u as (
  select * from zc
  union all
  select * from vt where n not in (select n from zc)
),
d as (select distinct on (n) n, cent, f, gz from u order by n, f)
select string_agg(n || E'\t' || cent || E'\t' || to_char(f,'YYYY-MM-DD') || E'\t' || gz, E'\n' order by n) blob
from d where n > @DESDE@ and n <= @HASTA@;
