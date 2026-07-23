-- =====================================================================
-- 057 — Se borra lo que ya no usa nadie
--
-- Cada cosa de aqui se reviso una por una contra el codigo VIVO: las tres
-- Edge Functions, el docs/index.html y todas las funciones de la base.
-- Nada de esto tiene un solo llamador.
--
--   orden_etapas()          Solo la usaba la migracion 006, cuyas
--                           funciones reemplazo la 024 hace tres dias.
--   vista etapas_medibles   Se creo en la 008 y NUNCA se consulto. El
--                           reporte lee 'etapas' directo.
--   empleados.iniciales     Columna MUERTA y ademas EQUIVOCADA: la vista
--                           'secadores' la ignora y recalcula
--                           iniciales_de() sobre otro nombre. Medido: 3
--                           de 19 no coincidian (Walter tenia guardado
--                           'WA' y en pantalla salia 'WR'). La app
--                           siempre leyo la vista, nunca la columna.
--   carros_cancelado_idx    Indice DEGENERADO: indexaba cancelado_en
--                           filtrando where cancelado_en is null, o sea
--                           que sus 318 entradas tenian todas la misma
--                           clave (null). No ordenaba nada.
--
-- Y se pone en su lugar el indice que la cola SI necesita.
--
-- QUE NO SE BORRA, y por que:
--   etapa_efectiva()  la usa avanzar_etapa(). Traduce 'tunel' y
--                     'por_asignar', estados que ya no se generan, pero
--                     si quedara uno vivo, quitarla dejaria pasar un
--                     carro sin validar. No se gana nada y se puede
--                     romper algo.
--   sin_acentos()     ahora la usan es_servicio_especial() (055) y
--                     nombre_corto_de() (056).
-- =====================================================================

-- --- Antes de tocar la columna: quitarla de quien la escribe ---------
-- agregar_secador_manual la insertaba. Si se borra la columna primero,
-- esta funcion truena la proxima vez que el supervisor use el boton
-- "No aparece el empleado".
create or replace function public.agregar_secador_manual(p_nombre text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  limpio text;
  nuevo  text;
begin
  limpio := btrim(coalesce(p_nombre, ''));
  if length(limpio) < 2 then
    return jsonb_build_object('ok', false, 'error', 'Escribe el nombre');
  end if;

  nuevo := 'manual-' || replace(gen_random_uuid()::text, '-', '');

  insert into public.empleados
    (id, nombre, nombre_corto, nombre_display, estado, desde,
     manual, permanente, rol, actualizado_en)
  values
    (nuevo, limpio, nombre_corto_de(limpio), limpio,
     'activo', now(), true, false, 'secador', now());

  -- El color lo reparte esta, que es el unico sistema desde la 056.
  perform public.asignar_colores_libres();

  return jsonb_build_object('ok', true, 'id', nuevo, 'nombre', limpio);
end;
$$;

-- --- Las iniciales: una sola pasada, y sin comerse el apellido -------
-- Tenia dos problemas chicos:
--   1. Llamaba a nombre_corto_de() DOS veces y partia el texto DOS veces
--      para sacar dos letras.
--   2. Con el apellido corregido en la 056, "Saul de Anda" daba 'SD'
--      (Saul + de). Las preposiciones no son inicial de nada.
create or replace function public.iniciales_de(p_nombre text)
returns text language plpgsql immutable as $$
declare
  partes text[];
  ligas  text[] := array['de','del','la','las','los','y','san','santa','da','di','von','van'];
  letras text := '';
  w      text;
begin
  partes := regexp_split_to_array(public.nombre_corto_de(p_nombre), '\s+');

  foreach w in array coalesce(partes, array[]::text[]) loop
    continue when btrim(w) = '';
    -- Las preposiciones no dan inicial: "Saul de Anda" es SA, no SD.
    continue when lower(public.sin_acentos(w)) = any (
      select lower(x) from unnest(ligas) x
    );
    letras := letras || substr(w, 1, 1);
    exit when length(letras) >= 2;
  end loop;

  return upper(letras);
end;
$$;

-- --- Fuera lo muerto -------------------------------------------------
drop view     if exists public.etapas_medibles;
drop function if exists public.orden_etapas();

-- La app SIEMPRE leyo esto de la vista 'secadores', que lo recalcula.
-- La columna no la consulta nadie, y ademas no coincidia con lo que se
-- muestra. Es recuperable en cualquier momento con iniciales_de(nombre).
alter table public.empleados drop column if exists iniciales;

-- --- Indices ---------------------------------------------------------
-- Este no ordenaba nada: todas sus entradas tenian la clave null.
drop index if exists public.carros_cancelado_idx;

-- El que la cola SI necesita. /cola corre cada 3 segundos y pide
-- exactamente esto: los no entregados, no cancelados, por hora de
-- entrada. Hoy son 300 filas y da igual; a 90 carros por dia son 33,000
-- al ano y ahi ya no da igual.
create index if not exists carros_cola_idx
  on public.carros (creado_en)
  where estado <> 'entregado' and cancelado_en is null;

comment on index public.carros_cola_idx is
  'Para /cola, que corre cada 3 segundos. El predicado es identico al de '
  'la consulta (estado <> entregado y cancelado_en is null) para que '
  'Postgres pueda usar el indice parcial.';

-- --- Dejar las iniciales guardadas al dia (por si alguien las mira) --
-- (la columna ya no existe; esto solo refresca nombre_corto)
update public.empleados
   set nombre_corto = public.nombre_corto_de(nombre)
 where nombre_corto is distinct from public.nombre_corto_de(nombre);
