# =====================================================================
# ClientNoteTracker -> staging TSV. Una fila por VISITA.
#   Uso:  awk -v nl=<linea_de_"Notes"> -f staging.awk zettle_gratis.tsv notas_utf8.txt > staging_full.tsv
#   Salida (TAB):  nombre_norm  display  fecha_24h  es_gratis(0/1)  monto_centavos  ticket
#
# REGLAS (ver RUNBOOK.md):
#   - es_gratis: si la visita tiene match del mismo dia (+-3) con una compra de
#     Zettle -> ZETTLE MANDA (gz = producto "Gratis"). Sin match -> deteccion de
#     texto de la nota (palabra "gratis" o typo por Levenshtein<=2; "pendiente"
#     NO cuenta = se guarda como disponible).
#   - numero de ticket: se normaliza la letra O -> 0 (ej. 2O969) y se toma la
#     corrida de digitos mas larga.
#   - QUE LINEA ES "la del ticket": ver es_linea_de_ticket(). La guardia era el
#     literal `Ticket:` y perdia 23 tickets del export por errores de dedo en el
#     prefijo (`Ticke26179`, `TickeT 23163`, `TIcket:19158`, `Ticket 21019`).
#     Callando: la visita entraba sin ticket, sin monto y sin ligarse a su carro.
#   - monto: el amount de Zettle (centavos) solo si hay match del mismo dia.
#   - override unico: Gabriel Rodriguez Valdez, ticket "6" del 2026-04-25 = gratis
#     (ticket ilegible; el dueno lo marca a mano). QUITAR si en la base nueva no
#     aplica.
# =====================================================================
function lev(a,b,  la,lb,i,j,cost,m,prev,cur){ la=length(a);lb=length(b); for(j=0;j<=lb;j++)prev[j]=j; for(i=1;i<=la;i++){cur[0]=i; for(j=1;j<=lb;j++){cost=(substr(a,i,1)==substr(b,j,1))?0:1; m=prev[j]+1; if(cur[j-1]+1<m)m=cur[j-1]+1; if(prev[j-1]+cost<m)m=prev[j-1]+cost; cur[j]=m} for(j=0;j<=lb;j++)prev[j]=cur[j]} return prev[lb] }
function norm(s){ s=tolower(s); gsub(/[[:space:]]+/," ",s); gsub(/^ | $/,"",s); return s }
# Es la linea del ticket si la cajera escribio algo parecido a "Ticket", como
# sea que lo haya escrito, O si la nota es UN NUMERO PELON. Las dos formas se
# midieron sobre el export completo del 28/ago/2026 (15,568 notas):
#   - 23 lineas traen "tick" sin ser exactamente `Ticket:`
#   - 4 lineas son solo digitos, y NINGUNA es un numero de pagina (se comprobo)
# ⚠️ Se afloja la GUARDIA, no la extraccion: las dos lineas que sacan el numero
#    ya trabajan sobre el texto en mayusculas/minusculas, asi que un prefijo sin
#    dos puntos igual queda hecho espacios por el `gsub(/[^0-9]/," ")`.
# ⚠️ Y no filtra basura A PROPOSITO: que numeros NO son tickets (los marcadores
#    0-5, los que Zettle no tiene) lo decide `limpiar-tickets.sql`, que corre
#    despues. Es UNA sola regla y vive en un solo lugar.
function es_linea_de_ticket(s,  t){
  t=s; gsub(/\x0c/,"",t); gsub(/^[[:space:]]+|[[:space:]]+$/,"",t)
  if(tolower(t) ~ /tick/) return 1
  if(t ~ /^[0-9]+$/) return 1
  return 0 }
function diasdiff(a,b,  ta,tb){ ta=mktime(substr(a,1,4)" "substr(a,6,2)" "substr(a,9,2)" 12 0 0"); tb=mktime(substr(b,1,4)" "substr(b,6,2)" "substr(b,9,2)" 12 0 0"); if(ta<0||tb<0)return 999; return (ta>tb?ta-tb:tb-ta)/86400 }
function to24(s,  fe,hp,hh,mm,ap){ fe=substr(s,1,10); hp=substr(s,12); split(hp,p," "); split(p[1],hm,":"); hh=hm[1]+0; mm=hm[2]; ap=p[2]; if(ap=="PM"&&hh<12)hh+=12; if(ap=="AM"&&hh==12)hh=0; return fe" "sprintf("%02d:%s:00",hh,mm) }
function emit(){ if(!have)return;
  # UNION: gratis si la nota de CNT lo dice O si Zettle tiene producto "Gratis"
  # (con match del mismo dia). Asi se AGREGAN los que la cajera olvido (Zettle)
  # sin QUITAR los que la cajera SI anoto y Zettle cobro distinto.
  esg = (cntg==1 || (matched && gz[num]==1)) ? 1 : 0
  if(cur=="gabriel rodriguez valdez" && num=="6" && fecha=="2026-04-25") esg=1
  # Monto: si la visita es gratis pero Zettle NO la tiene como producto "Gratis"
  # (gz!=1), el numero de ticket esta mal (apunta a una venta pagada ajena). El
  # lavado fue gratis -> no se le atribuye ese monto (queda sin monto). Los gratis
  # reales de Zettle (gz=1) conservan su monto ($0 o el extra que sí pagaron).
  if(esg==1 && !(matched && gz[num]==1)) monto=""
  printf "%s\t%s\t%s\t%d\t%s\t%s\n", cur, disp, dt24, esg, monto, num
  have=0 }
FNR==NR { amt[$1]=$2; zd[$1]=$3; gz[$1]=$4; next }
FNR>=nl {
  if ($0 ~ /Name:/){ emit(); n=$0; sub(/.*Name:[[:space:]]*/,"",n); gsub(/[[:space:]]+$/,"",n); disp=n; cur=norm(n); have=1; dt24=""; fecha=""; num=""; monto=""; matched=0; cntg=0 }
  else if ($0 ~ /Time:/){ tt=$0; sub(/.*Time:[[:space:]]*/,"",tt); fecha=substr(tt,1,10); dt24=to24(tt) }
  else if (es_linea_de_ticket($0)){
    low=tolower($0); sub(/.*ticket:[[:space:]]*/,"",low); z=low; gsub(/[^a-z]+/," ",z); nw=split(z,W," "); gr=0;pe=0;
    for(i=1;i<=nw;i++){w=W[i]; if(w=="")continue; if(index(w,"gratis")>0)gr=1; else if(length(w)>=4&&lev(w,"gratis")<=2)gr=1; if(substr(w,1,4)=="pend")pe=1}
    cntg=(gr==1&&pe==0)?1:0
    t=toupper($0); sub(/.*TICKET:[[:space:]]*/,"",t); gsub(/O/,"0",t); gsub(/[^0-9]/," ",t); mm=split(t,a," "); num=""; for(i=1;i<=mm;i++) if(length(a[i])>length(num)) num=a[i];
    if(num!="" && (num in amt) && diasdiff(fecha,zd[num])<=3){ matched=1; monto=amt[num] }
  }
}
END{ emit() }
