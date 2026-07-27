-- =====================================================================
-- RUSH — La caja no duplica clientes al crear · 26/jul/2026
--
-- El primer dia de prueba de la caja, la cajera creo un cliente y el boton
-- no dio senal (wifi lento); pico 3 veces mas y quedaron 4 "Luis Gonzalez"
-- identicos. Se arreglo por los dos lados:
--   - Front: candado que bloquea el boton y muestra "Guardando…" al primer
--     toque (caja.html).
--   - Aqui (defensa de fondo): al CREAR, si ya existe una persona con el
--     MISMO nombre normalizado y el MISMO telefono (solo digitos), se
--     devuelve ESA en vez de insertar otra. Cubre el doble-toque aunque el
--     candado del front falle.
--
-- Ojo: el guardia solo aplica cuando hay telefono. Dos personas DISTINTAS
-- sin telefono y con el mismo nombre siguen pudiendo crearse (la cajera las
-- distingue); para ese caso la unica defensa es el candado del front. En un
-- programa de lealtad casi siempre se captura el telefono, asi que cubre el
-- caso comun. Editar (p_id no nulo) no cambia.
-- =====================================================================

create or replace function public.upsert_persona(
  p_id       bigint default null,
  p_nombre   text   default null,
  p_telefono text   default null,
  p_notas    text   default null
) returns jsonb language plpgsql as $$
declare
  v_id  bigint;
  v_tel text;
begin
  if nullif(btrim(coalesce(p_nombre, '')), '') is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el nombre');
  end if;

  if p_id is null then
    -- Telefono normalizado a solo digitos, para que '686-221-2329' y
    -- '6862212329' cuenten como el mismo.
    v_tel := nullif(regexp_replace(coalesce(p_telefono, ''), '\D', '', 'g'), '');

    -- Anti-duplicado: mismo nombre + mismo telefono -> es la misma persona.
    if v_tel is not null then
      select id into v_id
        from public.personas
       where nombre_norm = public.normalizar_nombre(p_nombre)
         and regexp_replace(coalesce(telefono, ''), '\D', '', 'g') = v_tel
       order by id
       limit 1;
    end if;

    if v_id is null then
      insert into public.personas (nombre, nombre_norm, telefono, notas)
      values (btrim(p_nombre), public.normalizar_nombre(p_nombre),
              nullif(btrim(coalesce(p_telefono, '')), ''), nullif(btrim(coalesce(p_notas, '')), ''))
      returning id into v_id;
    end if;
  else
    update public.personas set
      nombre      = btrim(p_nombre),
      nombre_norm = public.normalizar_nombre(p_nombre),
      telefono    = nullif(btrim(coalesce(p_telefono, '')), ''),
      notas       = nullif(btrim(coalesce(p_notas, '')), ''),
      actualizado_en = now()
    where id = p_id
    returning id into v_id;
    if v_id is null then
      return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
    end if;
  end if;

  return jsonb_build_object('ok', true, 'persona', public.persona_json(v_id));
end;
$$;
