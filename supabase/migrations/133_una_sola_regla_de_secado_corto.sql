-- 133 · Los 3 minutos de secado dejan de estar escritos en dos lugares, y el
--       desglose del carro por fin dice cuando un tiempo no es real
--
-- Hallazgo de la auditoria del 21-22/ago: "el desglose del carro presenta como
-- medido un secado que el reporte descarta por ser ficcion".
--
-- ---------------------------------------------------------------------------
-- EL HALLAZGO
--
-- Desde la migracion 064 hay una regla: un secado de MENOS DE 3 MINUTOS es
-- imposible, ni con el taller vacio. No es trabajo, es un olvido registrado
-- tarde -- el supervisor perdio la huella del carro y, al acordarse, lo asigno
-- y lo entrego de un jalon. El carro cuenta como lavado; su secado NO entra a
-- ningun promedio.
--
-- Las OTRAS dos pantallas donde ese numero se le muestra a una persona ya lo
-- dicen: el reporte del dueno lo cuenta aparte (`secados_descartados`) y el
-- perfil del trabajador lo rotula "olvido" (migracion 106). El desglose del
-- carro -- el que abre la ⓘ de la cola y el que se abre desde Finalizados --
-- no. Ahi un secado de 6 segundos se lee como un secado de 6 segundos.
--
-- Ya avisaba de los otros dos casos que si son ficcion (`cerrado_solo` y
-- `tiempo_imposible`), asi que la pantalla ya tiene el lugar y el tono: lo que
-- faltaba era este tercer caso.
--
-- ---------------------------------------------------------------------------
-- Y AL IR A ARREGLARLO SALIO LO DE FONDO: LA REGLA YA ESTABA EN DOS LUGARES
--
-- Medido en la base, no supuesto:
--
--     proname             veces que aparece 180
--     ------------------  ---------------------
--     reporte_del_rango   1
--     perfil_de_secador   1
--
-- Y el comentario de `reporte_del_rango` dice, textual: "Vive aqui, en un solo
-- lugar." Ya no era cierto desde la 106. Agregar el tercer uso a mano habria
-- dejado la MISMA regla escrita en TRES lugares -- que es, con nombre y
-- apellido, el patron #1 de la tabla de `pruebas/README.md` y el error que
-- este proyecto ya cometio seis veces.
--
-- Por eso la regla pasa a una funcion, `segundos_minimos_de_secado()`, y los
-- tres le preguntan a ella. Si el dueno decide manana que son 4 minutos, se
-- cambia en un lugar y las tres pantallas se enteran juntas. Es el mismo
-- movimiento de la 055 (`es_servicio_especial`) y de la 111
-- (`placa_repetida_hoy`).
--
-- El valor NO cambia: sigue siendo 180. Este es un cambio de donde vive la
-- regla, no de cual es -- y por eso se comprueba contra una linea base, abajo.

-- ---------------------------------------------------------------------------
-- 1) La regla, en un solo lugar
create or replace function public.segundos_minimos_de_secado()
returns int
language sql
immutable
as $function$
  -- 3 minutos. Menos que esto es imposible de secar, ni con el taller vacio:
  -- es un olvido registrado tarde, no trabajo. El carro SI cuenta como lavado;
  -- lo que no cuenta es su tiempo de secado.
  --
  -- Le preguntan: reporte_del_rango (los promedios y `secados_descartados`),
  -- perfil_de_secador (el rotulo "olvido") y detalle_del_carro (el aviso del
  -- desglose). Si esto cambia, cambia para las tres a la vez -- que es todo
  -- el punto de que viva aqui.
  select 180;
$function$;

comment on function public.segundos_minimos_de_secado() is
  'Segundos minimos para que un secado se considere real (064). Un secado mas corto es un olvido registrado tarde: cuenta como lavado pero no como tiempo.';

-- ---------------------------------------------------------------------------
-- 2) Que las tres le pregunten a ella.
--
-- Las tres funciones son largas y llenas de reglas con sus razones escritas,
-- asi que NO se copian: se les pide su propia definicion, se les cambia lo
-- justo con anclas comprobadas y se vuelven a crear. Patron de la 117, la 130
-- y la 132. Si un ancla no aparece, se cae con un mensaje claro.

do $do$
declare
  def text;
  a   text;
  n   text;
begin
  -- --------------------------------------------------------- reporte ---
  select pg_get_functiondef('public.reporte_del_rango(date, date)'::regprocedure) into def;

  a := $a$  -- 3 min. Menos que esto es imposible de secar, ni con el taller vacio: es
  -- un olvido registrado tarde, no trabajo. Vive aqui, en un solo lugar.
  secado_min constant int := 180;$a$;

  n := $n$  -- 3 min. Menos que esto es imposible de secar, ni con el taller vacio: es
  -- un olvido registrado tarde, no trabajo. La regla vive en
  -- segundos_minimos_de_secado() -- aqui decia "vive aqui, en un solo lugar" y
  -- para entonces ya estaba tambien en perfil_de_secador (133).
  secado_min constant int := public.segundos_minimos_de_secado();$n$;

  if position(a in def) = 0 then
    raise exception 'reporte_del_rango: no aparece el ancla de secado_min. Revisar a mano.';
  end if;
  execute replace(def, a, n);
  raise notice 'reporte_del_rango: usa segundos_minimos_de_secado()';

  -- ---------------------------------------------------------- perfil ---
  select pg_get_functiondef(
    'public.perfil_de_secador(text, date, date, text, integer, integer)'::regprocedure
  ) into def;

  a := $a$        'secado_corto',  (h.secado_seg is not null and h.secado_seg < 180),$a$;
  n := $n$        'secado_corto',  (h.secado_seg is not null
                          and h.secado_seg < public.segundos_minimos_de_secado()),$n$;

  if position(a in def) = 0 then
    raise exception 'perfil_de_secador: no aparece el ancla del 180. Revisar a mano.';
  end if;
  def := replace(def, a, n);

  -- De paso: el filtro de tiempo_imposible y su comentario estaban PEGADOS
  -- DOS VECES, identicos. No cambia nada (la condicion repetida da lo mismo),
  -- pero el que lo lea manana se va a preguntar cual de las dos manda. Se
  -- quita la copia.
  a := $a$       -- Ver `trabajadores`: el filtro vive aqui, en el unico lugar del que
       -- salen el conteo, los rechazos y la tabla.
       and not coalesce(c.tiempo_imposible, false)
       -- Ver `trabajadores`: el filtro vive aqui, en el unico lugar del que
       -- salen el conteo, los rechazos y la tabla.
       and not coalesce(c.tiempo_imposible, false)$a$;

  n := $n$       -- Ver `trabajadores`: el filtro vive aqui, en el unico lugar del que
       -- salen el conteo, los rechazos y la tabla.
       and not coalesce(c.tiempo_imposible, false)$n$;

  if position(a in def) > 0 then
    def := replace(def, a, n);
    raise notice 'perfil_de_secador: se quito el filtro duplicado de tiempo_imposible';
  end if;

  execute def;
  raise notice 'perfil_de_secador: usa segundos_minimos_de_secado()';

  -- --------------------------------------------------------- detalle ---
  select pg_get_functiondef('public.detalle_del_carro(bigint)'::regprocedure) into def;

  a := $a$    'tiempo_imposible',        c.tiempo_imposible,$a$;

  n := $n$    'tiempo_imposible',        c.tiempo_imposible,
    -- El tercer tiempo que NO es real, y el unico que esta pantalla no
    -- decia. Un secado de menos de 3 min es un olvido registrado tarde; el
    -- reporte y el perfil del trabajador ya lo dicen, y aqui se leia como un
    -- secado de verdad. La regla la manda segundos_minimos_de_secado().
    --
    -- Solo se declara cuando el carro YA SE ENTREGO: mientras se trabaja, el
    -- secado esta corriendo y el desglose lo muestra "en curso" -- llamarle
    -- olvido a un carro que apenas arranca seria mentir al reves.
    'secado_corto', (
      select c.entregado_en is not null
         and s.seg is not null
         and s.seg < public.segundos_minimos_de_secado()
        from (select sum(e.segundos)::int as seg
                from public.etapas e
               where e.carro_id = c.id and e.etapa = 'secando') s
    ),$n$;

  if position(a in def) = 0 then
    raise exception 'detalle_del_carro: no aparece el ancla de tiempo_imposible. Revisar a mano.';
  end if;
  execute replace(def, a, n);
  raise notice 'detalle_del_carro: ahora dice secado_corto';
end
$do$;

-- ---------------------------------------------------------------------------
-- Comprobacion de SOLO LECTURA.
do $do$
declare
  n_dup int;
begin
  if public.segundos_minimos_de_secado() <> 180 then
    raise exception 'el valor de la regla cambio, y esta migracion no debia cambiarlo';
  end if;

  -- Ya no debe quedar ningun 180 suelto en las funciones que aplican la regla.
  select count(*) into n_dup
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and p.proname in ('reporte_del_rango', 'perfil_de_secador')
     and pg_get_functiondef(p.oid) like '%180%';
  if n_dup > 0 then
    raise exception 'la regla de los 3 min sigue escrita a mano en % funcion(es)', n_dup;
  end if;

  if position('secado_corto' in pg_get_functiondef('public.detalle_del_carro(bigint)'::regprocedure)) = 0 then
    raise exception 'detalle_del_carro no quedo con secado_corto';
  end if;

  raise notice 'una sola regla de secado corto: comprobado';
end
$do$;
