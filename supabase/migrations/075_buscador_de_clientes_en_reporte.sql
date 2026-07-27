-- =====================================================================
-- RUSH — Buscador de clientes/vehiculos en el reporte del dueno · 27/jul/2026
--
-- El dueno quiere, en el reporte (pagina aparte del supervisor), poder:
--   - buscar por nombre O placa O marca O submarca,
--   - abrir el perfil de una PERSONA: tarjeta de lealtad (sellos, lavados
--     gratis acumulados, placas) + todas sus visitas,
--   - abrir el perfil de una PLACA: todas sus visitas, cada una con
--     entrada, salida, quien la seco, y la PERSONA de lealtad de esa venta.
--
-- Casi todo ya existe (buscar_personas, persona_json, historial_de_persona,
-- lealtad_de). Aqui va lo unico nuevo:
--   1. submarca expuesta en la vista historial_placas (el dato ya vive en
--      carros.submarca desde la 061; solo faltaba mostrarlo).
--   2. historial_de_placa(placa): las visitas de UNA placa, con la persona
--      de lealtad de cada venta (via visitas.carro_id).
--   3. buscar_vehiculos(q): match por placa, marca o submarca sobre
--      historial_placas (normalizado, sin acentos ni mayusculas).
-- =====================================================================

-- --- 1. submarca en historial_placas ---------------------------------
-- Se AGREGA al FINAL: `create or replace view` no permite reordenar ni
-- renombrar columnas existentes, solo anadir al final. El orden no le
-- importa a quien la consulta (todo es por nombre).
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
    sum(coalesce(monto, 0::numeric)) as gastado,
    (array_agg(submarca order by creado_en desc) filter (where submarca is not null))[1] as submarca
   from public.carros c
  where placa is not null and not es_prueba and cancelado_en is null
  group by (normalizar_placa(placa));

-- --- 2. historial_de_placa: las visitas de UNA placa -----------------
-- Espina = carros (ahi viven los tiempos y los secadores). La persona de
-- lealtad de cada venta se une via visitas.carro_id (lateral, la mas
-- reciente activa). Un carro sin visita ligada en caja -> persona = null,
-- que el front muestra como "sin asignar". Mismo criterio de secadores que
-- historial_de_persona (coalesce mostrar/secador, distinct).
create or replace function public.historial_de_placa(p_placa text)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'fecha',     c.creado_en,
      'placa',     coalesce(c.placa_display, c.placa),
      'color',     c.color,
      'marca',     c.marca,
      'submarca',  c.submarca,
      'tipo',      c.tipo_unidad,
      'producto',  c.producto,
      'variante',  c.variante,
      'linea',     c.linea,
      'entrada',   c.creado_en,
      'salida',    c.entregado_en,
      'es_gratis', vp.es_gratis,
      'persona',   case when vp.persona_id is not null
                     then jsonb_build_object('id', vp.persona_id, 'nombre', vp.nombre)
                     else null end,
      'secadores', coalesce((
        select jsonb_agg(distinct coalesce(s.mostrar, a.secador))
          from public.asignaciones a
          left join public.secadores s on s.id = a.empleado_id
         where a.carro_id = c.id
      ), '[]'::jsonb)
    ) order by c.creado_en desc
  ), '[]'::jsonb)
  from public.carros c
  left join lateral (
    select v.persona_id, v.es_gratis, p.nombre
      from public.visitas v
      join public.personas p on p.id = v.persona_id
     where v.carro_id = c.id and v.estado = 'activa'
     order by v.creado_en desc
     limit 1
  ) vp on true
  where public.normalizar_placa(c.placa) = public.normalizar_placa(p_placa)
    and c.placa is not null and not c.es_prueba and c.cancelado_en is null;
$$;

-- --- 3. buscar_vehiculos: por placa, marca o submarca ----------------
-- Sobre historial_placas (ya agrupada por placa). Placa con
-- normalizar_placa (alnum/mayusculas), marca/submarca con normalizar_nombre
-- (sin acentos, minusculas) para que "corolla", "Corolla" y "COROLLA"
-- caigan igual. nullif(...,'') evita que una q sin caracteres utiles
-- matchee todo. Top 50 por visitas.
create or replace function public.buscar_vehiculos(p_q text)
returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(to_jsonb(h) order by h.visitas desc), '[]'::jsonb)
  from (
    select hp.*
    from public.historial_placas hp
    where
      (nullif(public.normalizar_placa(p_q), '') is not null
        and hp.placa like '%' || public.normalizar_placa(p_q) || '%')
      or (nullif(public.normalizar_nombre(p_q), '') is not null and hp.marca is not null
        and public.normalizar_nombre(hp.marca) like '%' || public.normalizar_nombre(p_q) || '%')
      or (nullif(public.normalizar_nombre(p_q), '') is not null and hp.submarca is not null
        and public.normalizar_nombre(hp.submarca) like '%' || public.normalizar_nombre(p_q) || '%')
    order by hp.visitas desc
    limit 50
  ) h;
$$;
