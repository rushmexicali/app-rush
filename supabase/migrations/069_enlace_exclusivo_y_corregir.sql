-- =====================================================================
-- RUSH — Un lavado (venta) no se asigna a dos clientes; corregir revierte
-- 26/jul/2026
--
-- En la prueba de la caja: la cajera enlazaba una visita a un lavado, picaba
-- "Refrescar", y la pantalla la dejaba re-asignar — pudiendo mandar la misma
-- venta a dos carros. Se cierra por los dos lados. Aqui, el backend:
--
-- 1) enlazar_visita_a_carro RECHAZA si ese carro ya lo tomo OTRA visita
--    activa. Un lavado = un cliente. (El front ademas bloquea y pide Corregir.)
--
-- 2) desenlazar_visita ahora REVIERTE la identidad que la visita le escribio
--    al carro (placa/marca/submarca/foto/cliente). Al corregir de un carro
--    equivocado a otro, el equivocado NO se queda con la placa/foto del
--    cliente — si no, se recrea el bug de la placa duplicada. En el flujo de
--    caja el carro nace en blanco (recien pagado), asi que revertir a blanco
--    es correcto; si el supervisor ya le tomo foto, su foto es autoritativa y
--    re-tomable. No toca datos_de_nota ni tipo_unidad (fuente de la cajera).
-- =====================================================================

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

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v.persona_id));
end;
$$;

create or replace function public.desenlazar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare
  v_persona bigint;
  v_carro   bigint;
  v_placa   text;
begin
  select persona_id, carro_id into v_persona, v_carro
    from public.visitas where id = p_visita;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;

  -- Revertir la identidad que ESTA visita le escribio al carro, para que un
  -- carro corregido no se quede con la placa/foto del cliente equivocado.
  -- Solo si la placa del carro sigue siendo la de esta visita (si el
  -- supervisor ya la cambio, se respeta lo suyo).
  if v_carro is not null then
    select placa into v_placa from public.visitas where id = p_visita;
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

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;
