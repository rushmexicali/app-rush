#!/bin/bash
# =====================================================================
# EL CANDADO DEL RESET: no puede borrar lealtad que nadie respalda.
#
# Desde el 31/ago/2026 el ClientNoteTracker ya no se llena (decision del
# dueno el 30/ago), asi que `visitas` con `caja <> 'import'` es la UNICA
# copia de la lealtad y el `delete` sin `where` de reset-total.sql la
# borraria sin vuelta. El archivo dejo de limitarse a AVISAR al final y
# ahora ABORTA. Esta prueba comprueba las dos direcciones.
#
# 🔑 Ejercita el ARCHIVO REAL, no una copia de su logica — igual que
#    dryrun-import.sh. Una prueba sobre una copia deja de medir el dia que
#    alguien toque el original.
#
# Todo revierte: el caso 1 aborta por el candado (la siembra se va con el),
# y el caso 2 termina en un `raise` puesto al final a proposito.
# =====================================================================
set -u
cd "$(dirname "$0")/.." || exit 1

ORIGEN=scripts/importar-clientnotetracker/reset-total.sql
T="${TMPDIR:-/tmp}/rush-candado-$$"

# CUANTAS visitas de caja no tiene respaldo HOY. No se escribe a mano: crece
# con cada venta que la caja registra despues del ultimo export del CNT, que
# desde el 31/ago ya no se vuelve a generar. Un numero fijo dejaria de cuadrar
# en la siguiente venta y la prueba fallaria sin que nada este roto.
cat > "$T-n.sql" <<'SQL'
select count(*) sin_respaldo from public.visitas v
 where v.caja <> 'import' and v.estado = 'activa'
   and (v.ticket is null or not exists
        (select 1 from public.stg_cnt s where s.ticket = v.ticket));
SQL
YA=$(bash scripts/releer-fotos/q.sh "$T-n.sql" | gawk 'match($0,/"sin_respaldo":"?[0-9]+/){v=substr($0,RSTART,RLENGTH); sub(/.*:"?/,"",v); print v}')
cat /dev/null > "$T-n.sql"
[ -n "$YA" ] || { echo "  FALLA: no se pudo contar las de caja sin respaldo"; exit 1; }
# La prueba siembra UNA mas, asi que el candado va a pedir YA+1.
ESPERADO=$((YA + 1))

# Una visita de caja con un ticket que el export NO puede tener.
SIEMBRA="insert into public.visitas (persona_id, es_gratis, es_cortesia, estado, caja, es_prueba, ticket, monto)
select id, false, false, 'activa', 'principal', false, '99999999', 123.45 from public.personas limit 1;"

fallas=0

# ---------------------------------------------------------------- caso 1
# Sin permiso: debe abortar Y no borrar nada.
{ echo "$SIEMBRA"; cat "$ORIGEN"; } > "$T-1.sql"
S1=$(bash scripts/releer-fotos/q.sh "$T-1.sql" 2>&1)
cat /dev/null > "$T-1.sql"   # no se borra: ver la memoria "no usar Remove-Item"

if echo "$S1" | grep -q "RESET ABORTADO"; then
  echo "  el candado detiene el reset ....................... OK"
else
  echo "  FALLA: el reset NO aborto con una visita de caja sin respaldo."
  echo "         Eso significa que hoy se puede borrar lealtad irrecuperable."
  echo "$S1" | head -c 400; echo ""
  fallas=$((fallas+1))
fi

# El mensaje tiene que decir CUANTAS y como seguir; si no, no sirve de nada
# a las 8 de la noche con el taller cerrando.
if echo "$S1" | grep -q "rush.perdida_aceptada"; then
  echo "  el error dice como seguir ........................ OK"
else
  echo "  FALLA: el mensaje del candado no explica el override"
  fallas=$((fallas+1))
fi

# ---------------------------------------------------------------- caso 2
# La siembra tuvo que revertirse con el aborto.
cat > "$T-v.sql" <<'SQL'
select count(*) sembrada from public.visitas where ticket = '99999999';
SQL
SV=$(bash scripts/releer-fotos/q.sh "$T-v.sql" 2>&1)
cat /dev/null > "$T-v.sql"
if echo "$SV" | grep -q '"sembrada":0'; then
  echo "  el aborto no dejo basura ......................... OK"
else
  echo "  FALLA: la fila sembrada sobrevivio al aborto: $SV"
  fallas=$((fallas+1))
fi

# ---------------------------------------------------------------- caso 3
# Con el permiso EXACTO, si deja pasar. Se revierte con un raise al final.
{ echo "$SIEMBRA"
  echo "select set_config('rush.perdida_aceptada', '$ESPERADO', false);"
  cat "$ORIGEN"
  echo "do \$\$ begin raise exception 'ENSAYO CANDADO: el override dejo pasar'; end \$\$;"
} > "$T-2.sql"
S2=$(bash scripts/releer-fotos/q.sh "$T-2.sql" 2>&1)
cat /dev/null > "$T-2.sql"

if echo "$S2" | grep -q "ENSAYO CANDADO"; then
  echo "  el override exacto deja pasar .................... OK"
elif echo "$S2" | grep -q "RESET ABORTADO"; then
  echo "  FALLA: el override correcto NO dejo pasar. El reset quedaria"
  echo "         imposible de correr aun cuando se decida a conciencia."
  fallas=$((fallas+1))
else
  echo "  FALLA: el caso del override no llego a su raise: $(echo "$S2" | head -c 300)"
  fallas=$((fallas+1))
fi

# ---------------------------------------------------------------- caso 4
# Un numero que NO coincide no sirve: si sirviera, bastaria teclear
# cualquier cosa y el candado seria decorativo.
{ echo "$SIEMBRA"
  echo "select set_config('rush.perdida_aceptada', '999', false);"
  cat "$ORIGEN"
} > "$T-3.sql"
S3=$(bash scripts/releer-fotos/q.sh "$T-3.sql" 2>&1)
cat /dev/null > "$T-3.sql"
if echo "$S3" | grep -q "RESET ABORTADO"; then
  echo "  un numero que no cuadra no abre el candado ....... OK"
else
  echo "  FALLA: un override equivocado dejo pasar el reset"
  fallas=$((fallas+1))
fi

if [ "$fallas" -eq 0 ]; then
  echo "  PRUEBA PASADA -> el candado detiene, explica, no ensucia y solo abre con el numero exacto"
  exit 0
fi
exit 1
