#!/bin/bash
# Corre TODAS las pruebas. Sale con codigo 1 si alguna falla, para que se pueda
# encadenar antes de un despliegue:
#
#     bash pruebas/correr.sh && supabase functions deploy app --no-verify-jwt
#
# Ver pruebas/README.md para por que existe esto.
cd "$(dirname "$0")/.." || exit 1

fallos=0

correr() {
  echo ""
  echo "=============================================================="
  echo "  $1"
  echo "=============================================================="
  shift
  if ! "$@"; then fallos=$((fallos + 1)); fi
}

# Una prueba SQL arma su escenario contra la base REAL y lo revierte con un
# `raise` al terminar, asi que no ensucia la cola del supervisor. Pasa si el
# mensaje final dice "PASADA" — que suena al reves, pero es el precio de que la
# unica forma de revertir sea fallar a proposito.
sql() {
  local salida
  salida=$(bash scripts/releer-fotos/q.sh "$1" 2>&1)
  echo "$salida" | tr '|' '\n' | head -6
  echo "$salida" | grep -q "PASADA"
}

# --- JavaScript / TypeScript ----------------------------------------------
correr "marcarError - un error se ve como error" \
  cscript //E:JScript //Nologo pruebas/marcar-error.js

# --- Sintaxis de las tres pantallas ---------------------------------------
# No hay node ni deno en esta maquina: se usa el interprete de Windows sobre el
# JS extraido del HTML. Un error de PARSEO sale aqui; uno de ejecucion no (las
# pantallas necesitan `document`, que no existe en cscript), y eso esta bien:
# lo que se busca es que el archivo no este roto antes de publicarlo.
correr "sintaxis de docs/*.html" \
  bash pruebas/sintaxis-front.sh

# --- Contra la base -------------------------------------------------------
correr "canje sin saldo (lealtad)"        sql pruebas/canje-sin-saldo.sql
correr "perfil honesto y Jibble"          sql pruebas/perfil-y-jibble.sql
correr "editar valida antes de escribir"  sql pruebas/editar-y-foto.sql
correr "perfil del trabajador paginado"   sql pruebas/perfil-paginado.sql
correr "el trigger no tumba la venta"     sql pruebas/trigger-y-enlaces.sql
correr "un lavado, un cliente"            sql pruebas/un-lavado-un-cliente.sql
correr "payload y busquedas"              sql pruebas/payload-y-busquedas.sql
correr "el import del ClientNoteTracker" sql pruebas/import-cnt.sql
correr "limpieza 119: nulo no borra, Jibble" sql pruebas/limpieza-119.sql
correr "numeros honestos del reporte"     sql pruebas/numeros-del-reporte.sql

# El dry-run del import REVIERTE por diseno (termina en `raise`), asi que se
# puede correr contra produccion: es la unica prueba que ejercita el archivo
# de verdad, de punta a punta, en vez de una copia de su logica.
correr "el dry-run del import corre" \
  bash -c 'bash scripts/releer-fotos/q.sh scripts/importar-clientnotetracker/import-incremental-dryrun.sql | grep -q DRYRUN'

echo ""
echo "=============================================================="
if [ "$fallos" -eq 0 ]; then
  echo "  TODO PASO"
  exit 0
else
  echo "  $fallos GRUPO(S) DE PRUEBAS FALLARON - no despliegues"
  exit 1
fi
