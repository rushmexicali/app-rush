#!/bin/bash
# =====================================================================
# Export PDF del ClientNoteTracker -> staging listo para cargar.
#
#     bash scripts/importar-clientnotetracker/preparar-import.sh <export.pdf> <carpeta>
#
# Hace los pasos 3.1, 3.2 y 3.3 del RUNBOOK de un jalon y deja en <carpeta>:
#     notas_utf8.txt      el PDF en texto
#     zettle_gratis.tsv   ticket / centavos / fecha / gz, de las DOS fuentes
#     staging_full.tsv    una fila por visita
#     lote_NN.sql         los INSERT listos para cargar-staging.sh
#
# Es de SOLO LECTURA contra la base. No escribe nada en el CRM.
# =====================================================================
set -e
RAIZ="C:/Users/luis_/Desktop/App RUSH"
cd "$RAIZ" || exit 1
PDF="$1"; W="$2"
if [ -z "$PDF" ] || [ -z "$W" ]; then
  echo "uso: preparar-import.sh <export.pdf> <carpeta-de-trabajo>"; exit 1
fi
[ -f "$PDF" ] || { echo "FALLA: no existe $PDF"; exit 1; }
mkdir -p "$W"
D=scripts/importar-clientnotetracker
PDFTOTEXT="C:/Program Files/Git/mingw64/bin/pdftotext.exe"

echo "== 3.1  PDF -> texto =="
"$PDFTOTEXT" -enc UTF-8 -layout "$PDF" "$W/notas_utf8.txt"

# La zona del encabezado NO se usa para nada: sale del telefono del dueno y ya
# mintio una vez (21/ago/2026). Se imprime nada mas para saber que declara.
echo -n "   zona que DECLARA el export (informativa): "
grep -i -m1 "timezone" "$W/notas_utf8.txt" | sed 's/^ *//' || echo "(no dice)"

# 🔑 El corte es la primera linea que casa /Name:/ y NO la palabra "Notes":
# con -layout el encabezado se pega al final de una linea "First name:" y el
# grep no lo encuentra. /Name:/ distingue mayusculas, asi que "First name:" y
# "Last name:" (n minuscula) no estorban.
NL=$(gawk '/Name:/{print FNR; exit}' "$W/notas_utf8.txt")
echo "   corte de las notas: linea $NL"

# ⚠️ El PDF completo trae miles de paginas y pdftotext pega un salto de pagina
# PEGADO a la primera linea "Name:" de cada una. Por eso staging.awk busca
# /Name:/ sin anclar. Un grep "^Name:" pierde una visita por pagina y NO avisa.
PAGS=$(tr -cd '\f' < "$W/notas_utf8.txt" | wc -c)
NOTAS=$(grep -c "Name:" "$W/notas_utf8.txt")
ANCLADAS=$(grep -c "^Name:" "$W/notas_utf8.txt" || true)
PADRON=$(grep -c "First name:" "$W/notas_utf8.txt")
echo "   paginas: $((PAGS + 1))   notas: $NOTAS   (ancladas: $ANCLADAS)   padron: $PADRON"
if [ "$NOTAS" != "$ANCLADAS" ]; then
  echo "   nota: $((NOTAS - ANCLADAS)) notas llevan el salto de pagina pegado. Normal; staging.awk las agarra."
fi

echo "== 3.2  Zettle desde la base (zettle_compras + ventas) =="
sed 's/@FIN@/$/' "$D/zettle-desde-la-base.sql.tpl" > "$W/_z.tpl"
: > "$W/zettle_gratis.tsv"
for par in "0 9000" "9000 18000" "18000 99999999"; do
  set -- $par
  sed -e "s/@DESDE@/$1/" -e "s/@HASTA@/$2/" "$W/_z.tpl" > "$W/_z.sql"
  bash scripts/releer-fotos/q.sh "$W/_z.sql" > "$W/_z.json"
  gawk -f "$D/desblob.awk" "$W/_z.json" >> "$W/zettle_gratis.tsv"
done
# Una linea vacia se cuela si alguna tanda no trajo nada.
gawk 'NF>0' "$W/zettle_gratis.tsv" > "$W/_zz" && mv "$W/_zz" "$W/zettle_gratis.tsv"
ZN=$(wc -l < "$W/zettle_gratis.tsv")
ZMAL=$(gawk -F'\t' 'NF!=4' "$W/zettle_gratis.tsv" | wc -l)
echo "   compras: $ZN   mal formadas: $ZMAL"
[ "$ZMAL" -eq 0 ] || { echo "FALLA: hay filas de Zettle mal formadas"; exit 1; }

echo "== 3.3  staging (una fila por visita) =="
gawk -v nl="$NL" -f "$D/staging.awk" "$W/zettle_gratis.tsv" "$W/notas_utf8.txt" > "$W/staging_full.tsv"
SN=$(wc -l < "$W/staging_full.tsv")
if [ "$SN" != "$NOTAS" ]; then
  echo "FALLA: el staging trae $SN filas y el PDF $NOTAS notas. Revisa el corte."; exit 1
fi
gawk -F'\t' '{
  if($4==1) g++; if($5!="") m++; if($6!="") t++; s+=$5; n[$1]=1
} END{
  c=0; for(k in n) c++
  printf "   visitas: %d   gratis: %d   con monto: %d   con ticket: %d\n", NR, g, m, t
  printf "   personas distintas: %d   suma: $%.2f\n", c, s/100
}' "$W/staging_full.tsv"

echo "== lotes para cargar =="
gawk -v dest="$W" -f "$D/gen-inserts.awk" "$W/staging_full.tsv" | sed 's/^/   /'

echo ""
echo "LISTO. Sigue:  bash $D/cargar-staging.sh \"$W\""
