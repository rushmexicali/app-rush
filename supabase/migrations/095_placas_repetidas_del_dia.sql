-- =====================================================================
-- 095 — Aviso: dos (o más) carros del MISMO día con la MISMA placa
-- 30/jul/2026
--
-- Señal barata de "la foto se pegó al carro equivocado" (§12.1). Cuando el
-- supervisor le toma la foto a un carro que no es —típico en un apuro—, esa
-- placa se guarda en dos carros del día. Consecuencias ya vistas: el
-- historial por placa SOBRECUENTA visitas (BF-8884-A salió con "3 visitas /
-- Petro Gonzales Avila" el 30/jul cuando fue 1 carro) y el enlace
-- placa->cliente se puede pegar al cliente equivocado. Hoy nadie se entera.
--
-- Devuelve, por (día local, placa) con 2+ carros, la lista de esos carros
-- con lo justo para que el dueño distinga cuál es el bueno: hora,
-- descripción (los colores/tipos casi siempre difieren en un mispin) y el
-- ticket (clicable, abre la venta). El dueño abre la placa para ver la
-- galería de fotos y cachar el pegado.
--
-- "Mismo DÍA" a propósito: una placa que vuelve otro día es una visita real,
-- no un error. Se agrupa por día LOCAL (America/Tijuana), no UTC. Solo
-- lectura, no toca nada; no modifica el reporte congelado (vive aparte).
-- =====================================================================

create or replace function public.placas_repetidas_del_rango(p_desde date, p_hasta date)
returns jsonb
language sql
stable
as $function$
  with c as (
    select
      c.id,
      c.creado_en,
      (c.creado_en at time zone 'America/Tijuana')::date as dloc,
      public.normalizar_placa(c.placa)   as pn,
      coalesce(c.placa_display, c.placa)  as placa,
      c.tipo_unidad, c.color, c.marca, c.submarca, c.cliente,
      (select ((v.payload->>'payload')::jsonb)->>'purchaseNumber'
         from public.ventas v where v.purchase_uuid = c.purchase_uuid limit 1) as ticket
    from public.carros c
    where not c.es_prueba
      and c.cancelado_en is null
      and c.placa is not null
      and (c.creado_en at time zone 'America/Tijuana')::date between p_desde and p_hasta
  ),
  grupos as (
    select dloc, pn,
           (array_agg(placa order by creado_en desc))[1] as placa,
           count(*) as n
    from c
    group by dloc, pn
    having count(*) > 1
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'dia',     g.dloc,
    'placa',   g.placa,
    'cuantos', g.n,
    'carros', (
      select jsonb_agg(jsonb_build_object(
               'carro_id',    x.id,
               'hora',        x.creado_en,
               'tipo_unidad', x.tipo_unidad,
               'color',       x.color,
               'marca',       x.marca,
               'submarca',    x.submarca,
               'cliente',     x.cliente,
               'ticket',      x.ticket
             ) order by x.creado_en)
        from c x where x.dloc = g.dloc and x.pn = g.pn
    )
  ) order by g.dloc desc, g.placa), '[]'::jsonb)
  from grupos g;
$function$;

comment on function public.placas_repetidas_del_rango(date, date) is
  'Placas compartidas por 2+ carros del MISMO dia local (senal de foto pegada '
  'al carro equivocado). Por grupo: dia, placa y los carros (hora, descripcion, '
  'ticket). Solo lectura; no toca el reporte congelado.';
