-- Prueba: la regla de cortesia llega al import (migracion 129).
--
-- Una cortesia (`Gratis` + variante que NO empieza con `6to`) es un regalo del
-- negocio: NI suma sello NI consume gratis. La regla vive en `clase_de_gratis()`
-- y hasta el 23/ago solo la consultaba el camino de la CAJA; el del IMPORT se la
-- brincaba, y por eso 11 visitas de 7 personas quedaron contadas como canje --
-- o sea que a cinco clientes se les cobro un lavado gratis que ya tenian ganado.
--
-- El grupo 3 REPRODUCE el bug viejo antes de comprobar el arreglo: si esa parte
-- dejara de fallar, la prueba habria dejado de medir lo que dice medir.
--
-- Revierte con `raise` al final, asi que se puede correr contra produccion.
do $prueba$
declare
  msg      text := '';
  v_p      bigint;
  v_v      bigint;
  n        int;
  r        jsonb;
  t_cort   text := '63';   -- ticket real de Zettle: Gratis + variante de cortesia
  t_canje  text := '520';  -- ticket real de Zettle: Gratis + 6to
begin
  -- 1) La funcion que decide clasifica bien los dos casos y calla en el resto.
  if public.clase_de_gratis_del_ticket(t_cort) is distinct from 'cortesia' then
    raise exception 'PRUEBA FALLIDA -> el ticket % deberia ser cortesia y dio %',
      t_cort, public.clase_de_gratis_del_ticket(t_cort);
  end if;
  if public.clase_de_gratis_del_ticket(t_canje) is distinct from 'canje' then
    raise exception 'PRUEBA FALLIDA -> el ticket % deberia ser canje y dio %',
      t_canje, public.clase_de_gratis_del_ticket(t_canje);
  end if;
  -- Un ticket que no existe, uno vacio y uno con basura NO pueden reventar ni
  -- inventar: devuelven NULL, y quien la use no debe tocar nada.
  if public.clase_de_gratis_del_ticket('99999999') is not null
     or public.clase_de_gratis_del_ticket('') is not null
     or public.clase_de_gratis_del_ticket('AB-12') is not null
     or public.clase_de_gratis_del_ticket(null) is not null then
    raise exception 'PRUEBA FALLIDA -> un ticket irresoluble deberia dar NULL';
  end if;
  msg := msg || 'clasifica y calla OK. ';

  -- 2) Hoy no queda ninguna mal contada.
  select count(*) into n
    from public.visitas vi
   where vi.caja='import' and vi.estado='activa'
     and public.clase_de_gratis_del_ticket(vi.ticket)='cortesia'
     and (vi.es_gratis or not vi.es_cortesia);
  if n > 0 then
    raise exception 'PRUEBA FALLIDA -> % cortesias siguen contadas como canje', n;
  end if;
  msg := msg || 'no queda ninguna mal contada OK. ';

  -- 3) EL BUG VIEJO, reproducido: el insert crudo del import (el que hacen los
  --    tres scripts) deja la cortesia marcada como gratis. Si esto dejara de
  --    pasar, esta prueba ya no estaria midiendo el bug.
  insert into public.personas (nombre, nombre_norm, visitas_seed, sellos_iniciales, origen)
  values ('zz prueba cortesia', public.normalizar_nombre('zz prueba cortesia 129'), 0, 0, 'import')
  returning id into v_p;

  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, monto, ticket)
  values (v_p, true, 'activa', 'import', false, now(), 0, t_cort)
  returning id into v_v;

  if exists (select 1 from public.visitas where id=v_v and es_cortesia) then
    raise exception 'PRUEBA FALLIDA -> el insert crudo ya la marcaba: la prueba dejo de medir el bug';
  end if;
  msg := msg || 'bug viejo reproducido OK. ';

  -- 4) Y el cuello por el que pasa TODO import la corrige. Se llama la misma
  --    funcion que llaman los tres scripts, no una copia de su logica.
  r := public.ligar_visitas_de_import();

  select count(*) into n from public.visitas
   where id = v_v and es_cortesia and not es_gratis;
  if n <> 1 then
    raise exception 'PRUEBA FALLIDA -> el import no corrigio la cortesia (ligado: %)', r;
  end if;
  msg := msg || 'el import la corrige OK. ';

  -- 5) Y una cortesia NO le consume el gratis a nadie: con 5 lavados pagados
  --    mas una cortesia, sigue habiendo 1 disponible.
  insert into public.visitas (persona_id, es_gratis, estado, caja, es_prueba, creado_en, monto, ticket)
  select v_p, false, 'activa', 'import', false, now(), 100, null from generate_series(1,5);
  perform public.ligar_visitas_de_import();

  select disponibles into n from public.lealtad_por_persona where persona_id = v_p;
  if n <> 1 then
    raise exception 'PRUEBA FALLIDA -> la cortesia consumio el gratis: disponibles=%', n;
  end if;
  msg := msg || 'la cortesia no consume gratis OK. ';

  raise exception 'PRUEBA PASADA -> %', msg;
end
$prueba$;
