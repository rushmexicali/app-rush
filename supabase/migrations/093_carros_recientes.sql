-- =====================================================================
-- 093 — Los ultimos carros lavados (para el reporte, seccion Clientes)
-- 30/jul/2026
--
-- En el reporte, seccion Clientes, la lista "Ultimas visitas" se alimenta
-- de la tabla `visitas` (el libro de lealtad): solo crece cuando la cajera
-- registra a un cliente en vivo o cuando se sube el concentrado del
-- ClientNoteTracker. Los carros que pasan por el lavado (webhook de Zettle)
-- NO crean visitas, asi que esa lista NO refleja la operacion del dia.
--
-- El dueno pidio una SEGUNDA lista, aparte de la de lealtad: "Ultimos
-- lavados", que si se actualiza sola con cada carro. Regla de identidad
-- que pidio, textual: "Si el cliente no se identifica con nombre, deberia
-- de salir la placa, si la placa no se identifica, entonces no aparece."
--
-- Esta funcion devuelve los ultimos N carros (mas reciente primero) que
-- tienen AL MENOS uno de los dos: nombre de cliente (la nota de caja) o
-- placa. Un carro sin ninguno de los dos no puede identificarse -> se
-- excluye aqui mismo (no aparece). El dueno de lealtad (para ligar el
-- nombre a su perfil) NO se calcula aqui: el Edge Function lo agrega con
-- clientes_de_placas — la MISMA fuente que el Historial por placa, para no
-- tener dos reglas para "quien es el dueno de esta placa".
--
-- Excluye pruebas y cancelados (borrados/devueltos), el mismo filtro que
-- historial_placas y /cola. La placa sale normalizada (clave de enlace) y
-- "como se lee" con guiones (placa_display), igual que historial_placas.
-- =====================================================================

create or replace function public.carros_recientes(p_limite int default 10)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.creado_en desc), '[]'::jsonb)
  from (
    select
      c.id                                as carro_id,
      c.creado_en,
      public.normalizar_placa(c.placa)    as placa,
      coalesce(c.placa_display, c.placa)  as placa_como_se_lee,
      c.cliente,
      c.marca,
      c.submarca,
      c.tipo_unidad,
      c.color
    from public.carros c
    where not coalesce(c.es_prueba, false)
      and c.cancelado_en is null
      and (nullif(btrim(coalesce(c.cliente, '')), '') is not null
           or c.placa is not null)
    order by c.creado_en desc
    limit greatest(p_limite, 0)
  ) x;
$function$;

comment on function public.carros_recientes(int) is
  'Los N carros lavados mas recientes (mas nuevo primero) para la lista '
  '"Ultimos lavados" del reporte. Solo los que se pueden identificar: con '
  'nombre de caja o con placa; sin ninguno de los dos, no aparece. El dueno '
  'de lealtad lo agrega el Edge Function con clientes_de_placas.';
