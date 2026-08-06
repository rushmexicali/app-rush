# Extrae el padron (seccion "Client Info") del export: una linea por persona =
# "First Last". Es la lista AUTORITATIVA de nombres actuales; se usa para el diff
# de "personas que desaparecen / nuevas".
#   Uso: gawk -v nl=<linea_de_"Notes"> -f padron.awk notas_utf8.txt > padron.tsv
function emit(){ if(fn!=""){ full=fn; if(ln!="")full=fn" "ln; gsub(/[[:space:]]+$/,"",full); print full } fn=""; ln="" }
NR>=nl { exit }
/First name:/ { emit(); s=$0; sub(/.*First name:[[:space:]]*/,"",s); gsub(/[[:space:]]+$/,"",s); fn=s; ln="" }
/Last name:/  { s=$0; sub(/.*Last name:[[:space:]]*/,"",s); gsub(/[[:space:]]+$/,"",s); ln=s }
END{ emit() }
