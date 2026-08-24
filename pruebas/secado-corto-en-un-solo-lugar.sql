-- Prueba de la migracion 133:
--
--   La regla de "un secado de menos de 3 min es un olvido, no trabajo" vive
--   en UN solo lugar (segundos_minimos_de_secado), y el desglose del carro
--   por fin la dice en vez de presentar el numero como si fuera medido.
--
-- Corre contra la base real y REVIERTE TODO con el raise final.
--
--   bash scripts/releer-fotos/q.sh pruebas/secado-corto-en-un-solo-lugar.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta bigint;
  c_corto bigint;   -- entregado con 60 s de secado: un olvido
  c_bueno bigint;   -- entregado con 25 min: trabajo de verdad
  c_vivo  bigint;   -- todavia secando, con una etapa corta cerrada
  v_min   int;
  v_n     int;
  d       jsonb;
  v_msg   text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;

  -- ==================================================================
  -- 1) LA REGLA VIVE EN UN SOLO LUGAR
  --    Esta es la parte que evita que el problema vuelva. Si alguien
  --    escribe el 180 a mano otra vez -- que es como llego a estar en dos
  --    lugares -- esta prueba lo caza.
  -- ==================================================================
  v_min := public.segundos_minimos_de_secado();
  if v_min <> 180 then
    raise exception 'FALLA: la regla dice % s y se esperaban 180', v_min;
  end if;

  select count(*) into v_n
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and p.proname in ('reporte_del_rango', 'perfil_de_secador', 'detalle_del_carro')
     and pg_get_functiondef(p.oid) like '%180%';
  if v_n > 0 then
    raise exception 'FALLA: % funcion(es) volvieron a escribir el 180 a mano', v_n;
  end if;
  v_msg := v_msg || 'la regla vive en un solo lugar OK. ';

  -- ==================================================================
  -- 2) UN OLVIDO SE DECLARA COMO OLVIDO EN EL DESGLOSE
  -- ==================================================================
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en,
     estado, linea, entregado_en, es_prueba)
  values
    ('prueba-133-corto-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now() - interval '70 minutes', 'entregado', 2, now() - interval '5 minutes', true)
  returning id into c_corto;

  insert into public.etapas (carro_id, etapa, inicio, fin)
  values (c_corto, 'secando', now() - interval '6 minutes', now() - interval '5 minutes' - interval '4 seconds');

  d := public.detalle_del_carro(c_corto);
  if (d->>'secando_seg')::int >= 180 then
    raise exception 'FALLA: el escenario no sirve, el secado salio de % s', d->>'secando_seg';
  end if;
  -- ⚠️ Con `coalesce`, no a secas: si el campo NO VIENE -- que es exactamente
  -- como estaba antes de la 133 -- `(null)::boolean` hace que el `if` no
  -- dispare y la prueba pasaria sin medir nada. Un campo ausente tiene que
  -- fallar igual que un `false`.
  if not coalesce((d->>'secado_corto')::boolean, false) then
    raise exception 'FALLA: un secado de % s no se declaro como olvido (secado_corto = %)',
                    d->>'secando_seg', coalesce(d->>'secado_corto', '(no viene)');
  end if;
  v_msg := v_msg || 'el olvido se declara OK. ';

  -- ==================================================================
  -- 3) UN SECADO DE VERDAD NO SE DECLARA COMO OLVIDO
  --    (una prueba que solo mira el caso malo no sirve: hay que comprobar
  --    que no grita de mas, o la pantalla se llenaria de avisos falsos)
  -- ==================================================================
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en,
     estado, linea, entregado_en, es_prueba)
  values
    ('prueba-133-bueno-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now() - interval '70 minutes', 'entregado', 2, now() - interval '5 minutes', true)
  returning id into c_bueno;

  insert into public.etapas (carro_id, etapa, inicio, fin)
  values (c_bueno, 'secando', now() - interval '30 minutes', now() - interval '5 minutes');

  d := public.detalle_del_carro(c_bueno);
  if (d->>'secado_corto')::boolean then
    raise exception 'FALLA: un secado de % s se declaro olvido', d->>'secando_seg';
  end if;
  v_msg := v_msg || 'un secado bueno no se declara OK. ';

  -- ==================================================================
  -- 4) UN CARRO QUE TODAVIA SE TRABAJA NUNCA SE DECLARA OLVIDO
  --    Su secado esta corriendo y el desglose lo muestra "en curso";
  --    llamarle olvido a un carro que apenas arranca seria mentir al reves.
  -- ==================================================================
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en,
     estado, linea, es_prueba)
  values
    ('prueba-133-vivo-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now() - interval '40 minutes', 'secando', 2, true)
  returning id into c_vivo;

  -- Una etapa corta ya cerrada (paso por un Regresar) mas la que corre.
  insert into public.etapas (carro_id, etapa, inicio, fin)
  values (c_vivo, 'secando', now() - interval '20 minutes', now() - interval '20 minutes' + interval '30 seconds');
  insert into public.etapas (carro_id, etapa, inicio)
  values (c_vivo, 'secando', now() - interval '19 minutes');

  d := public.detalle_del_carro(c_vivo);
  if (d->>'secado_corto')::boolean then
    raise exception 'FALLA: un carro que sigue secando se declaro olvido';
  end if;
  v_msg := v_msg || 'el que sigue secando no se declara OK. ';

  -- ==================================================================
  -- 5) Y EL REPORTE SIGUE CONTANDOLO DONDE SIEMPRE
  --    El desglose y el reporte tienen que decir lo mismo del mismo carro:
  --    ese era el hallazgo.
  -- ==================================================================
  -- El carro corto es es_prueba, asi que no entra al reporte. Se le quita la
  -- marca solo para esta comprobacion (todo se revierte con el raise final).
  update public.carros set es_prueba = false where id = c_corto;

  select (public.reporte_del_rango(
            (now() at time zone 'America/Tijuana')::date,
            (now() at time zone 'America/Tijuana')::date
          )->>'secados_descartados')::int
    into v_n;
  if v_n < 1 then
    raise exception 'FALLA: el reporte no conto el secado corto (secados_descartados = %)', v_n;
  end if;
  v_msg := v_msg || 'el reporte y el desglose dicen lo mismo OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end
$$;
