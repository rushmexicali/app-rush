-- =====================================================================
-- RUSH Car Wash — Fase 2: mover el carro de etapa, y deshacer
--
-- Van como funciones de la base y no como varios pasos desde la app
-- para que sean ATOMICAS: cerrar una etapa, cambiar el estado y abrir la
-- siguiente ocurren juntas o no ocurren. Si el wifi del taller se cae a
-- media pulsacion, ningun carro queda a medias.
--
-- El CLAUDE.md exige que "Corregir" siempre este a la mano: el
-- supervisor va a tocar la etapa equivocada y no debe buscar como
-- deshacerlo.
-- =====================================================================

-- Orden del proceso. Vive en un solo lugar para no repetirlo.
create or replace function public.orden_etapas()
returns text[]
language sql
immutable
as $$
  select array['prelavado','tunel','por_asignar','secando','entregado'];
$$;

-- ---------------------------------------------------------------------
-- Avanzar a la siguiente etapa (el boton grande de la tarjeta)
-- ---------------------------------------------------------------------
create or replace function public.avanzar_etapa(p_carro bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  orden     text[] := orden_etapas();
  actual    text;
  siguiente text;
  i         int;
begin
  -- for update: si el supervisor pica dos veces rapido, la segunda
  -- espera a que termine la primera en vez de saltarse una etapa.
  select estado into actual from carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  i := array_position(orden, actual);
  if i is null or i >= array_length(orden, 1) then
    return jsonb_build_object('ok', false, 'error', 'El carro ya fue entregado');
  end if;

  siguiente := orden[i + 1];

  update etapas set fin = now()
   where carro_id = p_carro and fin is null;

  update carros
     set estado = siguiente,
         entregado_en = case when siguiente = 'entregado' then now() else entregado_en end
   where id = p_carro;

  -- "entregado" es el final: no se le abre cronometro.
  if siguiente <> 'entregado' then
    insert into etapas (carro_id, etapa, inicio) values (p_carro, siguiente, now());
  end if;

  return jsonb_build_object('ok', true, 'estado', siguiente);
end;
$$;

-- ---------------------------------------------------------------------
-- Corregir: regresar una etapa
--
-- Se BORRA la etapa abierta por error en vez de cerrarla, porque no
-- ocurrio de verdad. Dejarla guardada ensuciaria la analitica con
-- tramos de dos segundos que nadie trabajo.
-- ---------------------------------------------------------------------
create or replace function public.regresar_etapa(p_carro bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  orden    text[] := orden_etapas();
  actual   text;
  anterior text;
  i        int;
begin
  select estado into actual from carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  i := array_position(orden, actual);
  if i is null or i <= 1 then
    return jsonb_build_object('ok', false, 'error', 'El carro apenas va empezando');
  end if;

  anterior := orden[i - 1];

  delete from etapas where carro_id = p_carro and fin is null;

  -- Se reabre la etapa anterior para que el cronometro siga contando
  -- desde donde iba, no desde cero.
  update etapas set fin = null
   where id = (
     select id from etapas
      where carro_id = p_carro and etapa = anterior
      order by inicio desc limit 1
   );

  update carros
     set estado = anterior,
         entregado_en = null,
         -- Si regresa a "falta asignar", la linea deja de aplicar.
         linea = case when anterior = 'por_asignar' then null else linea end
   where id = p_carro;

  if anterior = 'por_asignar' then
    update asignaciones set fin = now()
     where carro_id = p_carro and fin is null;
  end if;

  return jsonb_build_object('ok', true, 'estado', anterior);
end;
$$;
