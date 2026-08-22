#!/bin/bash
# Recorre el respaldo COMPLETO contra la API real y comprueba que cada tabla
# entregue exactamente las filas que promete el manifiesto.
#
#   bash pruebas/respaldo-completo.sh
#
# Por que existe: hasta el 21/ago/2026 `/respaldo` bajaba 94 kB con una sola
# llave (los reportes diarios) y nadie lo habia apretado nunca. Un respaldo
# que no se prueba no es un respaldo; y el modo de falla que importa aqui no
# es que truene, es que baje de menos y se vea completo.
#
# Es de SOLO LECTURA. Pasa si dice "PRUEBA PASADA".
cd "$(dirname "$0")/.." || exit 1

ENVF="${ENVF:-.env}"
REF=$(grep -a '^SUPABASE_PROJECT_REF=' "$ENVF" | head -1 | cut -d= -f2 | tr -d '\r')
COD=$(grep -a '^CODIGO_ACCESO=' "$ENVF" | head -1 | cut -d= -f2 | tr -d '\r')
API="https://$REF.supabase.co/functions/v1/app"

pedir() { curl.exe -s -H "x-codigo: $COD" "$API$1"; }

MAN=$(pedir "/respaldo")
if ! echo "$MAN" | grep -q '"tablas"'; then
  echo "FALLA: el manifiesto no vino. Respuesta: $(echo "$MAN" | head -c 200)"
  exit 1
fi

# tabla<TAB>filas, sacado del manifiesto sin depender de jq.
LISTA=$(echo "$MAN" | gawk '{
  while (match($0, /\{"tabla":"[^"]+","clave":"[^"]+","pagina":[0-9]+,"filas":[0-9]+\}/)) {
    b = substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART+RLENGTH)
    match(b, /"tabla":"[^"]+"/); t = substr(b, RSTART+9, RLENGTH-10)
    match(b, /"filas":[0-9]+/);  f = substr(b, RSTART+8, RLENGTH-8)
    print t "\t" f
  }
}')

if [ -z "$LISTA" ]; then echo "FALLA: no se pudo leer la lista de tablas del manifiesto"; exit 1; fi

fallos=0
total=0
while IFS=$'\t' read -r tabla esperadas; do
  [ -z "$tabla" ] && continue
  cursor=""
  bajadas=0
  paginas=0
  while : ; do
    if [ -z "$cursor" ]; then r=$(pedir "/respaldo?tabla=$tabla")
    else                      r=$(pedir "/respaldo?tabla=$tabla&desde=$cursor"); fi
    if echo "$r" | grep -q '"ok":false'; then
      echo "  FALLA $tabla: la API devolvio error -> $(echo "$r" | head -c 160)"
      fallos=$((fallos+1)); break
    fi
    # El conteo lo dice la propia respuesta (`n`). Contarlo desde afuera
    # obliga a adivinar donde empieza cada renglon, y los payloads de
    # `ventas` traen `"id"` anidado en cada producto: la primera version de
    # esta prueba conto 10 veces de mas por eso.
    n=$(echo "$r" | gawk 'match($0, /"n":[0-9]+/) { print substr($0, RSTART+4, RLENGTH-4) }')
    sig=$(echo "$r" | gawk 'match($0, /"siguiente":("[^"]*"|[0-9]+|null)/) {
             s = substr($0, RSTART+12, RLENGTH-12); gsub(/"/, "", s); print s }')
    if [ -z "$n" ]; then
      echo "  FALLA $tabla: la respuesta no trae \`n\`"; fallos=$((fallos+1)); break
    fi
    bajadas=$((bajadas + n)); paginas=$((paginas+1))
    if [ "$sig" = "null" ] || [ -z "$sig" ]; then break; fi
    cursor="$sig"
    if [ "$paginas" -gt 200 ]; then
      echo "  FALLA $tabla: mas de 200 paginas, el cursor no avanza"; fallos=$((fallos+1)); break
    fi
  done
  if [ "$bajadas" -ne "$esperadas" ]; then
    echo "  FALLA $tabla: el manifiesto dice $esperadas y bajaron $bajadas"
    fallos=$((fallos+1))
  else
    echo "  ok    $tabla: $bajadas filas en $paginas pagina(s)"
  fi
  total=$((total + bajadas))
done <<< "$LISTA"

# El respaldo tiene que traer las tablas que de verdad no se pueden perder.
for t in carros etapas asignaciones personas visitas ventas reportes_diarios; do
  if ! echo "$LISTA" | cut -f1 | grep -qx "$t"; then
    echo "  FALLA: el respaldo no incluye \`$t\`"; fallos=$((fallos+1))
  fi
done

echo ""
if [ "$fallos" -eq 0 ]; then
  echo "PRUEBA PASADA -> $total renglones, todas las tablas cuadran con el manifiesto."
  exit 0
fi
echo "$fallos FALLA(S) en el respaldo"
exit 1
