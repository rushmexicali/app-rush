-- =====================================================================
-- 144 — "Borrar unidad" deja de esperar. Queda siempre disponible.
--
-- Decision del dueno, 31/ago/2026: *"Haz que el boton de borrar unidad ya no
-- se active por tiempo. Dejalo permanentemente activado"*.
--
-- QUE SE VA: los dos umbrales que puso la 083/084 —30 min sin asignar, 2 h
-- secando—. Existian para que el supervisor (de la tercera edad) no borrara
-- por accidente una unidad que iba bien. En la operacion real resultaron
-- estorbo: el dia que hay que limpiar la cola, el carro que sobra casi nunca
-- lleva media hora esperando.
--
-- ⛔ QUE SE QUEDA, y no es negociable:
--
--   1. SOLO se puede borrar un carro que este EN LA COLA (`prelavado` o
--      `secando`). Un carro entregado no se borra por aqui — para eso esta
--      "Restaurar" en Finalizados. Sin esto, una llamada suelta podria sacar
--      del reporte un lavado ya cerrado.
--   2. NO BORRA LA FILA. Sigue siendo `cancelado_en` + motivo
--      'borrado_supervisor', que es reversible y conserva producto, monto,
--      nota, foto, hora de entrada, etapas y asignaciones.
--   3. Es idempotente: pedirlo dos veces no truena.
--   4. La confirmacion del front se queda, y AHORA IMPORTA MAS: era la
--      segunda reja; ahora es la unica.
--
-- ⚠️ LO QUE ESTO CUESTA, DICHO DE FRENTE: hasta hoy la base no dejaba borrar
--    un carro recien entrado ni uno que llevaba 20 minutos secando, aunque el
--    front fallara. Eso se acaba. Un toque por error ahora si saca el carro de
--    la cola — se recupera (`cancelado_en = null`), pero hay que darse cuenta.
--
-- ⚠️ Y EL ORDEN CON LA CAJA IMPORTA MAS QUE ANTES. `registrar_visita_con_carro`
--    RECHAZA un lavado cancelado ("Ese lavado esta cancelado"). Si se borra la
--    unidad antes de que la cajera registre al cliente, ese sello se pierde y
--    no hay forma de ponerlo. Antes los 30 minutos hacian que ese cruce fuera
--    casi imposible (la caja registra a los ~40 segundos del cobro); ahora la
--    ventana esta abierta desde el primer segundo.
-- =====================================================================

create or replace function public.borrar_unidad(p_carro bigint)
returns jsonb
language plpgsql
as $function$
declare
  c public.carros%rowtype;
begin
  select * into c from public.carros where id = p_carro for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no existe el carro');
  end if;

  -- Idempotente: si ya salio de la cola, no es un error volver a pedirlo.
  if c.cancelado_en is not null then
    return jsonb_build_object('ok', true, 'carro', p_carro, 'ya_estaba', true);
  end if;

  -- El unico candado que queda: tiene que estar EN LA COLA. Un carro
  -- entregado se restaura desde Finalizados, no se borra desde aqui.
  if c.estado not in ('prelavado', 'secando') then
    return jsonb_build_object('ok', false,
      'error', 'Solo se puede borrar una unidad que siga en la cola');
  end if;

  update public.carros
     set cancelado_en = now(),
         cancelado_motivo = 'borrado_supervisor'
   where id = p_carro;

  return jsonb_build_object('ok', true, 'carro', p_carro);
end;
$function$;
