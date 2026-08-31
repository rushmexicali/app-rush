#!/bin/bash
# Corre el import REAL en seco: el mismo archivo que se usa en produccion
# (`reset-total.sql`), con su `raise notice` final cambiado a `raise exception`
# para que la transaccion se revierta entera. Es el propio encabezado del
# archivo el que documenta este modo: "ensayarlo es gratis y hay que hacerlo".
#
# ⚠️ APUNTA A reset-total.sql DESDE EL 28/ago/2026. Antes ejercitaba
#    `import-incremental-dryrun.sql`, que ese mismo dia quedo RETIRADO por
#    decision del dueno: cada import es borron y cuenta nueva. Una prueba que
#    ejercita el camino que ya nadie corre no esta midiendo nada.
#
# ⚠️ TOMA CANDADOS SOBRE `visitas`, `personas` y `persona_placas` ~7 segundos
#    (borra y reinserta ~15,500 filas, y lo revierte). Si se corre con la caja
#    abierta, un registro de visita en ese instante espera esos segundos. La
#    suite se corre antes de desplegar, y desplegar va en el corte (CLAUDE.md
#    §2), asi que en la practica no coincide — pero queda dicho.
set -u
cd "$(dirname "$0")/.." || exit 1

ORIGEN=scripts/importar-clientnotetracker/reset-total.sql
AYUDA="${TMPDIR:-/tmp}/rush-dryrun-cuenta-$$.sql"
TMP="${TMPDIR:-/tmp}/rush-dryrun-$$.sql"

# El unico cambio es el raise final. Si el archivo dejara de tener ese ancla,
# el sed no hace nada, no aparece DRYRUN y la prueba falla — que es lo correcto:
# significa que el archivo cambio y hay que volver a ver esta prueba.
# 🔑 EL CANDADO DEL RESET (30/ago) HAY QUE ABRIRLO PARA PODER ENSAYARLO.
# Desde que el CNT se retiro, cada visita que la caja registra despues del
# ultimo export queda "sin respaldo", y el reset se niega a correr. Eso es
# lo correcto en produccion, pero aqui estorbaria: este ensayo REVIERTE.
# El numero NO se escribe a mano — se pregunta, porque crece cada dia que
# la caja trabaja. Un numero fijo dejaria de cuadrar en la siguiente venta.
cat > "$AYUDA" <<'SQL'
select count(*) sin_respaldo from public.visitas v
 where v.caja <> 'import' and v.estado = 'activa'
   and (v.ticket is null or not exists
        (select 1 from public.stg_cnt s where s.ticket = v.ticket));
SQL
N=$(bash scripts/releer-fotos/q.sh "$AYUDA" | gawk 'match($0,/"sin_respaldo":"?[0-9]+/){v=substr($0,RSTART,RLENGTH); sub(/.*:"?/,"",v); print v}')
cat /dev/null > "$AYUDA"
[ -n "$N" ] || { echo "  FALLA: no se pudo contar las visitas de caja sin respaldo"; exit 1; }
echo "  visitas de caja sin respaldo en el export: $N (el candado pide ese numero)"

{ echo "select set_config('rush.perdida_aceptada', '$N', false);"
  sed "s/raise notice E'RESET TOTAL/raise exception E'DRYRUN RESET TOTAL/" "$ORIGEN"
} > "$TMP"

SALIDA=$(bash scripts/releer-fotos/q.sh "$TMP" 2>&1)
cat /dev/null > "$TMP"   # no se borra: ver la memoria "no usar Remove-Item"

echo "$SALIDA" | head -c 700
echo ""

if ! echo "$SALIDA" | grep -q "DRYRUN RESET TOTAL"; then
  echo "  FALLA: el reset en seco no llego a su raise (revisa el ancla del sed,"
  echo "         o alguna de las guardas internas del archivo se disparo)"
  exit 1
fi

# `visitas 0` querria decir que el INSERT no hizo nada y la prueba no midio el
# camino que importa. Mismo criterio que tenia la version vieja.
if ! echo "$SALIDA" | grep -qE 'IMPORT +personas [1-9][0-9]* +visitas [1-9][0-9]*'; then
  echo "  FALLA: el reset en seco no importo personas ni visitas"
  exit 1
fi

if ! echo "$SALIDA" | grep -qE 'ligadas a carro [1-9][0-9]*'; then
  echo "  FALLA: no ligo ni un lavado a su cliente"
  exit 1
fi

# La operacion NO se toca: si `carros` saliera en 0, el reset estaria borrando
# algo que no le toca. Es la guarda que el propio archivo promete en su
# encabezado ("NO TOCA la operacion").
if ! echo "$SALIDA" | grep -qE 'INTACTO +carros [1-9][0-9]*'; then
  echo "  FALLA: la operacion no quedo intacta"
  exit 1
fi

echo "  PRUEBA PASADA -> el reset corrio en seco, importo, ligo y no toco la operacion"
exit 0
