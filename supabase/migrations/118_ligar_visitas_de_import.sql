-- =====================================================================
-- 118 - El ligado del import vive en UNA sola funcion (y ya no mata al CRM)
--
-- Que paso, en corto: el candado que puso la migracion `114` —un lavado, un
-- cliente— rompio el import del ClientNoteTracker el mismo dia que se aplico.
-- El paso de ligado del import hacia un `update ... set carro_id` sin
-- preguntar si ese carro ya tenia visita activa, chocaba con
-- `visitas_un_lavado_un_cliente`, y como el import es un `do $$` sin
-- manejador, se caia el BLOQUE ENTERO: no entraba ni una sola visita.
--
-- Resultado medido: el CRM paso CINCO DIAS (17 al 21/ago) sin registrar una
-- visita, con 407 lavados sin sello y 50 gratis vendidos sin descontar. El
-- encabezado de la `114` ya decia que al import le faltaba justo esa
-- comprobacion; lo que faltaba era ponersela.
--
-- Por que una FUNCION y no arreglar los scripts: el mismo bloque de ligado
-- estaba COPIADO en `import.sql`, `import-incremental.sql` y el dryrun. Tres
-- copias de la misma regla es exactamente como se desfasan las cosas en este
-- proyecto (paso con `es_servicio_especial`, con `ventas_indexar` y con los
-- dos sistemas de colores). Ahora los tres llaman aqui.
--
-- Los tres candados que la funcion pone, uno por cada error ya pagado:
--
--  a) El numero de venta sale de `detalle_venta()`, NO de desarmar el payload
--     a mano. Los scripts hacian `(payload->>'payload')::jsonb->>'purchaseNumber'`,
--     que solo entiende el aviso ENVUELTO. Zettle tambien lo manda plano, y
--     esas ventas se quedaban sin ligar EN SILENCIO. Es palabra por palabra el
--     error que la migracion `115` le corrigio a `ventas_indexar` — la misma
--     pregunta contestada de dos maneras en dos lugares.
--
--  b) Un carro que ya tiene visita activa NO se toca. Es la regla de la `114`,
--     ahora preguntada ANTES de escribir en vez de descubierta al chocar.
--
--  c) Si dos visitas se pelean el mismo carro (dos clientes con el mismo
--     ticket: en la base ya pasa 164 veces), gana UNA y de forma DETERMINISTA
--     — la mas cercana en el tiempo a ese carro, el mismo criterio de "Zettle
--     desempata por fecha" del RUNBOOK 4d. Las demas quedan sin ligar y
--     ANOTADAS en `imp_ligado_conflictos`, no descartadas en silencio (la
--     leccion de la migracion `108`).
--
-- Y el ligado va en su propio sub-bloque con manejador: si aun asi chocara,
-- se pierden los ENLACES, nunca las VISITAS. Una visita sin ligar se liga
-- despues; una visita que no entro hay que volver a sacarla del export.
--
-- ⚠️ A proposito NO llama a `enlazar_visita_a_carro`. Esa funcion ademas
-- escribe `carros.cliente`, la foto y la placa DE LA VISITA sobre el carro, y
-- una visita de import no trae nada de eso: le pisaria al carro el nombre que
-- puso la cajera en su nota. El import liga; no reescribe el carro.
-- =====================================================================

create table if not exists public.imp_ligado_conflictos (
  carro_id   bigint,
  visita_id  bigint,
  ticket     text,
  persona_id bigint,
  motivo     text,
  anotado_en timestamptz not null default now()
);

create or replace function public.ligar_visitas_de_import()
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_ligadas    int := 0;
  v_ocupados   int := 0;
  v_peleados   int := 0;
  v_ambiguos   int := 0;
  v_error      text := null;
begin
  delete from public.imp_ligado_conflictos;

  -- Candidatos: visita de import sin ligar  x  carro real con ese ticket.
  -- Se llama mas de una vez en la misma transaccion (las pruebas lo hacen), y
  -- `on commit drop` solo limpia al COMMIT: hay que tirarlas a mano.
  drop table if exists _cand;
  create temp table _cand on commit drop as
  select vi.id as visita_id, vi.ticket, vi.persona_id,
         vi.creado_en as visita_en, z.carro_id, z.carro_en, z.ocupado
  from public.visitas vi
  join (
    select c.id as carro_id, c.creado_en as carro_en,
           (public.detalle_venta(v.payload) ->> 'purchaseNumber') as recibo,
           exists (select 1 from public.visitas o
                    where o.carro_id = c.id and o.estado = 'activa') as ocupado
    from public.carros c
    join public.ventas v on v.purchase_uuid = c.purchase_uuid
    where not c.es_prueba and c.cancelado_en is null
  ) z on z.recibo = vi.ticket
  where vi.caja = 'import' and vi.estado = 'activa' and vi.carro_id is null;

  -- De los carros LIBRES, un solo ganador por carro y un solo carro por visita.
  drop table if exists _gana;
  create temp table _gana on commit drop as
  select c.*,
         row_number() over (partition by c.carro_id
                            order by abs(extract(epoch from (c.visita_en - c.carro_en))),
                                     c.visita_id) as rn_c,
         row_number() over (partition by c.visita_id
                            order by abs(extract(epoch from (c.visita_en - c.carro_en))),
                                     c.carro_id) as rn_v
  from _cand c
  where not c.ocupado;

  begin
    update public.visitas vi
       set carro_id = g.carro_id
      from _gana g
     where g.rn_c = 1 and g.rn_v = 1 and vi.id = g.visita_id;
    get diagnostics v_ligadas = row_count;
  exception when others then
    v_error := sqlerrm;
    v_ligadas := 0;
  end;

  insert into public.imp_ligado_conflictos (carro_id, visita_id, ticket, persona_id, motivo)
  select carro_id, visita_id, ticket, persona_id, 'ese lavado ya esta asignado a otro cliente'
    from _cand where ocupado
  union all
  select carro_id, visita_id, ticket, persona_id, 'dos visitas se pelean el mismo lavado'
    from _gana where rn_c > 1
  union all
  select carro_id, visita_id, ticket, persona_id, 'la visita empata con varios lavados'
    from _gana where rn_v > 1 and rn_c = 1;

  select count(*) filter (where motivo like 'ese lavado%'),
         count(*) filter (where motivo like 'dos visitas%'),
         count(*) filter (where motivo like 'la visita%')
    into v_ocupados, v_peleados, v_ambiguos
    from public.imp_ligado_conflictos;

  if v_error is not null then
    insert into public.imp_ligado_conflictos (motivo)
    values ('el ligado completo fallo y se omitio: ' || v_error);
  end if;

  return jsonb_build_object(
    'ligadas',   v_ligadas,
    'ocupados',  v_ocupados,
    'peleados',  v_peleados,
    'ambiguos',  v_ambiguos,
    'error',     v_error);
end;
$function$;

revoke execute on function public.ligar_visitas_de_import() from public;
