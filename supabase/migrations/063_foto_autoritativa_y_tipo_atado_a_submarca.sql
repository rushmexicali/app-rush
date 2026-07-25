-- =====================================================================
-- RUSH Car Wash — la foto nueva manda, y el tipo solo se corrige si se
-- reconocio el modelo (arregla dos huecos del review del 24/jul/2026)
--
-- HUECO #3 — el coalesce "nunca borra" empeoraba el bug recurrente de la
-- foto pegada al carro equivocado (CLAUDE.md §12.1: carros 69/71, 269/272).
-- Con coalesce, si el supervisor re-tomaba la foto del carro CORRECTO pero
-- la placa salia ilegible, la placa del carro AJENO se quedaba pegada.
-- Ademas marca/submarca no se editan en la app, asi que no habia ninguna
-- via de correccion.
--   Arreglo: la foto es AUTORITATIVA. Cada subida re-identifica ESE carro y
--   sobrescribe placa/marca/submarca (incluso a null). Asi, re-tomar una foto
--   buena limpia el dato ajeno — esa re-toma es la via de correccion. Es
--   ademas el comportamiento que /foto tenia ANTES de la 061 (la placa se
--   sobrescribia siempre); el coalesce fue la desviacion. La "aceptacion
--   parcial" que pidio el dueño era: dentro de UNA lectura, los campos son
--   independientes (leer placa y no marca guarda la placa). Sobrescribir la
--   respeta: cada campo toma su propio valor de esta lectura.
--
-- HUECO #4 — el tipo de la foto pisaba al de la cajera SIEMPRE, aunque la IA
-- no hubiera reconocido el modelo. La premisa del dueño era "cuando SE el
-- modelo, corrijo" (un Corolla es auto); pero el codigo corregia con puro
-- ojo, y el tipo fallo 9 de 57 en la prueba (un Wrangler salio "pickup").
--   Arreglo: el tipo solo pisa a la cajera cuando la MISMA lectura trajo
--   submarca (reconocio el modelo). Sin submarca, el tipo es puro ojo: solo
--   rellena si la cajera no puso nada, nunca la pisa.
--
-- Sigue sin tocar datos_de_nota (mide si la cajera lleno la nota; nada de
-- esto habla de eso). Misma firma que la 061.
-- =====================================================================

create or replace function public.guardar_datos_de_foto(
  p_carro    bigint,
  p_placa    text default null,
  p_org      text default null,
  p_marca    text default null,
  p_submarca text default null,
  p_tipo     text default null
)
returns jsonb
language plpgsql
as $$
declare
  nueva_submarca text;
  tipo_limpio    text;
begin
  nueva_submarca := nullif(btrim(upper(coalesce(p_submarca, ''))), '');

  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;  -- un tipo raro de la IA se ignora
  end if;

  update public.carros set
    -- La foto es autoritativa: sobrescribe (incluso a null). placa_en
    -- siempre, para conservar "se intento y no se pudo" (§9).
    placa              = nullif(btrim(coalesce(p_placa, '')), ''),
    placa_organizacion = nullif(btrim(coalesce(p_org, '')), ''),
    placa_en           = now(),
    marca              = nullif(btrim(upper(coalesce(p_marca, ''))), ''),
    submarca           = nueva_submarca,
    -- El tipo es el UNICO campo con una segunda fuente (la nota de la
    -- cajera). Solo se corrige cuando la foto reconocio el modelo
    -- (nueva_submarca no nula); si no, se respeta a la cajera y solo se
    -- rellena si venia vacio.
    tipo_unidad        = case
                           when nueva_submarca is not null
                             then coalesce(tipo_limpio, tipo_unidad)
                           else coalesce(tipo_unidad, tipo_limpio)
                         end
  where id = p_carro;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.guardar_datos_de_foto(bigint, text, text, text, text, text) is
  'Guarda la lectura de la foto. La foto es autoritativa: sobrescribe placa/marca/submarca (recupera el caso foto-mal-pegada). El tipo solo corrige a la cajera si hubo submarca. placa_en siempre. No toca datos_de_nota (063).';
