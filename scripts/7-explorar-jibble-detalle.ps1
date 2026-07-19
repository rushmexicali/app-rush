# =====================================================================
# RUSH Car Wash — Fase 3: segunda pasada de exploracion
#
# El primer explorador encontro que Timesheets (500) y TrackedTimeReport
# (400) SI existen, solo que les faltaban parametros. Un 400 y un 500
# traen el motivo en el cuerpo; aqui se lee ese cuerpo en vez de solo el
# codigo.
#
# Tambien revisa los campos de People que sirven para saber si alguien
# esta trabajando: status y latestTimeEntryTime.
# =====================================================================

$ErrorActionPreference = "Stop"

$raiz = Split-Path -Parent $PSScriptRoot
$v = @{}
Get-Content (Join-Path $raiz ".env") | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
  $p = $_ -split '=', 2
  $v[$p[0].Trim()] = $p[1].Trim()
}

$tmp = Join-Path $env:TEMP "rush-jibble2.txt"

$cuerpo = "grant_type=client_credentials" +
          "&client_id=" + [Uri]::EscapeDataString($v['JIBBLE_CLIENT_ID']) +
          "&client_secret=" + [Uri]::EscapeDataString($v['JIBBLE_CLIENT_SECRET'])
[IO.File]::WriteAllText($tmp, $cuerpo, (New-Object Text.UTF8Encoding($false)))
$tok = ((curl.exe -s -m 30 -X POST -H "Content-Type: application/x-www-form-urlencoded" `
  --data-binary ("@" + $tmp) "https://identity.prod.jibble.io/connect/token") -join '' | ConvertFrom-Json).access_token

function Consultar($etiqueta, $url) {
  $code = curl.exe -s -m 25 -o $tmp -w "%{http_code}" -H ("Authorization: Bearer " + $tok) $url
  $txt = [IO.File]::ReadAllText($tmp)
  Write-Host ("`n--- {0}  (HTTP {1})" -f $etiqueta, $code) -ForegroundColor Yellow
  if ($txt.Length -gt 1200) { $txt = $txt.Substring(0, 1200) + " ...(recortado)" }
  Write-Host $txt
  return @{ code = $code; cuerpo = $txt }
}

$hoy   = (Get-Date).ToString("yyyy-MM-dd")
$ayer  = (Get-Date).AddDays(-1).ToString("yyyy-MM-dd")
$manana = (Get-Date).AddDays(1).ToString("yyyy-MM-dd")

Write-Host "`n===== POR QUE FALLARON =====" -ForegroundColor Cyan
Consultar "Timesheets sin parametros" "https://time-attendance.prod.jibble.io/v1/Timesheets" | Out-Null
Consultar "TrackedTimeReport sin parametros" "https://time-attendance.prod.jibble.io/v1/TrackedTimeReport" | Out-Null

Write-Host "`n===== INTENTOS CON PARAMETROS =====" -ForegroundColor Cyan
Consultar "TrackedTimeReport con rango" `
  "https://time-attendance.prod.jibble.io/v1/TrackedTimeReport?startDate=$ayer&endDate=$manana" | Out-Null
Consultar "Timesheets diario" `
  "https://time-attendance.prod.jibble.io/v1/Timesheets?period=Daily&date=$hoy" | Out-Null
Consultar "TimesheetsSummary" `
  "https://time-attendance.prod.jibble.io/v1/TimesheetsSummary?startDate=$ayer&endDate=$manana" | Out-Null
Consultar "TimeEntries plural v1" `
  "https://time-attendance.prod.jibble.io/v1/timeEntries?startDate=$ayer&endDate=$manana" | Out-Null

Write-Host "`n===== LOS GRUPOS (para filtrar solo secadores) =====" -ForegroundColor Cyan
$g = curl.exe -s -m 25 -H ("Authorization: Bearer " + $tok) "https://workspace.prod.jibble.io/v1/Groups"
($g -join '' | ConvertFrom-Json).value | ForEach-Object {
  Write-Host ("  {0,-40} id={1}" -f $_.name, $_.id)
}

Write-Host "`n===== QUE DICE People SOBRE SI ESTAN TRABAJANDO =====" -ForegroundColor Cyan
$p = curl.exe -s -m 25 -H ("Authorization: Bearer " + $tok) `
  "https://workspace.prod.jibble.io/v1/People?`$select=id,fullName,status,latestTimeEntryTime,groupId,role"
($p -join '' | ConvertFrom-Json).value | Select-Object -First 12 | ForEach-Object {
  Write-Host ("  {0,-34} status={1,-10} ultimo registro={2}" -f $_.fullName, $_.status, $_.latestTimeEntryTime)
}
