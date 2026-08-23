-- 128 · La llave publica deja de alcanzar nuestras funciones -- Y DEJA DE VOLVER
--
-- La auditoria del 21/ago encontro que seis funciones SECURITY DEFINER nuevas
-- -- cuatro de ellas escriben o borran -- las puede ejecutar la llave
-- publicable: limpiar_crudo_del_webhook, limpiar_bitacora_del_cron,
-- ligar_visitas_de_import, anotar_aviso, fotos_huerfanas, fotos_huerfanas_lista.
--
-- 🔑 LO IMPORTANTE NO ES REVOCARLAS. Es que el revoke del 19/ago YA se habia
-- hecho y volvio a pasar. La causa es estructural: Supabase deja puesto un
--
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS
--       TO anon, authenticated, service_role
--
-- asi que TODA funcion nacida despues del revoke sale otorgada de nuevo. Medido
-- hoy: de 124 funciones en `public`, anon alcanza 119. Revocar la lista de hoy
-- sin quitar el default seria hacer el mismo trabajo por tercera vez, y volveria
-- a abrirse con la siguiente migracion que cree una funcion.
--
-- Por eso esta migracion hace DOS cosas, y la segunda es la que vale:
--   1) revoca lo ya otorgado,
--   2) cambia el default para que lo nuevo NAZCA cerrado.
--
-- QUE NO SE TOCA, Y POR QUE
--
-- - `service_role` conserva su concesion EXPLICITA (`service_role=X/postgres`),
--   que es la que sobrevive a un revoke. Es la llave de las Edge Functions, o
--   sea toda la app. Verificado funcion por funcion antes de escribir esto.
--
-- - Las 3 funciones que devuelven `trigger`/`event_trigger`
--   (crear_carro_desde_venta, rls_auto_enable, ventas_indexar) quedan intactas,
--   igual que el 19/ago. PostgREST no las expone y Postgres no comprueba EXECUTE
--   al disparar un trigger (lo comprueba al crearlo), asi que revocarlas no gana
--   nada -- y la primera es el camino por donde entra el dinero. Mover permisos
--   ahi por un riesgo que no existe es un mal trato.
--
-- - Las 35 funciones de `pg_trgm` y `unaccent` instaladas en `public`: son de
--   supabase_admin (no somos duenos, el revoke fallaria), no tocan datos, y
--   `normalizar_placa` / `interpretar_nota` cuelgan de `unaccent`.
--
-- - `authenticated` SI entra al revoke: hoy hay **0 usuarios** en `auth.users`
--   (medido), asi que el riesgo de hacerlo es cero y el de no hacerlo es que el
--   dia que se prenda Auth, cada usuario nazca con acceso a las 89 funciones.
--   Se cierra la puerta mientras cerrarla no cuesta nada.

do $do$
declare
  r         record;
  revocadas int := 0;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and pg_get_userbyid(p.proowner) = 'postgres'
       and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', r.sig);
    revocadas := revocadas + 1;
  end loop;

  raise notice 'Revocadas: % funciones', revocadas;
end
$do$;

-- 2) Lo NUEVO nace cerrado. Esta es la parte que impide la cuarta vez, y la
--    unica que de verdad importa: revocar la lista de hoy sin esto seria hacer
--    el mismo trabajo por tercera vez.
--
--    ⚠️ EL `ALTER DEFAULT PRIVILEGES` NO ALCANZA, y se comprobo, no se supuso:
--    se aplico `revoke execute on functions from public, anon, authenticated`
--    sobre el default de `postgres` y una funcion creada despues -- ya
--    comprometido el cambio, en OTRA transaccion -- nacio igual con
--
--        {=X/postgres, postgres=X/postgres, service_role=X/postgres}
--
--    Ese `=X` es PUBLIC, y por ahi le llega el permiso a `anon` aunque no tenga
--    concesion propia (la misma trampa que el `CLAUDE.md §11.50` documento del
--    revoke del 19/ago). El `pg_default_acl` se veia CORRECTO -- decia
--    `{postgres=X, service_role=X}` -- mientras las funciones seguian naciendo
--    abiertas. Leyendo el catalogo no se veia; se encontro creando una funcion
--    de prueba y preguntando por ella.
--
--    Asi que la garantia se pone donde no dependa de esa sutileza: un EVENT
--    TRIGGER que revoca al terminar cada DDL. Es el MISMO patron que este
--    proyecto ya usa en `rls_auto_enable` (que prende RLS en cada tabla nueva),
--    en el mismo lugar y con la misma forma -- incluido tragarse su propio
--    error, porque una salvaguarda nunca puede tumbar una migracion.
--
--    Se deja tambien el ALTER DEFAULT PRIVILEGES: no basta, pero no estorba, y
--    el dia que Postgres cambie ese comportamiento ya esta puesto.
alter default privileges for role postgres in schema public
  revoke execute on functions from public, anon, authenticated;

create or replace function public.cerrar_funciones_nuevas()
returns event_trigger
language plpgsql
security definer
set search_path to 'pg_catalog, public'
as $function$
declare
  cmd record;
begin
  for cmd in
    select * from pg_event_trigger_ddl_commands()
     where command_tag in ('CREATE FUNCTION', 'ALTER FUNCTION')
       and object_type = 'function'
  loop
    begin
      -- Solo lo nuestro: funciones de `public`, propiedad de postgres, que no
      -- devuelvan trigger. Las de extension (pg_trgm, unaccent) son de
      -- supabase_admin y el revoke fallaria; los triggers se dejan a proposito
      -- (ver el encabezado).
      perform 1
        from pg_proc p
        join pg_namespace n on n.oid = p.pronamespace
       where p.oid = cmd.objid
         and n.nspname = 'public'
         and pg_get_userbyid(p.proowner) = 'postgres'
         and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype);

      if found then
        execute format('revoke execute on function %s from public, anon, authenticated',
                       cmd.objid::regprocedure);
        raise log 'cerrar_funciones_nuevas: cerrada %', cmd.object_identity;
      end if;
    exception when others then
      -- Nunca tumbar la migracion por la salvaguarda. Si esto falla, la funcion
      -- queda abierta y lo cacha la comprobacion del bloque 3 de la proxima
      -- migracion -- que es ruidoso, no silencioso.
      raise log 'cerrar_funciones_nuevas: no se pudo cerrar %', cmd.object_identity;
    end;
  end loop;
end;
$function$;

drop event trigger if exists cerrar_funciones_nuevas;
create event trigger cerrar_funciones_nuevas
  on ddl_command_end
  when tag in ('CREATE FUNCTION', 'ALTER FUNCTION')
  execute function public.cerrar_funciones_nuevas();

-- El event trigger acaba de crear una funcion nueva (la suya) antes de existir,
-- asi que se cierra a mano. De aqui en adelante se cierran solas.
revoke execute on function public.cerrar_funciones_nuevas() from public, anon, authenticated;

-- 3) Comprobacion dentro de la misma transaccion: si algo quedo alcanzable, la
--    migracion se cae en vez de reportar exito a medias.
do $do$
declare
  quedan int;
  lista  text;
begin
  select count(*), string_agg(p.proname, ', ' order by p.proname)
    into quedan, lista
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_userbyid(p.proowner) = 'postgres'
     and p.prorettype not in ('trigger'::regtype, 'event_trigger'::regtype)
     and (has_function_privilege('anon', p.oid, 'EXECUTE')
       or has_function_privilege('authenticated', p.oid, 'EXECUTE'));

  if quedan > 0 then
    raise exception 'Quedaron % funciones alcanzables por la llave publica: %', quedan, lista;
  end if;

  select count(*)
    into quedan
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and pg_get_userbyid(p.proowner) = 'postgres'
     and not has_function_privilege('service_role', p.oid, 'EXECUTE');

  if quedan > 0 then
    raise exception 'ROTO: service_role perdio EXECUTE en % funciones', quedan;
  end if;

  raise notice 'OK: la llave publica no alcanza ninguna funcion nuestra y service_role las alcanza todas';
end
$do$;

-- 4) La comprobacion que de verdad importa, y la que cacho el error de arriba:
--    una funcion NUEVA tiene que nacer cerrada. Leer `pg_default_acl` no basta.
do $do$
declare
  oid_f oid;
begin
  create function public.zz_nace_cerrada_prueba()
    returns int language sql immutable as 'select 1';

  oid_f := 'public.zz_nace_cerrada_prueba()'::regprocedure;

  if has_function_privilege('anon', oid_f, 'EXECUTE') then
    raise exception 'FALLO: una funcion NUEVA nace abierta para anon';
  end if;
  if has_function_privilege('authenticated', oid_f, 'EXECUTE') then
    raise exception 'FALLO: una funcion NUEVA nace abierta para authenticated';
  end if;
  if not has_function_privilege('service_role', oid_f, 'EXECUTE') then
    raise exception 'FALLO: service_role NO alcanza una funcion NUEVA -- la app se romperia';
  end if;

  drop function public.zz_nace_cerrada_prueba();
  raise notice 'OK: lo nuevo nace cerrado para la llave publica y abierto para la app';
end
$do$;
