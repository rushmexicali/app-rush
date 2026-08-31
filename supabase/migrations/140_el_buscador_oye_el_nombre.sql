-- =====================================================================
-- 140 — El buscador de la caja oye el nombre, no sólo lo lee.
--
-- Pregunta del dueno, 30/ago/2026: "Hay alguna manera de que siempre que se
-- usen las siguientes letras las considere ambas para el buscador. S con Z,
-- V con B, entre otras?"
--
-- Si, y es lo correcto: en el espanol de Mexico esos pares NO son errores de
-- dedo, son ortografia alternativa del MISMO nombre. GONZALEZ y GONSALES
-- suenan igual; VALDERRAMA y BALDERRAMA tambien. El cliente dicta su apellido
-- y la cajera lo escribe como lo oye.
--
-- EL PROBLEMA QUE RESUELVE, medido el 30/ago:
--   "galaiz"       -> 0 resultados     "galaviz"       -> 3
--   "osuna favela" -> 0 resultados     "ozuna favela"  -> 1
--   "balderrama"   -> 2                "valderrama"    -> 4   (la MISMA persona,
--                                                              partida en dos)
-- La cajera ve "Nadie con ese nombre", el unico boton que le queda es
-- "+ Registrar cliente nuevo", y nace una ficha duplicada. Hasta el 30/ago eso
-- se corregia solo (cada import reconstruia el padron desde el CNT y ganaba la
-- ortografia del CNT); desde el 31/ago **el CNT ya no se llena** y no hay nada
-- que lo corrija. Hoy ya hay 126 pares de fichas muy parecidas y 23 donde el
-- cliente pierde un lavado gratis que ya se gano.
--
-- COMO: una clave FONETICA. Se colapsan las letras que suenan igual y se
-- compara sobre eso. Es el mismo `like '%...%'` de siempre — la cajera no
-- tiene que aprender nada nuevo — nada mas que deletreado por sonido.
--
--   seseo      s = z = c(e,i)      GONZALEZ  -> gonsales
--   b = v = w                      VALDERRAMA-> balderama
--   g suave = j                    GIL       -> jil
--   qu = c(a,o,u) = k              QUINTERO  -> kintero
--   ll = y = i                     YOLANDA   -> iolanda
--   h muda                         HERNANDEZ -> ernandes
--   rr = r,  x = ks,  dobles
--
-- 🔑 LO QUE NO HACE, Y ES A PROPOSITO: **no toca las vocales.** a/e/i/o/u no
--    son homofonas en espanol, y colapsarlas juntaria gente distinta. Medido:
--    MARIO HERNANDEZ -> 'mario ernandes' y MARINA HERNANDEZ -> 'marina
--    ernandes' siguen siendo DISTINTAS, que es tan importante como que
--    GONZALEZ y GONSALES sean iguales. Un buscador que funde a dos personas es
--    peor que uno que no encuentra a una: el primero le da los sellos de
--    alguien a otro, y eso no se nota nunca.
--
-- 🔑 DOS FUNCIONES, Y LA RAZON ES EL INDICE:
--    · `clave_fonetica_de_norm(text)` es IMMUTABLE de verdad — puras
--      operaciones de texto sobre algo YA normalizado. Por eso se puede
--      indexar. Aqui vive la regla, en un solo lugar.
--    · `clave_fonetica(text)` es el envoltorio STABLE para el lado de la
--      consulta (normaliza y luego llama a la de arriba). NO se indexa: llama
--      a `normalizar_nombre`, que es STABLE porque `unaccent` depende del
--      diccionario. Indexar eso seria mentirle a Postgres.
--
-- ⚠️ EL INDICE Y LA CONSULTA TIENEN QUE USAR LA MISMA EXPRESION, palabra por
--    palabra (`clave_fonetica_de_norm(nombre_norm)`), o el indice no se usa y
--    el buscador se va a ~161 ms por tecla. Medido antes de indexar: Seq Scan,
--    161 ms. Con el indice, abajo, se comprueba.
--    Se apoya en que `nombre_norm` esta al dia: verificado, 5,091 de 5,091 con
--    `nombre_norm = normalizar_nombre(nombre)` y 0 nulos.
--
-- ⛔ NO se agrega una columna `nombre_fon`. Nadie mantiene `nombre_norm` con un
--    trigger (lo escribe cada quien que inserta), asi que una segunda columna
--    seria una segunda cosa que alguien puede olvidar llenar. El indice de
--    expresion se mantiene solo.
-- =====================================================================


-- La regla, en UN solo lugar. Entra texto ya normalizado (mayusculas y sin
-- acentos); sale la clave. El orden de los pasos SI importa y va comentado.
create or replace function public.clave_fonetica_de_norm(p_norm text)
returns text
language sql
immutable
as $function$
  select nullif(btrim(
    -- 12) el token vuelve a ser 'ch'
    replace(
    -- 11) dobles que hayan quedado al colapsar
    replace(replace(replace(replace(replace(replace(replace(replace(
    -- 10) y = i   (la 'll' ya se volvio 'y' en el paso 1)
    translate(
    -- 9) rr = r
    replace(
    -- 8) x = ks
    replace(
    -- 7) la h es muda. Segura: 'ch' y 'sh' estan guardadas en el token.
    replace(
    -- 6) b = v = w
    translate(
    -- 5) la c que queda es dura = k   (ce/ci y z ya se fueron a s)
    replace(
    -- 4) seseo: ce = se, ci = si, z = s
    replace(replace(replace(
    -- 3) la u de gue/gui es muda. VA DESPUES del paso 2 a proposito: si fuera
    --    antes, 'guerrero' se volveria 'gerrero' y el paso 2 lo haria
    --    'jerrero', que suena distinto.
    replace(replace(
    -- 2) g suave = j  (no toca 'gue'/'gui': ahi la g va seguida de u)
    replace(replace(
    -- 1) sh = ch, ll = y, qu = k. 'sh' y 'ch' van al MISMO token: en Mexico se
    --    escriben una por otra (Michelle/Michel, Shirley/Chirley), y ademas
    --    asi quedan a salvo del paso 7, que borra la h.
    --    ⚠️ 'sh' primero, y las dos ANTES de que la h se borre.
    replace(replace(replace(replace(
      lower(coalesce(p_norm, '')),
      'sh', '@'), 'ch', '@'), 'll', 'y'), 'qu', 'k'),
      'ge', 'je'), 'gi', 'ji'),
      'gue', 'ge'), 'gui', 'gi'),
      'ce', 'se'), 'ci', 'si'), 'z', 's'),
      'c', 'k'),
      'vw', 'bb'),
      'h', ''),
      'x', 'ks'),
      'rr', 'r'),
      'y', 'i'),
      'ss','s'), 'nn','n'), 'mm','m'), 'bb','b'), 'kk','k'), 'tt','t'), 'aa','a'), 'ee','e'),
      '@', 'ch')
  ), '');
$function$;

-- El lado de la consulta: normaliza lo que tecleo la cajera y saca su clave.
create or replace function public.clave_fonetica(p_texto text)
returns text
language sql
stable
as $function$
  select public.clave_fonetica_de_norm(public.normalizar_nombre(p_texto));
$function$;

-- El indice tiene que casar palabra por palabra con la consulta de
-- `personas_que_casan`, o no se usa. Sirve para los DOS caminos nuevos: el
-- `like` de la clave y el `%` del parecido.
drop index if exists personas_fonetica_trgm;
create index personas_fonetica_trgm
  on public.personas using gin (public.clave_fonetica_de_norm(nombre_norm) gin_trgm_ops);

analyze public.personas;

-- ---------------------------------------------------------------------
-- El buscador. `personas_que_casan` es el UNICO cuello: de aqui salen la
-- lista que ve la cajera Y el total que se le dice, asi que la regla nueva
-- entra una sola vez y las dos quedan de acuerdo.
--
-- Son TRES caminos y se SUMAN con `or`: todo lo que se encontraba antes se
-- sigue encontrando. Comprobado contra linea base, consulta por consulta.
--
--   1. como se ESCRIBE   (el de siempre)
--   2. como SUENA        (mismo `like`, sobre la clave fonetica)
--   3. como se PARECE    (trigramas SOBRE LA CLAVE, no sobre el nombre)
--
-- El 3 existe porque el 2 no alcanza cuando hay una letra de mas o de menos:
-- GALAIZ vs GALAVIZ no son homofonas, es una v que se comio. Sobre la clave
-- fonetica los dos errores colapsan a la vez.
--
-- 🔑 EL 3 CASI NO HACE RUIDO, Y ESO SE MIDIO (30/ago). Los trigramas exigen
--    largos parecidos, asi que solo dispara cuando se teclea un NOMBRE
--    COMPLETO — que es justo cuando nace un duplicado (la cajera escribe todo,
--    no encuentra nada, y le da a "Registrar cliente nuevo"). Consultas
--    cortas y comunes: 'a', 'lu', 'luis', 'jose', 'maria', 'gonz',
--    'gonzalez', 'martinez', 'jose luis' -> **0 resultados extra** en todas.
--    Y en los cinco nombres que crearon duplicados el fin de semana, encontro
--    al bueno en los cinco.
--
-- ⚠️ EL UMBRAL SE ESCRIBE, NO SE HEREDA. `%` usa `pg_trgm.similarity_threshold`,
--    que es una variable de SESION (default 0.3) y que ni siquiera existe
--    hasta que la extension se carga — `current_setting` sobre ella truena en
--    una sesion nueva. Depender de eso seria que el buscador se comporte
--    distinto segun quien lo llame. Asi que van las dos cosas: `%` para que el
--    indice trabaje (trae de mas) y `similarity(...) >= 0.55` para decidir.
--
-- ⚠️ `como_literal` tambien sobre la clave: si la cajera teclea un `%`, en LIKE
--    significa otra cosa. Mismo cuidado de la migracion 130.
-- ---------------------------------------------------------------------
create or replace function public.personas_que_casan(p_q text)
returns setof bigint
language sql
stable
as $function$
  select p.id
  from public.personas p
  where
    -- 1) por nombre, tal como se ESCRIBE
    (public.normalizar_nombre(p_q) is not null
      and p.nombre_norm like '%' || public.como_literal(public.normalizar_nombre(p_q)) || '%')
    -- 2) por nombre, tal como SUENA
    or (public.clave_fonetica(p_q) is not null
      and public.clave_fonetica_de_norm(p.nombre_norm)
          like '%' || public.como_literal(public.clave_fonetica(p_q)) || '%')
    -- 3) por parecido SOBRE LA CLAVE (una letra de mas o de menos)
    or (public.clave_fonetica(p_q) is not null
      and public.clave_fonetica_de_norm(p.nombre_norm) % public.clave_fonetica(p_q)
      and similarity(public.clave_fonetica_de_norm(p.nombre_norm),
                     public.clave_fonetica(p_q)) >= 0.55)
    -- 4) por placa (una placa puede ligar a varias personas: salen todas)
    or (public.normalizar_placa(p_q) is not null
      and exists (
        select 1 from public.persona_placas pp
        where pp.persona_id = p.id
          and pp.placa_norm like '%' || public.como_literal(public.normalizar_placa(p_q)) || '%'));
$function$;

-- Comprobacion, con los casos que la motivaron y con los que NO deben juntarse.
do $$
declare malos text := '';
begin
  -- Suenan igual -> misma clave.
  if public.clave_fonetica('GONZALEZ')   is distinct from public.clave_fonetica('GONSALES')   then malos := malos || ' gonzalez/gonsales'; end if;
  if public.clave_fonetica('VALDERRAMA') is distinct from public.clave_fonetica('BALDERRAMA') then malos := malos || ' v/b'; end if;
  if public.clave_fonetica('OZUNA')      is distinct from public.clave_fonetica('OSUNA')      then malos := malos || ' z/s'; end if;
  if public.clave_fonetica('HERNANDEZ')  is distinct from public.clave_fonetica('ERNANDES')   then malos := malos || ' h muda'; end if;
  if public.clave_fonetica('YOLANDA')    is distinct from public.clave_fonetica('LLOLANDA')   then malos := malos || ' ll/y'; end if;
  if public.clave_fonetica('JAVIER')     is distinct from public.clave_fonetica('JABIER')     then malos := malos || ' j v/b'; end if;
  if public.clave_fonetica('QUINTERO')   is distinct from public.clave_fonetica('KINTERO')    then malos := malos || ' qu/k'; end if;
  if public.clave_fonetica('GIL')        is distinct from public.clave_fonetica('JIL')        then malos := malos || ' g suave/j'; end if;
  if public.clave_fonetica('CECILIA')    is distinct from public.clave_fonetica('SESILIA')    then malos := malos || ' ce/ci'; end if;
  -- sh = ch (pedido del dueno, 30/ago)
  if public.clave_fonetica('MICHELLE')   is distinct from public.clave_fonetica('MISHELLE')   then malos := malos || ' sh/ch'; end if;
  if public.clave_fonetica('SHIRLEY')    is distinct from public.clave_fonetica('CHIRLEY')    then malos := malos || ' sh/ch inicial'; end if;
  if public.clave_fonetica('SANCHEZ')    is distinct from public.clave_fonetica('SANSHES')    then malos := malos || ' sh/ch en apellido'; end if;

  -- Suenan DISTINTO -> claves distintas. Tan importante como lo de arriba.
  if public.clave_fonetica('MARIO HERNANDEZ') = public.clave_fonetica('MARINA HERNANDEZ') then malos := malos || ' mario=marina'; end if;
  if public.clave_fonetica('PEREZ')    = public.clave_fonetica('PERAZ')  then malos := malos || ' vocales colapsadas'; end if;
  if public.clave_fonetica('GUERRERO') = public.clave_fonetica('JERERO') then malos := malos || ' gue se volvio je'; end if;
  -- La h suelta se borra, pero 'sh'/'ch' NO se confunden con 's'/'c' solas.
  if public.clave_fonetica('SANCHEZ') = public.clave_fonetica('SANSES') then malos := malos || ' ch se rompio'; end if;

  -- El buscador encuentra lo que antes no, y sigue encontrando lo de antes.
  if not exists (select 1 from public.personas_que_casan('gonsales'))     then malos := malos || ' no-oye'; end if;
  if not exists (select 1 from public.personas_que_casan('osuna favela')) then malos := malos || ' no-oye-z'; end if;
  if exists (select 1 from public.personas_que_casan('%'))                then malos := malos || ' comodin-se-colo'; end if;

  if malos <> '' then raise exception 'FALLO clave_fonetica:%', malos; end if;
  raise notice 'clave_fonetica OK';
end $$;
