-- =====================================================================
-- 103 — La foto de la caja SÍ se le pega a su carro.
--
-- Al quitar la pantalla de enlazar (migración 101) se perdió sin querer lo
-- que hacía `enlazar_visita_a_carro`: pasarle al carro la foto y lo que la
-- cámara de la caja alcanzó a leer. La foto quedaba huérfana en Storage y el
-- carro llegaba a la cola del supervisor sin foto y sin placa, aunque la caja
-- ya lo hubiera fotografiado. Eso desperdiciaba justo la cámara de la entrada.
--
-- 🔑 Y la parte importante, que viene del dueño (15/ago/2026):
--
--    "Los carros de Mexicali tienden a llegar muchas pickup muy grandes como
--     las Tundra, lo cual hace que no se aprecie bien la placa. Una vez que se
--     tome la placa y no se pueda leer correctamente, se debe proceder
--     normalmente con el registro. No le avises a la cajera que hay que
--     retomar foto, ya que es imposible decirle al cliente que se haga para
--     adelante: ya no estaría a la altura de la ventana de la caja para poder
--     cobrar. Al momento de asignar a fila y secador, ahí se le pedirá de
--     nuevo la foto al supervisor si no se pudo concretar bien la lectura."
--
-- O sea: la caja NUNCA se traba ni regaña, y el segundo intento se hace donde
-- el carro sí se deja fotografiar bien — en el patio, al asignarlo.
--
-- Medido antes de escribir esto: del 4 al 14/ago hubo **65 carros con foto y
-- sin placa** (~6 por día, 9%). A ninguno se le volvió a intentar, porque la
-- app da el requisito de foto por cumplido en cuanto existe una foto — sin
-- fijarse en si sirvió para leer la placa. Ese es el hueco que esto cierra
-- junto con el cambio del front.
-- =====================================================================
-- ⚠️ Se BORRA la firma vieja de 4 parámetros antes de crear la nueva. Con
-- `create or replace` quedarían las DOS (distinta firma = otra función), y como
-- los parámetros nuevos tienen valor por omisión, una llamada de 4 argumentos
-- sería ambigua y Postgres la rechazaría. Es la misma trampa que ya se pisó con
-- `editar_carro` en la migración 052.
drop function if exists public.registrar_visita_con_carro(bigint, bigint, boolean, text);

create or replace function public.registrar_visita_con_carro(
  p_persona    bigint,
  p_carro      bigint,
  p_usa_gratis boolean default false,
  p_caja       text    default 'principal',
  -- Lo que la cámara de la caja alcanzó a sacar. Todo opcional: la visita se
  -- registra igual sin nada de esto.
  p_foto_path  text    default null,
  p_placa      text    default null,
  p_marca      text    default null,
  p_submarca   text    default null,
  p_tipo       text    default null
) returns jsonb language plpgsql as $$
declare
  c        record;
  v_clase  text;
  v_gratis boolean;
  v_cort   boolean;
  v_id     bigint;
  v_foto   text;
  v_dudosa boolean := false;
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

  v_foto := nullif(btrim(coalesce(p_foto_path,'')),'');

  insert into public.visitas
    (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, carro_id, enlazada_en,
     placa, marca, submarca, tipo_unidad, foto_path)
  values
    (p_persona, v_gratis, v_cort, 'activa',
     coalesce(nullif(btrim(p_caja),''),'principal'), false, p_carro, now(),
     nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     v_foto)
  returning id into v_id;

  update public.carros
     set cliente = coalesce((select nombre from public.personas where id = p_persona), cliente)
   where id = p_carro;

  -- La foto de la caja pasa a ser la del carro, para que el supervisor la vea
  -- en la cola. Solo si el carro no trae ya una (no se pisa la del supervisor).
  if v_foto is not null then
    update public.carros
       set foto_path       = v_foto,
           foto_url        = null,
           foto_url_expira = null
     where id = p_carro and foto_path is null;
  end if;

  -- Lo que la cámara leyó se guarda con la MISMA función que usa el supervisor
  -- (`guardar_datos_de_foto`), no con una copia: ahí vive el candado de la
  -- placa repetida del día (migración 100) y el ligado placa→cliente. Tener dos
  -- caminos para lo mismo es el error que este proyecto ya cometió tres veces.
  --
  -- Se llama SOLO si de verdad hubo foto. Si la lectura no sacó placa, la
  -- función deja `placa` en nulo y estampa `placa_en`, que es justo la señal de
  -- "se intentó y no se pudo" — la que hace que al asignar se le vuelva a pedir
  -- la foto al supervisor.
  if v_foto is not null then
    select coalesce((public.guardar_datos_de_foto(
             p_carro, p_placa, null, p_marca, p_submarca, p_tipo
           ) ->> 'placa_dudosa')::boolean, false) into v_dudosa;
  end if;

  return jsonb_build_object('ok', true, 'visita', v_id, 'clase', v_clase,
                            'es_gratis', v_gratis, 'es_cortesia', v_cort,
                            'placa_dudosa', v_dudosa,
                            'lealtad', public.lealtad_de(p_persona));
end;
$$;

comment on function public.registrar_visita_con_carro(bigint, bigint, boolean, text, text, text, text, text, text) is
  'Caja: registra la visita, la enlaza a su lavado y le pega la foto/lectura de la camara de la caja. El ticket manda sobre el switch de gratis. Si la placa no se leyo, NO se avisa a la cajera: el segundo intento lo hace el supervisor al asignar.';
