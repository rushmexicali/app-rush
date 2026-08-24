#!/bin/bash
# =====================================================================
# RUSH Car Wash - Comprueba el esquema de firma de Zettle
#
#     bash scripts/comprobar-firma-zettle.sh
#
# Recalcula la firma de TODOS los avisos guardados en `webhook_bitacora`
# y dice cuantos cuadran. Sale con codigo 1 si alguno no cuadra.
#
# EL ESQUEMA, descubierto el 24/ago/2026 midiendo (no de documentacion,
# que no existe):
#
#     x-izettle-signature = HMAC-SHA256(
#         llave    = ZETTLE_SIGNING_KEY, como texto plano (los 64 caracteres
#                    tal cual; NO se decodifica de base64),
#         mensaje  = timestamp + "." + payload
#     )  en hexadecimal minusculas
#
# 🔑 EL DETALLE QUE COSTO ENCONTRARLO: `payload` es el valor DECODIFICADO,
# no como viaja. En el cuerpo del aviso el payload es una CADENA JSON
# dentro de otro JSON, o sea que viaja escapado:
#
#     ...,"payload":"{\"organizationUuid\":\"...\"}","timestamp":"..."
#                    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ esto NO es lo que se firma
#
# Lo que se firma es esa cadena ya desescapada: {"organizationUuid":"..."}.
# El script viejo (descubrir-firma-zettle.sh) probaba "timestamp.payload"
# con la forma ESCAPADA, y por eso reportaba que ninguna combinacion
# coincidia. Estaba a un desescapado de distancia.
#
# Comprobado contra 213 avisos reales: 213 de 213.
#
# ⚠️ La llave nunca se imprime ni sale de esta maquina.
# =====================================================================
set -e
cd "$(dirname "$0")/.."

LLAVE=$(grep -a '^ZETTLE_SIGNING_KEY=' .env | cut -d= -f2- | tr -d '\r')
if [ -z "$LLAVE" ]; then echo "Falta ZETTLE_SIGNING_KEY en .env"; exit 1; fi
HK=$(printf "%s" "$LLAVE" | xxd -p -c 9999 | tr -d '\n')

T="${TMPDIR:-/tmp}/firma-zettle"; mkdir -p "$T"

# Un solo texto: "firma:mensajehex firma:mensajehex ...". Todo hexadecimal y
# dos puntos, asi que no hay nada que se pueda romper por el camino -- que es
# justo lo que hizo fallar el primer intento de medir esto.
cat > "$T/pares.sql" <<'EOF'
select string_agg(
         (cabeceras ->> 'x-izettle-signature') || ':' ||
         encode(convert_to(((crudo::jsonb) ->> 'timestamp') || '.' ||
                           ((crudo::jsonb) ->> 'payload'), 'UTF8'), 'hex'),
         ' ' order by id) as pares
  from public.webhook_bitacora
 where motivo = 'ok' and crudo is not null and crudo is json
   and cabeceras ? 'x-izettle-signature';
EOF

bash scripts/releer-fotos/q.sh "$T/pares.sql" \
  | gawk 'match($0, /"pares":"([^"]*)"/, m) { print m[1] }' \
  | tr ' ' '\n' > "$T/pares.txt"

ok=0; mal=0
while IFS=: read -r firma msg; do
  [ -z "$firma" ] && continue
  printf "%s" "$msg" | xxd -r -p > "$T/m.bin"
  h=$(openssl dgst -sha256 -mac HMAC -macopt "hexkey:$HK" -hex < "$T/m.bin" | sed 's/.*= *//')
  if [ "$h" = "$firma" ]; then ok=$((ok+1)); else mal=$((mal+1)); fi
done < "$T/pares.txt"

echo "avisos con cuerpo crudo y firma : $((ok+mal))"
echo "firma reproducida                : $ok"
echo "no cuadro                        : $mal"
echo ""
if [ "$mal" -eq 0 ] && [ "$ok" -gt 0 ]; then
  echo "El esquema sigue siendo: HMAC-SHA256(llave, timestamp + '.' + payload decodificado)"
  exit 0
fi
echo "OJO: hay avisos cuya firma no se reproduce. NO implementar el rechazo"
echo "hasta entender por que: rechazar con una regla equivocada tumba ventas."
exit 1
