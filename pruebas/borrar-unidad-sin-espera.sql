-- =====================================================================
-- "BORRAR UNIDAD" SIN ESPERA (migracion 144)
--
-- El dueno quito los umbrales de tiempo el 31/ago/2026. Esta prueba fija lo
-- que SI se tiene que seguir cumpliendo, que es lo que queda de proteccion.
-- Todo revierte: termina en `raise`.
-- =====================================================================
do $$
declare
  v_venta bigint; v_carro bigint; r jsonb; ok text := ''; malos text := '';

begin
  select id into v_venta from public.ventas order by id desc limit 1;

  -- ---- 1. Un carro RECIEN entrado ya se puede borrar ---------------
  -- Antes habia que esperar 30 minutos. Ese es justo el cambio.
  declare m text := '';
  begin
    insert into public.carros (venta_id, purchase_uuid, producto, variante, categoria, monto, estado)
    values (v_venta, gen_random_uuid()::text, 'Completo RUSH', 'Chico', 'Paquetes', 270, 'prelavado')
    returning id into v_carro;
    r := public.borrar_unidad(v_carro);
    if coalesce((r->>'ok')::boolean,false) is not true then
      m := m || ' un carro recien entrado NO se pudo borrar: ' || coalesce(r->>'error','?');
    end if;
    malos := malos || m;
    if m = '' then ok := ok || 'recien entrado se borra OK. '; end if;
  end;

  -- ---- 2. Y NO borra la fila: se puede deshacer ---------------------
  declare m2 text := ''; v_cancel timestamptz; v_ent timestamptz; v_prod text;
  begin
    select cancelado_en, entregado_en, producto into v_cancel, v_ent, v_prod
      from public.carros where id = v_carro;
    if v_cancel is null then m2 := m2 || ' no quedo cancelado'; end if;
    if v_ent is not null then m2 := m2 || ' le puso hora de salida'; end if;
    if v_prod is distinct from 'Completo RUSH' then m2 := m2 || ' perdio el producto'; end if;
    if not exists (select 1 from public.carros
                    where id=v_carro and cancelado_motivo='borrado_supervisor') then
      m2 := m2 || ' no quedo marcado como borrado_supervisor';
    end if;
    malos := malos || m2;
    if m2 = '' then ok := ok || 'conserva la fila y no pone salida OK. '; end if;
  end;

  -- ---- 3. Es idempotente -------------------------------------------
  declare m3 text := '';
  begin
    r := public.borrar_unidad(v_carro);
    if coalesce((r->>'ok')::boolean,false) is not true or coalesce((r->>'ya_estaba')::boolean,false) is not true then
      m3 := m3 || ' borrarlo dos veces no contesta ya_estaba';
    end if;
    malos := malos || m3;
    if m3 = '' then ok := ok || 'idempotente OK. '; end if;
  end;

  -- ---- 4. Un carro ENTREGADO no se borra por aqui -------------------
  -- Es el unico candado que queda y el que impide sacar del reporte un
  -- lavado ya cerrado. Para eso esta "Restaurar" en Finalizados.
  declare m4 text := ''; v_c2 bigint;
  begin
    insert into public.carros (venta_id, purchase_uuid, producto, variante, categoria, monto, estado, entregado_en)
    values (v_venta, gen_random_uuid()::text, 'Completo RUSH', 'Chico', 'Paquetes', 270, 'entregado', now())
    returning id into v_c2;
    r := public.borrar_unidad(v_c2);
    if coalesce((r->>'ok')::boolean,true) then m4 := m4 || ' dejo borrar un entregado'; end if;
    malos := malos || m4;
    if m4 = '' then ok := ok || 'un entregado NO se borra OK. '; end if;
  end;

  -- ---- 5. Un carro que no existe contesta, no truena ----------------
  declare m5 text := '';
  begin
    r := public.borrar_unidad(-1);
    if coalesce((r->>'ok')::boolean,true) then m5 := m5 || ' un id inexistente dijo ok'; end if;
    malos := malos || m5;
    if m5 = '' then ok := ok || 'id inexistente contesta OK. '; end if;
  end;

  -- ---- 6. Secando recien asignado tambien se borra ------------------
  declare m6 text := ''; v_c3 bigint;
  begin
    insert into public.carros (venta_id, purchase_uuid, producto, variante, categoria, monto, estado)
    values (v_venta, gen_random_uuid()::text, 'Completo RUSH', 'Chico', 'Paquetes', 270, 'secando')
    returning id into v_c3;
    insert into public.etapas (carro_id, etapa, inicio) values (v_c3, 'secando', now());
    r := public.borrar_unidad(v_c3);
    if coalesce((r->>'ok')::boolean,false) is not true then
      m6 := m6 || ' secando recien asignado no se pudo borrar: ' || coalesce(r->>'error','?');
    end if;
    malos := malos || m6;
    if m6 = '' then ok := ok || 'secando recien asignado se borra OK. '; end if;
  end;

  if malos <> '' then raise exception 'PRUEBA FALLIDA ->%', malos; end if;
  raise exception 'PRUEBA PASADA -> %', ok;
end $$;
