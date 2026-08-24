-- Prueba de la migracion 132:
--
--   Corregir un carro que ya seca NO le mueve la hora de las asignaciones
--   cuando no se cambia ningun secador; y quitar el tipo o el color en
--   Corregir de verdad los deja en blanco (antes contestaba "ok" y no
--   borraba nada).
--
-- Corre contra la base real y REVIERTE TODO con el raise final.
--
--   bash scripts/releer-fotos/q.sh pruebas/corregir-no-mueve-la-hora.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_venta   bigint;
  v_emp     text;
  v_emp2    text;
  c1        bigint;
  r         jsonb;
  h0        timestamptz;
  h1        timestamptz;
  h_nuevo   timestamptz;
  v_txt     text;
  v_n       int;
  v_msg     text := '';
begin
  select id into v_venta from public.ventas order by id desc limit 1;
  select id into v_emp  from public.empleados order by id limit 1;
  select id into v_emp2 from public.empleados order by id offset 1 limit 1;

  if v_emp2 is null then
    raise exception 'FALLA: el escenario necesita dos empleados y solo hay uno';
  end if;

  -- Un carro que lleva 40 minutos secando, con un secador asignado desde
  -- entonces. Es el escenario del hallazgo: el supervisor entra a Corregir
  -- SOLO para arreglar el color.
  insert into public.carros
    (purchase_uuid, venta_id, producto, variante, monto, creado_en,
     estado, linea, tipo_unidad, color, marca, es_prueba)
  values
    ('prueba-132-' || gen_random_uuid(), v_venta, 'Completo RUSH', 'Chico', 270,
     now() - interval '55 minutes', 'secando', 2, 'camioneta', 'BLANCA', 'TOYOTA', true)
  returning id into c1;

  insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
  values (c1, 2, 'PRUEBA132A', v_emp, now() - interval '40 minutes');

  select inicio into h0 from public.asignaciones where carro_id = c1 and fin is null;

  -- ==================================================================
  -- 1) EL BUG VIEJO, REPRODUCIDO A MANO
  --    Es lo que hacia la funcion antes: borrar y reinsertar con now().
  --    Si esto dejara de mover la hora, la prueba estaria midiendo otra cosa
  --    y hay que enterarse.
  -- ==================================================================
  delete from public.asignaciones where carro_id = c1 and fin is null;
  insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
  values (c1, 2, 'PRUEBA132A', v_emp, now());

  select inicio into h1 from public.asignaciones where carro_id = c1 and fin is null;
  if h1 <= h0 + interval '30 minutes' then
    raise exception 'FALLA: el bug viejo ya no se reproduce; esta prueba dejo de medir lo que cree';
  end if;
  v_msg := v_msg || 'bug viejo reproducido OK. ';

  -- Se deja el escenario como estaba para probar la funcion de verdad.
  delete from public.asignaciones where carro_id = c1 and fin is null;
  insert into public.asignaciones (carro_id, linea, secador, empleado_id, inicio)
  values (c1, 2, 'PRUEBA132A', v_emp, now() - interval '40 minutes');

  -- ==================================================================
  -- 2) CORREGIR SOLO EL COLOR NO LE MUEVE LA HORA AL SECADOR
  -- ==================================================================
  r := public.editar_carro(
         p_carro     := c1,
         p_tipo_unidad := 'camioneta',
         p_color     := 'NEGRA',
         p_linea     := 2::smallint,
         p_secadores := array['PRUEBA132A'],
         p_empleados := array[v_emp]);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: rechazo un guardado valido -> %', r->>'error';
  end if;

  select color into v_txt from public.carros where id = c1;
  if v_txt is distinct from 'NEGRA' then
    raise exception 'FALLA: el color no se guardo (quedo %)', v_txt;
  end if;

  select inicio into h1 from public.asignaciones where carro_id = c1 and fin is null;
  if h1 is distinct from h0 then
    raise exception 'FALLA: corregir el color movio la hora de asignacion de % a %', h0, h1;
  end if;
  v_msg := v_msg || 'corregir el color no mueve la hora OK. ';

  -- Y el juego de filas quedo igual que antes: una sola.
  select count(*) into v_n from public.asignaciones where carro_id = c1 and fin is null;
  if v_n <> 1 then
    raise exception 'FALLA: quedaron % asignaciones abiertas en vez de 1', v_n;
  end if;

  -- ==================================================================
  -- 3) AGREGAR UN SECADOR: el que ya estaba conserva su hora, el nuevo
  --    entra con la de ahora.
  -- ==================================================================
  r := public.editar_carro(
         p_carro     := c1,
         p_secadores := array['PRUEBA132A', 'PRUEBA132B'],
         p_empleados := array[v_emp, v_emp2]);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: rechazo el alta de un segundo secador -> %', r->>'error';
  end if;

  select count(*) into v_n from public.asignaciones where carro_id = c1 and fin is null;
  if v_n <> 2 then
    raise exception 'FALLA: se esperaban 2 secadores y quedaron %', v_n;
  end if;

  select inicio into h1 from public.asignaciones
   where carro_id = c1 and fin is null and empleado_id = v_emp;
  if h1 is distinct from h0 then
    raise exception 'FALLA: al agregar a otro, al primero se le movio la hora de % a %', h0, h1;
  end if;

  select inicio into h_nuevo from public.asignaciones
   where carro_id = c1 and fin is null and empleado_id = v_emp2;
  if h_nuevo < now() - interval '2 minutes' then
    raise exception 'FALLA: el secador NUEVO entro con una hora vieja (%)', h_nuevo;
  end if;
  v_msg := v_msg || 'el que llega entra con su hora y el que sigue conserva la suya OK. ';

  -- ==================================================================
  -- 4) QUITAR UN SECADOR: se va solo ese, y al que queda no se le mueve
  -- ==================================================================
  r := public.editar_carro(
         p_carro     := c1,
         p_secadores := array['PRUEBA132A'],
         p_empleados := array[v_emp]);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: rechazo quitar un secador -> %', r->>'error';
  end if;

  select count(*) into v_n from public.asignaciones where carro_id = c1 and fin is null;
  if v_n <> 1 then
    raise exception 'FALLA: al quitar uno quedaron % asignaciones', v_n;
  end if;

  select inicio into h1 from public.asignaciones where carro_id = c1 and fin is null;
  if h1 is distinct from h0 then
    raise exception 'FALLA: quitar al otro le movio la hora al que se queda (% -> %)', h0, h1;
  end if;
  v_msg := v_msg || 'quitar a uno no le mueve la hora al otro OK. ';

  -- ==================================================================
  -- 5) VACIAR EL TIPO Y EL COLOR DE VERDAD LOS DEJA EN BLANCO
  -- ==================================================================
  r := public.editar_carro(
         p_carro       := c1,
         p_tipo_unidad := null,
         p_color       := null,
         p_secadores   := array['PRUEBA132A'],
         p_empleados   := array[v_emp]);

  if not (r->>'ok')::boolean then
    raise exception 'FALLA: rechazo el vaciado -> %', r->>'error';
  end if;

  select tipo_unidad into v_txt from public.carros where id = c1;
  if v_txt is not null then
    raise exception 'FALLA: el tipo no se vacio (quedo %)', v_txt;
  end if;
  select color into v_txt from public.carros where id = c1;
  if v_txt is not null then
    raise exception 'FALLA: el color no se vacio (quedo %)', v_txt;
  end if;
  v_msg := v_msg || 'el vaciado si borra OK. ';

  -- ==================================================================
  -- 6) LA MARCA NO SE BORRA. /editar le manda null SIEMPRE porque la pone
  --    la foto (061); si el nulo la borrara, cada Corregir tiraria lo que
  --    la foto leyo. Es la leccion de la migracion 109.
  -- ==================================================================
  select marca into v_txt from public.carros where id = c1;
  if v_txt is distinct from 'TOYOTA' then
    raise exception 'FALLA: un Corregir borro la marca que habia leido la foto (quedo %)', v_txt;
  end if;
  v_msg := v_msg || 'la marca de la foto sobrevive OK. ';

  -- ==================================================================
  -- 7) Y las ETAPAS siguen sin tocarse: el cronometro de secado no se
  --    reinicia. Era cierto antes y tiene que seguir siendolo.
  -- ==================================================================
  select count(*) into v_n from public.etapas where carro_id = c1;
  if v_n <> 0 then
    raise exception 'FALLA: editar_carro creo % etapas, y no debe crear ninguna', v_n;
  end if;
  v_msg := v_msg || 'no toca las etapas OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end
$$;
