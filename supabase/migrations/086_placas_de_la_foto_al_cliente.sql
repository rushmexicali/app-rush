-- =====================================================================
-- 086 — La placa de la foto del supervisor se liga al cliente (con nivel
--        de confianza), para ir construyendo la base de placas
-- 29/jul/2026
--
-- Problema (detectado con Mario Torres): la placa que el supervisor leyo de
-- la foto vive en el CARRO. persona_placas (la unica fuente de "placas del
-- cliente", que leen caja, la busqueda y el reporte) solo se llenaba con la
-- placa TECLEADA por la cajera. Como casi todos se registran por nombre, la
-- placa de la foto nunca llegaba al CRM: el reporte la mostraba (via el
-- carro), pero caja y la busqueda por placa no la conocian.
--
-- Regla del dueno: si se va a ligar una placa a un cliente, hay que estar
-- 1000% seguro; si no, mejor no ligarla. El enlace visita<->carro lo
-- confirma la cajera (elige el lavado), asi que el CLIENTE es confiable; el
-- riesgo esta en la PLACA (mala lectura de OCR, o foto pegada al carro
-- equivocado). Por eso:
--
--   * TECLEADA por la cajera            -> confirmada (un humano la leyo)
--   * De la FOTO de un carro ligado     -> SUGERIDA ("por confirmar")
--   * Una sugerida sube a confirmada si:
--       - un humano la confirma (boton en caja/reporte), o
--       - se corrobora sola: coincide con una tecleada, o la MISMA placa
--         aparece en 2+ carros distintos ligados a esa persona (una foto mal
--         pegada no se repite identica).
--
-- Todo pasa por UN solo helper (ligar_placa_a_persona) para no tener dos
-- reglas de lo mismo. Nada se presenta como placa del cliente sin certeza:
-- las sugeridas salen aparte, marcadas "por confirmar".
-- =====================================================================

-- --- 0. Estado de cada enlace placa->persona ---------------------------
-- Las filas que ya existen venian de placa tecleada: quedan confirmadas.
alter table public.persona_placas
  add column if not exists confirmada boolean not null default true;
alter table public.persona_placas
  add column if not exists origen text;   -- 'cajera' | 'foto' (informativo)

comment on column public.persona_placas.confirmada is
  'true = placa segura (tecleada por cajera, confirmada por humano, o '
  'corroborada). false = sugerida por la foto, "por confirmar".';


-- --- 1. Helper unico: ligar (o corroborar) una placa a una persona -----
create or replace function public.ligar_placa_a_persona(
  p_persona   bigint,
  p_placa     text,               -- como se lee (con guiones o no); se normaliza aqui
  p_origen    text    default 'foto',
  p_confirmar boolean default false
) returns void
language plpgsql
as $function$
declare
  v_norm text := public.normalizar_placa(p_placa);
  v_disp text := nullif(btrim(coalesce(p_placa, '')), '');
  v_conf boolean;
begin
  if p_persona is null or v_norm is null then
    return;
  end if;

  -- 1000%: confirmada si el que llama lo pide (placa tecleada por la cajera)
  -- o si hay corroboracion independiente.
  v_conf := coalesce(p_confirmar, false)
    or exists (select 1 from public.persona_placas pp
                where pp.persona_id = p_persona and pp.placa_norm = v_norm and pp.confirmada)
    -- la persona tecleo esta misma placa en alguna visita
    or exists (select 1 from public.visitas v
                where v.persona_id = p_persona and v.placa_norm = v_norm)
    -- la misma placa en 2+ carros distintos ligados a la persona
    or (select count(distinct v.carro_id)
          from public.visitas v
          join public.carros c on c.id = v.carro_id
         where v.persona_id = p_persona
           and v.estado = 'activa'
           and public.normalizar_placa(c.placa) = v_norm) >= 2;

  insert into public.persona_placas (persona_id, placa_norm, placa_como_se_lee, confirmada, origen)
  values (p_persona, v_norm, v_disp, v_conf, p_origen)
  on conflict (persona_id, placa_norm) do update
    set confirmada        = persona_placas.confirmada or excluded.confirmada,  -- nunca degrada
        placa_como_se_lee = coalesce(persona_placas.placa_como_se_lee, excluded.placa_como_se_lee),
        origen            = coalesce(persona_placas.origen, excluded.origen);
end;
$function$;

comment on function public.ligar_placa_a_persona(bigint, text, text, boolean) is
  'Liga una placa a una persona en persona_placas. p_confirmar=true (tecleada) '
  'o corroboracion -> confirmada; si no, sugerida. Nunca degrada una confirmada.';


-- --- 2. enlazar_visita_a_carro: teclada=confirmada, foto=sugerida -------
-- Igual que la 077, pero el bloque que ligaba la placa ahora pasa por el
-- helper, y ADEMAS liga la placa de la FOTO del carro (sugerida) cuando la
-- cajera no tecleo ninguna.
create or replace function public.enlazar_visita_a_carro(
  p_visita bigint,
  p_carro  bigint
) returns jsonb language plpgsql as $$
declare
  v            record;
  v_nombre     text;
  v_sub        text;
  v_tipo       text;
  v_carro_placa text;
begin
  select * into v from public.visitas where id = p_visita;
  if v.id is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;
  if not exists (select 1 from public.carros where id = p_carro) then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

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

  -- La venta ya se concreto: se liga la placa al cliente.
  --   * la que TECLEO la cajera -> confirmada (un humano la leyo)
  if v.placa_norm is not null then
    perform public.ligar_placa_a_persona(v.persona_id, v.placa, 'cajera', true);
  end if;
  --   * la de la FOTO del carro -> sugerida (o confirmada si se corrobora).
  --     Se lee la placa ACTUAL del carro (si la cajera tecleo, es la misma y
  --     el helper no duplica; si no, es la de la foto del supervisor).
  select coalesce(placa_display, placa) into v_carro_placa
    from public.carros where id = p_carro;
  if v_carro_placa is not null then
    perform public.ligar_placa_a_persona(v.persona_id, v_carro_placa, 'foto', false);
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v.persona_id));
end;
$$;


-- --- 3. guardar_datos_de_foto: al leer la placa, propagar al cliente ----
-- Si el carro YA esta ligado a una visita activa, la placa recien leida se
-- liga a esa persona (sugerida). Cubre el caso de que el supervisor tome la
-- foto DESPUES de que la cajera enlazo la venta.
create or replace function public.guardar_datos_de_foto(
  p_carro bigint, p_placa text default null, p_org text default null,
  p_marca text default null, p_submarca text default null, p_tipo text default null)
returns jsonb language plpgsql as $function$
declare
  nueva_submarca text;
  tipo_limpio    text;
  v_raw          text;
  v_norm         text;
  r              record;
begin
  nueva_submarca := nullif(btrim(upper(coalesce(p_submarca, ''))), '');

  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;
  end if;

  v_raw  := nullif(btrim(upper(coalesce(p_placa, ''))), '');
  v_norm := public.normalizar_placa(p_placa);

  update public.carros set
    placa              = v_norm,
    placa_display      = case when v_raw is distinct from v_norm then v_raw else null end,
    placa_organizacion = nullif(btrim(coalesce(p_org, '')), ''),
    placa_en           = now(),
    marca              = nullif(btrim(upper(coalesce(p_marca, ''))), ''),
    submarca           = nueva_submarca,
    tipo_unidad        = case
                           when nueva_submarca is not null
                             then coalesce(tipo_limpio, tipo_unidad)
                           else coalesce(tipo_unidad, tipo_limpio)
                         end
  where id = p_carro;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- Si el carro ya tiene dueno (visita activa ligada), la placa leida se le
  -- liga como SUGERIDA. Interconexion: la foto del supervisor alimenta el CRM.
  if v_norm is not null then
    for r in select persona_id from public.visitas
              where carro_id = p_carro and estado = 'activa' and persona_id is not null loop
      perform public.ligar_placa_a_persona(r.persona_id, coalesce(v_raw, v_norm), 'foto', false);
    end loop;
  end if;

  return jsonb_build_object('ok', true);
end;
$function$;


-- --- 4. persona_json: separa placas confirmadas de las "por confirmar" --
create or replace function public.persona_json(p_persona bigint)
returns jsonb language sql stable as $function$
  select jsonb_build_object(
    'id',       p.id,
    'nombre',   p.nombre,
    'telefono', p.telefono,
    'notas',    p.notas,
    'lealtad',  public.lealtad_de(p.id),
    'gastado',  coalesce((
      select sum(v.monto) from public.visitas v
       where v.persona_id = p.id and v.estado = 'activa'
    ), 0),
    -- Placas CONFIRMADAS: las seguras. Es lo que cuenta como "placas del
    -- cliente" en caja y en la busqueda.
    'placas',   coalesce((
      select jsonb_agg(coalesce(pp.placa_como_se_lee, pp.placa_norm) order by pp.creado_en)
        from public.persona_placas pp
       where pp.persona_id = p.id and pp.confirmada
    ), '[]'::jsonb),
    -- Placas POR CONFIRMAR: salieron de la foto, aun sin corroborar. Se
    -- muestran aparte, marcadas, con opcion de confirmar de un toque.
    'placas_por_confirmar', coalesce((
      select jsonb_agg(coalesce(pp.placa_como_se_lee, pp.placa_norm) order by pp.creado_en)
        from public.persona_placas pp
       where pp.persona_id = p.id and not pp.confirmada
    ), '[]'::jsonb)
  )
  from public.personas p
  where p.id = p_persona;
$function$;


-- --- 5. duenos_de_placa: dice si cada dueno esta confirmado -------------
create or replace function public.duenos_de_placa(p_placa text)
returns jsonb language sql stable as $function$
  select coalesce(jsonb_agg(
    jsonb_build_object('id', pe.id, 'nombre', pe.nombre, 'confirmada', pp.confirmada)
    order by pp.confirmada desc, pe.nombre
  ), '[]'::jsonb)
  from public.persona_placas pp
  join public.personas pe on pe.id = pp.persona_id
  where pp.placa_norm = public.normalizar_placa(p_placa);
$function$;


-- --- 6. Confirmar / descartar una placa (accion humana) ----------------
create or replace function public.confirmar_placa_de_persona(p_persona bigint, p_placa text)
returns jsonb language plpgsql as $function$
declare
  v_norm text := public.normalizar_placa(p_placa);
begin
  if v_norm is null then
    return jsonb_build_object('ok', false, 'error', 'Placa inválida');
  end if;
  update public.persona_placas
     set confirmada = true
   where persona_id = p_persona and placa_norm = v_norm;
  return jsonb_build_object('ok', true, 'persona', public.persona_json(p_persona));
end;
$function$;

create or replace function public.descartar_placa_de_persona(p_persona bigint, p_placa text)
returns jsonb language plpgsql as $function$
declare
  v_norm text := public.normalizar_placa(p_placa);
begin
  if v_norm is null then
    return jsonb_build_object('ok', false, 'error', 'Placa inválida');
  end if;
  delete from public.persona_placas
   where persona_id = p_persona and placa_norm = v_norm;
  return jsonb_build_object('ok', true, 'persona', public.persona_json(p_persona));
end;
$function$;


-- --- 7. Al desenlazar/descartar una visita: soltar la sugerida huerfana -
-- Solo se quitan las SUGERIDAS (confirmada=false) que ya nada sostiene. Las
-- confirmadas jamas se tocan aqui (un humano dijo que si, o se corroboro).
-- El helper de limpieza mira el carro de la visita.
create or replace function public.desenlazar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare
  v_persona    bigint;
  v_carro      bigint;
  v_placa      text;
  v_placa_norm text;
  v_carro_norm text;
begin
  select persona_id, carro_id, placa, placa_norm
    into v_persona, v_carro, v_placa, v_placa_norm
    from public.visitas where id = p_visita;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;

  -- La placa (de foto) del carro de esta visita, antes de tocar nada.
  if v_carro is not null then
    select public.normalizar_placa(placa) into v_carro_norm
      from public.carros where id = v_carro;
  end if;

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

  -- Placa TECLEADA: soltar su enlace salvo que otra venta real lo use (igual
  -- que la 077).
  if v_placa_norm is not null and not exists (
       select 1 from public.visitas v2
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa' and v2.carro_id is not null
          and v2.placa_norm = v_placa_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_placa_norm;
  end if;

  -- Placa de la FOTO del carro: si quedo como SUGERIDA y ya ninguna otra
  -- visita activa ligada de la persona tiene un carro con esa placa, se
  -- suelta. Las confirmadas no se tocan.
  if v_carro_norm is not null and v_carro_norm is distinct from v_placa_norm and not exists (
       select 1 from public.visitas v2
         join public.carros c2 on c2.id = v2.carro_id
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa'
          and public.normalizar_placa(c2.placa) = v_carro_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_carro_norm and not confirmada;
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;

create or replace function public.descartar_visita(p_visita bigint)
returns jsonb language plpgsql as $$
declare
  v_persona    bigint;
  v_carro      bigint;
  v_placa_norm text;
  v_carro_norm text;
begin
  select persona_id, carro_id, placa_norm into v_persona, v_carro, v_placa_norm
    from public.visitas where id = p_visita;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;

  if v_carro is not null then
    select public.normalizar_placa(placa) into v_carro_norm
      from public.carros where id = v_carro;
  end if;

  update public.visitas set estado = 'descartada' where id = p_visita;

  -- Placa tecleada: soltar salvo que otra visita activa enlazada la use.
  if v_placa_norm is not null and not exists (
       select 1 from public.visitas v2
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa' and v2.carro_id is not null
          and v2.placa_norm = v_placa_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_placa_norm;
  end if;

  -- Placa de la foto: soltar la SUGERIDA huerfana (ver desenlazar).
  if v_carro_norm is not null and v_carro_norm is distinct from v_placa_norm and not exists (
       select 1 from public.visitas v2
         join public.carros c2 on c2.id = v2.carro_id
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa'
          and public.normalizar_placa(c2.placa) = v_carro_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_carro_norm and not confirmada;
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;
