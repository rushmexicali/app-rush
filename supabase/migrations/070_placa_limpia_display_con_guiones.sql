-- =====================================================================
-- RUSH — La placa en el backend SIEMPRE sin guiones; los guiones solo para
-- mostrar · 26/jul/2026
--
-- El dueno lo pidio: caja y supervisor se comunican, asi que el valor de la
-- placa en la base debe ser UNO SOLO e igual en los dos lados — sin guiones
-- ni espacios (para que casen y se busquen facil). Pero si la foto trae los
-- guiones (como los lee Claude), la app los muestra.
--
-- Solucion: dos representaciones en `carros`.
--   * placa          -> canonica, SIEMPRE limpia (sin guiones). Es la que casa
--                       caja<->supervisor y la que agrupa el historial.
--   * placa_display  -> "como se lee", con guiones, SOLO cuando la lectura los
--                       trajo. La app muestra placa_display || placa.
--
-- La caja ya guarda limpio (normPlaca en el front), asi que sus carros no
-- traen guiones (placa_display null) — se ven limpios, correcto. La foto del
-- supervisor SI puede traerlos, y ahi se conservan para mostrar.
-- =====================================================================

alter table public.carros add column if not exists placa_display text;

-- Backfill: la placa vieja (cruda, quiza con guiones) pasa a placa_display si
-- tenia guiones; placa queda limpia. Todo en un UPDATE (las expresiones leen
-- los valores VIEJOS de la fila).
update public.carros set
  placa_display = case when placa is distinct from public.normalizar_placa(placa)
                       then placa else null end,
  placa         = public.normalizar_placa(placa)
where placa is not null;

-- ---------------------------------------------------------------------
-- guardar_datos_de_foto (supervisor /foto): guarda placa limpia + display.
-- Igual que la 063 (autoritativa, tipo atado a submarca, no toca datos_de_nota)
-- pero separando limpia/display.
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
  nueva_submarca text;
  tipo_limpio    text;
  v_raw          text;   -- como se lee (con guiones)
  v_norm         text;   -- limpia
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
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------
-- enlazar_visita_a_carro (caja): la visita trae placa limpia; placa_display
-- se pone null (la caja no maneja guiones, y ademas limpia cualquier display
-- viejo de una foto previa de OTRO carro). Igual que la 069 en lo demas.
-- ---------------------------------------------------------------------
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
      placa         = v.placa_norm,     -- SIEMPRE limpia
      placa_display = null,             -- la caja no trae guiones
      placa_en      = now(),
      marca         = nullif(btrim(upper(coalesce(v.marca, ''))), ''),
      submarca      = v_sub,
      tipo_unidad   = case when v_sub is not null
                           then coalesce(v_tipo, tipo_unidad)
                           else coalesce(tipo_unidad, v_tipo) end
    where id = p_carro;
  end if;

  update public.visitas set carro_id = p_carro, enlazada_en = now()
  where id = p_visita;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v.persona_id));
end;
$$;

-- ---------------------------------------------------------------------
-- desenlazar_visita: al revertir el carro, limpia tambien placa_display.
-- ---------------------------------------------------------------------
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

  if v_carro is not null then
    select placa_norm into v_placa from public.visitas where id = p_visita;
    update public.carros set
      placa              = null,
      placa_display      = null,
      placa_organizacion = null,
      placa_en           = null,
      marca              = null,
      submarca           = null,
      cliente            = null,
      foto_path          = null,
      foto_url           = null,
      foto_url_expira    = null
    where id = v_carro
      and public.normalizar_placa(placa) is not distinct from v_placa;
  end if;

  update public.visitas set carro_id = null, enlazada_en = null
  where id = p_visita;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$$;

-- ---------------------------------------------------------------------
-- detalle_del_carro: agrega placa_display (para el desglose del supervisor).
-- Igual que la 062 mas ese campo.
-- ---------------------------------------------------------------------
create or replace function public.detalle_del_carro(p_carro bigint)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'id',           c.id,
    'producto',     c.producto,
    'variante',     c.variante,
    'monto',        c.monto,
    'placa',        c.placa,
    'placa_display',c.placa_display,
    'tipo_unidad',  c.tipo_unidad,
    'color',        c.color,
    'marca',        c.marca,
    'submarca',     c.submarca,
    'cliente',      c.cliente,
    'linea',        c.linea,
    'aviso',        c.aviso,
    'a_mano',       c.a_mano,
    'es_express',   c.es_express,
    'creado_en',    c.creado_en,
    'entregado_en', c.entregado_en,
    'cerrado_automaticamente', c.cerrado_automaticamente is not null,
    'tiempo_imposible',        c.tiempo_imposible,
    'foto_path',    c.foto_path,
    'prelavado_seg', (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'prelavado'),
    'tunel_seg',     (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'tunel'),
    'secando_seg',   (select sum(e.segundos)::int from public.etapas e
                       where e.carro_id = c.id and e.etapa = 'secando'),
    'total_seg', case when c.entregado_en is not null
                      then extract(epoch from (c.entregado_en - c.creado_en))::int end,
    'abierta_etapa',  (select e.etapa  from public.etapas e
                        where e.carro_id = c.id and e.fin is null
                        order by e.inicio desc limit 1),
    'abierta_inicio', (select e.inicio from public.etapas e
                        where e.carro_id = c.id and e.fin is null
                        order by e.inicio desc limit 1),
    'secadores', coalesce((
      select jsonb_agg(distinct coalesce(s.mostrar, a.secador))
        from public.asignaciones a
        left join public.secadores s on s.id = a.empleado_id
       where a.carro_id = c.id
    ), '[]'::jsonb)
  )
  from public.carros c
  where c.id = p_carro;
$$;

-- ---------------------------------------------------------------------
-- historial_placas: "como se lee" ahora prefiere placa_display (con guiones);
-- si no hay, la limpia. El agrupamiento sigue por placa (ya limpia).
-- ---------------------------------------------------------------------
create or replace view public.historial_placas as
  select normalizar_placa(placa) as placa,
    (array_agg(coalesce(placa_display, placa) order by creado_en desc))[1] as placa_como_se_lee,
    count(*)::integer as visitas,
    min(creado_en) as primera_visita,
    max(creado_en) as ultima_visita,
    (array_agg(tipo_unidad order by creado_en desc) filter (where tipo_unidad is not null))[1] as tipo_unidad,
    (array_agg(color order by creado_en desc) filter (where color is not null))[1] as color,
    (array_agg(marca order by creado_en desc) filter (where marca is not null))[1] as marca,
    (array_agg(cliente order by creado_en desc) filter (where cliente is not null))[1] as cliente,
    sum(coalesce(monto, 0::numeric)) as gastado
   from public.carros c
  where placa is not null and not es_prueba and cancelado_en is null
  group by (normalizar_placa(placa));
