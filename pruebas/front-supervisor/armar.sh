#!/usr/bin/env bash
# Arma el arnes del front del supervisor en una carpeta temporal.
#
# 🔑 NO copia el HTML a mano: lo EXTRAE de docs/index.html en cada corrida,
# igual que marcar-error.js extrae la funcion del Edge Function. Lo unico
# que se agrega es UNA linea que carga stub.js (que reemplaza window.fetch
# antes de que corra el script de la app). Si alguien cambia la pantalla,
# el arnes prueba la version nueva; una copia seria el patron #1 de la
# tabla del README, esta vez dentro de las pruebas.
set -e
raiz="$(cd "$(dirname "$0")/../.." && pwd)"
destino="${1:-$raiz/pruebas/front-supervisor/.armado}"
mkdir -p "$destino"

awk 'NR==4{print; print "<script src=\"stub.js\"></script>"; next} {print}' \
    "$raiz/docs/index.html" > "$destino/index.html"
cp "$raiz/pruebas/front-supervisor/stub.js" "$destino/stub.js"

# Se comprueba que la unica diferencia con produccion sea esa linea. Si el
# arnes se desviara del archivo real, estaria probando otra cosa.
if ! diff <(sed '5d' "$destino/index.html") "$raiz/docs/index.html" > /dev/null; then
  echo "FALLO: el arnes no coincide con docs/index.html" >&2
  exit 1
fi

echo "Arnes armado en: $destino"
echo "Levanta el servidor (hace falta http:// porque pushState no corre en file://):"
echo "  powershell.exe -NoProfile -ExecutionPolicy Bypass -File pruebas/front-supervisor/servidor.ps1 -Raiz \"$destino\" -Puerto 8777"
echo "Y abre http://localhost:8777/"
