#!/bin/bash
# Descubre QUE firma Zettle, midiendo en vez de suponiendo.
#
# ✅ YA SE DESCUBRIO (24/ago/2026). El esquema es:
#
#     HMAC-SHA256(llave, timestamp + "." + payload DECODIFICADO)
#
# Este script reportaba "ninguna combinacion coincidio" porque probaba
# "timestamp.payload" con el payload TAL COMO VIAJA (escapado dentro del
# JSON de afuera), y lo que se firma es la cadena ya desescapada. Estaba a
# un desescapado de distancia.
#
# Para comprobar el esquema contra todos los avisos guardados, usa:
#     bash scripts/comprobar-firma-zettle.sh
# Este archivo se conserva por si algun dia Zettle cambia el esquema y hay
# que volver a buscarlo.
#
# Toma el ultimo aviso bueno de `webhook_bitacora` (cuerpo crudo + la cabecera
# `x-izettle-signature`), y prueba las combinaciones posibles con la llave
# `ZETTLE_SIGNING_KEY` hasta encontrar cual reproduce la firma real.
#
#   bash scripts/descubrir-firma-zettle.sh
#
# Por que existe: no hay documentacion publica confiable del esquema de firma
# de Zettle, y adivinarlo en el camino por donde entra el dinero significaria
# rechazar ventas REALES. Con un aviso de verdad se sabe con certeza.
set -e
cd "$(dirname "$0")/.."

LLAVE=$(grep -a '^ZETTLE_SIGNING_KEY=' .env | cut -d= -f2- | tr -d '\r')
if [ -z "$LLAVE" ]; then echo "Falta ZETTLE_SIGNING_KEY en .env"; exit 1; fi

TMP="${TMPDIR:-/tmp}/firma-zettle"
mkdir -p "$TMP"

# Sacar el ultimo aviso bueno. Se piden por separado para no pelear con el
# escapado del JSON: cada uno sale como texto plano.
cat > "$TMP/crudo.sql" <<'EOF'
select crudo from public.webhook_bitacora
 where motivo = 'ok' and crudo is not null
 order by id desc limit 1;
EOF
cat > "$TMP/firma.sql" <<'EOF'
select cabeceras ->> 'x-izettle-signature' as firma
  from public.webhook_bitacora
 where motivo = 'ok' and crudo is not null
 order by id desc limit 1;
EOF

bash scripts/releer-fotos/q.sh "$TMP/crudo.sql" > "$TMP/crudo.json"
FIRMA=$(bash scripts/releer-fotos/q.sh "$TMP/firma.sql" | gawk 'match($0, /"firma":"([^"]*)"/, m) { print m[1] }')

if [ -z "$FIRMA" ]; then
  echo "Todavia no hay un aviso bueno con cuerpo crudo guardado. Espera una venta."
  exit 1
fi

# El cuerpo crudo, tal cual llego (los bytes importan: re-serializar el JSON
# NO da los mismos bytes y el HMAC no cuadraria).
gawk -f "${TMPDIR:-/tmp}/../scratchpad/desescapar.awk" "$TMP/crudo.json" 2>/dev/null \
  || gawk '{ s=$0; sub(/^\[\{"crudo":"/,"",s); sub(/"\}\]$/,"",s);
             gsub(/\\\\/,"\001",s); gsub(/\\n/,"\n",s); gsub(/\\"/,"\"",s); gsub(/\001/,"\\",s);
             printf "%s", s }' "$TMP/crudo.json" > "$TMP/cuerpo.txt"

echo "Firma real:  $FIRMA"
echo "Cuerpo:      $(wc -c < "$TMP/cuerpo.txt") bytes"
echo ""

# Los pedazos que Zettle podria estar firmando.
gawk 'match($0, /"payload"[[:space:]]*:[[:space:]]*"(.*)","timestamp"/, m) { printf "%s", m[1] }' "$TMP/cuerpo.txt" > "$TMP/payload-escapado.txt" || true
gawk 'match($0, /"timestamp"[[:space:]]*:[[:space:]]*"([^"]*)"/, m) { printf "%s", m[1] }' "$TMP/cuerpo.txt" > "$TMP/timestamp.txt" || true
TS=$(cat "$TMP/timestamp.txt" 2>/dev/null || echo "")

probar() {
  local nombre="$1" archivo="$2"
  local h
  h=$(openssl dgst -sha256 -hmac "$LLAVE" -hex < "$archivo" | sed 's/.*= *//')
  if [ "$h" = "$FIRMA" ]; then
    echo "  ✅ COINCIDE  -> $nombre"
    echo "$nombre" > "$TMP/GANADOR.txt"
  else
    echo "     no        $nombre"
  fi
}

echo "Probando combinaciones (HMAC-SHA256 con la llave de firma):"
probar "el cuerpo crudo completo" "$TMP/cuerpo.txt"

if [ -s "$TMP/payload-escapado.txt" ]; then
  probar "solo el payload (tal como viaja, escapado)" "$TMP/payload-escapado.txt"
  if [ -n "$TS" ]; then
    { cat "$TMP/payload-escapado.txt"; printf "%s" "$TS"; } > "$TMP/p-mas-ts.txt"
    probar "payload + timestamp" "$TMP/p-mas-ts.txt"
    { printf "%s" "$TS"; cat "$TMP/payload-escapado.txt"; } > "$TMP/ts-mas-p.txt"
    probar "timestamp + payload" "$TMP/ts-mas-p.txt"
    { printf "%s." "$TS"; cat "$TMP/payload-escapado.txt"; } > "$TMP/ts-punto-p.txt"
    probar "timestamp.payload" "$TMP/ts-punto-p.txt"
  fi
fi

if [ -n "$TS" ]; then
  { cat "$TMP/cuerpo.txt"; printf "%s" "$TS"; } > "$TMP/c-mas-ts.txt"
  probar "cuerpo + timestamp" "$TMP/c-mas-ts.txt"
fi

# Y por si no fuera HMAC sino un hash simple con la llave pegada.
{ printf "%s" "$LLAVE"; cat "$TMP/cuerpo.txt"; } > "$TMP/k-mas-c.txt"
h=$(openssl dgst -sha256 -hex < "$TMP/k-mas-c.txt" | sed 's/.*= *//')
[ "$h" = "$FIRMA" ] && { echo "  ✅ COINCIDE  -> sha256(llave + cuerpo), NO es HMAC"; echo "sha256(llave+cuerpo)" > "$TMP/GANADOR.txt"; } \
                    || echo "     no        sha256(llave + cuerpo)"

echo ""
if [ -f "$TMP/GANADOR.txt" ]; then
  echo "Esquema encontrado: $(cat "$TMP/GANADOR.txt")"
else
  echo "Ninguna combinacion coincidio. NO implementar verificacion todavia:"
  echo "rechazar avisos con una regla equivocada tumbaria ventas reales."
fi
