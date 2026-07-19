-- =====================================================================
-- RUSH Car Wash — Fase 1: tabla que recibe las ventas de Zettle
-- Correr una sola vez en: panel de Supabase > SQL Editor > New query
-- =====================================================================

create table if not exists public.ventas (
  -- Numero consecutivo que Postgres asigna solo: 1, 2, 3...
  id             bigint generated always as identity primary key,

  -- El identificador que Zettle le da a la venta.
  -- "unique" = si Zettle manda el mismo evento dos veces (pasa: reintenta
  -- cuando no recibe respuesta a tiempo), la segunda no crea fila duplicada.
  purchase_uuid  text not null unique,

  -- Total cobrado en pesos. Zettle lo manda en centavos; la Edge Function
  -- lo divide entre 100 antes de guardarlo aqui.
  monto          numeric(10,2),

  -- Cuando la venta ocurrio segun Zettle.
  recibido_en    timestamptz,

  -- El evento completo tal como llego, sin tocar. Es la red de seguridad:
  -- si mañana necesitamos un dato que hoy no estamos leyendo (propina,
  -- producto, cajero), aqui va a estar. Guardar de mas cuesta casi nada.
  payload        jsonb,

  -- Cuando nuestra base lo guardo. Comparado contra recibido_en nos dice
  -- cuanto tardo el webhook en llegar.
  creado_en      timestamptz not null default now()
);

-- La app siempre va a pedir "las ventas de hoy, la mas nueva primero".
-- Este indice hace esa consulta rapida aunque la tabla crezca a miles de filas.
create index if not exists ventas_creado_en_idx
  on public.ventas (creado_en desc);

-- Candado encendido: nadie puede leer ni escribir esta tabla desde fuera.
-- La Edge Function si puede, porque usa la llave secreta, que se salta el candado.
-- Cuando llegue la app Flutter (Fase 2) abriremos permisos de lectura a proposito.
alter table public.ventas enable row level security;

-- Notas para quien abra esta tabla en el futuro desde el panel.
comment on table  public.ventas               is 'Ventas recibidas por webhook de Zettle. Cada fila = un carro que entra a la cola.';
comment on column public.ventas.purchase_uuid is 'UUID de la venta en Zettle. Unico: evita duplicados por reintentos.';
comment on column public.ventas.payload       is 'Evento PurchaseCreated completo, sin procesar.';
