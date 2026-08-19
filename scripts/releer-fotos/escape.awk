BEGIN { ORS=""; primera=1 }
{
  s = $0
  gsub(/\r/, "", s)
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  if (primera) { primera = 0 } else { print "\\n" }
  print s
}
