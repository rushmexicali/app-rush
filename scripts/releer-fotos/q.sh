#!/bin/bash
# Corre un archivo .sql contra la base de Supabase por la API de administracion.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
ENVF="${ENVF:-$D/../../.env}"
REF=$(grep -a '^SUPABASE_PROJECT_REF=' "$ENVF" | head -1 | cut -d= -f2 | tr -d '\r')
TOK=$(grep -a '^SUPABASE_ACCESS_TOKEN=' "$ENVF" | head -1 | cut -d= -f2 | tr -d '\r')
SQLFILE="$1"
BODY="${SQLFILE}.body.json"
gawk -f "$D/tojson.awk" "$SQLFILE" > "$BODY"
curl.exe -s -X POST "https://api.supabase.com/v1/projects/$REF/database/query" \
  -H "Authorization: Bearer $TOK" -H "Content-Type: application/json" \
  --data-binary "@$BODY"
echo
