-- =====================================================================
-- 113 - El sexto duplicado, que mi propio criterio se saltaba
--
-- La 112 descarto cinco visitas duplicadas (misma persona, mismo ticket).
-- Las busco asi:
--
--     group by ticket having count(*) > 1 and count(distinct persona_id) = 1
--
-- Y ese `count(distinct persona_id) = 1` es el error: solo encuentra el
-- duplicado cuando en el ticket NO hay nadie mas. El ticket 26723 tiene
-- TRES visitas — ELLIUT SILVA dos veces y Victor Palacios una — asi que
-- cayo del lado de "dos personas distintas" y se quedo con su sello de mas.
--
-- El criterio correcto agrupa por el PAR: `group by ticket, persona_id`.
-- Con el, en toda la base sale exactamente un caso mas, y es este.
--
-- Se encontro leyendo la lista de los 14 lavados que quedaron para decidir,
-- no revisando la consulta: el mismo nombre aparecia dos veces en el mismo
-- renglon. Es la razon por la que vale la pena imprimir el dato crudo antes
-- de dar por buena una cuenta.
-- =====================================================================

insert into public.bak_visitas_duplicadas_0819 (id, persona_id, ticket, creado_en, respaldado_en)
select v.id, v.persona_id, v.ticket, v.creado_en, now()
  from public.visitas v
 where v.estado = 'activa' and v.ticket is not null and not v.es_prueba
   and exists (
     select 1 from public.visitas v2
      where v2.estado = 'activa' and not v2.es_prueba
        and v2.ticket = v.ticket
        and v2.persona_id = v.persona_id
        and v2.id < v.id
   )
   and v.id not in (select id from public.bak_visitas_duplicadas_0819);

update public.visitas
   set estado = 'descartada'
 where id in (select id from public.bak_visitas_duplicadas_0819)
   and estado = 'activa';
