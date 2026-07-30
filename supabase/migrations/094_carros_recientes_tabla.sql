-- =====================================================================
-- 094 — "Últimos lavados" pasa a ser UNA tabla como el Historial por placa
-- 30/jul/2026
--
-- El dueño redefinió la sección Clientes: en vez de dos listas (lealtad +
-- lavados), UNA sola tabla con los ultimos 20 lavados que van entrando, con
-- la MISMA informacion que el "Historial por placa" (seccion Operacion) pero
-- SIN la columna de visitas y CON el numero de ticket clicable al final.
--
-- La fila es por CARRO (no agregada por placa), y se va llenando sola:
--   - Al cobrar: sale la descripcion de la cajera ("Camioneta Blanca") y el
--     ticket (clicable, abre la venta de Zettle con ticket_detalle — 088).
--   - Al tomar la foto: la descripcion pasa a marca+submarca+color ("MG RX5
--     Blanca") y aparece la placa (clicable a su perfil).
--   - Si la placa liga a un cliente de lealtad: aparece su nombre (clicable)
--     — eso lo agrega el Edge Function con clientes_de_placas, como en /placas.
--   - Los secadores de ESE carro, clicables a su perfil.
--
-- Cambios de esta version respecto a la 093:
--   1. Default 20 (antes 10).
--   2. Ya NO se exige nombre-o-placa: un carro recien pagado aparece de
--      inmediato aunque no tenga ninguno (la funcion es "ver los lavados
--      entrando"). Solo se excluyen prueba y cancelados, como el resto del
--      reporte.
--   3. Se agregan por carro: `ticket` (purchaseNumber, en vivo desde
--      ventas.payload, igual que ticket_detalle) y `secadores` (id+nombre de
--      la tripulacion de ESTE carro, para ligar a su perfil).
-- =====================================================================

create or replace function public.carros_recientes(p_limite int default 20)
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
      c.color,
      -- Ticket = purchaseNumber de la venta. En vivo desde ventas.payload
      -- (el mismo dato que consume ticket_detalle, migracion 088), asi que
      -- los lavados de hoy —que aun no estan en zettle_compras— ya lo traen.
      (select ((v.payload->>'payload')::jsonb)->>'purchaseNumber'
         from public.ventas v
        where v.purchase_uuid = c.purchase_uuid
        limit 1) as ticket,
      -- Secadores de ESTE carro (no de la ultima visita de la placa): id (para
      -- ligar al perfil) + nombre. Mismo shape que secadores_de_placas (090).
      coalesce((
        select jsonb_agg(distinct jsonb_build_object(
                 'id',     a.empleado_id,
                 'nombre', coalesce(sd.mostrar, a.secador)))
          from public.asignaciones a
          left join public.secadores sd on sd.id = a.empleado_id
         where a.carro_id = c.id
      ), '[]'::jsonb) as secadores
    from public.carros c
    where not coalesce(c.es_prueba, false)
      and c.cancelado_en is null
    order by c.creado_en desc
    limit greatest(p_limite, 0)
  ) x;
$function$;

comment on function public.carros_recientes(int) is
  'Los N carros lavados mas recientes (mas nuevo primero) para la tabla '
  '"Ultimos lavados" del reporte (seccion Clientes). Por carro: descripcion, '
  'placa, cliente (nota), ticket (purchaseNumber en vivo) y secadores. El '
  'dueno de lealtad lo agrega el Edge Function con clientes_de_placas.';
