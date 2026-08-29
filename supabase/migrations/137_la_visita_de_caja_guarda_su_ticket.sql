-- =====================================================================
-- 137 — La visita de la caja guarda su TICKET y su MONTO.
--
-- 🔴 EL PROBLEMA, medido el 28/ago/2026 con la caja ya en uso real:
--    `registrar_visita_con_carro` nunca escribio esas dos columnas. Las 16
--    visitas del primer turno real quedaron con `ticket = null` y
--    `monto = null`, mientras que TODAS las visitas del ClientNoteTracker si
--    los traen. O sea dos formas de guardar lo mismo, que es exactamente como
--    se desfasan las cosas en este proyecto.
--
--    Lo que costaba: `persona_json` calcula el gasto con `sum(v.monto)`, asi
--    que un lavado registrado por la caja sumaba CERO al historial del
--    cliente. Alfredo Carballo tiene 25 visitas y $5,110 acumulados; su lavado
--    del 28/ago no aparecia en esa suma. Mientras mas se use la caja, mas se
--    degrada el dato.
--
-- 💡 Y hay un beneficio que no es obvio: con el ticket puesto, una visita de
--    caja se puede CONCILIAR contra la del CNT (que se sigue llenando en
--    paralelo). Sin ticket no habia ni forma de saber si el CNT la cubrio.
--
-- El dato NO se inventa: sale del carro que la cajera ya escogio.
--   monto   -> carros.monto (el total que cobro Zettle)
--   ticket  -> el purchaseNumber de la venta de ese carro
--
-- ⚠️ El ticket se saca con `detalle_venta()` y NO desarmando el payload a
--    mano. Zettle manda el aviso envuelto en una llave `payload` unas veces y
--    plano otras; quien lo desarma a mano solo entiende una forma y devuelve
--    nulo con la otra. Ese error ya se corrigio tres veces aqui (migraciones
--    115, 118 y 130) y no se vuelve a introducir.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) UN SOLO LUGAR donde se contesta "cual es el recibo de este carro".
--    `ligar_visitas_de_import()` hace la misma pregunta en bloque, con la
--    MISMA expresion (detalle_venta(v.payload) ->> 'purchaseNumber'). No se
--    reescribe esa funcion —son ~90 lineas de reglas con sus razones escritas,
--    y reescribirlas para cambiar una expresion es el movimiento que ya salio
--    mal aqui (§11.45)—; en su lugar, pruebas/visita-de-caja-con-ticket.sql
--    comprueba que las dos den lo MISMO sobre los carros reales. Si alguien
--    cambia una nada mas, la prueba avisa.
-- ---------------------------------------------------------------------
create or replace function public.recibo_del_carro(p_carro bigint)
returns text
language sql
stable
as $function$
  select public.detalle_venta(v.payload) ->> 'purchaseNumber'
  from public.carros c
  join public.ventas v on v.purchase_uuid = c.purchase_uuid
  where c.id = p_carro;
$function$;

revoke execute on function public.recibo_del_carro(bigint) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) La RPC de la caja. Cambia SOLO el insert: se le agregan ticket y monto.
--    La firma no cambia, asi que basta `create or replace` y no hay que
--    dropear nada (la leccion de la 052 no aplica aqui).
-- ---------------------------------------------------------------------
create or replace function public.registrar_visita_con_carro(
  p_persona bigint,
  p_carro bigint,
  p_usa_gratis boolean default false,
  p_caja text default 'principal',
  p_foto_path text default null,
  p_placa text default null,
  p_marca text default null,
  p_submarca text default null,
  p_tipo text default null,
  p_hubo_lectura boolean default true)
returns jsonb
language plpgsql
as $function$
declare
  c        record;
  v_clase  text;
  v_gratis boolean;
  v_cort   boolean;
  v_id     bigint;
  v_foto   text;
  v_dudosa boolean := false;
  v_ticket text;
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
  end if;

  select * into c from public.carros where id = p_carro;
  if c.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado ya no existe');
  end if;
  if c.cancelado_en is not null or coalesce(c.es_prueba,false) then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado está cancelado');
  end if;

  if exists (select 1 from public.visitas v2
             where v2.carro_id = p_carro and v2.estado = 'activa') then
    return jsonb_build_object('ok', false, 'error', 'Ese ticket ya se registró con otro cliente');
  end if;

  -- ⚠️ `is not distinct from` y no `=`: para un lavado normal clase_de_gratis
  -- devuelve NULL, y `null = 'canje'` es NULL — no false.
  v_clase := public.clase_de_gratis(c.producto, c.variante);
  v_cort  := (v_clase is not distinct from 'cortesia');
  -- EL TICKET MANDA sobre el switch de la cajera (ver CLAUDE.md §11.70).
  v_gratis := (v_clase is not distinct from 'canje');

  if coalesce(p_usa_gratis,false) and v_clase is distinct from 'canje' then
    return jsonb_build_object('ok', false,
      'error', 'Selecciona un ticket con lavado gratis',
      'motivo', 'sin_gratis');
  end if;

  -- Y la direccion contraria, que faltaba: un ticket de 6to cobrado a quien
  -- NO tiene lavado gratis disponible. Antes pasaba, y `greatest(0, ...)` de
  -- la vista escondia el descubierto: el cliente ademas perdia el gratis que
  -- si se iba a ganar. Decision del dueno (19/ago/2026): se rechaza.
  if v_gratis and public.saldo_de_gratis(p_persona) <= 0 then
    return jsonb_build_object('ok', false,
      'error', 'Este cliente todavía no tiene lavado gratis. Cóbralo normal.',
      'motivo', 'sin_saldo',
      'lealtad', public.lealtad_de(p_persona));
  end if;

  v_foto := nullif(btrim(coalesce(p_foto_path,'')),'');

  -- ⚠️ Si la venta todavia no esta en `ventas` (el webhook viene en camino),
  --    esto queda NULL y la visita se registra igual. NUNCA se bloquea a la
  --    cajera por un dato secundario — es la leccion de la fecha en
  --    milisegundos (§7) aplicada aqui.
  v_ticket := public.recibo_del_carro(p_carro);

  insert into public.visitas
    (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, carro_id, enlazada_en,
     placa, marca, submarca, tipo_unidad, foto_path, ticket, monto)
  values
    (p_persona, v_gratis, v_cort, 'activa',
     coalesce(nullif(btrim(p_caja),''),'principal'), false, p_carro, now(),
     nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     v_foto, v_ticket, c.monto)
  returning id into v_id;

  update public.carros
     set cliente = coalesce((select nombre from public.personas where id = p_persona), cliente)
   where id = p_carro;

  -- La foto se pega con `pegar_foto_de_caja`, que es la MISMA funcion que usa
  -- el camino de "No asignar a cliente" (136). Antes esto estaba escrito aqui
  -- adentro; al aparecer el segundo camino habrian quedado dos copias de la
  -- misma regla, con sus tres candados, y se habrian desfasado.
  select coalesce((public.pegar_foto_de_caja(
           p_carro, p_foto_path, p_placa, p_marca, p_submarca, p_tipo, p_hubo_lectura
         ) ->> 'placa_dudosa')::boolean, false) into v_dudosa;

  return jsonb_build_object('ok', true, 'visita', v_id, 'clase', v_clase,
                            'es_gratis', v_gratis, 'es_cortesia', v_cort,
                            'placa_dudosa', v_dudosa,
                            'ticket', v_ticket,
                            'lealtad', public.lealtad_de(p_persona));
end;
$function$;

revoke execute on function public.registrar_visita_con_carro(
  bigint, bigint, boolean, text, text, text, text, text, text, boolean)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) Las que ya se registraron sin ticket. Acotado a lo que de verdad le
--    falta: visitas que NO son del import, con carro y sin ticket. No toca
--    ni una fila del CNT.
-- ---------------------------------------------------------------------
do $rellenar$
declare n int; falta int;
begin
  update public.visitas v
     set ticket = public.recibo_del_carro(v.carro_id),
         monto  = c.monto
    from public.carros c
   where c.id = v.carro_id
     and v.caja <> 'import'
     and v.carro_id is not null
     and v.ticket is null;
  get diagnostics n = row_count;

  select count(*) into falta
    from public.visitas
   where caja <> 'import' and carro_id is not null and ticket is null;

  raise notice '137: % visitas de caja rellenadas; quedan % sin ticket', n, falta;
end $rellenar$;
