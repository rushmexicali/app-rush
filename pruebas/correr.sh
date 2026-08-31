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
correr "corregir no mueve la hora"        sql pruebas/corregir-no-mueve-la-hora.sql
correr "una sola regla de secado corto"   sql pruebas/secado-corto-en-un-solo-lugar.sql
correr "la caja confirma la placa a la 1a" sql pruebas/placa-caja-confirma-a-la-primera.sql
correr "foto al ticket sin cliente"       sql pruebas/foto-al-ticket-sin-cliente.sql
correr "perfil del trabajador paginado"   sql pruebas/perfil-paginado.sql
correr "el trigger no tumba la venta"     sql pruebas/trigger-y-enlaces.sql
correr "un lavado, un cliente"            sql pruebas/un-lavado-un-cliente.sql
correr "payload y busquedas"              sql pruebas/payload-y-busquedas.sql
correr "el import del ClientNoteTracker" sql pruebas/import-cnt.sql
correr "limpieza 119: nulo no borra, Jibble" sql pruebas/limpieza-119.sql
correr "numeros honestos del reporte"     sql pruebas/numeros-del-reporte.sql
correr "el aviso plano y las placas dudosas" sql pruebas/aviso-plano.sql
correr "el buscador oye el nombre"     sql pruebas/buscador-fonetico.sql

correr "la llave publica no alcanza nada" sql pruebas/llave-publica.sql
correr "la cortesia del import"       sql pruebas/cortesia-del-import.sql
correr "avisos atendidos"             sql pruebas/avisos-atendidos.sql

correr "la visita de caja guarda su ticket" sql pruebas/visita-de-caja-con-ticket.sql

# El dry-run del import REVIERTE por diseno (termina en `raise`), asi que se
# puede correr contra produccion: es la unica prueba que ejercita el archivo
# de verdad, de punta a punta, en vez de una copia de su logica.
# ⚠️ Desde el 28/ago apunta a `reset-total.sql`, no al incremental: ese quedo
# retirado ese dia (cada import es borron y cuenta nueva) y una prueba sobre el
# camino que ya nadie corre no mide nada. Toma candados sobre `visitas` unos 7
# segundos; ver el encabezado de pruebas/dryrun-import.sh.
correr "el reset del import corre en seco" bash pruebas/dryrun-import.sh

# El candado que impide borrar lealtad que nadie respalda. Desde el 31/ago
# el CNT ya no se llena, asi que `visitas` de caja es la UNICA copia y el
# `delete` sin `where` del reset la borraria sin vuelta. Ejercita el archivo
# REAL en las dos direcciones (detiene / deja pasar con el numero exacto).
correr "el candado del reset"          bash pruebas/candado-del-reset.sh

echo ""
echo "=============================================================="
if [ "$fallos" -eq 0 ]; then
  echo "  TODO PASO"
  exit 0
else
  echo "  $fallos GRUPO(S) DE PRUEBAS FALLARON - no despliegues"
  exit 1
fi
