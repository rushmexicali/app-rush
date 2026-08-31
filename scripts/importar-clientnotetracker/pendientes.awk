# =====================================================================
# Saca del export las notas de "GRATIS PENDIENTE", que NO son un lavado
# normal, y las clasifica. Sale: nombre <TAB> fecha-hora local <TAB> clase
#
# 🔑 LA MISMA PALABRA SIGNIFICA DOS COSAS OPUESTAS, y lo que las separa es
#    si la nota trae numero de ticket. Textual del dueno (31/ago/2026):
#
#      "Cuando dice Gratis pendiente es que se les guardaba el gratis y
#       seguian acumulando sellos. Cuando dice Gratis pendiente y aparte
#       tiene un numero de ticket, es que se habia utilizado ese lavado
#       gratis acumulado con anterioridad."
#
#      sin numero -> MARCADOR : se le guarda el gratis. NO ES UN LAVADO.
#      con numero -> CANJE    : uso el gratis que traia guardado.
#
#    Las dos entraban como lavado PAGADO. La primera regalaba un sello que
#    nadie se gano; la segunda es peor, porque ademas no restaba el gratis.
#
# ⚠️ Un numero de 1 a 5 NO es un ticket: son los rellenos que la cajera
#    teclea (ver limpiar-tickets.sql, 443 casos). Si se contaran, un
#    marcador con "Ticket:1" se leeria como canje.
#
# ⚠️ `Name:` va SIN anclar: con -layout, pdftotext pega el salto de pagina
#    a la primera linea de cada pagina y un "^Name:" pierde una por pagina
#    sin avisar. Misma razon que en staging.awk.
#
# El corte de las notas (donde acaba el padron) se pasa en `nl`, igual que
# a staging.awk.
# =====================================================================
BEGIN { IGNORECASE = 1 }

FNR < nl { next }

/Name:/ { nm = $0; sub(/.*Name: /, "", nm); t = ""; next }
/^Time:/ { t = $0; sub(/^Time: /, "", t); next }

/[Tt][Ii][Cc][Kk]/ {
  linea = $0
  if (linea !~ /pendiente|pendiennte/) next          # incluye el typo real del export

  num = linea
  sub(/.*[Tt][Ii][Cc][Kk][^ :]*:?/, "", num)
  gsub(/[^0-9]/, "", num)
  tiene_ticket = (num != "" && num + 0 > 5)

  clase = tiene_ticket ? "CANJE" : "MARCADOR"

  # "2026-01-15 11:12 AM" -> "2026-01-15 11:12:00" en 24 h
  split(t, a, " "); split(a[2], h, ":")
  hh = h[1] + 0
  if (a[3] == "PM" && hh < 12) hh += 12
  if (a[3] == "AM" && hh == 12) hh = 0
  printf "%s\t%s %02d:%s:00\t%s\n", nm, a[1], hh, h[2], clase
}
