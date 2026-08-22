-- =====================================================================
-- 123 - El aviso PLANO de Zettle, en las cuatro funciones que faltaban
--       (y por fin se pueden VER los carros con placa dudosa)
--
-- 🔴 Esta clase de error ya se arreglo TRES veces y seguia viva en cuatro
-- lugares mas. Zettle manda el aviso de una venta envuelto en una llave
-- `payload` unas veces y PLANO otras. Quien lo desarma a mano —
-- `(v.payload->>'payload')::jsonb`— solo entiende la forma envuelta y
-- devuelve NULO con la otra, en silencio:
--
--   * migracion `115`: le paso a `ventas_indexar`, y por eso la caja no
--     encontraba tickets que si existian.
--   * migracion `118`: le paso al ligado del import.
--   * y hoy, medido: `tickets_recientes`, `ticket_detalle`,
--     `carros_recientes` y `placas_repetidas_del_rango`.
--
-- La peor de las cuatro es **`tickets_recientes`**: es la lista que la cajera
-- toca para registrar la visita. Con una venta plana, el ticket sencillamente
-- NO APARECE, y ella no tiene forma de saber si el cobro no entro o si la
-- lista se equivoco — con el cliente enfrente. `ticket_detalle` es el modal
-- del ticket; `carros_recientes` y `placas_repetidas_del_rango`, dos tablas
-- del reporte que saldrian sin numero de ticket.
--
-- La respuesta correcta ya existe y esta probada: `detalle_venta(payload)`,
-- que entiende las dos formas. Las cuatro le preguntan a ella.
--
-- Hoy hay 2 ventas planas de 2,860, asi que el dano medible es chico. El
-- punto no es el dano de hoy: es que la regla vuelva a vivir en un solo lado.
--
-- ---------------------------------------------------------------------
-- Y lo segundo: `carros.placa_dudosa` ya se puede VER.
--
-- Tres funciones la escriben y CERO codigo la lee. Son 20 carros marcados
-- (14 cuando la auditoria lo encontro: sigue creciendo) y no habia ninguna
-- via en el producto para revisarlos. Es la red cazando el problema y
-- enterrando la evidencia: el candado atajo una placa que se iba a pegar al
-- carro equivocado, lo apunto, y nadie podia mirarlo nunca.
--
-- `placas_dudosas_del_rango` sale con la misma forma que
-- `placas_repetidas_del_rango` para que la pantalla del dueno la pinte con
-- el mismo molde, junto a la otra alerta.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Las cuatro que desarmaban el payload a mano
-- ---------------------------------------------------------------------
do $$
declare
  r record;
  d text;
  nuevo text;
  n int := 0;
begin
  for r in
    select p.oid, p.proname
      from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public' and p.prokind = 'f'
       and pg_get_functiondef(p.oid) like '%payload->>''payload''%'
  loop
    d := pg_get_functiondef(r.oid);
    -- Las dos formas exactas que aparecen en la base, con y sin el parentesis
    -- exterior. Se comprueba abajo que no quede ninguna.
    nuevo := replace(d, '((v.payload->>''payload'')::jsonb)', 'public.detalle_venta(v.payload)');
    nuevo := replace(nuevo, '(v.payload->>''payload'')::jsonb', 'public.detalle_venta(v.payload)');
    if nuevo = d then
      raise exception 'No se pudo reescribir %: la expresion no coincide. Revisar a mano.', r.proname;
    end if;
    execute nuevo;
    n := n + 1;
  end loop;
  raise notice 'reescritas % funciones', n;
end $$;

-- Que no quede ninguna. Si manana alguien escribe una quinta, esta
-- comprobacion NO la va a cachar (solo corre al aplicar la migracion), pero
-- `pruebas/payload-y-busquedas.sql` si la caza en cada despliegue.
do $$
declare quedan text;
begin
  select string_agg(p.proname, ', ') into quedan
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public' and p.prokind = 'f'
     and pg_get_functiondef(p.oid) like '%payload->>''payload''%';
  if quedan is not null then
    raise exception 'Siguen desarmando el payload a mano: %', quedan;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 2) Los carros con placa dudosa, por fin visibles
-- ---------------------------------------------------------------------
create or replace function public.placas_dudosas_del_rango(p_desde date, p_hasta date)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(jsonb_build_object(
    'carro_id',     c.id,
    'dia',          (c.creado_en at time zone 'America/Tijuana')::date,
    'hora',         c.creado_en,
    'placa_dudosa', c.placa_dudosa,
    -- La que SI se le quedo al carro, si tiene. Comparar las dos es lo que
    -- deja ver si la foto se pego al carro equivocado.
    'placa',        coalesce(c.placa_display, c.placa),
    'tipo_unidad',  c.tipo_unidad,
    'color',        c.color,
    'marca',        c.marca,
    'submarca',     c.submarca,
    'cliente',      c.cliente,
    'ticket',       (select public.detalle_venta(v.payload) ->> 'purchaseNumber'
                       from public.ventas v where v.purchase_uuid = c.purchase_uuid limit 1),
    -- El OTRO carro del mismo dia que ya traia esa placa: es el candidato a
    -- ser el dueno real de la foto.
    'choca_con',    (select x.id from public.carros x
                      where x.placa = public.normalizar_placa(c.placa_dudosa)
                        and x.id <> c.id
                        and not x.es_prueba and x.cancelado_en is null
                        and (x.creado_en at time zone 'America/Tijuana')::date
                            = (c.creado_en at time zone 'America/Tijuana')::date
                      order by x.creado_en limit 1)
  ) order by c.creado_en desc), '[]'::jsonb)
  from public.carros c
  where c.placa_dudosa is not null
    and not c.es_prueba
    and c.cancelado_en is null
    and (c.creado_en at time zone 'America/Tijuana')::date between p_desde and p_hasta;
$function$;

revoke execute on function public.placas_dudosas_del_rango(date, date) from public;
