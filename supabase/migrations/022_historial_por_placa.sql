-- =====================================================================
-- RUSH Car Wash — historial por placa
--
-- Cuantas veces ha venido cada carro. La placa sale sola de la foto
-- (ver seccion 9 del CLAUDE.md).
--
-- ⚠️ ESTE CONTEO ES UN PISO, NO UN TOTAL.
--
-- La foto es OPCIONAL por diseno: el dueno pidio explicitamente que en
-- dia pesado el supervisor la pueda ignorar y el carro salga igual. Un
-- carro sin foto no tiene placa, y por lo tanto no cuenta como visita.
--
-- O sea: si aqui dice que una placa vino 3 veces, vino 3 veces O MAS.
-- Nunca menos. La pantalla tiene que decirlo, porque un numero que se lee
-- como total cuando es piso lleva a conclusiones falsas — por ejemplo
-- creer que un cliente dejo de venir cuando lo que paso es que nadie le
-- tomo la foto.
--
-- El reporte diario incluye cuantas placas se alcanzaron a leer ese dia,
-- justo para poder medir que tan piso es el piso.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Normalizar la placa para poder compararla
--
-- "BF-4505-A", "BF 4505 A" y "bf4505a" son la MISMA placa. Se compara sin
-- separadores y en mayusculas. Se guarda aparte la forma como se leyo,
-- porque esa es la que el humano reconoce.
-- ---------------------------------------------------------------------
create or replace function public.normalizar_placa(p_placa text)
returns text
language sql
immutable
as $$
  select nullif(
    regexp_replace(upper(btrim(coalesce(p_placa, ''))), '[^A-Z0-9]', '', 'g'),
    ''
  );
$$;

comment on function public.normalizar_placa(text) is
  'Placa sin guiones ni espacios y en mayusculas, para comparar. BF-4505-A = BF4505A.';

-- Sin esto, buscar una placa recorre toda la tabla. Con pocos carros da
-- igual; en un ano no.
create index if not exists carros_placa_normalizada_idx
  on public.carros (public.normalizar_placa(placa))
  where placa is not null;

-- ---------------------------------------------------------------------
-- El historial
--
-- Es vista y no tabla a proposito: se deriva por completo de carros, asi
-- que no hay nada que mantener sincronizado ni que se pueda desfasar.
--
-- Los carros de prueba quedan fuera. Los no entregados SI cuentan: el
-- cliente ya esta aqui, aunque el carro siga en la linea.
-- ---------------------------------------------------------------------
create or replace view public.historial_placas as
select
  public.normalizar_placa(c.placa)          as placa,
  -- La forma mas reciente en que se leyo es la que se muestra.
  (array_agg(c.placa order by c.creado_en desc))[1] as placa_como_se_lee,
  count(*)::int                             as visitas,
  min(c.creado_en)                          as primera_visita,
  max(c.creado_en)                          as ultima_visita,
  -- Del carro nos quedamos con lo ultimo que se supo: el color se puede
  -- corregir, la marca se captura al asignar.
  (array_agg(c.tipo_unidad order by c.creado_en desc) filter (where c.tipo_unidad is not null))[1] as tipo_unidad,
  (array_agg(c.color       order by c.creado_en desc) filter (where c.color       is not null))[1] as color,
  (array_agg(c.marca       order by c.creado_en desc) filter (where c.marca       is not null))[1] as marca,
  (array_agg(c.cliente     order by c.creado_en desc) filter (where c.cliente     is not null))[1] as cliente,
  sum(coalesce(c.monto, 0))                 as gastado
from public.carros c
where c.placa is not null
  and not c.es_prueba
group by public.normalizar_placa(c.placa);

comment on view public.historial_placas is
  'Visitas por placa. PISO, no total: la foto es opcional, asi que hay visitas sin registrar.';
