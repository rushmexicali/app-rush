-- =====================================================================
-- 125 - El cuerpo crudo de los avisos de Zettle caduca a los 3 dias
--
-- La bitacora del webhook guardaba la FIRMA (`x-izettle-signature`) pero no
-- los BYTES que esa firma cubre: en el camino bueno mandaba `crudo = null`
-- con el argumento de que "el payload ya vive en `ventas.payload`". Es falso
-- para este proposito — `ventas.payload` es el JSON ya parseado, y una firma
-- se calcula sobre los bytes exactos (espacios, orden de llaves). Volver a
-- serializarlo da otros bytes. Se estaba guardando la firma sin lo firmado,
-- que es como guardar el candado sin la puerta: el pendiente de verificar la
-- firma de Zettle no se podia cerrar con eso.
--
-- Ya se guarda. Y para que no se vuelva un almacen de datos de venta
-- duplicados, se borra a los 3 dias: son ~270 avisos reales, de sobra para
-- deducir el esquema. Se borra SOLO el cuerpo (`crudo`); el renglon, la hora
-- y las cabeceras se quedan, que es lo que hace de bitacora.
--
-- ⚠️ Los motivos que NO son 'ok' conservan su cuerpo mas tiempo: esos son los
-- avisos que se descartaron y su cuerpo es la unica evidencia de POR QUE. Hoy
-- hay uno solo (`json_invalido`) en toda la historia.
-- =====================================================================

create or replace function public.limpiar_crudo_del_webhook(p_dias int default 3)
returns text
language plpgsql
security definer
set search_path = public
as $function$
declare n int;
begin
  update public.webhook_bitacora
     set crudo = null
   where motivo = 'ok'
     and crudo is not null
     and recibido_en < now() - make_interval(days => p_dias);
  get diagnostics n = row_count;
  return 'bitacora del webhook: se solto el cuerpo de ' || n || ' avisos buenos de mas de ' || p_dias || ' dias';
end;
$function$;

revoke execute on function public.limpiar_crudo_del_webhook(int) from public;

-- Se cuelga de la misma corrida que ya limpia la bitacora del cron, para no
-- agendar otro trabajo por algo tan chico.
select cron.schedule('limpiar-bitacora-cron', '10 3 * * *',
  $$select public.limpiar_bitacora_del_cron(7), public.limpiar_crudo_del_webhook(3)$$);

select public.limpiar_crudo_del_webhook(3) as primera_corrida;
