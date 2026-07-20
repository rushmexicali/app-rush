-- =====================================================================
-- RUSH Car Wash — avisar en la tarjeta que NO es un lavado normal
--
-- Pedido del dueno el 20/jul/2026, y no es una mejora cosmetica:
--
--   "nos pasa mucho que los gerentes y secadores no leen los tickets y
--    asumen que es un lavado, creando quejas de los clientes al no
--    seguir las instrucciones"
--
-- O sea que esto existe para evitar QUEJAS DE CLIENTES, no para adornar
-- la pantalla. Un encerado manual de $900 tratado como un lavado de $260
-- es un cliente molesto y trabajo que hay que rehacer.
--
-- Mismo patron que la banderita del express, que ya funciona: el
-- supervisor no tiene que leer el ticket ni el nombre del producto —
-- la tarjeta grita lo que es.
--
-- ---------------------------------------------------------------------
-- Que se avisa
-- ---------------------------------------------------------------------
--   Paquetes Especial  -> el nombre del producto tal cual:
--                         ENCERADO MANUAL, SUPER BRILLO, DETALLADO
--   Manual (cualquiera)-> LAVADO A MANO
--   Pasajeros + Manual -> LAVADO A MANO (las combis tambien se lavan a mano)
--
-- Se usa el nombre del producto y no una etiqueta inventada: si el dueno
-- da de alta "Encerado Ceramico" en Paquetes Especial, la tarjeta lo dice
-- solo, sin tocar codigo. Es la misma idea que usar su categoria para
-- agrupar el reporte.
--
-- ---------------------------------------------------------------------
-- Por que es INDEPENDIENTE del express
-- ---------------------------------------------------------------------
-- Son dos preguntas distintas y un carro puede necesitar las dos:
--
--   es_express  -> a que LINEA va (la 1 es solo de express)
--   este aviso  -> que TRABAJO hay que hacerle
--
-- Un "Manual / Express Grande" ($400) es las dos cosas: va a la linea 1
-- Y es a mano. Si el aviso se hubiera metido dentro de es_express, uno
-- de los dos datos se perderia. Por eso son funciones separadas y la
-- tarjeta puede mostrar las dos banderitas.
-- =====================================================================

create or replace function public.aviso_de_servicio(
  p_producto text, p_variante text, p_categoria text
)
returns text
language sql
immutable
as $$
  select case
    when nullif(btrim(coalesce(p_producto, '')), '') is null then null

    -- La taxonomia del dueno manda: lo que el puso en "Paquetes
    -- Especial" lleva instrucciones. Se muestra su propio nombre.
    when btrim(coalesce(p_categoria, '')) = 'Paquetes Especial'
      then upper(btrim(p_producto))

    -- Respaldo por nombre, para carros viejos sin categoria guardada.
    when lower(btrim(p_producto)) like 'encerado%'
      or translate(lower(btrim(p_producto)), 'áéíóúü', 'aeiouu') like '%brillo%'
      or lower(btrim(p_producto)) like 'detallado%'
      then upper(btrim(p_producto))

    -- Lavado a mano. Aplica aunque ademas sea express: son dos cosas
    -- distintas y las dos importan.
    when lower(btrim(p_producto)) like 'manual%'
      then 'LAVADO A MANO'

    -- Las combis tambien tienen version a mano.
    when lower(btrim(p_producto)) like 'pasajeros%'
     and lower(btrim(coalesce(p_variante, ''))) like 'manual%'
      then 'LAVADO A MANO'

    else null
  end;
$$;

comment on function public.aviso_de_servicio(text, text, text) is
  'Texto de la banderita cuando el servicio NO es un lavado normal. NULL = lavado normal. Existe para evitar quejas por no leer el ticket.';
