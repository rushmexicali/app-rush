-- =====================================================================
-- 101 — Caja: cortesías que no cuentan, y registrar+enlazar en UN paso.
--
-- Dos cambios, los dos pedidos por el dueño el 15/ago/2026:
--
-- 1) Un "Gratis" de CORTESÍA (Cortesia, Mango, Remake, Tony, SushiRoll,
--    Uribe, Admin…) NO es un canje del 6to lavado. Hasta hoy el modelo solo
--    tenía dos estados (pagada / canje) y la cortesía caía en canje, o sea
--    que le DESCONTABA al cliente un lavado gratis que nunca usó.
--
-- 2) La caja elige el ticket ANTES de registrar, así que registrar la visita
--    y enlazarla a su lavado pasan a ser una sola operación atómica. Eso mata
--    de raíz la fuga de lealtad documentada en PENDIENTES.md (visita colgada
--    cuando la cajera usaba el botón atrás).
-- =====================================================================

-- --- 1. UNA sola regla para clasificar un "Gratis" -------------------
-- Devuelve 'canje' (6to lavado), 'cortesia' (regalo del negocio) o NULL
-- (no es un Gratis). Es UNA función y no dos, ni una condición copiada en
-- varios lados: este proyecto ya se equivocó tres veces por tener la misma
-- regla escrita en dos lugares (ver CLAUDE.md §5).
--
-- ⚠️ La decide la VARIANTE, no el nombre del producto — la misma trampa de
-- `Manual`/`Express` y de `Encerado Manual`. Y es por PREFIJO ('6to%'), no
-- por lista blanca de cortesías: los nombres de cortesía los inventa el dueño
-- en Zettle (ya van 7 distintos) y una lista se queda vieja en silencio. Con
-- el prefijo, lo que NO es 6to cae solo del lado de cortesía, que es el error
-- barato (no regalar de más).
create or replace function public.clase_de_gratis(p_producto text, p_variante text)
returns text language sql immutable as $$
  select case
    when coalesce(p_producto,'') not ilike 'gratis%' then null
    when coalesce(p_variante,'') ilike '6to%'        then 'canje'
    else 'cortesia'
  end;
$$;

comment on function public.clase_de_gratis(text, text) is
  'Clasifica una venta "Gratis": canje del 6to lavado vs cortesia del negocio. Manda la VARIANTE (6to% = canje). Fuente unica de la regla.';

-- --- 2. La visita puede ser neutra -----------------------------------
-- Tercer estado. Se agrega columna en vez de cambiar `es_gratis` a texto
-- para no tocar el import de ClientNoteTracker ni nada que ya lea la
-- bandera. Una cortesía va con es_gratis=false y es_cortesia=true.
alter table public.visitas
  add column if not exists es_cortesia boolean not null default false;

comment on column public.visitas.es_cortesia is
  'Regalo del negocio (no 6to lavado): NO suma sello ni consume gratis. Ver clase_de_gratis().';

-- --- 3. La lealtad ignora las cortesías -------------------------------
-- Cambian solo dos renglones: `lavados_pagados` y `canjes` excluyen las
-- cortesías. `visitas_totales` SÍ las cuenta — el cliente sí vino, y su
-- historial debe decirlo; lo que no hace es mover el premio.
create or replace view public.lealtad_por_persona as
  select p.id as persona_id,
    coalesce(count(*) filter (where v.id is not null and not v.es_gratis and not v.es_cortesia), 0::bigint)::integer as lavados_pagados,
    coalesce(count(*) filter (where v.id is not null and v.es_gratis and not v.es_cortesia), 0::bigint)::integer as canjes,
    (p.sellos_iniciales + coalesce(count(*) filter (where v.id is not null and not v.es_gratis and not v.es_cortesia), 0::bigint)::integer) % 5 as sellos,
    p.visitas_seed + coalesce(count(*) filter (where v.id is not null), 0::bigint)::integer as visitas_totales,
    max(v.creado_en) as ultima_visita,
    floor((p.sellos_iniciales + coalesce(count(*) filter (where v.id is not null and not v.es_gratis and not v.es_cortesia), 0::bigint)::integer)::numeric / 5.0)::integer as ganados,
    greatest(0, floor((p.sellos_iniciales + coalesce(count(*) filter (where v.id is not null and not v.es_gratis and not v.es_cortesia), 0::bigint)::integer)::numeric / 5.0)::integer
                - coalesce(count(*) filter (where v.id is not null and v.es_gratis and not v.es_cortesia), 0::bigint)::integer) as disponibles
  from public.personas p
  left join public.visitas v
    on v.persona_id = p.id and v.estado = 'activa' and not v.es_prueba
  group by p.id, p.sellos_iniciales, p.visitas_seed;

-- --- 4. Registrar la visita Y enlazarla, en una sola operación --------
-- El ticket ya está elegido, así que no hay ventana en la que exista una
-- visita sin lavado. Si algo falla, no se escribe nada.
--
-- 🔑 EL TICKET MANDA sobre el switch de la cajera: si el lavado es un 6to,
-- se registra como canje AUNQUE se le haya olvidado prender el switch. Si no
-- fuera así, un lavado regalado le sumaría un sello al cliente y cobraría el
-- mismo premio dos veces.
create or replace function public.registrar_visita_con_carro(
  p_persona    bigint,
  p_carro      bigint,
  p_usa_gratis boolean default false,
  p_caja       text    default 'principal'
) returns jsonb language plpgsql as $$
declare
  c        record;
  v_clase  text;
  v_gratis boolean;
  v_cort   boolean;
  v_id     bigint;
begin
  if not exists (select 1 from public.personas where id = p_persona) then
    return jsonb_build_object('ok', false, 'error', 'Esa persona no existe');
  end if;

  select * into c from public.carros where id = p_carro;
  if c.id is null then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado ya no existe');
  end if;
  if c.cancelado_en is not null or coalesce(c.es_prueba,false) then
    return jsonb_build_object('ok', false, 'error', 'Ese lavado está cancelado');
  end if;

  -- Mismo candado que enlazar_visita_a_carro: un lavado es de UN cliente.
  if exists (select 1 from public.visitas v2
             where v2.carro_id = p_carro and v2.estado = 'activa') then
    return jsonb_build_object('ok', false, 'error', 'Ese ticket ya se registró con otro cliente');
  end if;

  -- ⚠️ `is not distinct from` y no `=`: para un lavado normal clase_de_gratis
  -- devuelve NULL, y `null = 'canje'` es NULL — no false. Con `=` la columna
  -- es_gratis salía nula y reventaba el not-null (visto en la prueba).
  v_clase := public.clase_de_gratis(c.producto, c.variante);
  v_cort  := (v_clase is not distinct from 'cortesia');
  -- El ticket manda (ver arriba). El switch solo sirve para avisarle a la
  -- cajera ANTES, en la pantalla; aquí la verdad es el producto vendido.
  v_gratis := (v_clase is not distinct from 'canje');

  -- La cajera dijo "va a usar su lavado gratis" pero el ticket no es un 6to.
  -- Se rechaza: si se dejara pasar, se cobraría un lavado y además se le
  -- descontaría el premio.
  if coalesce(p_usa_gratis,false) and v_clase is distinct from 'canje' then
    return jsonb_build_object('ok', false,
      'error', 'Selecciona un ticket con lavado gratis',
      'motivo', 'sin_gratis');
  end if;

  insert into public.visitas
    (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, carro_id, enlazada_en)
  values
    (p_persona, v_gratis, v_cort, 'activa',
     coalesce(nullif(btrim(p_caja),''),'principal'), false, p_carro, now())
  returning id into v_id;

  -- Lo que ya hacía enlazar_visita_a_carro: ponerle el nombre del cliente al
  -- carro para que el supervisor lo vea. La foto y la placa NO se tocan aquí
  -- — ahora las pone el supervisor (la caja dejó de capturar placa a mano).
  update public.carros
     set cliente = coalesce((select nombre from public.personas where id = p_persona), cliente)
   where id = p_carro;

  -- La venta se concretó: la placa que leyó la foto se le sugiere al cliente.
  -- Mismo helper de siempre (migración 086), no una regla nueva.
  if coalesce(c.placa_display, c.placa) is not null then
    perform public.ligar_placa_a_persona(p_persona, coalesce(c.placa_display, c.placa), 'foto', false);
  end if;

  return jsonb_build_object('ok', true, 'visita', v_id, 'clase', v_clase,
                            'es_gratis', v_gratis, 'es_cortesia', v_cort,
                            'lealtad', public.lealtad_de(p_persona));
end;
$$;

comment on function public.registrar_visita_con_carro(bigint, bigint, boolean, text) is
  'Caja: registra la visita Y la enlaza a su lavado en un solo paso (el ticket se elige antes). El ticket manda sobre el switch de gratis.';
