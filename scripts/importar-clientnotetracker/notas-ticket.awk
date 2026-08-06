# Extrae ticket<TAB>nombre de la seccion Notes del export CNT, replicando la
# MISMA normalizacion de ticket de staging.awk (O->0, corrida de digitos mas larga).
# Sirve para detectar renombres: liga cada ticket al nombre ACTUAL del cliente.
#   Uso: gawk -v nl=<linea_de_"Notes"> -f notas-ticket.awk notas_utf8.txt > ticket_nombre.tsv
function emit(){ if(name!="" && num!=""){ printf "%s\t%s\n", num, name } name=""; num="" }
FNR>=nl {
  if ($0 ~ /Name:/){ emit(); n=$0; sub(/.*Name:[[:space:]]*/,"",n); gsub(/[[:space:]]+$/,"",n); name=n; num="" }
  else if ($0 ~ /Ticket:/){
    t=toupper($0); sub(/.*TICKET:[[:space:]]*/,"",t); gsub(/O/,"0",t); gsub(/[^0-9]/," ",t);
    mm=split(t,a," "); num=""; for(i=1;i<=mm;i++) if(length(a[i])>length(num)) num=a[i];
  }
}
END{ emit() }
