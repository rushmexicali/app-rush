-- Prueba de la migracion 110: el perfil del trabajador pagina y filtra sin
-- que los numeros de arriba se contradigan con la tabla de abajo.
--
-- No arma escenario: mide contra los datos REALES de la persona con mas
-- carros, que es justo el caso que motivo la migracion (346 carros en una
-- sola respuesta). Aun asi va en `do $$ ... raise` por costumbre: si algun
-- dia se le agrega una siembra, ya revierte.
--
--   bash scripts/releer-fotos/q.sh pruebas/perfil-paginado.sql
--
-- Pasa si el mensaje final dice "PRUEBA PASADA".
do $$
declare
  v_emp    text;
  v_todo   jsonb;
  v_p1     jsonb;
  v_p2     jsonb;
  v_con    jsonb;
  v_sin    jsonb;
  v_enc    jsonb;
  v_dia    jsonb;
  v_fecha  date;
  v_total  int;
  v_n      int;
  v_msg    text := '';
begin
  -- La persona con mas carros: el peor caso de tamano de respuesta.
  select a.empleado_id into v_emp
    from public.asignaciones a
    join public.carros c on c.id = a.carro_id
   where a.empleado_id is not null and not c.es_prueba and c.cancelado_en is null
   group by a.empleado_id
   order by count(distinct a.carro_id) desc
   limit 1;

  if v_emp is null then
    raise exception 'FALLA: no hay ningun secador con carros para probar';
  end if;

  -- ---------- 1) limite 0 = todo, y el conteo cuadra con las filas ----------
  v_todo  := public.perfil_de_secador(v_emp, p_limite := 0);
  v_total := (v_todo->>'total')::int;

  if v_total < 20 then
    raise exception 'FALLA: el escenario no sirve, el que mas carros tiene solo trae %', v_total;
  end if;
  if jsonb_array_length(v_todo->'historial') <> v_total then
    raise exception 'FALLA: limite 0 devolvio % filas para un total de %',
      jsonb_array_length(v_todo->'historial'), v_total;
  end if;
  if (v_todo->>'lavados')::int <> v_total then
    raise exception 'FALLA: lavados (%) no cuadra con total (%)', v_todo->>'lavados', v_total;
  end if;
  v_msg := v_msg || 'limite 0 OK (' || v_total || ' carros). ';

  -- ---------- 2) la pagina no pierde ni repite carros ----------
  v_p1 := public.perfil_de_secador(v_emp, p_limite := 10);
  v_p2 := public.perfil_de_secador(v_emp, p_limite := 10, p_saltar := 10);

  if jsonb_array_length(v_p1->'historial') <> 10
     or jsonb_array_length(v_p2->'historial') <> 10 then
    raise exception 'FALLA: las paginas no traen 10 filas (% y %)',
      jsonb_array_length(v_p1->'historial'), jsonb_array_length(v_p2->'historial');
  end if;

  -- El total NO cambia al paginar: es el que le dice al dueno cuanto falta.
  if (v_p1->>'total')::int <> v_total then
    raise exception 'FALLA: el total cambio al paginar (% vs %)', v_p1->>'total', v_total;
  end if;

  select count(distinct x) into v_n
    from (
      select jsonb_array_elements(v_p1->'historial')->>'carro_id' as x
      union all
      select jsonb_array_elements(v_p2->'historial')->>'carro_id'
    ) t;
  if v_n <> 20 then
    raise exception 'FALLA: las dos paginas comparten carros (% distintos de 20)', v_n;
  end if;

  -- La segunda pagina va DESPUES en el tiempo (orden descendente estable).
  if (v_p1->'historial'->9->>'fecha')::timestamptz
     < (v_p2->'historial'->0->>'fecha')::timestamptz then
    raise exception 'FALLA: la pagina 2 trae carros mas nuevos que la 1';
  end if;
  v_msg := v_msg || 'paginado OK. ';

  -- ---------- 3) el filtro por tipo PARTE el total, no lo inventa ----------
  v_con := public.perfil_de_secador(v_emp, p_tipo := 'con_aspirado', p_limite := 0);
  v_sin := public.perfil_de_secador(v_emp, p_tipo := 'sin_aspirado', p_limite := 0);
  v_enc := public.perfil_de_secador(v_emp, p_tipo := 'encerado',     p_limite := 0);

  if (v_con->>'total')::int + (v_sin->>'total')::int + (v_enc->>'total')::int > v_total then
    raise exception 'FALLA: los tres tipos suman mas que el total (% + % + % > %)',
      v_con->>'total', v_sin->>'total', v_enc->>'total', v_total;
  end if;
  if (v_con->>'total')::int = 0 then
    raise exception 'FALLA: el que mas seca no tiene ni un carro con aspirado';
  end if;
  if jsonb_array_length(v_con->'historial') <> (v_con->>'total')::int then
    raise exception 'FALLA: con el filtro puesto, el contador y la tabla no cuadran';
  end if;
  v_msg := v_msg || 'filtro por tipo OK. ';

  -- ---------- 4) el filtro por dia usa el dia LOCAL ----------
  select (creado_en at time zone 'America/Tijuana')::date into v_fecha
    from public.carros c
   where c.id in (select carro_id from public.asignaciones where empleado_id = v_emp)
     and not c.es_prueba and c.cancelado_en is null
   order by creado_en desc limit 1;

  v_dia := public.perfil_de_secador(v_emp, p_desde := v_fecha, p_hasta := v_fecha, p_limite := 0);

  if (v_dia->>'total')::int = 0 then
    raise exception 'FALLA: filtrando por el dia de su ultimo carro no salio ninguno (dia local %)', v_fecha;
  end if;
  if (v_dia->>'total')::int >= v_total then
    raise exception 'FALLA: filtrar por un dia devolvio todo (% de %)', v_dia->>'total', v_total;
  end if;

  select count(*) into v_n
    from jsonb_array_elements(v_dia->'historial') h
   where ((h->>'fecha')::timestamptz at time zone 'America/Tijuana')::date <> v_fecha;
  if v_n <> 0 then
    raise exception 'FALLA: el filtro por dia dejo pasar % carros de otro dia', v_n;
  end if;
  v_msg := v_msg || 'filtro por dia OK. ';

  -- ---------- 5) los rechazos tambien respetan el filtro ----------
  if (v_dia->>'rechazos')::int > (v_todo->>'rechazos')::int then
    raise exception 'FALLA: un dia solo trae mas rechazos (%) que toda la historia (%)',
      v_dia->>'rechazos', v_todo->>'rechazos';
  end if;
  v_msg := v_msg || 'rechazos filtrados OK. ';

  raise exception 'PRUEBA PASADA -> %', v_msg;
end $$;
