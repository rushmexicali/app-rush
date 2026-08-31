-- =====================================================================
-- 139 — Un lavado de ARRENDATARIOS no suma sello.
--
-- Regla del dueno, 30/ago/2026, textual: "los lavados de arrendatarios, no
-- generan sellos. Igual se pueden asignar al cliente, pero no generan
-- visita". Escogio la opcion A: queda en el historial, marcado, pero ni
-- suma sello ni consume gratis.
--
-- Eso es EXACTAMENTE lo que ya significa `es_cortesia` desde la 101/102
-- ("ni suma sello ni consume gratis, pero si queda en el historial"), asi
-- que no se inventa un cuarto estado: se reusa el tercero que ya existe y
-- ya esta probado.
--
-- 🔑 SE CAMBIA UNA SOLA FUNCION, Y ESA ES LA GRACIA. `clase_de_gratis` es
--    el unico lugar donde se decide canje/cortesia, y los DOS caminos que
--    registran visitas le preguntan a ella:
--      · caja en vivo -> registrar_visita_con_carro
--      · import       -> clase_de_gratis_del_ticket
--                        -> aplicar_clase_de_gratis_del_import
--    Tocar los dos por separado es como se desfasan las cosas aqui (es el
--    error que este proyecto ya cometio con es_servicio_especial (055), con
--    la cortesia del import (129) y con el aviso plano de Zettle tres veces).
--
-- ⚠️ EL ORDEN DE LOS `when` NO ES COSMETICO. El de arrendatarios va PRIMERO:
--    si fuera despues, el `not ilike 'gratis%' -> null` lo atajaria y la
--    regla no haria nada. Un arrendatario no es un producto "Gratis".
--
-- ⚠️ SE EMPAREJA 'arrenda', NO la categoria 'Descuento'. En esa categoria
--    tambien viven `Instagram` y `Passie Completo`, que son descuentos de
--    PUBLICIDAD a clientes normales de mostrador (CLAUDE.md §12.1): esos si
--    ganan su sello y meterlos aqui le quitaria lealtad a gente que la gano.
--    Se mira producto Y variante por si algun dia se da de alta como
--    `Express / Arrendatarios`.
--
-- Alcance medido antes de escribir: 20 ventas de arrendatarios en toda la
-- historia y 1 sola con nota en el ClientNoteTracker. O sea que esto pesa
-- HACIA ADELANTE — la caja ya los registra todos los dias.
--
-- Efecto visible en la caja, sin tocar el front: `tickets_recientes` ya
-- devuelve `clase`, y caja.html pinta la etiqueta "CORTESIA - no suma"
-- cuando vale 'cortesia'. Un arrendatario la va a mostrar solita.
-- =====================================================================

create or replace function public.clase_de_gratis(p_producto text, p_variante text)
returns text
language sql
immutable
as $function$
  select case
    -- Arrendatarios: contrato de flotilla, no lealtad. VA PRIMERO (ver arriba).
    when coalesce(p_producto,'') ilike '%arrenda%'
      or coalesce(p_variante,'') ilike '%arrenda%'        then 'cortesia'
    when coalesce(p_producto,'') not ilike 'gratis%'      then null
    when coalesce(p_variante,'') ilike '6to%'             then 'canje'
    else 'cortesia'
  end;
$function$;

-- Comprobacion: la regla nueva hace lo suyo y NO mueve nada de lo de antes.
do $$
declare
  malos text := '';
begin
  -- Lo nuevo.
  if public.clase_de_gratis('Completo Arrendatarios', null) is distinct from 'cortesia' then
    malos := malos || ' arrendatarios-no-es-cortesia';
  end if;
  if public.clase_de_gratis('Express', 'Arrendatarios') is distinct from 'cortesia' then
    malos := malos || ' variante-arrendatarios-no-es-cortesia';
  end if;

  -- Lo viejo, intacto.
  if public.clase_de_gratis('Gratis', '6to Lavado')  is distinct from 'canje'    then malos := malos || ' 6to-lavado'; end if;
  if public.clase_de_gratis('Gratis', '6to Express') is distinct from 'canje'    then malos := malos || ' 6to-express'; end if;
  if public.clase_de_gratis('Gratis', 'Cortesia')    is distinct from 'cortesia' then malos := malos || ' cortesia'; end if;
  if public.clase_de_gratis('Gratis', 'Mango')       is distinct from 'cortesia' then malos := malos || ' mango'; end if;
  if public.clase_de_gratis('Completo RUSH','Grande') is not null                then malos := malos || ' completo-rush'; end if;
  if public.clase_de_gratis('Express','Chico')        is not null                then malos := malos || ' express'; end if;
  -- Los descuentos de PUBLICIDAD siguen ganando sello.
  if public.clase_de_gratis('Instagram', null)        is not null                then malos := malos || ' instagram'; end if;
  if public.clase_de_gratis('Passie Completo', null)  is not null                then malos := malos || ' passie'; end if;

  if malos <> '' then
    raise exception 'FALLO clase_de_gratis:%', malos;
  end if;
  raise notice 'clase_de_gratis OK: arrendatarios son cortesia; canjes, cortesias, pagados y publicidad sin cambio.';
end $$;
