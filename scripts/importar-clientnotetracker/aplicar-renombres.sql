-- =====================================================================
-- APLICA los renombres/fusiones YA AUTORIZADOS por el dueno. Lee public.ren_cand
-- (la produce diff-renombres.sql). Idempotente-ish: reasigna visitas y placas del
-- duplicado al registro que conserva la historia, borra el duplicado, y renombra.
--
-- ⚠️ NO correr sin que el dueno haya revisado ren_cand. Borra filas de personas.
-- Para DRY-RUN: agregar `raise exception 'dry-run ...'` antes del `end $$;`.
--
-- Solo dos tablas referencian personas.id: visitas y persona_placas (ambas se
-- reasignan aqui). Si algun dia hay mas FKs, agregarlas.
-- =====================================================================
do $$
declare
  r record; rc int := 0;
  v_moved int := 0; v_placas int := 0; v_del int := 0; v_ren int := 0;
begin
  for r in select * from public.ren_cand loop
    if r.choca_id is not null and r.choca_id <> r.old_id then
      -- subir 'confirmada' en placas que ambos comparten
      update public.persona_placas o
        set confirmada = o.confirmada or c.confirmada
        from public.persona_placas c
        where o.persona_id = r.old_id and c.persona_id = r.choca_id
          and o.placa_norm = c.placa_norm;
      -- mover placas del duplicado que el bueno no tiene
      update public.persona_placas
        set persona_id = r.old_id
        where persona_id = r.choca_id
          and placa_norm not in (select placa_norm from public.persona_placas where persona_id = r.old_id);
      get diagnostics rc = row_count; v_placas := v_placas + rc;
      delete from public.persona_placas where persona_id = r.choca_id;
      -- mover visitas del duplicado al bueno
      update public.visitas set persona_id = r.old_id where persona_id = r.choca_id;
      get diagnostics rc = row_count; v_moved := v_moved + rc;
      -- borrar el duplicado (ya sin visitas ni placas)
      delete from public.personas where id = r.choca_id;
      get diagnostics rc = row_count; v_del := v_del + rc;
    end if;
    update public.personas
      set nombre = r.new_nombre, nombre_norm = r.new_norm, actualizado_en = now()
      where id = r.old_id;
    v_ren := v_ren + 1;
  end loop;
  raise notice 'visitas_movidas=% placas_movidas=% duplicados_borrados=% renombrados=%',
    v_moved, v_placas, v_del, v_ren;
end $$;
