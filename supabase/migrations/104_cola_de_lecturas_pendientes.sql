-- =====================================================================
-- 104 — La lectura de la foto se reintenta sola en el servidor
--
-- El 17/ago/2026, de 16:40 a 18:20, 17 carros seguidos subieron foto y la
-- lectura NUNCA corrio: `placa_en` quedo nulo. La foto se guardo bien (eso
-- ya estaba resuelto), pero el tramo servidor -> Anthropic se cayo y el
-- dato se perdio en silencio hasta que alguien lo encontro dos dias
-- despues. Ver CLAUDE.md §11.60.
--
-- POR QUE EL SERVIDOR Y NO EL TELEFONO: la cola durable del front (3/ago)
-- reintenta la SUBIDA, y tiene un candado a proposito — "si el servidor ya
-- tiene la foto, se descarta sin subir; asi jamas se re-lee en Claude una
-- foto ya guardada". Esta bien que sea asi. Ademas, en la caida del 17 el
-- telefono si tenia internet: la foto subio perfecto. Lo que fallo fue la
-- lectura, del lado del servidor. Ahi es donde tiene que vivir el
-- reintento.
--
-- POR QUE NO HAY TABLA DE COLA: ya existe. Un carro con foto guardada y
-- `placa_en` nulo ES un pendiente de leer — esa es justo la semantica que
-- el proyecto ya documenta ("nulo = nunca se intento; con fecha y placa
-- vacia = se intento y no se pudo"). Inventar una segunda lista seria
-- tener dos verdades para la misma pregunta, el error que este proyecto ya
-- cometio varias veces.
-- =====================================================================

-- --------------------------------------------------------------------
-- 1) El contador de intentos
--
-- No es para rendirse rapido: es el unico freno contra una foto que de
-- plano no se puede procesar (corrupta en Storage), que si no se
-- reintentaria para siempre y cobrando cada vez. Una foto ILEGIBLE no
-- llega aqui: esa si tuvo lectura, el modelo dijo "no veo placa", y
-- `placa_en` la saca de la cola.
-- --------------------------------------------------------------------
alter table public.carros
  add column if not exists placa_intentos   smallint    not null default 0,
  add column if not exists placa_intento_en timestamptz;

comment on column public.carros.placa_intentos is
  'Cuantas veces el obrero de fondo intento leer esta foto. Se reinicia cuando se sube una foto nueva.';

-- El indice tiene el MISMO predicado que la cola, para que preguntar
-- "¿hay pendientes?" cada minuto no cueste nada cuando la respuesta es no.
create index if not exists carros_lectura_pendiente_idx
  on public.carros (coalesce(foto_en, creado_en))
  where foto_path is not null
    and placa_en is null
    and cancelado_en is null
    and not coalesce(es_prueba, false);

-- --------------------------------------------------------------------
-- 2) El tope de intentos, en UN solo lugar
--
-- Lo consultan la cola (a quien reintentar) y el conteo del reporte
-- (quien se rindio). Copiar el numero en los dos seria la misma trampa de
-- siempre.
-- --------------------------------------------------------------------
create or replace function public.placa_max_intentos()
returns int language sql immutable as $$ select 20 $$;

comment on function public.placa_max_intentos() is
  '20 intentos con espera creciente (tope 15 min) cubren ~4.5 h de caida. Mas alla, se rinde y se ve en el reporte.';

-- --------------------------------------------------------------------
-- 3) QUIEN es elegible — la regla, en UN solo lugar
--
-- La consultan el obrero (a quien leer ahora) y el disparador (¿hay algo
-- que hacer?). Tener el mismo `where` copiado en dos funciones es
-- exactamente como se desincronizan: alguien afina el backoff en una y la
-- otra sigue disparando de mas. Se descubrio en la prueba, no leyendo.
-- --------------------------------------------------------------------
create or replace view public.fotos_por_leer as
select c.id,
       c.foto_path,
       (c.creado_en at time zone 'America/Tijuana')::date as dia,
       coalesce(c.foto_en, c.creado_en)                   as desde
from public.carros c
where c.foto_path is not null
  and c.placa_en is null
  and c.cancelado_en is null
  and not coalesce(c.es_prueba, false)
  -- Gracia de 3 min: la lectura en vivo de /foto todavia puede venir en
  -- camino (corta a los 25 s, mas la subida). Sin esto, el obrero pagaria
  -- una segunda lectura de algo que ya se estaba leyendo.
  and coalesce(c.foto_en, c.creado_en) < now() - interval '3 minutes'
  and c.placa_intentos < public.placa_max_intentos()
  -- Espera creciente 2, 4, 8, 15, 15... min. Con TOPE, porque el punto es
  -- que se arregle solo en cuanto vuelva el servicio; un backoff sin techo
  -- dejaria un carro esperando horas despues de que ya se podia leer.
  and (c.placa_intento_en is null
       or c.placa_intento_en <
          now() - least(interval '15 minutes',
                        interval '2 minutes' * power(2, c.placa_intentos)));

comment on view public.fotos_por_leer is
  'Cola de fotos pendientes de leer. No es una tabla: la cola SON los carros con foto y placa_en nulo.';

-- --------------------------------------------------------------------
-- 4) La cola: entrega el siguiente lote Y marca el intento
--
-- Marcar aqui adentro, y no despues, es lo que evita que dos corridas del
-- cron encimadas lean la misma foto dos veces (y la cobren dos veces).
-- `for update skip locked` hace lo mismo si llegaran a coincidir.
-- --------------------------------------------------------------------
create or replace function public.fotos_pendientes_de_leer(p_limite int default 10)
returns table (id bigint, foto_path text, dia date)
language plpgsql
as $$
begin
  return query
  with elegibles as (
    select c.id
    from public.carros c
    where c.id in (select v.id from public.fotos_por_leer v
                    order by v.desde
                    limit greatest(1, coalesce(p_limite, 10)))
    for update skip locked
  )
  update public.carros c
     set placa_intentos   = c.placa_intentos + 1,
         placa_intento_en = now()
    from elegibles e
   where c.id = e.id
  returning c.id, c.foto_path,
            (c.creado_en at time zone 'America/Tijuana')::date;
end $$;

-- --------------------------------------------------------------------
-- 4) El reporte congelado se corrige SOLO en el bloque `placas`
--
-- Una lectura que llega tarde cambia cuantas placas se alcanzaron a leer
-- ese dia, y nada mas. Recalcular el reporte entero haria que "congelado"
-- dejara de significar congelado: cualquier otro cambio posterior (una
-- correccion de captura, por ejemplo) se colaria sin que nadie lo pidiera.
-- Se toca el campo que cambio y ya. `congelado_en` NO se mueve: la hora
-- del corte es un hecho.
-- --------------------------------------------------------------------
create or replace function public.recongelar_placas_del_dia(p_fecha date)
returns boolean
language plpgsql
as $$
declare
  v_nuevo jsonb;
begin
  -- El dia de hoy todavia no tiene fila; se calcula al vuelo y no hay nada
  -- que corregir.
  if not exists (select 1 from public.reportes_diarios where fecha = p_fecha) then
    return false;
  end if;

  v_nuevo := (public.reporte_del_dia(p_fecha)) -> 'placas';

  update public.reportes_diarios
     set datos = jsonb_set(datos, '{placas}', v_nuevo)
   where fecha = p_fecha
     and datos -> 'placas' is distinct from v_nuevo;

  return found;
end $$;

-- --------------------------------------------------------------------
-- 5) Que se vea, sin ser una alarma
--
-- Va APARTE del reporte congelado (mismo patron que la alerta de placas
-- repetidas, migracion 095): es solo lectura y sirve para cualquier dia o
-- rango. Si el obrero esta trabajando, `esperando` baja solo; si se queda
-- pegado, se ve que algo de verdad se rompio. `se_rindieron` es la lista
-- corta que si necesita una mano (scripts/releer-fotos/).
-- --------------------------------------------------------------------
create or replace function public.fotos_pendientes_del_rango(p_desde date, p_hasta date)
returns jsonb
language sql
stable
as $$
  with c as (
    select c.id,
           c.placa_intentos,
           (c.creado_en at time zone 'America/Tijuana')::date as dia,
           to_char(coalesce(c.foto_en, c.creado_en) at time zone 'America/Tijuana', 'HH24:MI') as hora
    from public.carros c
    where c.foto_path is not null
      and c.placa_en is null
      and c.cancelado_en is null
      and not coalesce(c.es_prueba, false)
      and (c.creado_en at time zone 'America/Tijuana')::date between p_desde and p_hasta
  )
  select jsonb_build_object(
    'esperando',    coalesce(count(*) filter (where placa_intentos <  public.placa_max_intentos()), 0),
    'se_rindieron', coalesce(count(*) filter (where placa_intentos >= public.placa_max_intentos()), 0),
    'carros', coalesce(
      jsonb_agg(jsonb_build_object(
        'carro_id', id, 'dia', dia, 'hora', hora, 'intentos', placa_intentos
      ) order by id),
      '[]'::jsonb)
  )
  from c;
$$;

-- --------------------------------------------------------------------
-- 6) El disparador: solo llama al obrero si hay algo que hacer
--
-- Mismo patron que `sincronizar_jibble_si_toca` (060): el cron dispara
-- seguido y quien decide es Postgres. Cuando la cola esta vacia —o sea
-- casi siempre— esto es un count sobre el indice parcial y NI SIQUIERA
-- sale de la base. Nada de 288 llamadas HTTP al dia por si acaso.
-- --------------------------------------------------------------------
create or replace function public.releer_fotos_si_toca()
returns text
language plpgsql
as $$
declare
  v_n     int;
  v_token text;
begin
  -- La MISMA vista que usa el obrero. Sin copiar el `where`.
  select count(*) into v_n from public.fotos_por_leer;

  if v_n = 0 then
    return 'sin pendientes';
  end if;

  select decrypted_secret into v_token
  from vault.decrypted_secrets where name = 'relectura_token';

  if v_token is null then
    return 'FALTA el secreto relectura_token en Vault; no se disparo nada';
  end if;

  perform net.http_post(
    url := 'https://rwoyfvddhlabmmuvkpjx.supabase.co/functions/v1/app/releer-pendientes',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-tarea', v_token),
    timeout_milliseconds := 120000
  );

  return 'disparado con ' || v_n || ' pendientes';
end $$;

-- --------------------------------------------------------------------
-- 7) La caja deja de tapar sus propias fallas
--
-- Hasta hoy, `registrar_visita_con_carro` llamaba a
-- `guardar_datos_de_foto` con solo mirar si habia foto. Esa RPC estampa
-- `placa_en` SIEMPRE, asi que una lectura que nunca corrio quedaba
-- registrada como "se intento y no se pudo" — y el carro NUNCA entraba a
-- esta cola. Paso de verdad el 17/ago con el carro 2643.
--
-- Ahora la caja dice explicitamente si hubo lectura. Si no la hubo, la
-- foto se pega al carro igual (el supervisor la ve) pero `placa_en` se
-- queda nulo y el obrero de fondo lo levanta.
--
-- ⚠️ Se DROPEA la version vieja antes de crear la nueva: agregar un
-- parametro crea una SOBRECARGA, no un reemplazo, y dos funciones con el
-- mismo nombre vuelven ambigua la llamada (leccion de la migracion 052).
-- --------------------------------------------------------------------
drop function if exists public.registrar_visita_con_carro(
  bigint, bigint, boolean, text, text, text, text, text, text);

create or replace function public.registrar_visita_con_carro(
  p_persona       bigint,
  p_carro         bigint,
  p_usa_gratis    boolean default false,
  p_caja          text    default 'principal',
  p_foto_path     text    default null,
  p_placa         text    default null,
  p_marca         text    default null,
  p_submarca      text    default null,
  p_tipo          text    default null,
  p_hubo_lectura  boolean default true
)
returns jsonb
language plpgsql
as $$
declare
  c        record;
  v_clase  text;
  v_gratis boolean;
  v_cort   boolean;
  v_id     bigint;
  v_foto   text;
  v_dudosa boolean := false;
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

  if exists (select 1 from public.visitas v2
             where v2.carro_id = p_carro and v2.estado = 'activa') then
    return jsonb_build_object('ok', false, 'error', 'Ese ticket ya se registró con otro cliente');
  end if;

  -- ⚠️ `is not distinct from` y no `=`: para un lavado normal clase_de_gratis
  -- devuelve NULL, y `null = 'canje'` es NULL — no false.
  v_clase := public.clase_de_gratis(c.producto, c.variante);
  v_cort  := (v_clase is not distinct from 'cortesia');
  -- EL TICKET MANDA sobre el switch de la cajera (ver CLAUDE.md §11.70).
  v_gratis := (v_clase is not distinct from 'canje');

  if coalesce(p_usa_gratis,false) and v_clase is distinct from 'canje' then
    return jsonb_build_object('ok', false,
      'error', 'Selecciona un ticket con lavado gratis',
      'motivo', 'sin_gratis');
  end if;

  v_foto := nullif(btrim(coalesce(p_foto_path,'')),'');

  insert into public.visitas
    (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, carro_id, enlazada_en,
     placa, marca, submarca, tipo_unidad, foto_path)
  values
    (p_persona, v_gratis, v_cort, 'activa',
     coalesce(nullif(btrim(p_caja),''),'principal'), false, p_carro, now(),
     nullif(btrim(coalesce(p_placa,'')),''),
     nullif(btrim(upper(coalesce(p_marca,''))),''),
     nullif(btrim(upper(coalesce(p_submarca,''))),''),
     nullif(btrim(coalesce(p_tipo,'')),''),
     v_foto)
  returning id into v_id;

  update public.carros
     set cliente = coalesce((select nombre from public.personas where id = p_persona), cliente)
   where id = p_carro;

  -- La foto de la caja pasa a ser la del carro, para que el supervisor la vea
  -- en la cola. Solo si el carro no trae ya una (no se pisa la del supervisor).
  if v_foto is not null then
    update public.carros
       set foto_path       = v_foto,
           foto_url        = null,
           foto_url_expira = null
     where id = p_carro and foto_path is null;
  end if;

  -- Lo que la cámara leyó se guarda con la MISMA función que usa el supervisor
  -- (`guardar_datos_de_foto`), no con una copia: ahí vive el candado de la
  -- placa repetida del día (migración 100) y el ligado placa→cliente.
  --
  -- ⚠️ SOLO si de verdad HUBO lectura. Antes bastaba con que hubiera foto, y
  -- como esa RPC estampa `placa_en` siempre, una caída del servicio quedaba
  -- disfrazada de "se intentó y no se pudo" — y el carro nunca entraba a la
  -- cola de reintentos (migración 104). Sin lectura, la foto se pega al carro
  -- pero `placa_en` se queda nulo, que es la verdad: nunca se intentó.
  if v_foto is not null and coalesce(p_hubo_lectura, true) then
    select coalesce((public.guardar_datos_de_foto(
             p_carro, p_placa, null, p_marca, p_submarca, p_tipo
           ) ->> 'placa_dudosa')::boolean, false) into v_dudosa;
  end if;

  return jsonb_build_object('ok', true, 'visita', v_id, 'clase', v_clase,
                            'es_gratis', v_gratis, 'es_cortesia', v_cort,
                            'placa_dudosa', v_dudosa,
                            'lealtad', public.lealtad_de(p_persona));
end $$;
