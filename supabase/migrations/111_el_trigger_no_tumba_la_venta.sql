-- =====================================================================
-- 111 - Cuatro escrituras y un indice, de lo que quedaba de la auditoria
--
--   #24  crear_carro_desde_venta puede tumbar la venta entera.
--   #25  falta el indice en asignaciones(empleado_id).
--   #25  enlazar_visita_a_carro escribe la placa CRUDA y brinca el candado.
--   #25  desenlazar_visita borra la foto y el cliente que no puso ese enlace.
--   #25  cerrar_pendientes no alcanza un carro creado despues del corte.
-- =====================================================================


-- ---------------------------------------------------------------------
-- #24 - un error creando el carro ya no se lleva la VENTA entre las patas
--
-- `ventas_crear_carro` es un trigger AFTER INSERT: si la funcion revienta,
-- revienta el insert de la venta. O sea que un error creando el carro
-- —un producto con una forma que no esperabamos, un tipo que no cuadra—
-- no deja un carro sin crear: deja la VENTA sin guardar. Y el webhook le
-- responde 500 a Zettle.
--
-- Es exactamente la leccion de §7 un nivel mas abajo: alli una venta real
-- se perdio porque la fecha venia en milisegundos y Postgres tumbo la fila
-- completa. La regla que salio de eso —"si un dato secundario no se
-- entiende, se guarda en blanco; la venta nunca se pierde por un campo que
-- no era esencial"— vale igual aqui: el carro es importante, pero la venta
-- es el dinero.
--
-- ⚠️ Tragarse el error NO puede significar descartar en silencio: eso es el
-- hallazgo #23, que la 108 acaba de cerrar. Por eso el error va a
-- `webhook_bitacora`, la misma tabla, en vez de a un `console.error` que
-- nadie mira. Si un dia el catalogo cambia y ninguna venta crea carro, la
-- cola amanece vacia PERO queda escrito por que.
--
-- Y la bitacora, a su vez, tampoco puede tumbar la venta: su insert va en
-- su propio bloque y su fallo se traga a proposito. Misma regla que la 108.
-- ---------------------------------------------------------------------
create or replace function public.crear_carro_desde_venta()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $func$
declare
  detalle   jsonb;
  producto  jsonb;
  nuevo_id  bigint;
  arranque  timestamptz;
  nota      text;
  gratis    boolean;
  leido     jsonb;
  devuelve  text;
begin
  detalle  := detalle_venta(new.payload);
  devuelve := nullif(btrim(coalesce(detalle ->> 'refundsPurchaseUuid', '')), '');

  -- --- Devolucion -----------------------------------------------------
  if devuelve is not null or coalesce(new.monto, 0) < 0 then
    if devuelve is not null then
      update public.carros
         set cancelado_en = now()
       where purchase_uuid = devuelve
         and estado <> 'entregado'
         and cancelado_en is null;
    end if;
    return new;
  end if;

  producto := producto_del_vehiculo(new.payload);

  if producto is null then
    return new;
  end if;

  arranque := coalesce(new.recibido_en, new.creado_en, now());

  gratis := coalesce(new.monto, 0) = 0 or coalesce(producto ->> 'name', '') ilike 'gratis%';
  nota   := nota_de_la_venta(new.payload, gratis);
  leido  := interpretar_nota(nota, gratis);

  insert into public.carros (
    venta_id, purchase_uuid, monto, producto, variante, categoria, es_express, creado_en,
    nota, tipo_unidad, color, cliente, datos_de_nota
  )
  values (
    new.id,
    new.purchase_uuid,
    new.monto,
    producto ->> 'name',
    producto ->> 'variantName',
    -- La taxonomia del dueno viaja con el carro.
    nullif(btrim(coalesce(producto -> 'category' ->> 'name', '')), ''),
    es_lavado_express(producto ->> 'name', producto ->> 'variantName'),
    arranque,
    nota,
    leido ->> 'tipo_unidad',
    leido ->> 'color',
    leido ->> 'cliente',
    (leido ->> 'tipo_unidad') is not null
  )
  on conflict (purchase_uuid) do nothing
  returning id into nuevo_id;

  if nuevo_id is not null then
    insert into public.etapas (carro_id, etapa, inicio)
    values (nuevo_id, 'prelavado', arranque);
  end if;

  return new;

exception when others then
  -- La venta SE GUARDA. Lo que falla aqui es el carro, y un carro se puede
  -- recrear a mano desde `ventas.payload` (que ya quedo guardado entero);
  -- una venta perdida no se recupera de ningun lado.
  begin
    insert into public.webhook_bitacora (motivo, evento, crudo)
    values ('trigger_carro_fallo',
            sqlstate || ' ' || sqlerrm,
            left(coalesce(new.payload::text, ''), 20000));
  exception when others then
    null;   -- la bitacora NUNCA tumba una venta
  end;
  return new;
end;
$func$;

comment on function public.crear_carro_desde_venta() is
  'Trigger AFTER INSERT en ventas. Si falla creando el carro NO tumba la venta (111): el error queda en webhook_bitacora con motivo trigger_carro_fallo y el carro se puede recrear desde el payload.';


-- ---------------------------------------------------------------------
-- #25 - el indice que faltaba en asignaciones(empleado_id)
--
-- Tres funciones buscan por empleado y las tres hacian Seq Scan sobre las
-- 2,706 filas: `perfil_de_secador`, `trabajadores` y el auto-join de
-- encimados del reporte. Medido antes: Seq Scan, 43 buffers, 9.2 ms solo en
-- ese paso.
--
-- Se indexa `(empleado_id, carro_id)` y no solo `empleado_id`: las tres
-- consultas piden justo el par (cuales carros son de esta persona), asi que
-- el indice las cubre sin volver a la tabla. Los nulos se quedan fuera —
-- las filas viejas sin empleado_id no se buscan por empleado.
-- ---------------------------------------------------------------------
create index if not exists asignaciones_empleado_idx
  on public.asignaciones (empleado_id, carro_id)
  where empleado_id is not null;


-- ---------------------------------------------------------------------
-- #25 - enlazar_visita_a_carro escribia la placa CRUDA y brincaba el candado
--
-- Dos problemas en el mismo `update`:
--
--   1. Guardaba `v.placa` tal como la tecleo la cajera, mientras que el
--      camino de la foto guarda `normalizar_placa(placa)` en `placa` y lo
--      crudo en `placa_display`. Dos formatos en la misma columna: la misma
--      placa contaria como dos carros en el historial.
--
--   2. No preguntaba por el candado de la 100 (placa repetida el mismo dia).
--      O sea que el camino que SI se salta la proteccion es el de la caja,
--      donde el dato entra a nombre de un cliente con nombre.
--
-- La regla de "esta placa ya esta en otro carro de hoy" pasa a vivir en UNA
-- sola funcion, `placa_repetida_hoy`, que consultan los dos caminos. Estaba
-- escrita dentro de `guardar_datos_de_foto`; copiarla aqui habria sido el
-- error que este proyecto ya cometio varias veces.
-- ---------------------------------------------------------------------
create or replace function public.placa_repetida_hoy(p_carro bigint, p_placa_norm text)
returns boolean
language sql
stable
as $func$
  select exists (
    select 1
    from public.carros c2, public.carros c1
    where p_placa_norm is not null
      and c1.id = p_carro
      and c2.id <> p_carro
      and c2.cancelado_en is null
      and not coalesce(c2.es_prueba, false)
      and c2.placa = p_placa_norm
      and (c2.creado_en at time zone 'America/Tijuana')::date
        = (c1.creado_en at time zone 'America/Tijuana')::date
  );
$func$;

comment on function public.placa_repetida_hoy(bigint, text) is
  'La placa leida/tecleada ya esta en otro carro no cancelado del MISMO dia local? Una sola regla para los dos caminos que escriben placa: la foto (guardar_datos_de_foto) y la caja (enlazar_visita_a_carro). Migracion 100, unificada en la 111.';


create or replace function public.enlazar_visita_a_carro(p_visita bigint, p_carro bigint)
returns jsonb
language plpgsql
as $func$
declare
  v             record;
  v_nombre      text;
  v_sub         text;
  v_tipo        text;
  v_carro_placa text;
  v_raw         text;
  v_norm        text;
  v_choca       boolean := false;
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

    v_raw   := nullif(btrim(upper(coalesce(v.placa, ''))), '');
    v_norm  := public.normalizar_placa(v.placa);
    v_choca := public.placa_repetida_hoy(p_carro, v_norm);

    if v_choca then
      -- Mismo trato que en el camino de la foto: se marca para revisar y no
      -- se ensucia el carro. La marca/submarca tampoco se escriben: si la
      -- placa es de otro carro, lo demas del renglon tambien lo es.
      update public.carros
         set placa_dudosa = coalesce(v_raw, v_norm),
             placa_en     = now()
       where id = p_carro;
    else
      update public.carros set
        placa         = v_norm,
        placa_display = case when v_raw is distinct from v_norm then v_raw else null end,
        placa_dudosa  = null,
        placa_en      = now(),
        marca         = nullif(btrim(upper(coalesce(v.marca, ''))), ''),
        submarca      = v_sub,
        tipo_unidad   = case when v_sub is not null
                             then coalesce(v_tipo, tipo_unidad)
                             else coalesce(tipo_unidad, v_tipo) end
      where id = p_carro;
    end if;
  end if;

  update public.visitas set carro_id = p_carro, enlazada_en = now()
  where id = p_visita;

  -- La venta ya se concreto: se liga la placa al cliente. Si la placa choco,
  -- NO se liga nada: seria pegarle a un cliente el carro de otro, que es el
  -- caso que el candado existe para evitar.
  if v.placa_norm is not null and not v_choca then
    --   * la que TECLEO la cajera -> confirmada (un humano la leyo)
    perform public.ligar_placa_a_persona(v.persona_id, v.placa, 'cajera', true);
  end if;
  --   * la de la FOTO del carro -> sugerida (o confirmada si se corrobora).
  if not v_choca then
    select coalesce(placa_display, placa) into v_carro_placa
      from public.carros where id = p_carro;
    if v_carro_placa is not null then
      perform public.ligar_placa_a_persona(v.persona_id, v_carro_placa, 'foto', false);
    end if;
  end if;

  return jsonb_build_object('ok', true, 'placa_dudosa', v_choca,
                            'lealtad', public.lealtad_de(v.persona_id));
end;
$func$;

comment on function public.enlazar_visita_a_carro(bigint, bigint) is
  'Pega una visita de la caja a su lavado. Guarda la placa NORMALIZADA y respeta el candado de placa repetida del dia (111): antes escribia la placa cruda y se saltaba la proteccion, justo en el camino donde el dato entra a nombre de un cliente.';


-- ---------------------------------------------------------------------
-- #25 - desenlazar_visita borraba lo que ese enlace nunca puso
--
-- Deshacer un enlace tiene que deshacer lo que ESE enlace escribio, ni mas.
-- Borraba dos cosas que casi nunca eran suyas:
--
--   * `cliente` — lo pone la NOTA DE LA CAJERA al crear el carro
--     (`interpretar_nota`), mucho antes de que exista la visita. Un
--     desenlace le borraba el nombre que escribio la cajera en Zettle.
--     Ahora solo se quita si es EXACTAMENTE el nombre que puso este enlace.
--
--   * `foto_path` — casi siempre es la foto que tomo el SUPERVISOR al
--     asignar, no la de la caja. Borrarla deja al carro sin su unica imagen
--     y sin forma de releer la placa. Ahora solo se quita si es la misma
--     ruta que aporto esta visita.
--
-- El resto (placa/marca/submarca) ya venia con su guarda: solo se limpia si
-- la placa del carro sigue siendo la de esta visita.
-- ---------------------------------------------------------------------
create or replace function public.desenlazar_visita(p_visita bigint)
returns jsonb
language plpgsql
as $func$
declare
  v_persona    bigint;
  v_carro      bigint;
  v_placa      text;
  v_placa_norm text;
  v_foto       text;
  v_carro_norm text;
  v_nombre     text;
begin
  select persona_id, carro_id, placa, placa_norm, foto_path
    into v_persona, v_carro, v_placa, v_placa_norm, v_foto
    from public.visitas where id = p_visita;
  if v_persona is null then
    return jsonb_build_object('ok', false, 'error', 'Esa visita no existe');
  end if;

  select nombre into v_nombre from public.personas where id = v_persona;

  -- La placa (de foto) del carro de esta visita, antes de tocar nada.
  if v_carro is not null then
    select public.normalizar_placa(placa) into v_carro_norm
      from public.carros where id = v_carro;
  end if;

  if v_carro is not null then
    -- Lo que este enlace escribio en el renglon del vehiculo.
    update public.carros set
      placa              = null,
      placa_organizacion = null,
      placa_en           = null,
      marca              = null,
      submarca           = null
    where id = v_carro
      and public.normalizar_placa(placa) is not distinct from public.normalizar_placa(v_placa);

    -- El nombre: SOLO si es el que puso este enlace. Si dice otra cosa, lo
    -- escribio la nota de la cajera y no es de nadie mas.
    update public.carros set cliente = null
     where id = v_carro and v_nombre is not null and cliente = v_nombre;

    -- La foto: SOLO si es la que aporto esta visita. La del supervisor se
    -- queda donde esta.
    update public.carros set
      foto_path       = null,
      foto_url        = null,
      foto_url_expira = null
    where id = v_carro and v_foto is not null and foto_path = v_foto;
  end if;

  update public.visitas set carro_id = null, enlazada_en = null
  where id = p_visita;

  -- Placa TECLEADA: soltar su enlace salvo que otra venta real lo use (igual
  -- que la 077).
  if v_placa_norm is not null and not exists (
       select 1 from public.visitas v2
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa' and v2.carro_id is not null
          and v2.placa_norm = v_placa_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_placa_norm;
  end if;

  -- Placa de la FOTO del carro: si quedo como SUGERIDA y ya ninguna otra
  -- visita activa ligada de la persona tiene un carro con esa placa, se
  -- suelta. Las confirmadas no se tocan.
  if v_carro_norm is not null and v_carro_norm is distinct from v_placa_norm and not exists (
       select 1 from public.visitas v2
         join public.carros c2 on c2.id = v2.carro_id
        where v2.persona_id = v_persona and v2.id <> p_visita
          and v2.estado = 'activa'
          and public.normalizar_placa(c2.placa) = v_carro_norm
     ) then
    delete from public.persona_placas
     where persona_id = v_persona and placa_norm = v_carro_norm and not confirmada;
  end if;

  return jsonb_build_object('ok', true, 'lealtad', public.lealtad_de(v_persona));
end;
$func$;

comment on function public.desenlazar_visita(bigint) is
  'Deshace el enlace visita->lavado. Solo borra lo que ESE enlace escribio (111): el nombre se quita si es el que puso el enlace, y la foto solo si es la que aporto la visita — antes se llevaba la foto del supervisor y el cliente de la nota de caja.';


-- ---------------------------------------------------------------------
-- #25 - cerrar_pendientes ya alcanza al carro que entro tarde
--
-- Corre a las 20:30 (dentro de `congelar_reporte`) y solo miraba los carros
-- creados en el dia de HOY. Un carro que entra a las 20:45 no existia
-- todavia cuando corrio, y la corrida de manana ya filtra por el dia de
-- manana: se quedaba abierto para siempre, con el cronometro corriendo y
-- poniendose rojo en la pantalla del supervisor.
--
-- Medido antes de tocar: en toda la historia hay **0** carros entrados
-- despues de las 20:30 y **0** carros abiertos de dias anteriores. O sea que
-- el hueco nunca se ha disparado — pero se destapa solo el dia que el turno
-- se alargue, que es justo lo que el CLAUDE.md §12.1 ya advierte del corte.
--
-- El arreglo es quitar el piso de la ventana: se cierra todo lo que siga
-- abierto y sea anterior al fin del dia. `cerrados` y `estaban` siguen
-- contando lo mismo para un dia normal (donde no hay rezagados), asi que el
-- numero del reporte no cambia de significado.
-- ---------------------------------------------------------------------
create or replace function public.cerrar_pendientes(p_fecha date default null)
returns jsonb
language plpgsql
as $func$
declare
  dia      date;
  termina  timestamptz;
  cerrados int;
  detalle  jsonb;
begin
  dia := coalesce(p_fecha, (now() at time zone 'America/Tijuana')::date);
  termina := ((dia::text || ' 00:00:00')::timestamp at time zone 'America/Tijuana')
             + interval '1 day';

  -- Que quedaba abierto y en que etapa. Se guarda ANTES de cerrarlos,
  -- porque despues todos diran 'entregado'.
  select coalesce(jsonb_object_agg(estado, cuantos), '{}'::jsonb)
    into detalle
    from (
      select estado, count(*)::int as cuantos
        from public.carros
       where not es_prueba
         and cancelado_en is null
         and estado <> 'entregado'
         and creado_en < termina
       group by estado
    ) x;

  -- Cerrar las etapas abiertas. segundos es columna generada, asi que se
  -- calcula solo al poner fin.
  update public.etapas e
     set fin = now()
   where e.fin is null
     and e.carro_id in (
       select c.id from public.carros c
        where not c.es_prueba
          and c.cancelado_en is null
          and c.estado <> 'entregado'
          and c.creado_en < termina
     );

  update public.carros
     set estado = 'entregado',
         entregado_en = now(),
         cerrado_automaticamente = now()
   where not es_prueba
     and cancelado_en is null
     and estado <> 'entregado'
     and creado_en < termina;

  get diagnostics cerrados = row_count;

  -- Las asignaciones tambien se cierran, igual que en una entrega normal
  -- (migracion 030). Si no, quedarian abiertas para siempre.
  update public.asignaciones a
     set fin = now()
   where a.fin is null
     and a.carro_id in (
       select c.id from public.carros c
        where c.cerrado_automaticamente is not null
          and c.creado_en < termina
     );

  return jsonb_build_object('ok', true, 'fecha', dia, 'cerrados', cerrados, 'estaban', detalle);
end;
$func$;

comment on function public.cerrar_pendientes(date) is
  'Cierra lo que quedo abierto, antes de congelar el reporte. Sin piso de ventana (111): un carro creado DESPUES del corte de las 20:30 se quedaba abierto para siempre porque la corrida del dia siguiente ya no lo miraba.';


-- ---------------------------------------------------------------------
-- Y guardar_datos_de_foto le pregunta a la MISMA funcion
--
-- Sin esto, la regla de "placa repetida el mismo dia" quedaria escrita en
-- dos lugares: aqui y en `enlazar_visita_a_carro`. Es exactamente el patron
-- que la auditoria conto seis veces (la misma regla que diverge en
-- silencio), y no tiene caso arreglarlo de un lado creandolo del otro.
--
-- El cuerpo es el de la 109 sin un solo cambio de comportamiento: solo se
-- reemplaza el `select exists (...)` inline por la llamada.
-- ---------------------------------------------------------------------
create or replace function public.guardar_datos_de_foto(
  p_carro    bigint,
  p_placa    text default null,
  p_org      text default null,
  p_marca    text default null,
  p_submarca text default null,
  p_tipo     text default null
) returns jsonb
language plpgsql
as $func$
declare
  nueva_marca    text;
  nueva_submarca text;
  tipo_limpio    text;
  v_raw          text;
  v_norm         text;
  v_placa_vieja  text;
  v_otro_carro   boolean := false;
  v_colision     boolean := false;
  r              record;
begin
  nueva_marca    := nullif(btrim(upper(coalesce(p_marca, ''))), '');
  nueva_submarca := nullif(btrim(upper(coalesce(p_submarca, ''))), '');

  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;
  end if;

  v_raw  := nullif(btrim(upper(coalesce(p_placa, ''))), '');
  v_norm := public.normalizar_placa(p_placa);

  select placa into v_placa_vieja from public.carros where id = p_carro;

  -- La lectura nueva es de OTRO carro: lo guardado no es de este vehiculo y
  -- se reemplaza entero (regla 2 de la 109).
  v_otro_carro := (v_norm is not null
                   and v_placa_vieja is not null
                   and v_norm is distinct from v_placa_vieja);

  -- Una sola regla, la de la 111.
  v_colision := public.placa_repetida_hoy(p_carro, v_norm);

  if v_colision then
    -- Choque: se marca para revision, no se ensucia el carro.
    update public.carros
       set placa_dudosa = coalesce(v_raw, v_norm),
           placa_en     = now()
     where id = p_carro;
  else
    update public.carros set
      -- La placa se escribe cuando se leyo. Una lectura muda no la borra.
      placa              = coalesce(v_norm, placa),
      placa_display      = case
                             when v_norm is not null
                               then case when v_raw is distinct from v_norm then v_raw else null end
                             else placa_display
                           end,
      -- La organizacion pertenece a la lectura de la placa: se escribe (y se
      -- limpia) junto con ella, nunca por su cuenta.
      placa_organizacion = case
                             when v_norm is not null
                               then nullif(btrim(coalesce(p_org, '')), '')
                             else placa_organizacion
                           end,
      placa_dudosa       = case when v_norm is not null then null else placa_dudosa end,
      placa_en           = now(),
      marca              = case when v_otro_carro then nueva_marca
                                else coalesce(nueva_marca, marca) end,
      submarca           = case when v_otro_carro then nueva_submarca
                                else coalesce(nueva_submarca, submarca) end,
      tipo_unidad        = case
                             when nueva_submarca is not null
                               then coalesce(tipo_limpio, tipo_unidad)
                             else coalesce(tipo_unidad, tipo_limpio)
                           end
    where id = p_carro;
  end if;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- Ligar la placa al cliente SOLO si no hubo choque.
  if v_norm is not null and not v_colision then
    for r in select persona_id from public.visitas
              where carro_id = p_carro and estado = 'activa' and persona_id is not null loop
      perform public.ligar_placa_a_persona(r.persona_id, coalesce(v_raw, v_norm), 'foto', false);
    end loop;
  end if;

  return jsonb_build_object('ok', true, 'placa_dudosa', v_colision);
end;
$func$;
