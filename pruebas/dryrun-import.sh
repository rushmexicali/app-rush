#!/bin/bash
# Corre el dry-run REAL del import (el archivo que se usa en produccion), pero
# con una fila sembrada para que el INSERT tenga trabajo.
#
# Antes esta prueba solo comprobaba que la salida dijera "DRYRUN", lo cual es
# cierto tambien cuando no inserta NADA -- que es justo lo que pasaba, porque
# `stg_cnt` queda con sus filas ya importadas. Ahora se exige que la cuenta de
# visitas agregadas sea MAYOR QUE CERO, o sea que el camino del insert se
# ejercito de verdad.
set -u
cd "$(dirname "$0")/.." || exit 1

TMP="${TMPDIR:-/tmp}/rush-dryrun-$$.sql"
cat pruebas/seed-dryrun.sql \
    scripts/importar-clientnotetracker/import-incremental-dryrun.sql > "$TMP"

SALIDA=$(bash scripts/releer-fotos/q.sh "$TMP" 2>&1)
cat /dev/null > "$TMP"   # no se borra: ver la memoria "no usar Remove-Item"

echo "$SALIDA" | head -c 400
echo ""

if ! echo "$SALIDA" | grep -q "DRYRUN"; then
  echo "  FALLA: el dry-run no llego a su raise"
  exit 1
fi

# `visitas +0` significa que el INSERT no hizo nada y la prueba no midio nada.
if ! echo "$SALIDA" | grep -qE 'DRYRUN visitas \+[1-9]'; then
  echo "  FALLA: el dry-run no inserto ni una visita -- la prueba no esta midiendo el insert"
  exit 1
fi

echo "  PRUEBA PASADA -> el dry-run corrio y ejercito el insert"
exit 0
