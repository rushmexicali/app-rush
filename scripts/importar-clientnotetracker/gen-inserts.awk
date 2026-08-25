# staging_full.tsv -> lote_NN.sql, listos para mandar a la API uno por uno.
#
#   gawk -v dest=<carpeta> -f gen-inserts.awk staging_full.tsv
#
# Entrada (la que escupe staging.awk):
#   nombre_norm | display | fecha_24h | es_gratis(0/1) | monto_cent | ticket
#
# Se manda `display` y NO `nombre_norm`: `import.sql` normaliza por su cuenta
# con `normalizar_nombre()`, y guardar el nombre bonito es lo que ve la cajera.
#
# El lote es de 1500 porque el cuerpo va como UNA cadena JSON: mas grande y la
# peticion se vuelve incomoda de depurar cuando falla.
function q(s){ gsub(/'/, "''", s); return "'" s "'" }
BEGIN{ FS="\t"; lote=1500; n=0; f=0; if(dest=="") dest="." }
{
  if (n % lote == 0) {
    if (f > 0) print ";" > out
    f++
    out = sprintf("%s/lote_%02d.sql", dest, f)
    printf "insert into public.stg_cnt (nombre, dt_local, es_gratis, monto_cent, ticket, tz) values\n" > out
    primera = 1
  }
  if (!primera) printf ",\n" > out
  primera = 0
  # tz siempre America/Tijuana: es la regla del proyecto. Si la medicion contra
  # Zettle dice otra cosa, se corrige DESPUES con un update (RUNBOOK 3.4).
  printf "(%s,%s,%s,%s,%s,'America/Tijuana')",
      q($2), q($3), ($4 == "1" ? "true" : "false"),
      ($5 == "" ? "null" : $5),
      ($6 == "" ? "null" : q($6)) > out
  n++
}
END{ if (f > 0) print ";" > out; printf "%d filas en %d lotes\n", n, f }
