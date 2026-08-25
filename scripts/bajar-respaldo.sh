#!/bin/bash
# Baja el respaldo COMPLETO de /respaldo a archivos en disco.
#
#     bash scripts/bajar-respaldo.sh "C:/Users/luis_/Desktop/respaldo-rush-AAAA-MM-DD"
#
# Existe porque el RUNBOOK del import manda "bajar /respaldo antes del reset" y
# eso era un boton en la pagina del dueno: no se podia hacer desde aqui, y un
# reset sin respaldo no se debe correr.
#
# 🔑 Dos trampas del formato, las dos ya pagadas:
#   - En una PAGINA, `filas` es el ARREGLO de renglones, no un conteo. El
#     numero viene en `n` y el cursor en `siguiente`. (En el MANIFIESTO `filas`
#     si es un numero — de ahi la confusion.)
#   - Se para con una pagina VACIA, nunca con una incompleta: PostgREST recorta
#     en 1000 sin avisar, y deducir "ya acabe" de una pagina corta fue lo que
#     dejo `etapas` respaldada al 12% el 21/ago/2026, completa a la vista.
#
# Compara lo bajado contra el manifiesto tabla por tabla y sale con codigo 1 si
# alguna no cuadra. Un respaldo a medias es peor que ninguno: nadie se entera
# hasta que lo necesita.
cd "C:/Users/luis_/Desktop/App RUSH" || exit 1
DEST="$1"; mkdir -p "$DEST"
REF=$(grep -a '^SUPABASE_PROJECT_REF=' .env | head -1 | cut -d= -f2 | tr -d '\r')
COD=$(grep -a '^CODIGO_ACCESO=' .env | head -1 | cut -d= -f2 | tr -d '\r')
API="https://$REF.supabase.co/functions/v1/app"
pedir(){ curl.exe -s --max-time 180 -H "x-codigo: $COD" "$API$1"; }

MAN=$(pedir "/respaldo")
printf '%s' "$MAN" > "$DEST/00-manifiesto.json"
echo "$MAN" | grep -q '"tablas"' || { echo "FALLA: sin manifiesto"; exit 1; }

LISTA=$(echo "$MAN" | gawk '{
  while (match($0, /\{"tabla":"[^"]+","clave":"[^"]+","pagina":[0-9]+,"filas":[0-9]+\}/)) {
    b = substr($0, RSTART, RLENGTH); $0 = substr($0, RSTART+RLENGTH)
    match(b, /"tabla":"[^"]+"/); t = substr(b, RSTART+9, RLENGTH-10)
    match(b, /"filas":[0-9]+/);  f = substr(b, RSTART+8, RLENGTH-8)
    print t "\t" f } }')

fallos=0; total=0
while IFS=$'\t' read -r tabla esperadas; do
  [ -z "$tabla" ] && continue
  cursor=""; bajadas=0; pag=0
  while : ; do
    if [ -z "$cursor" ]; then r=$(pedir "/respaldo?tabla=$tabla")
    else                      r=$(pedir "/respaldo?tabla=$tabla&desde=$cursor"); fi
    if echo "$r" | grep -q '"ok":false'; then echo "FALLA $tabla: $(echo "$r"|head -c 200)"; fallos=$((fallos+1)); break; fi
    n=$(echo "$r" | gawk 'match($0,/"n":[0-9]+/){print substr($0,RSTART+4,RLENGTH-4); exit}')
    [ -z "$n" ] && { echo "FALLA $tabla: la respuesta no trae n"; fallos=$((fallos+1)); break; }
    [ "$n" -eq 0 ] && break
    pag=$((pag+1)); bajadas=$((bajadas+n))
    printf '%s' "$r" > "$DEST/$tabla.$(printf '%03d' $pag).json"
    sig=$(echo "$r" | gawk 'match($0,/"siguiente":("[^"]*"|[0-9]+|null)/){s=substr($0,RSTART+12,RLENGTH-12); gsub(/"/,"",s); print s; exit}')
    [ "$sig" = "null" ] && break
    [ -z "$sig" ] && break
    cursor="$sig"
    [ "$pag" -gt 200 ] && { echo "FALLA $tabla: el cursor no avanza"; fallos=$((fallos+1)); break; }
  done
  if [ "$bajadas" != "$esperadas" ]; then
    echo "FALLA $tabla: bajadas=$bajadas esperadas=$esperadas"; fallos=$((fallos+1))
  else
    echo "OK   $tabla  $bajadas filas en $pag paginas"; total=$((total+bajadas))
  fi
done <<< "$LISTA"

if [ "$fallos" -eq 0 ]; then echo "RESPALDO COMPLETO OK -- $total renglones"; else echo "RESPALDO CON $fallos FALLOS"; exit 1; fi
