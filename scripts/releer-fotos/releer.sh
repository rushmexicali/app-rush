#!/bin/bash
# Vuelve a leer la foto de un carro con el MISMO prompt y el MISMO esquema que
# la Edge Function `app`, y guarda el resultado con `guardar_datos_de_foto`.
#
#   ./releer.sh <carro_id> <foto_path> [--solo-leer]
#
# --solo-leer imprime lo que devolvio el modelo y NO escribe en la base.
# Ver README.md antes de correrlo en lote.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
ENVF="${ENVF:-$D/../../.env}"
TS="${TS:-$D/../../supabase/functions/app/index.ts}"

SB_URL=$(grep -a '^SUPABASE_URL=' "$ENVF" | head -1 | cut -d= -f2- | tr -d '\r')
SB_KEY=$(grep -a '^SUPABASE_SECRET_KEY=' "$ENVF" | head -1 | cut -d= -f2- | tr -d '\r')
AN_KEY=$(grep -a '^ANTHROPIC_API_KEY=' "$ENVF" | head -1 | cut -d= -f2- | tr -d '\r')

CARRO="$1"; FOTO="$2"; MODO="$3"
W="$D/trabajo"; mkdir -p "$W"

# 0) El prompt sale del .ts EN CADA CORRIDA, no de una copia: dos versiones de
#    la misma regla se desincronizan en silencio (ver README, regla 1).
gawk '/^const INSTRUCCION_FOTO = `/ { f=1; sub(/^const INSTRUCCION_FOTO = `/,""); print; next }
      f { if (/`;$/) { sub(/`;$/,""); print; exit } print }' "$TS" > "$W/prompt.txt"
if [ ! -s "$W/prompt.txt" ]; then
  echo "$CARRO|ERROR|no se pudo extraer INSTRUCCION_FOTO de $TS"; exit 1
fi

# 1) La foto, del bucket privado.
curl.exe -s -f -o "$W/$CARRO.jpg" -H "Authorization: Bearer $SB_KEY" -H "apikey: $SB_KEY" \
  "$SB_URL/storage/v1/object/fotos/$FOTO" || { echo "$CARRO|ERROR|no se pudo bajar la foto"; exit 0; }

# 2) El cuerpo: parte1 + base64 + el prompt escapado.
{
  tr -d '\n' < "$D/parte1.json"
  base64 -w0 < "$W/$CARRO.jpg"
  printf '%s' '"}},{"type":"text","text":"'
  gawk -f "$D/escape.awk" "$W/prompt.txt"
  printf '%s' '"}]}]}'
} > "$W/$CARRO.body.json"

# 3) La lectura. Mismo modelo, mismo esquema, mismo corte de 25 s.
curl.exe -s --max-time 25 -o "$W/$CARRO.resp.json" \
  -H "x-api-key: $AN_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
  --data-binary "@$W/$CARRO.body.json" https://api.anthropic.com/v1/messages \
  || { echo "$CARRO|ERROR|la llamada a Anthropic fallo"; exit 0; }

if ! grep -q '"type":"text"' "$W/$CARRO.resp.json"; then
  echo "$CARRO|SIN_LECTURA|$(head -c 200 "$W/$CARRO.resp.json")"
  exit 0
fi

# 4) Quien aplica las reglas de aceptacion es Postgres, leyendo la respuesta
#    cruda: la placa solo si `placa_legible`, la organizacion solo si hay placa,
#    y el tipo solo si es uno de los cuatro validos. Mismas reglas que el .ts.
{
  printf '%s\n' 'with resp as (select $rsp$'
  cat "$W/$CARRO.resp.json"
  printf '%s\n' '$rsp$::jsonb as r),'
  printf '%s\n' 'lec as ('
  printf '%s\n' "  select (select (b->>'text')::jsonb from jsonb_array_elements(r->'content') b"
  printf '%s\n' "           where b->>'type' = 'text' limit 1) as l,"
  printf '%s\n' "         r->>'stop_reason' as stop from resp)"
  printf '%s\n' 'select public.guardar_datos_de_foto('
  printf '%s\n' "  $CARRO,"
  printf '%s\n' "  case when (l->>'placa_legible')::boolean then upper(nullif(btrim(l->>'placa'),'')) end,"
  printf '%s\n' "  case when (l->>'placa_legible')::boolean and nullif(btrim(l->>'placa'),'') is not null"
  printf '%s\n' "       then upper(nullif(btrim(l->>'organizacion'),'')) end,"
  printf '%s\n' "  nullif(btrim(l->>'marca'),''),"
  printf '%s\n' "  nullif(btrim(l->>'submarca'),''),"
  printf '%s\n' "  case when l->>'tipo' in ('automovil','camioneta','pickup','pasajeros') then l->>'tipo' end"
  printf '%s\n' ') as r from lec where stop is distinct from $x$refusal$x$ and l is not null;'
} > "$W/$CARRO.guardar.sql"

if [ "$MODO" = "--solo-leer" ]; then
  echo "$CARRO|LEIDO|$(gawk 'BEGIN{RS="\"text\":\""} NR==2{print substr($0,1,300)}' "$W/$CARRO.resp.json")"
  exit 0
fi

OUT=$(bash "$D/q.sh" "$W/$CARRO.guardar.sql")
echo "$CARRO|GUARDADO|$OUT"
