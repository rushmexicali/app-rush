#!/bin/bash
# Revisa que el JavaScript de las tres pantallas al menos PARSEE.
#
# No hay node ni deno en esta maquina. Se extrae el JS de cada HTML y se pasa
# por el interprete de Windows. Un error de PARSEO (comilla sin cerrar, coma de
# mas) sale con "expected" o "syntax"; un error de EJECUCION ("'document' is
# undefined") es lo NORMAL y esperado, porque las pantallas necesitan un
# navegador. Solo lo primero tumba la prueba.
#
# ⚠️ Se renombran los accesos a propiedades que se llaman como una palabra
# reservada (`.catch(`, `.delete(`). El JavaScript moderno las permite como
# nombre de propiedad; este interprete es de la epoca en que no. Sin este
# renombre, `st.delete(id)` de la cola de fotos sale como "error de sintaxis"
# y la prueba grita por algo que en el navegador funciona perfecto. Una prueba
# que da falsos positivos se deja de correr a la semana.
# No se toca el archivo real: el renombre pasa sobre una copia temporal.
cd "$(dirname "$0")/.." || exit 1
TMP="${TMPDIR:-/tmp}/rush-sintaxis"
mkdir -p "$TMP"

malos=0
for f in docs/index.html docs/caja.html docs/reporte.html; do
  nombre=$(basename "$f" .html)
  gawk '/<script>/{d=1;next} /<\/script>/{d=0} d' "$f" \
    | sed 's/\.catch(/.RESERVADA1(/g; s/\.delete(/.RESERVADA2(/g' > "$TMP/$nombre.js"
  salida=$(cscript //E:JScript //Nologo "$TMP/$nombre.js" 2>&1 | head -3)
  if echo "$salida" | grep -qiE "expected|syntax error|invalid character|unterminated"; then
    echo "  FALLA $f"
    echo "         $salida"
    malos=$((malos + 1))
  else
    echo "  ok    $f  (parsea; el error de 'document' es el esperado)"
  fi
done

if [ "$malos" -eq 0 ]; then
  echo ""
  echo "Las tres pantallas parsean."
  exit 0
fi
echo ""
echo "$malos pantalla(s) con error de sintaxis."
exit 1
