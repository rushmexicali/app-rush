-- =====================================================================
-- 084 — "Borrar unidad" tambien para carros con 2h+ SECANDO
--
-- Un carro que lleva 2 horas o mas "secando" no se esta secando: es un
-- olvido, igual que uno sin asignar. Nadie tarda 2 h en secar un carro. Su
-- tiempo de secado es basura y no debe entrar a los promedios ni al conteo.
-- El dueno pidio (29/jul/2026) que el mismo boton de borrar aplique ahi.
--
-- Se amplia borrar_unidad (083) para aceptar DOS casos, cada uno con su
-- propio candado de tiempo. El mecanismo es el mismo: cancelado_en +
-- cancelado_motivo='borrado_supervisor'. NO se tocan las etapas ni las
-- asignaciones (quien lo estaba secando queda registrado); cancelado_en ya
-- lo excluye de /cola y del reporte, y entregado_en nunca se toca.
--
--   estado prelavado -> 30 min sin asignar   (como en la 083)
--   estado secando   -> 2 h desde que arranco la etapa de secado abierta
--
-- El "2 h secando" se mide desde el inicio de la etapa 'secando' ABIERTA
-- (fin is null) — el mismo dato que el reloj de la tarjeta cuenta en vivo.
-- =====================================================================

create or replace function public.borrar_unidad(p_carro bigint)
returns jsonb
language plpgsql
as $function$
declare
  c   public.carros%rowtype;
  ini timestamptz;
begin
  select * into c from public.carros where id = p_carro for update;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no existe el carro');
  end if;

  -- Idempotente: si ya salio de la cola, no es un error volver a pedirlo.
  if c.cancelado_en is not null then
    return jsonb_build_object('ok', true, 'carro', p_carro, 'ya_estaba', true);
  end if;

  if c.estado = 'prelavado' then
    -- Sin asignar arranca en prelavado al crearse: tiempo sin asignar = now()-creado_en.
    if now() - c.creado_en < interval '30 minutes' then
      return jsonb_build_object('ok', false,
        'error', 'La unidad debe llevar 30 min sin asignar');
    end if;

  elsif c.estado = 'secando' then
    -- Inicio de la etapa de secado ABIERTA (la que cuenta el reloj).
    select e.inicio into ini
      from public.etapas e
     where e.carro_id = p_carro
       and e.etapa = 'secando'
       and e.fin is null
     order by e.inicio desc
     limit 1;

    if ini is null or now() - ini < interval '2 hours' then
      return jsonb_build_object('ok', false,
        'error', 'La unidad debe llevar 2 h secando');
    end if;

  else
    return jsonb_build_object('ok', false,
      'error', 'Solo se puede borrar una unidad sin asignar, o con 2 h secando');
  end if;

  update public.carros
     set cancelado_en = now(),
         cancelado_motivo = 'borrado_supervisor'
   where id = p_carro;

  return jsonb_build_object('ok', true, 'carro', p_carro);
end;
$function$;

comment on function public.borrar_unidad(bigint) is
  'Saca de la cola por basura: carro SIN ASIGNAR (prelavado, 30+ min) o con '
  '2 h+ SECANDO (olvido). Pone cancelado_en + cancelado_motivo=borrado_supervisor. '
  'No toca entregado_en, etapas ni asignaciones. Reversible con cancelado_en=null.';
