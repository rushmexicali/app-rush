#!/bin/bash
# =====================================================================
# Carga stg_cnt con lo que dejo preparar-import.sh, lo cuadra contra el
# archivo local, MIDE la zona horaria contra Zettle y limpia los tickets.
#
#     bash scripts/importar-clientnotetracker/cargar-staging.sh <carpeta>
#
# Toca UNICAMENTE stg_cnt. No escribe una sola fila del CRM: despues de esto
# el CRM sigue exactamente igual que antes, y por eso conviene correrlo ANTES
# de borrar nada (asi el CRM no pasa ni un segundo vacio).
# =====================================================================
set -e
RAIZ="C:/Users/luis_/Desktop/App RUSH"
cd "$RAIZ" || exit 1
W="$1"
[ -n "$W" ] || { echo "uso: cargar-staging.sh <carpeta-de-trabajo>"; exit 1; }
[ -f "$W/staging_full.tsv" ] || { echo "FALLA: falta $W/staging_full.tsv (corre preparar-import.sh)"; exit 1; }
D=scripts/importar-clientnotetracker
Q="bash scripts/releer-fotos/q.sh"

num(){ gawk -v k="$2" 'match($0, "\"" k "\":\"?[0-9.]+"){ v=substr($0,RSTART,RLENGTH); sub(/.*:"?/,"",v); print v; exit }' "$1"; }

echo "== recreando stg_cnt =="
cat > "$W/_crear.sql" <<'SQL'
drop table if exists public.stg_cnt;
create table public.stg_cnt (
  nombre text, dt_local text, es_gratis boolean,
  monto_cent integer, ticket text, tz text
);
select 1 ok;
SQL
$Q "$W/_crear.sql" > /dev/null

echo "== cargando lotes =="
for f in "$W"/lote_*.sql; do
  r=$($Q "$f")
  case "$r" in
    *error*|*ERROR*) echo "FALLA en $(basename "$f"): $r"; exit 1;;
  esac
  echo "   $(basename "$f") ok"
done

echo "== cuadrando contra el archivo local =="
cat > "$W/_ver.sql" <<'SQL'
select count(*) filas,
       count(*) filter (where ticket is not null) con_ticket,
       count(distinct public.normalizar_nombre(nombre)) personas
from public.stg_cnt;
SQL
$Q "$W/_ver.sql" > "$W/_ver.json"
DBF=$(num "$W/_ver.json" filas)
LOC=$(wc -l < "$W/staging_full.tsv")
echo "   local $LOC  vs  base $DBF"
[ "$DBF" = "$LOC" ] || { echo "FALLA: la carga no cuadra con el archivo"; exit 1; }

# 🔑 LA ZONA SE MIDE, NO SE LEE. El encabezado del PDF sale del telefono del
# dueno y el 21/ago/2026 vino una hora adelante. El ticket de cada nota es el
# purchaseNumber de una venta cuya hora si es confiable: de ahi sale el desfase.
echo "== midiendo la zona horaria contra Zettle =="
cat > "$W/_tz.sql" <<'SQL'
with z as (select (public.detalle_venta(payload)->>'purchaseNumber') recibo, creado_en from public.ventas)
select round(extract(epoch from ((s.dt_local::timestamp at time zone coalesce(s.tz,'America/Tijuana'))
                                 - z.creado_en))/60.0) dif_min, count(*) notas
from public.stg_cnt s join z on z.recibo = s.ticket
group by 1 order by 2 desc limit 5;
SQL
$Q "$W/_tz.sql" > "$W/_tz.json"
gawk 'BEGIN{RS="},"} match($0,/"dif_min":"?-?[0-9]+/){ d=substr($0,RSTART,RLENGTH); sub(/.*:"?/,"",d)
        match($0,/"notas":"?[0-9]+/); n=substr($0,RSTART,RLENGTH); sub(/.*:"?/,"",n)
        printf "   %+d min : %s notas\n", d, n }' "$W/_tz.json"
DIF=$(gawk 'match($0,/"dif_min":"?-?[0-9]+/){v=substr($0,RSTART,RLENGTH); sub(/.*:"?/,"",v); print v; exit}' "$W/_tz.json")
case "$DIF" in
  0|-1|1) echo "   OK: el export esta en hora de Tijuana.";;
  *) echo ""
     echo "   🔴 DESFASE DE $DIF MINUTOS. El export NO viene en hora de Tijuana."
     echo "      Corrige la zona y vuelve a medir ANTES de importar:"
     echo "        update public.stg_cnt set tz = '<zona que explica el desfase>';"
     echo "      Sin esto cada visita entra corrida, y el dedup del proximo"
     echo "      import deja de reconocerlas y las duplica."
     exit 1;;
esac

# Cotejo gratis: el taller SIEMPRE cierra a las 8 PM. Notas mas tarde = la zona
# quedo mal puesta, no es que hayan trabajado hasta tarde.
cat > "$W/_8pm.sql" <<'SQL'
select count(*) tarde from public.stg_cnt
where extract(hour from (dt_local::timestamp at time zone coalesce(tz,'America/Tijuana')
                         at time zone 'America/Tijuana')) >= 20
  and dt_local::timestamp >= timestamp '2025-09-01';
SQL
$Q "$W/_8pm.sql" > "$W/_8pm.json"
TARDE=$(num "$W/_8pm.json" tarde)
echo "   notas despues de las 8 PM: $TARDE (debe ser 0)"
[ "$TARDE" = "0" ] || { echo "FALLA: la zona quedo mal puesta"; exit 1; }

echo "== limpiando tickets (RUNBOOK 4d) =="
$Q "$D/limpiar-tickets.sql" > /dev/null
cat > "$W/_fin.sql" <<'SQL'
select count(*) visitas,
       count(*) filter (where ticket is not null) con_ticket,
       count(*) filter (where monto_cent is not null) con_monto,
       count(*) filter (where es_gratis) gratis,
       round(sum(monto_cent)/100.0,2) suma,
       (select count(*) from (select ticket from public.stg_cnt where ticket is not null
                              group by ticket having count(*)>1) x) repetidos
from public.stg_cnt;
SQL
$Q "$W/_fin.sql" | tr ',' '\n' | sed 's/[][{}"]//g; s/^/   /'

echo ""
echo "LISTO. stg_cnt cargada y limpia; el CRM no se ha tocado."
echo "Sigue el reset:  $D/reset-total.sql  (ensayalo primero, ver su encabezado)"
