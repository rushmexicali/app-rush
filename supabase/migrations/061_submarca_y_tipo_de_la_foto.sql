-- =====================================================================
-- RUSH Car Wash — marca, submarca y tipo salen de la FOTO, no del super
--
-- Decidido el 24/jul/2026. Una prueba sobre 59 fotos reales de archivo
-- mostro que la misma foto que ya se usa para leer la placa permite sacar
-- marca y modelo (submarca) con ~98% de precision cuando la IA se
-- compromete, y hasta cacha errores de captura del supervisor
-- (BYD->Buick, Lexus->Kia K5, SEAT->Suzuki). El costo marginal es casi
-- cero: la foto ya se le manda a Sonnet 5, solo se le piden mas campos en
-- la MISMA llamada.
--
-- El dueño decidio quitarle al supervisor la captura de marca por
-- completo. La marca, la submarca y el tipo de carroceria pasan a venir de
-- la foto. Reglas del dueño:
--   * Se acepta cualquier confianza (alta/media/baja). Solo null no se
--     guarda.
--   * Aceptacion parcial POR CAMPO: si se lee la placa pero no la marca,
--     se guarda la placa; un campo null nunca tumba a los demas.
--   * Si se lee la submarca pero no la marca, la IA deduce la marca (un
--     Corolla es Toyota). Eso vive en el prompt de la Edge Function.
--   * Cuando la foto trae tipo, corrige al de la cajera (una cajera que
--     puso "camioneta" a un Corolla queda "automovil"). Cuando la foto no
--     trae tipo, se queda el de la cajera.
--
-- Esta migracion agrega la columna submarca y una sola RPC que guarda todo
-- lo que la foto pudo leer, con coalesce POR CAMPO para cumplir la
-- aceptacion parcial: un null nunca borra lo que ya habia.
-- =====================================================================

alter table public.carros
  add column if not exists submarca text;

comment on column public.carros.submarca is
  'Modelo del auto leido de la foto (Corolla, Civic, L200). Solo de la foto; el supervisor ya no captura datos del vehiculo (061).';

-- ---------------------------------------------------------------------
-- guardar_datos_de_foto: escribe lo que la lectura de la foto pudo sacar.
--
-- coalesce(nuevo, viejo) por campo => un null NUNCA borra lo ya guardado.
-- Esto es la "aceptacion parcial": la placa puede leerse y la marca no, y
-- cada quien se guarda por su cuenta. Distinto del UPDATE viejo de /foto,
-- que escribia placa aunque viniera null y borraba una lectura buena
-- anterior.
--
-- placa_en SIEMPRE se pone: registra que hubo intento. Asi se conserva el
-- distintivo del CLAUDE.md §9 — placa_en con fecha + placa vacia = "se
-- intento y no se pudo", que es dato (fotos ilegibles), no error.
--
-- NO toca datos_de_nota: esa bandera mide si la cajera lleno la nota. Que
-- la foto corrija el tipo no dice nada sobre la nota; mezclarlo arruinaria
-- esa metrica (mismo cuidado que la 051).
-- ---------------------------------------------------------------------
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
  tipo_limpio text;
begin
  -- Un tipo raro de la IA se ignora (queda null y no pisa al de la cajera);
  -- nunca tumba el resto del guardado.
  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;
  end if;

  update public.carros set
    placa              = coalesce(nullif(btrim(coalesce(p_placa, '')), ''), placa),
    placa_organizacion = coalesce(nullif(btrim(coalesce(p_org, '')), ''), placa_organizacion),
    placa_en           = now(),
    marca              = coalesce(nullif(btrim(upper(coalesce(p_marca, ''))), ''), marca),
    submarca           = coalesce(nullif(btrim(upper(coalesce(p_submarca, ''))), ''), submarca),
    tipo_unidad        = coalesce(tipo_limpio, tipo_unidad)
  where id = p_carro;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

comment on function public.guardar_datos_de_foto(bigint, text, text, text, text, text) is
  'Guarda lo que la foto pudo leer (placa/org/marca/submarca/tipo) con coalesce por campo: un null nunca borra lo ya guardado. placa_en siempre. No toca datos_de_nota (061).';
