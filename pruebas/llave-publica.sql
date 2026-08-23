-- Prueba: la llave publicable no alcanza ninguna funcion nuestra, Y lo nuevo
-- nace cerrado.  (migracion 128)
--
-- El tercer grupo es la razon de que este archivo exista. Los dos primeros
-- comprueban el estado de HOY -- que es justo lo que ya se habia comprobado el
-- 19/ago antes de que la clase volviera. Lo unico que impide la cuarta vez es
-- que una funcion NUEVA nazca cerrada, y eso no se ve leyendo `pg_default_acl`:
-- el catalogo se veia correcto mientras las funciones nacian abiertas por PUBLIC.
--
-- Revierte con `raise` al final, asi que se puede correr contra produccion.
do $prueba$
declare
  n      int;
  lista  text;
  oid_f  oid;
  msg    text := '';
begin
  -- 1) Hoy: la llave publica no alcanza nada nuestro.
  select count(*), string_agg(p.proname, ', ' order by p.proname)
    into n, lista
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and pg_get_userbyid(p.proowner) = 'postgres'
     and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
     and (has_function_privilege('anon', p.oid, 'EXECUTE')
       or has_function_privilege('authenticated', p.oid, 'EXECUTE'));
  if n > 0 then
    raise exception 'PRUEBA FALLIDA -> la llave publica alcanza % funciones: %', n, lista;
  end if;
  msg := msg || 'la llave publica no alcanza nada OK. ';

  -- 2) Y la app sigue alcanzando TODO. Si esto falla, se rompio la app entera.
  select count(*) into n
    from pg_proc p
    join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and pg_get_userbyid(p.proowner) = 'postgres'
     and not has_function_privilege('service_role', p.oid, 'EXECUTE');
  if n > 0 then
    raise exception 'PRUEBA FALLIDA -> service_role perdio EXECUTE en % funciones', n;
  end if;
  msg := msg || 'service_role las alcanza todas OK. ';

  -- 3) LO QUE IMPIDE LA CUARTA VEZ: una funcion nueva nace cerrada.
  create function public.zz_prueba_llave_publica()
    returns int language sql immutable as 'select 1';
  oid_f := 'public.zz_prueba_llave_publica()'::regprocedure;

  if has_function_privilege('anon', oid_f, 'EXECUTE') then
    raise exception 'PRUEBA FALLIDA -> una funcion NUEVA nace abierta para anon';
  end if;
  if has_function_privilege('authenticated', oid_f, 'EXECUTE') then
    raise exception 'PRUEBA FALLIDA -> una funcion NUEVA nace abierta para authenticated';
  end if;
  if not has_function_privilege('service_role', oid_f, 'EXECUTE') then
    raise exception 'PRUEBA FALLIDA -> service_role NO alcanza una funcion NUEVA';
  end if;
  drop function public.zz_prueba_llave_publica();
  msg := msg || 'lo nuevo nace cerrado OK. ';

  -- 4) El guardian sigue instalado. Sin el, el 3 pasa por casualidad.
  if not exists (select 1 from pg_event_trigger
                  where evtname = 'cerrar_funciones_nuevas' and evtenabled <> 'D') then
    raise exception 'PRUEBA FALLIDA -> el event trigger cerrar_funciones_nuevas no esta activo';
  end if;
  msg := msg || 'el guardian esta activo OK. ';

  raise exception 'PRUEBA PASADA -> %', msg;
end
$prueba$;
