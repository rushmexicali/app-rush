-- =====================================================================
-- 116 - `encimados` deja de recorrer toda la historia
--
-- Hallazgo #25 de la auditoria. La CTE `encimados` de `reporte_del_rango`
-- une `asignaciones` consigo misma por `empleado_id`. El lado izquierdo si
-- esta acotado a los carros del rango, pero el DERECHO (`a2`) mira toda la
-- historia de esa persona. Cuesta ~18 ms por dia consultado y crece
-- cuadratico: el reporte se llama una vez POR CADA dia del rango, asi que
-- un mes son treinta pasadas sobre una tabla que no para de crecer.
--
-- El arreglo es acotar la ventana. Un carro "encimado" es uno que le entro
-- a la persona mientras traia otro sin entregar; ese otro no puede haber
-- arrancado hace tres semanas. Con 24 horas sobra de sobra.
--
-- ⚠️ Comprobado antes de aplicarlo, sobre TODA la historia: sin acotar
-- salen **856** carros encimados, acotado a 24 h salen **856**, y la
-- diferencia entre los dos conjuntos es **0**. No mueve ningun numero de
-- ningun reporte, ni congelado ni al vuelo.
--
-- ---------------------------------------------------------------------
-- Y sobre COMO se aplica, que es la parte que vale:
--
-- La funcion son ~300 lineas de reglas de negocio con sus razones escritas.
-- Reescribirlas aqui para cambiar UNA linea es justo el movimiento que ya
-- salio mal en este proyecto (la `sincronizar_empleados` de la §11.45, que
-- escrita de memoria salio equivocada y habria roto la sincronizacion).
--
-- Asi que esta migracion NO copia la funcion: le pide a Postgres su propia
-- definicion, le inserta la linea, comprueba que el ancla existia, y la
-- vuelve a crear. Si el ancla no aparece, se cae con un mensaje claro en
-- vez de aplicar algo a medias.
-- =====================================================================

do $$
declare
  def   text;
  nuevo text;
  ancla constant text := 'and a2.inicio < a.inicio';
  extra constant text :=
    'and a2.inicio < a.inicio' || E'\n' ||
    '       -- Ventana de 24 h (116): sin ella este lado del join recorre TODA' || E'\n' ||
    '       -- la historia de la persona. Verificado sobre toda la base: los' || E'\n' ||
    '       -- mismos 856 carros encimados con y sin la ventana.' || E'\n' ||
    '       and a2.inicio > a.inicio - interval ''24 hours''';
begin
  select pg_get_functiondef(p.oid) into def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'reporte_del_rango'
     and pg_get_function_identity_arguments(p.oid) = 'p_desde date, p_hasta date';

  if def is null then
    raise exception '116: no encontre reporte_del_rango(date, date)';
  end if;

  -- Ya aplicada: no se vuelve a insertar (si no, quedarian dos ventanas).
  if position('24 hours' in def) > 0 then
    raise notice '116: la ventana ya estaba puesta, no se toca';
    return;
  end if;

  if position(ancla in def) = 0 then
    raise exception '116: no encontre la linea a la que engancharme (%). '
                    'La funcion cambio; hay que revisar a mano.', ancla;
  end if;

  nuevo := replace(def, ancla, extra);

  if nuevo = def then
    raise exception '116: el reemplazo no cambio nada';
  end if;

  execute nuevo;
end $$;
