BEGIN { ORS=""; print "{\"query\":\"" }
{
  s = $0
  gsub(/\r/, "", s)
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  print s "\\n"
}
END { print "\"}" }
