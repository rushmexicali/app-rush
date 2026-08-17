-- =====================================================================
-- DIFF de renombres para AUTORIZACION MANUAL (politica del dueno, 5/ago/2026).
-- NO fusiona nada: solo arma las listas para que el dueno apruebe los merges.
--
-- Requiere cargadas dos tablas de staging del export NUEVO:
--   stg_names(ticket text, display text)  <- gawk notas-ticket.awk  (ticket->nombre actual)
--   stg_padron(display text)              <- gawk padron.awk        (lista autoritativa)
--
-- Produce tres tablas:
--   ren_cand           = MERGES/RENOMBRES sugeridos (deteccion por ticket LIMPIO,
--                        alta confianza). El dueno los revisa y aplica con
--                        aplicar-renombres.sql.
--   ren_desaparecen    = personas en la base que YA NO estan en el padron y que el
--                        diff NO explico como renombre (revisar a mano).
--   ren_nuevas         = nombres del padron que NO estan en la base y que NO son el
--                        destino de un renombre sugerido (clientes nuevos reales).
--
-- Regla anti-colision (la que costo cotejo el 5/ago): un ticket solo vale para
-- deducir un renombre si es LIMPIO -> en el export mapea a UN solo nombre y en la
-- base pertenece a UNA sola persona. Sin esto, los tickets chicos/pre-Zettle
-- compartidos inventan renombres falsos (decenas de personas "->Rogelio Valdivia").
-- =====================================================================

-- 1) MERGES/RENOMBRES sugeridos (solo tickets limpios, voto unanime por persona)
drop table if exists public.ren_cand;
create table public.ren_cand as
with tk_export as (
  select ticket from public.stg_names
  group by ticket having count(distinct public.normalizar_nombre(display)) = 1
),
tk_db as (
  select ticket from public.visitas
  where caja = 'import' and ticket is not null
  group by ticket having count(distinct persona_id) = 1
),
clean as (select ticket from tk_export intersect select ticket from tk_db),
vt as (
  select v.persona_id,
         public.normalizar_nombre(s.display) as new_norm,
         s.display as new_display
  from public.visitas v
  join clean cl on cl.ticket = v.ticket
  join public.stg_names s on s.ticket = v.ticket
  where v.caja = 'import'
),
por_persona as (
  select persona_id,
         count(distinct new_norm) as nombres_distintos,
         (array_agg(distinct new_norm))[1] as new_norm,
         (array_agg(new_display order by new_display))[1] as new_display,
         count(*) as tickets_limpios
  from vt group by persona_id
)
select pp.persona_id as old_id, p.nombre as old_nombre, p.nombre_norm as old_norm,
       pp.new_display as new_nombre, pp.new_norm as new_norm, pp.tickets_limpios,
       (select count(*) from public.visitas v where v.persona_id = pp.persona_id) as old_visitas,
       o.id as choca_id,
       (select count(*) from public.visitas v where v.persona_id = o.id) as choca_visitas,
       (select bool_and(w = any(string_to_array(pp.new_norm,' ')))
          from unnest(string_to_array(p.nombre_norm,' ')) w) as aditivo
from por_persona pp
join public.personas p on p.id = pp.persona_id
left join public.personas o on o.nombre_norm = pp.new_norm and o.id <> pp.persona_id
where pp.nombres_distintos = 1
  and pp.new_norm is distinct from p.nombre_norm;

-- 2) Personas que DESAPARECEN (en la base, no en el padron) y que el diff NO
--    explico como renombre. Con conteo de visitas para juzgar.
drop table if exists public.ren_desaparecen;
create table public.ren_desaparecen as
with padron as (select distinct public.normalizar_nombre(display) nn from public.stg_padron)
select p.id, p.nombre, p.nombre_norm,
       (select count(*) from public.visitas v where v.persona_id = p.id) visitas
from public.personas p
where p.origen = 'import'
  and p.nombre_norm not in (select nn from padron)
  and p.id not in (select old_id from public.ren_cand);

-- 3) Nombres NUEVOS del padron (no en la base) que no son destino de un renombre.
drop table if exists public.ren_nuevas;
create table public.ren_nuevas as
with dbnorm as (select nombre_norm from public.personas where origen='import')
select distinct public.normalizar_nombre(display) nombre_norm,
       (array_agg(display))[1] display
from public.stg_padron
where public.normalizar_nombre(display) is not null
  and public.normalizar_nombre(display) not in (select nombre_norm from dbnorm)
  and public.normalizar_nombre(display) not in (select new_norm from public.ren_cand)
group by public.normalizar_nombre(display);

-- 4) RENOMBRES POR PREFIJO DE PALABRAS: el nombre viejo es prefijo exacto del
--    nuevo (la cajera agrego apellido). Esta es la deteccion que DE VERDAD
--    encuentra los renombres; la de tickets (ren_cand) ha dado falsos las dos
--    ultimas veces. Ver RUNBOOK 4c.
--    Se aplica sin preguntar SOLO si los tres contadores de abajo dan cero:
--    viejos_ambiguos, nuevos_ambiguos y choca_con_persona_existente. Con los tres
--    en cero es un renombre PURO (no fusiona ni borra a nadie): se copia a
--    ren_cand con choca_id null y se corre aplicar-renombres.sql.
drop table if exists public.ren_prefijo;
create table public.ren_prefijo as
select d.id old_id, d.nombre old_nombre, d.nombre_norm old_norm, d.visitas,
       n.display new_nombre, n.nombre_norm new_norm
from public.ren_desaparecen d
join public.ren_nuevas n on n.nombre_norm like d.nombre_norm || ' %';

-- Resumen
select
  (select count(*) from public.ren_cand) merges_sugeridos,
  (select count(*) from public.ren_cand where choca_id is not null) con_duplicado,
  (select count(*) from public.ren_desaparecen) desaparecen_sin_explicar,
  (select count(*) from public.ren_nuevas) clientes_nuevos,
  (select count(*) from public.ren_prefijo) prefijo_pares,
  (select count(*) from (select old_id from public.ren_prefijo
                          group by old_id having count(*)>1) z) prefijo_viejos_ambiguos,
  (select count(*) from (select new_norm from public.ren_prefijo
                          group by new_norm having count(*)>1) z) prefijo_nuevos_ambiguos,
  (select count(*) from public.ren_prefijo r
     join public.personas p on p.nombre_norm = r.new_norm) prefijo_choca_con_persona;
