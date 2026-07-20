-- =====================================================================
-- RUSH Car Wash — un Manual con variante Express TAMBIEN es express
--
-- El dueno lo dijo el 19/jul/2026: "los lavados express no incluyen
-- aspirado y son los que van directo a la linea 1... tambien en manual
-- hay version express".
--
-- Son DOS consecuencias, y yo solo habia aplicado una:
--
--   1) No lleva aspirado        <- si estaba (migracion 021)
--   2) Va a la linea 1          <- NO estaba
--
-- es_express se calculaba solo del nombre del producto:
--
--     coalesce(producto ->> 'name','') ilike 'express%'
--
-- Asi que un "Manual / Express" entraba con es_express = false. Eso
-- significa que:
--   - no le salia la banderita de express en la cola, y
--   - si el supervisor le daba la linea 1, la base se lo RECHAZABA
--     ("La linea 1 es solo para express", ver 014_asignar_con_empleados).
--
-- Nunca trono porque hasta hoy no ha entrado ninguno (el unico Manual
-- registrado fue variante "Completo Grande"). Era un bug esperando.
--
-- Arreglo de fondo: "no lleva aspirado" y "va a la linea 1" son EL MISMO
-- conjunto de lavados. Por lo tanto salen de UNA sola funcion. Tenerlas
-- como dos reglas paralelas es justo como se desfasan con el tiempo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Que es un lavado express
--
-- La unica fuente de la verdad. De aqui salen las dos consecuencias.
-- ---------------------------------------------------------------------
create or replace function public.es_lavado_express(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select coalesce(p_producto, '') ilike 'express%'
      or (coalesce(p_producto, '') ilike 'manual%'
          and coalesce(p_variante, '') ilike 'express%');
$$;

comment on function public.es_lavado_express(text, text) is
  'Lavado express: producto Express, o Manual con variante Express. Va a linea 1 y no lleva aspirado.';

-- ---------------------------------------------------------------------
-- El aspirado ahora se define en terminos del express
--
-- Antes repetia la regla del Manual. Ahora dice lo que el dueno dijo:
-- todos los paquetes llevan aspirado MENOS los express.
--
-- Un producto que no reconozcamos sigue devolviendo NULL: se cuenta como
-- "sin clasificar" en el reporte en vez de adivinar de que lado va.
-- ---------------------------------------------------------------------
create or replace function public.lleva_aspirado(p_producto text, p_variante text)
returns boolean
language sql
immutable
as $$
  select case
    when coalesce(p_producto, '') ilike any (array[
           'express%', 'completo%', 'solo interior%', 'gratis%', 'manual%'
         ])
      then not public.es_lavado_express(p_producto, p_variante)
    else null
  end;
$$;

-- ---------------------------------------------------------------------
-- El disparador usa la misma funcion
--
-- Unico cambio respecto a la 020.
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
  nota      text;
  gratis    boolean;
  leido     jsonb;
begin
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
-- Corregir los que ya estan
--
-- Solo los que TODAVIA NO tienen linea. Un carro ya asignado no se toca:
-- cambiarle es_express con la linea puesta lo dejaria en un estado que la
-- validacion de asignar_carro considera imposible (express fuera de la
-- linea 1), y "Corregir" empezaria a fallar.
--
-- Hoy esto no mueve ninguna fila — no ha entrado ningun Manual express.
-- Se deja porque la migracion se puede correr despues de que si entre uno.
-- ---------------------------------------------------------------------
update public.carros c
   set es_express = es_lavado_express(c.producto, c.variante)
 where c.linea is null
   and c.es_express is distinct from es_lavado_express(c.producto, c.variante);
