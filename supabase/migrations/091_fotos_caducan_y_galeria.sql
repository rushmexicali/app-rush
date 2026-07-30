-- =====================================================================
-- RUSH — Las fotos caducan a los 3 meses + galeria por placa · 29/jul/2026
--
-- Decision del dueno: las fotos que se toman y se suben se borran despues
-- de 3 meses. Motivo: el plan gratis de Supabase da 1 GB de Storage y las
-- fotos crecen ~230 MB/mes; sin una regla, en unos meses se llena.
--
-- BORRAR de verdad tiene una trampa: borrar la fila de storage.objects con
-- un DELETE de SQL deja el archivo fisico HUERFANO en el backend (no libera
-- espacio). La unica via que libera espacio es la API de Storage
-- (storage.remove). Por eso el borrado lo hace un Edge Function
-- (limpiar-fotos) con el cliente de Storage; aqui solo viven las funciones
-- de apoyo que ese Edge Function usa:
--
--   fotos_viejas(dias)         -> los nombres (paths) de los archivos del
--                                 bucket 'fotos' con mas de N dias. El Edge
--                                 Function se los pasa a storage.remove().
--   olvidar_fotos_viejas(dias) -> pone en null foto_path/foto_url de los
--                                 carros cuya foto ya se borro, para que la
--                                 app no muestre una liga muerta.
--
-- Y de paso, para la galeria de la pantalla de placa:
--   fotos_de_placa(placa)      -> las fotos de esa placa (una por visita
--                                 que tuvo foto), de la mas nueva a la mas
--                                 vieja, con la hora en que se tomo.
--
-- Las dos primeras son SECURITY DEFINER porque leen/cruzan el esquema
-- storage, al que el rol de la app no llega por si mismo.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Los archivos con mas de N dias en el bucket 'fotos'
--
-- Incluye TODO el bucket: las fotos de carros (<dia>/carro-*.jpg) y las
-- capturas de la caja (capturas/<dia>/cap-*.jpg). Las dos son "fotos que se
-- toman y se suben", y las dos caducan igual.
-- ---------------------------------------------------------------------
create or replace function public.fotos_viejas(p_dias int default 90)
returns text[]
language sql
security definer
set search_path = public, storage
as $$
  select coalesce(array_agg(o.name), array[]::text[])
    from storage.objects o
   where o.bucket_id = 'fotos'
     and o.created_at < now() - make_interval(days => p_dias);
$$;

comment on function public.fotos_viejas(int) is
  'Paths de los archivos del bucket fotos con mas de N dias. Los borra el Edge Function limpiar-fotos via la API de Storage.';

-- ---------------------------------------------------------------------
-- Olvidar el apuntador de las fotos ya caducadas
--
-- Un carro cuya foto se tomo hace mas de N dias ya no tiene archivo (se
-- borro). Se limpia foto_path y el enlace firmado guardado, para que /cola
-- y el detalle no intenten mostrar una liga muerta. NO se toca ningun otro
-- dato del carro: placa, marca, tiempos y quien lo seco se conservan — la
-- foto ya cumplio su proposito (leer la placa) hace meses.
-- ---------------------------------------------------------------------
create or replace function public.olvidar_fotos_viejas(p_dias int default 90)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  cuantos int;
begin
  update public.carros
     set foto_path = null, foto_url = null, foto_url_expira = null
   where foto_path is not null
     and foto_en is not null
     and foto_en < now() - make_interval(days => p_dias);
  get diagnostics cuantos = row_count;
  return cuantos;
end;
$$;

comment on function public.olvidar_fotos_viejas(int) is
  'Pone en null foto_path/foto_url de los carros cuya foto ya caduco (mas de N dias). No toca ningun otro dato.';

-- ---------------------------------------------------------------------
-- La galeria de una placa
--
-- Una foto por visita (carro) que tuvo foto, de la mas nueva a la mas
-- vieja. 'tomada_en' es cuando se tomo la foto (foto_en); si por lo que sea
-- no se guardo esa hora, se cae a la hora de entrada del carro. El path se
-- firma en el Edge Function (bucket privado). Mismo criterio del resto del
-- reporte: sin pruebas ni cancelados.
-- ---------------------------------------------------------------------
create or replace function public.fotos_de_placa(p_placa text)
returns jsonb
language sql
stable
as $$
  select coalesce(jsonb_agg(
    jsonb_build_object(
      'carro_id',  c.id,
      'foto_path', c.foto_path,
      'tomada_en', coalesce(c.foto_en, c.creado_en),
      'placa',     coalesce(c.placa_display, c.placa)
    ) order by coalesce(c.foto_en, c.creado_en) desc
  ), '[]'::jsonb)
  from public.carros c
  where public.normalizar_placa(c.placa) = public.normalizar_placa(p_placa)
    and c.foto_path is not null
    and not c.es_prueba and c.cancelado_en is null;
$$;

comment on function public.fotos_de_placa(text) is
  'Las fotos de una placa (una por visita con foto), de la mas nueva a la mas vieja, con la hora en que se tomo. El path se firma en el Edge Function.';

-- ---------------------------------------------------------------------
-- El cliente (persona de lealtad) de cada placa
--
-- Para que el nombre del cliente en el Historial por placa sea clicable al
-- perfil del cliente, hace falta el ID de la persona (la columna 'cliente'
-- de historial_placas es solo el texto de la nota, sin liga). Aqui, por
-- placa (normalizada), sale el dueno de lealtad: id + nombre. Si una placa
-- tiene varios duenos (carro compartido) gana el confirmado / el primero
-- por nombre — el mismo orden que duenos_de_placa. Una sola consulta para
-- todas las placas de la tabla, para no pedir una por fila.
-- ---------------------------------------------------------------------
create or replace function public.clientes_de_placas(p_placas text[])
returns jsonb
language sql
stable
as $$
  with pl as (
    select distinct public.normalizar_placa(x) as placa_norm
    from unnest(coalesce(p_placas, array[]::text[])) x
    where nullif(public.normalizar_placa(x), '') is not null
  ),
  dueno as (
    select pl.placa_norm,
      (select jsonb_build_object('id', pe.id, 'nombre', pe.nombre)
         from public.persona_placas pp
         join public.personas pe on pe.id = pp.persona_id
        where pp.placa_norm = pl.placa_norm
        order by pp.confirmada desc, pe.nombre
        limit 1) as cliente
    from pl
  )
  select coalesce(jsonb_object_agg(d.placa_norm, d.cliente), '{}'::jsonb)
  from dueno d
  where d.cliente is not null;
$$;

comment on function public.clientes_de_placas(text[]) is
  'Para el Historial por placa: por placa (normalizada) el dueno de lealtad (id + nombre) para ligar el nombre del cliente a su perfil.';
