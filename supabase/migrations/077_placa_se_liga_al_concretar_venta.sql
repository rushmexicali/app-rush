-- =====================================================================
-- RUSH — La placa se liga al cliente al CONCRETAR la venta, no antes
-- 27/jul/2026
--
-- Bug reportado por el dueno: al registrar una visita, la placa quedaba
-- ligada al cliente de inmediato (persona_placas), ANTES de que hubiera
-- una venta real. Si la cajera se equivocaba de cliente y luego ponia
-- "No hubo venta", la placa se quedaba pegada a ese cliente para siempre,
-- sin forma de quitarla.
--
-- Regla nueva (pedida por el dueno): el enlace placa->cliente se vuelve
-- DURABLE solo cuando la visita se ata a un carro/venta real (de Zettle).
-- Si no hubo venta (descartar) o se corrige (desenlazar), la placa se
-- suelta — salvo que otra venta real del mismo cliente ya la use.
--
-- Cambios:
--   1. registrar_visita: YA NO inserta persona_placas (solo crea la visita;
--      la placa se guarda en visitas.placa como estaba).
--   2. enlazar_visita_a_carro: inserta persona_placas al concretar la venta.
--   3. descartar_visita / desenlazar_visita: quitan el enlace, con guardia
--      "salvo que otra visita activa y enlazada de la persona use esa placa".
--
-- persona_placas solo lo escribia registrar_visita (verificado: importar_
-- personas no siembra placas), asi que no hay enlaces sin visita que borrar
-- por accidente.
--
-- NOTA: no toca los enlaces YA existentes creados con la regla vieja (p.ej.
-- una placa de una visita que se descarto). Esos se limpian aparte si el
-- dueno lo pide (borrar datos = pide su OK).
-- =====================================================================

-- --- 1. registrar_visita: crea la visita, SIN ligar la placa -----------
create or replace function public.registrar_visita(
  p_persona   bigint,
  p_placa     text    default null,
  p_marca     text    default null,
  p_submarca  text    default null,
  p_tipo      text    default null,
  p_color     text    default null,
  p_foto_path text    default null,
  p_es_gratis boolean default false,
  p_caja      text    default 'principal'
) returns jsonb language plpgsql as $$
declare
  v_id     bigint;
  v_gratis boolean := coalesce(p_es_gratis, false);
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
  end if;

  -- Un gratis solo cuenta si tiene lavados gratis disponibles.
  if v_gratis and not exists (
       select 1 from public.lealtad_por_persona where persona_id = p_persona and disponibles > 0) then
    v_gratis := false;
  end if;

  insert into public.visitas
    (persona_id, placa, marca, submarca, tipo_unidad, color, foto_path, es_gratis, caja)
  values
    (p_persona, nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     nullif(btrim(upper(coalesce(p_color,''))),''),
     nullif(btrim(coalesce(p_foto_path,'')),''),
     v_gratis, coalesce(nullif(btrim(p_caja),''),'principal'))
  returning id into v_id;

  -- (Antes aqui se insertaba en persona_placas. Se movio a enlazar_visita_
  -- a_carro: la placa se liga al cliente al concretar la venta real.)

  return jsonb_build_object('ok', true, 'visita', v_id,
                            'lealtad', public.lealtad_de(p_persona));
end;
$$;

-- --- 2. enlazar_visita_a_carro: liga la placa al concretar la venta -----
create or replace function public.enlazar_visita_a_carro(
  p_visita bigint,
  p_carro  bigint
) returns jsonb language plpgsql as $$
declare
  v          record;
  v_nombre   text;
  v_sub      text;
  v_tipo     text;
begin
  select * into v from public.visitas where id = p_visita;
  if v.id is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;
  if not exists (select 1 from public.carros where id = p_carro) then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- Un lavado = un cliente: si otra visita activa ya lo tomo, no se re-asigna.
  if exists (select 1 from public.visitas v2
             where v2.carro_id = p_carro and v2.estado = 'activa' and v2.id <> p_visita) then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado ya está asignado a otro cliente. Usa Corregir en el otro registro.');
  end if;

  select nombre into v_nombre from public.personas where id = v.persona_id;

  update public.carros set
    cliente        = coalesce(v_nombre, cliente),
    foto_path      = coalesce(v.foto_path, foto_path),
    foto_url       = case when v.foto_path is not null then null else foto_url end,
    foto_url_expira= case when v.foto_path is not null then null else foto_url_expira end
  where id = p_carro;

  if v.placa_norm is not null then
    v_sub  := nullif(btrim(upper(coalesce(v.submarca, ''))), '');
    v_tipo := nullif(btrim(coalesce(v.tipo_unidad, '')), '');
    if v_tipo is not null and v_tipo not in ('pickup','camioneta','automovil','pasajeros') then
      v_tipo := null;
    end if;
    update public.carros set
      placa       = v.placa,
      placa_en    = now(),
      marca       = nullif(btrim(upper(coalesce(v.marca, ''))), ''),
      submarca    = v_sub,
      tipo_unidad = case when v_sub is not null
                         then coalesce(v_tipo, tipo_unidad)
                         else coalesce(tipo_unidad, v_tipo) end
    where id = p_carro;
  end if;

  update public.visitas set carro_id = p_carro, enlazada_en = now()
  where id = p_visita;

  -- AQUI se vuelve DURABLE el enlace placa->persona: la venta ya se concreto.
  -- Solo si la visita trajo placa. on conflict: si ya la tenia, no duplica.
  if v.placa_norm is not null then
    insert into public.persona_placas (persona_id, placa_norm, placa_como_se_lee)
    values (v.persona_id, v.placa_norm, nullif(btrim(coalesce(v.placa,'')),''))
    on conflict (persona_id, placa_norm) do nothing;
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v.persona_id));
end;
$$;

-- --- 3a. desenlazar_visita: suelta el carro Y la placa (con guardia) ----
create or replace function public.desenlazar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare
  v_persona    bigint;
  v_carro      bigint;
  v_placa      text;
  v_placa_norm text;
begin
  select persona_id, carro_id, placa, placa_norm
    into v_persona, v_carro, v_placa, v_placa_norm
    from public.visitas where id = p_visita;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;

  -- Revertir la identidad que ESTA visita le escribio al carro, solo si la
  -- placa del carro sigue siendo la de esta visita (si el supervisor ya la
  -- cambio, se respeta lo suyo).
  if v_carro is not null then
    update public.carros set
      placa              = null,
      placa_organizacion = null,
      placa_en           = null,
      marca              = null,
      submarca           = null,
      cliente            = null,
      foto_path          = null,
      foto_url           = null,
      foto_url_expira    = null
    where id = v_carro
      and public.normalizar_placa(placa) is not distinct from public.normalizar_placa(v_placa);
  end if;

  update public.visitas set carro_id = null, enlazada_en = null
  where id = p_visita;

  -- Soltar el enlace placa->persona que puso el enlazar, SALVO que otra
  -- visita activa y enlazada de esta persona siga usando esa placa (para no
  -- borrar una placa que el cliente ya tenia de otra venta real).
  if v_placa_norm is not null and not exists (
       select 1 from public.visitas v2
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa' and v2.carro_id is not null
          and v2.placa_norm = v_placa_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_placa_norm;
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;

-- --- 3b. descartar_visita ("No hubo venta"): suelta la placa (con guardia) -
create or replace function public.descartar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare
  v_persona    bigint;
  v_placa_norm text;
begin
  update public.visitas set estado = 'descartada'
  where id = p_visita
  returning persona_id, placa_norm into v_persona, v_placa_norm;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;

  -- No hubo venta: su placa no debe quedar pegada al cliente. Se quita, salvo
  -- que otra visita activa y enlazada de la persona la siga usando.
  if v_placa_norm is not null and not exists (
       select 1 from public.visitas v2
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa' and v2.carro_id is not null
          and v2.placa_norm = v_placa_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_placa_norm;
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;
