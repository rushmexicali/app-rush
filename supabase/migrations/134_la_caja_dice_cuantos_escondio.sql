-- 134 · El buscador de la caja dice cuantos clientes se quedaron fuera
--
-- Hallazgo de la auditoria del 21-22/ago: "en la caja, buscar por apellido
-- esconde clientes sin decirlo, y justo debajo de la lista recortada esta el
-- boton que crea la ficha duplicada".
--
-- ---------------------------------------------------------------------------
-- MEDIDO CONTRA PRODUCCION, Y SALE PEOR DE LO REPORTADO
--
--     busca        clientes que hay    se ven
--     ----------   ----------------    ------
--     lopez               191            25
--     garcia              177            25
--     maria               172            25
--     luis                144            25
--     hernandez           125            25
--     martinez            120            25
--     gonzalez            107            25
--
-- Siete apellidos de los mas comunes de Mexicali, los siete recortados en
-- silencio. La cajera teclea "lopez", ve 25 nombres que no son el suyo, y
-- HASTA ABAJO DE ESA MISMA LISTA esta "+ Registrar cliente nuevo". El
-- resultado es una ficha duplicada de alguien que si estaba -- con sus sellos
-- partidos en dos, que es justo lo que el 21/ago costo nueve fusiones a mano.
--
-- El limite de 25 NO se sube: con 191 resultados la lista tampoco sirve, y
-- bajarla al telefono cuesta. Lo que hace falta es que la pantalla DIGA que
-- esta recortada y cuanto, para que la cajera escriba mas letras en vez de dar
-- de alta un cliente que ya existe.
--
-- ---------------------------------------------------------------------------
-- COMO, SIN QUE LA REGLA QUEDE EN DOS LUGARES
--
-- Para poder decir "25 de 191" hace falta contar, y contar necesita el MISMO
-- `where` que busca. Copiarlo seria el patron #1 de `pruebas/README.md`: dos
-- reglas para la misma pregunta, que se desfasan el dia que alguien agregue un
-- campo al buscador y no al contador -- y entonces el numero mentiria, que es
-- peor que no tenerlo.
--
-- Asi que el `where` se muda a `personas_que_casan(q)`, que devuelve los ids,
-- y las dos le preguntan: `buscar_personas` (los primeros 25, ya con su json)
-- y `cuantas_personas_casan` (el total). Una sola regla, dos usos.
--
-- `buscar_personas` CONSERVA su firma y su tipo de salida, asi que las tres
-- pantallas que la consultan siguen funcionando sin tocarse. Lo nuevo viaja en
-- un campo aparte de la respuesta de /personas.
--
-- ⚠️ El escapado de comodines de la 130 se conserva tal cual: `como_literal`
-- sigue envolviendo los dos patrones. Sin el, buscar "%" devolvia 25 clientes
-- cualquiera.

-- ---------------------------------------------------------------------------
-- 1) El `where`, en un solo lugar
create or replace function public.personas_que_casan(p_q text)
returns setof bigint
language sql
stable
as $function$
  -- Quien casa con lo que tecleo la cajera. De aqui salen LAS DOS cosas: la
  -- lista que se muestra y el total que se le dice. Si esta regla cambia,
  -- cambia para las dos a la vez.
  select p.id
  from public.personas p
  where
    -- por nombre
    (public.normalizar_nombre(p_q) is not null
      and p.nombre_norm like '%' || public.como_literal(public.normalizar_nombre(p_q)) || '%')
    -- o por placa (una placa puede ligar a varias personas: salen todas)
    or (public.normalizar_placa(p_q) is not null
      and exists (
        select 1 from public.persona_placas pp
        where pp.persona_id = p.id
          and pp.placa_norm like '%' || public.como_literal(public.normalizar_placa(p_q)) || '%'));
$function$;

comment on function public.personas_que_casan(text) is
  'Ids de las personas que casan con lo que tecleo la cajera. Unico dueno de esa regla: la consultan buscar_personas y cuantas_personas_casan.';

-- ---------------------------------------------------------------------------
-- 2) La lista de siempre, con el mismo limite y el mismo orden
create or replace function public.buscar_personas(p_q text)
returns jsonb
language sql
stable
as $function$
  select coalesce(jsonb_agg(j order by nombre), '[]'::jsonb)
  from (
    select public.persona_json(p.id) as j, p.nombre
    from public.personas p
    where p.id in (select public.personas_que_casan(p_q))
    order by p.nombre
    -- 25 y no mas: con 191 resultados la lista tampoco sirve, y bajarla al
    -- telefono cuesta. Lo que se arreglo no es el limite, es que se callaba.
    limit 25
  ) s;
$function$;

-- ---------------------------------------------------------------------------
-- 3) Cuantos hay de verdad
create or replace function public.cuantas_personas_casan(p_q text)
returns int
language sql
stable
as $function$
  select count(*)::int from public.personas_que_casan(p_q);
$function$;

comment on function public.cuantas_personas_casan(text) is
  'Cuantos clientes casan en total, para que la caja pueda decir "se muestran 25 de 191" en vez de ofrecer dar de alta a alguien que ya existe.';

-- ---------------------------------------------------------------------------
-- Comprobacion de SOLO LECTURA.
do $do$
declare
  n_total int;
  n_lista int;
begin
  -- El contador y la lista tienen que estar de acuerdo cuando no hay recorte.
  n_total := public.cuantas_personas_casan('zzzznadie');
  n_lista := jsonb_array_length(public.buscar_personas('zzzznadie'));
  if n_total <> 0 or n_lista <> 0 then
    raise exception 'una busqueda sin resultados devolvio % / %', n_total, n_lista;
  end if;

  -- Y cuando SI hay recorte, el total tiene que ser mayor que la lista.
  n_total := public.cuantas_personas_casan('lopez');
  n_lista := jsonb_array_length(public.buscar_personas('lopez'));
  if n_lista <> 25 then
    raise exception 'la lista dejo de recortar a 25 (dio %)', n_lista;
  end if;
  if n_total <= n_lista then
    raise exception 'el contador (%) no supera a la lista (%), y con "lopez" tiene que hacerlo',
                    n_total, n_lista;
  end if;

  -- El escapado de la 130 sigue puesto: un comodin no puede volver a devolver
  -- clientes cualquiera.
  if jsonb_array_length(public.buscar_personas('%')) <> 0 then
    raise exception 'buscar_personas volvio a tratar el %% como comodin';
  end if;
  if public.cuantas_personas_casan('%') <> 0 then
    raise exception 'cuantas_personas_casan trata el %% como comodin';
  end if;

  raise notice 'la caja ya puede decir cuantos escondio: comprobado';
end
$do$;
