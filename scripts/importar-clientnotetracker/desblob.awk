# La API de administracion devuelve [{"blob":"...\t...\n..."}]. Esto lo vuelve
# TSV de verdad.
#
# Se usa `string_agg` del lado de Postgres en vez de traer una fila por renglon
# porque parsear 27,000 objetos JSON con awk es fragil; un solo campo con
# separadores conocidos no lo es.
{
  s = $0
  sub(/^\[\{"blob":"/, "", s)
  sub(/"\}\]$/, "", s)
  gsub(/\\t/, "\t", s)
  gsub(/\\n/, "\n", s)
  printf "%s\n", s
}
