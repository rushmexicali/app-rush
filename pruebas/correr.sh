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

# --- Pruebas de JavaScript/TypeScript (Edge Functions y las 3 pantallas) ---
correr "marcarError - un error se ve como error" \
  cscript //E:JScript //Nologo pruebas/marcar-error.js

# --- Sintaxis de las tres pantallas ---------------------------------------
# No hay node ni deno en esta maquina: se usa el interprete de Windows sobre el
# JS extraido del HTML. Un error de PARSEO sale aqui; uno de ejecucion no (las
# pantallas necesitan `document`, que no existe en cscript), y eso esta bien:
# lo que se busca es que el archivo no este roto antes de publicarlo.
correr "sintaxis de docs/*.html" \
  bash pruebas/sintaxis-front.sh

echo ""
echo "=============================================================="
if [ "$fallos" -eq 0 ]; then
  echo "  TODO PASO"
  exit 0
else
  echo "  $fallos GRUPO(S) DE PRUEBAS FALLARON - no despliegues"
  exit 1
fi
