-- =====================================================================
-- 100 — Prevención de foto-mal-pegada: no pegar una placa que ya está en otro
-- carro del mismo día.
--
-- Problema (visto el 5/ago con BF-8884-A en 3 carros, uno rojo y dos blancos):
-- la placa se lee de la foto, y a veces sale IGUAL en carros distintos —el
-- supervisor fotografía el carro equivocado, o la IA lee mal una placa parecida
-- (varias Peugeot Partner el mismo rato). Una placa no puede estar en dos carros
-- a la vez el mismo día, así que ese choque es casi seguro un error.
--
-- Arreglo: al guardar la lectura, si esa placa ya está en OTRO carro no cancelado
-- del MISMO día local, NO se escribe en carros.placa (para no ensuciar el
-- historial ni juntar clientes que no van juntos). Se guarda en `placa_dudosa`
-- para revisión, y NO se toca marca/submarca (la foto entera es sospechosa) ni se
-- liga a un cliente. El PRIMER carro que leyó la placa la conserva; los que
-- repiten quedan marcados. Retroactivo NO: esto es solo hacia adelante (los casos
-- viejos se avisan en el perfil de placa).
-- =====================================================================
alter table public.carros add column if not exists placa_dudosa text;

create or replace function public.guardar_datos_de_foto(
  p_carro bigint,
  p_placa text default null,
  p_org text default null,
  p_marca text default null,
  p_submarca text default null,
  p_tipo text default null)
returns jsonb
language plpgsql
as $function$
declare
  nueva_submarca text;
  tipo_limpio    text;
  v_raw          text;
  v_norm         text;
  v_colision     boolean := false;
  r              record;
begin
  nueva_submarca := nullif(btrim(upper(coalesce(p_submarca, ''))), '');

  tipo_limpio := nullif(btrim(coalesce(p_tipo, '')), '');
  if tipo_limpio is not null
     and tipo_limpio not in ('pickup', 'camioneta', 'automovil', 'pasajeros') then
    tipo_limpio := null;
  end if;

  v_raw  := nullif(btrim(upper(coalesce(p_placa, ''))), '');
  v_norm := public.normalizar_placa(p_placa);

  -- ¿La placa leída ya está en otro carro no cancelado del mismo día local?
  if v_norm is not null then
    select exists (
      select 1
      from public.carros c2, public.carros c1
      where c1.id = p_carro
        and c2.id <> p_carro
        and c2.cancelado_en is null
        and not coalesce(c2.es_prueba, false)
        and c2.placa = v_norm
        and (c2.creado_en at time zone 'America/Tijuana')::date
          = (c1.creado_en at time zone 'America/Tijuana')::date
    ) into v_colision;
  end if;

  if v_colision then
    -- Choque: se marca para revisión, no se ensucia el carro.
    update public.carros
       set placa_dudosa = coalesce(v_raw, v_norm),
           placa_en     = now()
     where id = p_carro;
  else
    -- Sin choque: comportamiento de siempre (la foto es autoritativa).
    update public.carros set
      placa              = v_norm,
      placa_display      = case when v_raw is distinct from v_norm then v_raw else null end,
      placa_dudosa       = null,
      placa_organizacion = nullif(btrim(coalesce(p_org, '')), ''),
      placa_en           = now(),
      marca              = nullif(btrim(upper(coalesce(p_marca, ''))), ''),
      submarca           = nueva_submarca,
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
$function$;
