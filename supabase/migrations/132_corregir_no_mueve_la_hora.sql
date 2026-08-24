-- 132 · Corregir deja de mover la hora de las asignaciones, y por fin puede
--       dejar en blanco el tipo o el color
--
-- Dos hallazgos de la auditoria del 21-22/ago, los dos en `editar_carro`, que
-- es la funcion detras del boton "Corregir". Se verificaron contra produccion
-- antes de tocar nada.
--
-- ---------------------------------------------------------------------------
-- 1) CORREGIR EL COLOR LE MOVIA LA HORA DE ASIGNACION AL CARRO
--
--    Cuando venian secadores (`p_empleados is not null`), la funcion BORRABA
--    todas las asignaciones abiertas y las volvia a insertar con
--    `inicio = now()`. Y la pantalla de Corregir manda SIEMPRE la lista,
--    porque los secadores vienen preseleccionados -- o sea que corregir
--    unicamente el COLOR de un carro que llevaba 50 minutos secando le movia
--    la hora de asignacion 50 minutos adelante, sin que nadie tocara un
--    secador.
--
--    No es cosmetico. `encimados` del reporte compara justo esas horas:
--
--        and a2.inicio < a.inicio
--
--    o sea la metrica de saturacion, la MISMA que ya produjo un juicio falso
--    por escrito sobre dos personas con nombre (migracion 105 y CLAUDE.md
--    §11.50). Y corrompe en las DOS direcciones: al carro corregido le
--    aparecen encimados que no tuvo, y a los carros que le siguieron les
--    desaparece el encimado que si tuvieron.
--
--    Medido hoy sobre toda la historia, antes de tocar: de 2,888 carros con
--    asignacion, 33 (1.1%) traen la hora de asignacion mas de 90 s DESPUES
--    del arranque de su propia etapa de secado, el peor por 36 minutos. Ya no
--    se puede saber cuales de esos 33 fueron una reasignacion de verdad y
--    cuales una correccion de color -- y esa imposibilidad es justamente el
--    argumento para arreglarlo.
--
--    Lo que NO estaba mal, y conviene dejar claro: las ETAPAS nunca se
--    tocaron, asi que el cronometro de secado tampoco se reiniciaba. Eso que
--    el CLAUDE.md promete siempre fue cierto. Lo que se movia era la hora de
--    la ASIGNACION, que es otro dato y alimenta otra cuenta.
--
--    🔑 ARREGLO CON EL DELTA MAS CHICO POSIBLE. Se penso primero en
--    reconciliar (quitar al que sobra, agregar al que falta, no tocar al que
--    sigue), y se descarto: cambiaba el juego de filas en casos raros y
--    rompia un caso de `pruebas/editar-y-foto.sql` -- la misma persona
--    listada dos veces con dos nombres pasaba de 2 filas a 1. Cuando un
--    arreglo cambia algo que nadie pidio cambiar, el arreglo esta de mas.
--
--    Lo que se hace es: se apunta la hora que YA tenia cada asignacion
--    abierta, se borra y se reinserta exactamente igual que antes, y a cada
--    fila se le devuelve su hora si esa misma pareja (persona, nombre) ya
--    estaba. El que llega nuevo entra con `now()`, que es la verdad. O sea
--    que el juego de filas queda IDENTICO al de antes y lo unico distinto es
--    `inicio` -- que es justo el bug.
--
--    Dicho de frente lo que NO cubre: si a una persona le cambia el nombre en
--    Jibble entre una correccion y otra (paso con "Saul de" -> "Saul de
--    Anda", migracion 056), la pareja no casa y esa fila si reinicia su hora.
--    Es el comportamiento de hoy, o sea que no empeora nada; solo no mejora
--    ese caso.
--
-- ---------------------------------------------------------------------------
-- 2) QUITAR EL TIPO O EL COLOR RESPONDIA "ok" Y NO BORRABA NADA
--
--    En la pantalla de Corregir, el segundo toque sobre el tipo o el color ya
--    seleccionado lo DESELECCIONA (docs/index.html, `? null :`). Eso llegaba
--    aqui como null, y el `coalesce(nuevo_tipo, tipo_unidad)` lo interpretaba
--    como "no tocar": la funcion contestaba `ok`, la pantalla se cerraba, y el
--    valor equivocado seguia ahi. El supervisor creia que lo habia borrado.
--
--    La regla que queda es la unica honesta con esa pantalla: EN CORREGIR, LO
--    QUE MUESTRA LA PANTALLA ES LA VERDAD. La pantalla se abre precargada con
--    lo que hay guardado, asi que un nulo al guardar solo puede significar dos
--    cosas -- que ya estaba vacio, o que el supervisor lo vacio a proposito --
--    y en las dos escribir el nulo es lo correcto.
--
--    Se puede hacer porque `editar_carro` tiene UNA sola llamadora: la ruta
--    /editar, que es Corregir y nada mas (comprobado en pg_proc y en el Edge
--    Function). Ninguna otra le manda nulos con el sentido de "no toques esto".
--
--    LA MARCA NO ENTRA A ESTO Y CONSERVA SU `coalesce`. La marca ya no la
--    captura el supervisor: sale de la FOTO (061), y /editar le manda `null`
--    SIEMPRE. Con la regla nueva, cada Corregir borraria la marca que la foto
--    leyo. Es la misma leccion de la migracion 109 -- "un nulo no borra" --
--    aplicada a un campo y no a los tres, porque quien manda el dato es
--    distinto en cada caso: el tipo y el color los ve el supervisor en la
--    pantalla; la marca no.
--
--    Y `datos_de_nota` se ajusta para que VACIAR tambien cuente como que el
--    supervisor toco algo (la 051 solo miraba los valores no nulos).
--
-- ---------------------------------------------------------------------------
-- COMO SE APLICA: la funcion son ~120 lineas de reglas con sus razones
-- escritas. Reescribirlas para cambiar unos bloques es el movimiento que ya
-- salio mal en este proyecto (§11.45), asi que esta migracion NO copia la
-- funcion: le pide a Postgres su propia definicion, le cambia los bloques con
-- anclas comprobadas, y la vuelve a crear. Si un ancla no aparece se cae con
-- un mensaje claro, en vez de aplicar algo a medias. Es el patron de las
-- migraciones 117 y 130.

do $do$
declare
  def text;
  a1  text;  n1  text;   -- las variables nuevas del declare
  a2  text;  n2  text;   -- el borra-y-reinserta de las asignaciones
  a3  text;  n3  text;   -- el update de carros con los coalesce
begin
  select pg_get_functiondef(
    'public.editar_carro(bigint, text, text, text, smallint, text[], text[])'::regprocedure
  ) into def;

  -- ------------------------------------------------------------------ 1 ---
  a1 := $a$  cuantos       int;
  i             int;
begin$a$;

  n1 := $n$  cuantos       int;
  i             int;
  horas         jsonb;     -- pareja (persona, nombre) -> hora que ya tenia
  emp_i         text;
  nom_i         text;
  clave         text;
begin$n$;

  -- ------------------------------------------------------------------ 2 ---
  a2 := $a$    -- Se BORRAN las asignaciones abiertas: eran la captura equivocada que
    -- se esta corrigiendo, no un hecho que conservar. Las que ya tienen
    -- fin (de un Regresar anterior) no se tocan. Las etapas NO se tocan,
    -- asi que el tiempo de secado no se pierde ni se reinicia.
    delete from public.asignaciones
     where carro_id = p_carro and fin is null;

    for i in 1 .. cuantos loop
      insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
      values (
        p_carro, ln, btrim(p_secadores[i]),
        case when array_length(p_empleados, 1) >= i then p_empleados[i] else null end,
        now()
      );
    end loop;$a$;

  n2 := $n$    -- Se apunta la hora que YA tenia cada asignacion abierta, por pareja
    -- (persona, nombre). Es lo unico que hace falta para que una correccion
    -- que no cambia secadores no les mueva el reloj.
    --
    -- 🔴 Antes esto borraba y reinsertaba TODO con inicio = now(), aunque el
    -- supervisor no hubiera cambiado ni un secador -- y la pantalla de
    -- Corregir manda siempre la lista, porque viene preseleccionada. O sea
    -- que corregir el COLOR de un carro con 50 min de secado le movia la
    -- hora de asignacion 50 min adelante. Eso envenena `encimados` del
    -- reporte, que compara justo esas horas (a2.inicio < a.inicio), que es
    -- la metrica de saturacion.
    select coalesce(jsonb_object_agg(s.k, to_jsonb(s.ts)), '{}'::jsonb)
      into horas
      from (
        select coalesce(a.empleado_id, '') || '|' || btrim(coalesce(a.secador, '')) as k,
               min(a.inicio) as ts
          from public.asignaciones a
         where a.carro_id = p_carro and a.fin is null
         group by 1
      ) s;

    -- Se BORRAN las asignaciones abiertas: eran la captura equivocada que
    -- se esta corrigiendo, no un hecho que conservar. Las que ya tienen
    -- fin (de un Regresar anterior) no se tocan. Las etapas NO se tocan,
    -- asi que el tiempo de secado no se pierde ni se reinicia.
    delete from public.asignaciones
     where carro_id = p_carro and fin is null;

    for i in 1 .. cuantos loop
      emp_i := case when array_length(p_empleados, 1) >= i then p_empleados[i] else null end;
      nom_i := btrim(p_secadores[i]);
      clave := coalesce(emp_i, '') || '|' || nom_i;

      insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
      values (
        p_carro, ln, nom_i, emp_i,
        -- El que ya estaba CONSERVA SU HORA: empezo cuando empezo. El que
        -- llega nuevo entra con now(), que es la verdad.
        coalesce((horas ->> clave)::timestamptz, now())
      );
    end loop;$n$;

  -- ------------------------------------------------------------------ 3 ---
  a3 := $a$  -- datos_de_nota solo se apaga si el supervisor CAMBIA algo (051).
  -- Reenviar el mismo valor no la apaga.
  toco_datos := (nuevo_tipo  is not null and nuevo_tipo  is distinct from actual_tipo)
             or (nuevo_color is not null and nuevo_color is distinct from actual_color);

  update public.carros
     set tipo_unidad   = coalesce(nuevo_tipo, tipo_unidad),
         color         = coalesce(nuevo_color, color),$a$;

  n3 := $n$  -- datos_de_nota solo se apaga si el supervisor CAMBIA algo (051).
  -- Reenviar el mismo valor no la apaga. VACIAR tambien cuenta como cambio:
  -- por eso ya no se exige `is not null`, que era lo que dejaba fuera el caso
  -- de borrar.
  toco_datos := (nuevo_tipo  is distinct from actual_tipo)
             or (nuevo_color is distinct from actual_color);

  -- En Corregir, LO QUE MUESTRA LA PANTALLA ES LA VERDAD: se abre precargada
  -- con lo guardado, asi que un nulo aqui solo puede ser "ya estaba vacio" o
  -- "el supervisor lo vacio", y en los dos casos se escribe el nulo. Antes el
  -- coalesce lo tomaba como "no tocar", contestaba `ok` y no borraba nada.
  --
  -- ⚠️ LA MARCA SI CONSERVA SU coalesce, y la diferencia importa: la marca la
  -- pone la FOTO (061), no el supervisor, y /editar le manda null SIEMPRE.
  -- Sin el coalesce, cada Corregir borraria lo que la foto leyo -- que es
  -- exactamente el error que la migracion 109 arreglo.
  update public.carros
     set tipo_unidad   = nuevo_tipo,
         color         = nuevo_color,$n$;

  if position(a1 in def) = 0 then
    raise exception 'editar_carro: no aparece el ancla del declare. Revisar a mano.';
  end if;
  if position(a2 in def) = 0 then
    raise exception 'editar_carro: no aparece el ancla del borra-y-reinserta. Revisar a mano.';
  end if;
  if position(a3 in def) = 0 then
    raise exception 'editar_carro: no aparece el ancla del update de carros. Revisar a mano.';
  end if;

  def := replace(replace(replace(def, a1, n1), a2, n2), a3, n3);
  execute def;
  raise notice 'editar_carro: conserva la hora de asignacion y respeta el vaciado de tipo/color';
end
$do$;

-- ---------------------------------------------------------------------------
-- Comprobacion de SOLO LECTURA: que la funcion viva quedo como se queria.
-- La prueba de COMPORTAMIENTO vive en pruebas/corregir-no-mueve-la-hora.sql,
-- con el patron do-$$-raise que revierte. Una comprobacion que escribe no
-- puede vivir aqui: es la leccion de la migracion 131, que al aplicarse dejo
-- un aviso falso en el panel del dueno.
do $do$
declare
  def text;
begin
  select pg_get_functiondef(
    'public.editar_carro(bigint, text, text, text, smallint, text[], text[])'::regprocedure
  ) into def;

  if position('CONSERVA SU HORA' in def) = 0 then
    raise exception 'editar_carro: no quedo el rescate de la hora de asignacion';
  end if;
  if position('coalesce((horas ->> clave)::timestamptz, now())' in def) = 0 then
    raise exception 'editar_carro: la insercion no esta devolviendo la hora guardada';
  end if;
  if position('coalesce(nuevo_tipo, tipo_unidad)' in def) > 0 then
    raise exception 'editar_carro: el tipo sigue sin poderse vaciar';
  end if;
  if position('coalesce(nuevo_color, color)' in def) > 0 then
    raise exception 'editar_carro: el color sigue sin poderse vaciar';
  end if;
  -- Y la marca SI tiene que seguir con su coalesce, o cada Corregir borraria
  -- lo que leyo la foto.
  if position($x$coalesce(nullif(btrim(upper(coalesce(p_marca, ''))), ''), marca)$x$ in def) = 0 then
    raise exception 'editar_carro: la marca perdio su coalesce y un Corregir la borraria';
  end if;

  raise notice 'editar_carro: comprobado';
end
$do$;
