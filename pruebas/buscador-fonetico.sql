-- =====================================================================
-- EL BUSCADOR OYE EL NOMBRE (migracion 140)
--
-- En el espanol de Mexico S/Z/C, B/V, LL/Y, G/J, QU/K, SH/CH y la H muda no
-- son errores de dedo: son la misma palabra escrita como se oye. Hasta el
-- 30/ago el buscador de la caja era `like '%texto%'` sobre el nombre tal cual,
-- asi que "gonsales" devolvia CERO y la cajera daba de alta una ficha
-- duplicada de alguien que ya estaba.
--
-- Todo revierte: no escribe nada, termina en `raise`.
-- =====================================================================
do $$
declare
  ok text := '';
  malos text := '';
begin
  -- ---- 1. Suenan igual -> MISMA clave ------------------------------
  if public.clave_fonetica('GONZALEZ')   is distinct from public.clave_fonetica('GONSALES')   then malos := malos || ' s/z'; end if;
  if public.clave_fonetica('VALDERRAMA') is distinct from public.clave_fonetica('BALDERRAMA') then malos := malos || ' b/v'; end if;
  if public.clave_fonetica('HERNANDEZ')  is distinct from public.clave_fonetica('ERNANDES')   then malos := malos || ' h muda'; end if;
  if public.clave_fonetica('YOLANDA')    is distinct from public.clave_fonetica('LLOLANDA')   then malos := malos || ' ll/y'; end if;
  if public.clave_fonetica('GIL')        is distinct from public.clave_fonetica('JIL')        then malos := malos || ' g/j'; end if;
  if public.clave_fonetica('QUINTERO')   is distinct from public.clave_fonetica('KINTERO')    then malos := malos || ' qu/k'; end if;
  if public.clave_fonetica('CECILIA')    is distinct from public.clave_fonetica('SESILIA')    then malos := malos || ' ce/ci'; end if;
  if public.clave_fonetica('MICHELLE')   is distinct from public.clave_fonetica('MISHELLE')   then malos := malos || ' sh/ch'; end if;
  if public.clave_fonetica('SANCHEZ')    is distinct from public.clave_fonetica('SANSHES')    then malos := malos || ' sh/ch apellido'; end if;
  if malos = '' then ok := ok || 'suenan igual OK. '; end if;

  -- ---- 2. Suenan DISTINTO -> claves distintas ----------------------
  -- Tan importante como lo de arriba: un buscador que funde a dos personas es
  -- PEOR que uno que no encuentra a una. El primero le da los sellos de
  -- alguien a otro, y eso no se nota nunca.
  declare m2 text := '';
  begin
    if public.clave_fonetica('MARIO HERNANDEZ') = public.clave_fonetica('MARINA HERNANDEZ') then m2 := m2 || ' mario=marina'; end if;
    if public.clave_fonetica('PEREZ')    = public.clave_fonetica('PERAZ')   then m2 := m2 || ' vocales'; end if;
    if public.clave_fonetica('GUERRERO') = public.clave_fonetica('JERERO')  then m2 := m2 || ' gue->je'; end if;
    if public.clave_fonetica('SANCHEZ')  = public.clave_fonetica('SANSES')  then m2 := m2 || ' ch roto'; end if;
    if public.clave_fonetica('CARLOS')   = public.clave_fonetica('CARLA')   then m2 := m2 || ' carlos=carla'; end if;
    malos := malos || m2;
    if m2 = '' then ok := ok || 'las vocales no se tocan OK. '; end if;
  end;

  -- ---- 3. El bug que lo motivo, contra la base real ----------------
  -- "gonsales" devolvia 0. Si vuelve a dar 0, el camino fonetico murio.
  declare m3 text := '';
  begin
    if not exists (select 1 from public.personas_que_casan('gonsales'))     then m3 := m3 || ' gonsales'; end if;
    if not exists (select 1 from public.personas_que_casan('osuna favela')) then m3 := m3 || ' osuna'; end if;
    -- Y las dos ortografias tienen que traer LO MISMO.
    if (select count(*) from public.personas_que_casan('valderrama')) <>
       (select count(*) from public.personas_que_casan('balderrama')) then m3 := m3 || ' v/b-difieren'; end if;
    malos := malos || m3;
    if m3 = '' then ok := ok || 'encuentra lo que antes no OK. '; end if;
  end;

  -- ---- 4. NO se perdio nada: el camino literal sigue vivo ----------
  -- Lo que casa por subcadena TIENE que seguir saliendo. Se comprueba contra
  -- la tabla real, no contra una lista escrita a mano.
  declare m4 text := ''; faltantes int;
  begin
    select count(*) into faltantes
    from public.personas p
    where p.nombre_norm like '%' || public.normalizar_nombre('martinez') || '%'
      and p.id not in (select x from public.personas_que_casan('martinez') x);
    if faltantes > 0 then m4 := m4 || ' se perdieron ' || faltantes; end if;
    malos := malos || m4;
    if m4 = '' then ok := ok || 'no se perdio nada OK. '; end if;
  end;

  -- ---- 5. El comodin no se cuela ------------------------------------
  -- `%` en LIKE significa "todo". La 130 lo escapo; el camino fonetico nuevo
  -- tiene que escaparlo tambien o la cajera ve una lista con cara de
  -- resultado bueno y toca al cliente equivocado.
  declare m5 text := '';
  begin
    if exists (select 1 from public.personas_que_casan('%')) then m5 := m5 || ' % se colo'; end if;
    if exists (select 1 from public.personas_que_casan('_')) then m5 := m5 || ' _ se colo'; end if;
    malos := malos || m5;
    if m5 = '' then ok := ok || 'el comodin no se cuela OK. '; end if;
  end;

  -- ---- 6. El umbral del parecido NO se hereda de la sesion ----------
  -- `%` usa pg_trgm.similarity_threshold, que es de SESION y default 0.3.
  -- La funcion escribe su propio 0.55; si alguien la dejara depender del GUC,
  -- el buscador se comportaria distinto segun quien lo llame.
  declare m6 text := ''; con_bajo int; con_alto int;
  begin
    set local pg_trgm.similarity_threshold = 0.1;
    select count(*) into con_bajo from public.personas_que_casan('isabel galaiz salcedo');
    set local pg_trgm.similarity_threshold = 0.5;
    select count(*) into con_alto from public.personas_que_casan('isabel galaiz salcedo');
    if con_bajo <> con_alto then
      m6 := m6 || ' el umbral se hereda (' || con_bajo || ' vs ' || con_alto || ')';
    end if;
    malos := malos || m6;
    if m6 = '' then ok := ok || 'el umbral no se hereda OK. '; end if;
  end;

  -- ---- 7. Los duplicados reales del 29-30/ago se encuentran ---------
  declare m7 text := '';
  begin
    if not exists (select 1 from public.personas_que_casan('isabel galaiz salcedo'))      then m7 := m7 || ' galaiz'; end if;
    if not exists (select 1 from public.personas_que_casan('wiliam cardenas'))            then m7 := m7 || ' wiliam'; end if;
    if not exists (select 1 from public.personas_que_casan('karolina magdaleno beltran')) then m7 := m7 || ' karolina'; end if;
    if not exists (select 1 from public.personas_que_casan('jose ramon osuna favela'))    then m7 := m7 || ' osuna favela'; end if;
    malos := malos || m7;
    if m7 = '' then ok := ok || 'los duplicados reales se encuentran OK. '; end if;
  end;

  if malos <> '' then
    raise exception 'PRUEBA FALLIDA ->%', malos;
  end if;
  raise exception 'PRUEBA PASADA -> %', ok;
end $$;
