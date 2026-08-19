-- =====================================================================
-- 108 — El webhook deja de descartar en silencio
--
-- Hallazgo K11 de la auditoria del 19/ago. Hay TRES caminos donde el webhook
-- responde 200 y no guarda nada: cuerpo ilegible, JSON invalido, y aviso sin
-- `purchaseUUID`. Responder 200 es CORRECTO (reintentar un aviso roto da el
-- mismo aviso roto, y esta bien argumentado en el propio archivo); el problema
-- es que el unico rastro es un `console.error` en logs que duran ~1 dia y que
-- nadie mira.
--
-- Escenario concreto: Zettle cambia el nombre de un campo en una version de su
-- API. Cada venta cae en el tercer camino, se responde 200, Zettle queda
-- contento, y la cola del supervisor amanece vacia sin una sola alerta.
--
-- Y de paso sirve para lo otro que falta: aprender COMO firma Zettle sus
-- avisos. La llave `ZETTLE_SIGNING_KEY` se guardo desde el dia uno "para
-- verificar firmas mas adelante" y ninguna funcion la lee. No hay
-- documentacion publica confiable del esquema, y ADIVINARLO en el camino por
-- donde entra el dinero es la peor opcion: una firma mal calculada rechaza
-- ventas reales. Se aprende del trafico real y despues se verifica.
-- =====================================================================

create table if not exists public.webhook_bitacora (
  id          bigint generated always as identity primary key,
  recibido_en timestamptz not null default now(),
  motivo      text        not null,
  evento      text,
  cabeceras   jsonb,
  crudo       text
);

comment on table public.webhook_bitacora is
  'Lo que el webhook de Zettle descarto, y las cabeceras de los avisos buenos mientras se aprende el esquema de firma. NO es el registro de ventas: eso vive en `ventas`.';

create index if not exists webhook_bitacora_recibido_idx
  on public.webhook_bitacora (recibido_en desc);

-- No la puede leer nadie con la llave publica: trae el cuerpo crudo de avisos
-- de venta. Las Edge Functions usan `service_role`, que no pasa por RLS.
alter table public.webhook_bitacora enable row level security;

-- --------------------------------------------------------------------
-- Cuantos avisos se descartaron, para poder mostrarlo donde se vea.
-- --------------------------------------------------------------------
create or replace function public.webhook_descartados_del_rango(p_desde date, p_hasta date)
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'cuantos', count(*) filter (where motivo <> 'ok'),
    'por_motivo', coalesce((
      select jsonb_object_agg(m, n)
        from (select motivo m, count(*)::int n
                from public.webhook_bitacora
               where motivo <> 'ok'
                 and (recibido_en at time zone 'America/Tijuana')::date between p_desde and p_hasta
               group by 1) x), '{}'::jsonb)
  )
  from public.webhook_bitacora
  where (recibido_en at time zone 'America/Tijuana')::date between p_desde and p_hasta;
$$;
