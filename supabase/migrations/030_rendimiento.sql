-- =====================================================================
-- RUSH Car Wash — que aguante 150-200 carros al dia
--
-- El dueno lo pidio explicito el 19/jul/2026: "en un buen dia podemos
-- lavar de 150 a 200 carros... debe de poder aguantar esa cantidad".
--
-- Se midio y habia un problema de verdad, introducido ese mismo dia:
--
--   asignaciones con fin NULL ................ 63
--   de esas, de carros YA ENTREGADOS ......... 62
--
-- /cola pide TODAS las asignaciones abiertas cada 3 segundos (para saber
-- quien seca cada carro). Como la entrega normal nunca cerraba la
-- asignacion, la lista solo crecia: con 200 carros al dia son ~400 filas
-- nuevas diarias que nunca se cierran. En un mes serian ~12,000 filas
-- viajando al telefono cada 3 segundos, todo el dia.
--
-- Se ataca en la raiz (cerrar al entregar) y no solo filtrando en la
-- consulta: si solo se filtrara, la tabla seguiria creciendo con basura.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Entregar CIERRA la asignacion
--
-- Es ademas lo correcto semanticamente: la asignacion de esa persona a
-- ese carro termino cuando el carro se entrego. Que quedara abierta para
-- siempre era un descuido desde la migracion 006.
-- ---------------------------------------------------------------------
create or replace function public.avanzar_etapa(p_carro bigint)
returns jsonb
language plpgsql
as $$
declare
  actual   text;
  efectiva text;
begin
  select estado into actual from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  efectiva := etapa_efectiva(actual);

  if efectiva = 'entregado' then
    return jsonb_build_object('ok', false, 'error', 'El carro ya fue entregado');
  end if;

  if efectiva = 'prelavado' then
    return jsonb_build_object('ok', false, 'error', 'Primero asignale linea y secador');
  end if;

  update public.etapas set fin = now() where carro_id = p_carro and fin is null;

  -- Aqui esta el arreglo: la asignacion termina con la entrega.
  update public.asignaciones set fin = now()
   where carro_id = p_carro and fin is null;

  update public.carros
     set estado = 'entregado',
         entregado_en = now()
   where id = p_carro;

  return jsonb_build_object('ok', true, 'estado', 'entregado');
end;
$$;

-- ---------------------------------------------------------------------
-- Restaurar vuelve a abrirla
--
-- Si no, un carro restaurado desde "Entregados" volveria a la cola SIN
-- secadores: la pantalla de confirmar entrega diria "Sin secador
-- registrado" y el rechazo no se podria ligar a nadie.
--
-- Se reabre el ultimo lote (el mismo inicio), que son justo las personas
-- que lo estaban secando cuando se entrego.
-- ---------------------------------------------------------------------
create or replace function public.regresar_etapa(p_carro bigint)
returns jsonb
language plpgsql
as $$
declare
  actual        text;
  inicio_secado timestamptz;
begin
  select estado into actual from public.carros where id = p_carro for update;

  if actual is null then
    return jsonb_build_object('ok', false, 'error', 'Ese carro no existe');
  end if;

  -- --- entregado -> secando ------------------------------------------
  if actual = 'entregado' then
    update public.carros set estado = 'secando', entregado_en = null where id = p_carro;

    update public.etapas set fin = null
     where id = (select id from public.etapas
                  where carro_id = p_carro and etapa = 'secando'
                  order by inicio desc limit 1);

    update public.asignaciones set fin = null
     where carro_id = p_carro
       and inicio = (select max(inicio) from public.asignaciones where carro_id = p_carro);

    return jsonb_build_object('ok', true, 'estado', 'secando');
  end if;

  -- --- secando -> prelavado (deshacer la asignacion) ------------------
  if actual = 'secando' then
    select inicio into inicio_secado
      from public.etapas
     where carro_id = p_carro and etapa = 'secando' and fin is null
     order by inicio desc limit 1;

    delete from public.etapas where carro_id = p_carro and fin is null;

    -- La fila de tunel FABRICADA en esa asignacion: se reconoce porque
    -- termina exactamente cuando empezo el secado. Un tunel medido de
    -- verdad (flujo viejo) tenia un 'por_asignar' en medio y sobrevive.
    if inicio_secado is not null then
      delete from public.etapas
       where carro_id = p_carro and etapa = 'tunel' and fin = inicio_secado;
    end if;

    update public.asignaciones set fin = now()
     where carro_id = p_carro and fin is null;

    update public.carros set estado = 'prelavado', linea = null where id = p_carro;

    update public.etapas set fin = null
     where id = (select id from public.etapas
                  where carro_id = p_carro and etapa = 'prelavado'
                  order by inicio desc limit 1);

    return jsonb_build_object('ok', true, 'estado', 'prelavado');
  end if;

  return jsonb_build_object('ok', false, 'error', 'El carro apenas va empezando');
end;
$$;

-- ---------------------------------------------------------------------
-- Cerrar las 62 que quedaron abiertas
--
-- Se les pone la hora de entrega del carro, no now(): asi el dato queda
-- correcto y no aparecen 62 asignaciones que "duraron todo el dia".
-- ---------------------------------------------------------------------
update public.asignaciones a
   set fin = c.entregado_en
  from public.carros c
 where c.id = a.carro_id
   and a.fin is null
   and c.estado = 'entregado'
   and c.entregado_en is not null;

-- ---------------------------------------------------------------------
-- Indices para el dia pesado
-- ---------------------------------------------------------------------

-- /entregados ordena por esto. Sin indice, con 200 carros al dia ordena
-- la tabla completa cada vez que el supervisor abre la lista.
create index if not exists carros_entregado_en_idx
  on public.carros (entregado_en desc) where estado = 'entregado';

-- El indice parcial hace la consulta de /cola barata sin importar cuantas
-- asignaciones cerradas se acumulen con los años.
create index if not exists asignaciones_abiertas_idx
  on public.asignaciones (carro_id) where fin is null;

-- El reporte agrupa las etapas de secado por carro.
create index if not exists etapas_secando_idx
  on public.etapas (carro_id) where etapa = 'secando';
