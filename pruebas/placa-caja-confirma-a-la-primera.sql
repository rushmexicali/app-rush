-- La politica de placa <-> cliente del dueno, comprobada contra la base real.
--
--   * Las visitas hechas DESDE NUESTRO PROGRAMA DE CAJA se confirman A LA
--     PRIMERA. El cliente esta enfrente, la cajera lo escoge por su nombre y la
--     camara fotografia ESE carro en ese momento: la asociacion se presencia,
--     no se infiere.
--   * En el IMPORT del ClientNoteTracker hace falta la MISMA placa en 2+ carros
--     distintos del cliente. Ahi el vinculo se infiere de una foto que se pudo
--     haber pegado al carro equivocado -- y una foto mal pegada tambien produce
--     una sola coincidencia. Es la regla de "1000% o nada" (dueno, 5/ago y
--     reafirmada el 24/ago/2026).
--
-- ⚠️ Lo que hace que la primera regla funcione es SUTIL y por eso hay que
-- probarlo: `registrar_visita_con_carro` guarda la placa en `visitas.placa`
-- ANTES de ligarla, `visitas.placa_norm` es columna GENERADA sobre esa, y
-- `ligar_placa_a_persona` confirma cuando "la persona ya trae esta placa en
-- alguna visita". O sea que la caja confirma por un camino INDIRECTO: llama con
-- `p_confirmar := false` y aun asi queda confirmada. Si alguien cambia el orden
-- de esas dos escrituras, la regla del dueno se rompe EN SILENCIO.
--
-- Corre contra la base real y REVIERTE TODO con el raise final.
--
--   bash scripts/releer-fotos/q.sh pruebas/placa-caja-confirma-a-la-primera.sql
--
do $$
declare
  v_venta   bigint;
  v_persona bigint;
  v_carro   bigint;
  r         jsonb;
  v_conf    boolean;
  v_origen  text;
  v_cuantas int;
  v_placa   text := 'ZZTEST' || (extract(epoch from now())::bigint % 100000);
  v_msg     text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;

  insert into public.personas (nombre, origen)
  values ('ZZ PRUEBA CAJA CONFIRMA', 'caja')
  returning id into v_persona;

  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en, estado, es_prueba)
  values
    ('prueba-caja-conf-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now(), 'prelavado', false)   -- registrar_visita_con_carro rechaza es_prueba; todo revierte igual
  returning id into v_carro;

  -- Asi llama la caja: con la foto de la camara, la placa que LEYO la camara
  -- (no tecleada: ese boton se quito el 15/ago) y hubo_lectura = true.
  r := public.registrar_visita_con_carro(
         p_persona       := v_persona,
         p_carro         := v_carro,
         p_usa_gratis    := false,
         p_caja          := 'principal',
         p_foto_path     := '2026-08-24/prueba-caja-conf.jpg',
         p_placa         := v_placa,
         p_marca         := 'TOYOTA',
         p_submarca      := 'COROLLA',
         p_tipo          := 'automovil',
         p_hubo_lectura  := true);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: la caja rechazo la visita -> %', r->>'error';
  end if;

  select count(*) into v_cuantas from public.persona_placas where persona_id = v_persona;
  if v_cuantas <> 1 then
    raise exception 'FALLA: se esperaba 1 placa ligada y hay %', v_cuantas;
  end if;

  select confirmada, origen into v_conf, v_origen
    from public.persona_placas where persona_id = v_persona;

  if not v_conf then
    raise exception 'FALLA: la caja NO confirmo a la primera (confirmada=%, origen=%). Hay que arreglarlo.',
                    v_conf, v_origen;
  end if;

  v_msg := 'la caja confirma a la primera OK (origen=' || coalesce(v_origen,'?') || '). ';

  -- Y el control: UN SOLO carro del import (sin visita en vivo que traiga la
  -- placa tecleada) NO debe confirmar. Es la regla de "2+ carros".
  declare
    v_p2 bigint; v_c2 bigint; v_conf2 boolean;
  begin
    insert into public.personas (nombre, origen)
    values ('ZZ PRUEBA IMPORT UNA SOLA', 'import') returning id into v_p2;

    insert into public.carros
      (purchase_uuid, venta_id, producto, variante, monto, creado_en, estado, es_prueba, placa)
    values
      ('prueba-import-1-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
       now(), 'prelavado', true, public.normalizar_placa(v_placa || 'B'))
    returning id into v_c2;

    -- Una visita de IMPORT: sin placa propia (el import no teclea placas).
    insert into public.visitas (persona_id, estado, caja, carro_id, es_gratis, es_cortesia)
    values (v_p2, 'activa', 'import', v_c2, false, false);

    perform public.ligar_placa_a_persona(v_p2, v_placa || 'B', 'foto', false);

    select confirmada into v_conf2 from public.persona_placas where persona_id = v_p2;
    if v_conf2 is null then
      raise exception 'FALLA (control): no se creo el enlace del import';
    end if;
    if v_conf2 then
      raise exception 'FALLA (control): el import confirmo con UN SOLO carro, y necesita 2+';
    end if;
    v_msg := v_msg || 'el import con un solo carro NO confirma OK. ';
  end;

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
