-- =====================================================================
-- 121 - Los dias congelados por fin traen los campos que se les agregaron
--
-- La migracion `107` (19/ago) agrego cuatro campos al reporte para arreglar
-- cuatro numeros que se contradecian —`entregados`, `secado_por_tipo`,
-- `sin_equipo_por_tipo`— y **nunca se recongelo el historico**: medido el
-- 21/ago, 31 de 33 dias guardados no los traen. O sea que la correccion
-- existe en la funcion y no se ve en ningun dia del historial, que es la
-- mitad del trabajo. Se suman tambien los dos campos de la `120`
-- (`devoluciones`, `devoluciones_tras_entregar`).
--
-- 🔑 SE COMPROBO ANTES, CAMPO POR CAMPO, que recongelar no reescribe ningun
-- numero: se compararon los 33 dias guardados contra un recalculo fresco y
-- **toda** diferencia es un campo que FALTA en lo guardado, no un valor
-- distinto. La unica excepcion es el `secado_promedio_seg` del **19/jul**,
-- que arrastra una version vieja de la funcion y que la `105` ya habia
-- dejado fuera del re-congelado a proposito. Se respeta esa decision: el
-- 19/jul no se toca.
--
-- Se conservan las DOS marcas de tiempo:
--   * `congelado_en` (columna) es la hora del corte y es un hecho.
--   * `datos->generado_en` es cuando se calculo lo que se guardo.
-- Reescribirlas haria que "congelado" dejara de significar congelado.
-- Es el mismo criterio de `recongelar_placas_del_dia` (migracion 104).
-- =====================================================================
do $$
declare
  n int;
begin
  update public.reportes_diarios rd
     set datos = jsonb_set(
                   public.reporte_del_rango(rd.fecha, rd.fecha),
                   '{generado_en}',
                   coalesce(rd.datos -> 'generado_en', to_jsonb(now()))
                 )
   where rd.fecha <> date '2026-07-19';
  get diagnostics n = row_count;
  raise notice 'recongelados % dias (el 19/jul se dejo fuera a proposito)', n;
end $$;

-- Comprobacion inmediata: ningun dia guardado puede quedarse sin los campos.
do $$
declare faltan int;
begin
  select count(*) into faltan
    from public.reportes_diarios
   where fecha <> date '2026-07-19'
     and not (datos ? 'entregados' and datos ? 'secado_por_tipo'
              and datos ? 'sin_equipo_por_tipo' and datos ? 'devoluciones'
              and datos ? 'devoluciones_tras_entregar');
  if faltan > 0 then
    raise exception 'FALLA: quedaron % dias sin los campos nuevos', faltan;
  end if;
end $$;
