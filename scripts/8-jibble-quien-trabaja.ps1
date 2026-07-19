# =====================================================================
# RUSH Car Wash — Fase 3: encontrar quien esta trabajando AHORA
#
# Lo aprendido en las pasadas anteriores:
#   - TrackedTimeReport pide "from" (no "startDate"). El error lo dijo.
#   - Existe el grupo "Secador", que es justo a quien hay que mostrar.
#   - status Removed = ex-empleado, no debe aparecer.
# =====================================================================

$ErrorActionPreference = "Stop"

$raiz = Split-Path -Parent $PSScriptRoot
$v = @{}
Get-Content (Join-Path $raiz ".env") | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
  $p = $_ -split '=', 2
  $v[$p[0].Trim()] = $p[1].Trim()
}

$tmp = Join-Path $env:TEMP "rush-jibble3.txt"
$cuerpo = "grant_type=client_credentials" +
          "&client_id=" + [Uri]::EscapeDataString($v['JIBBLE_CLIENT_ID']) +
          "&client_secret=" + [Uri]::EscapeDataString($v['JIBBLE_CLIENT_SECRET'])
[IO.File]::WriteAllText($tmp, $cuerpo, (New-Object Text.UTF8Encoding($false)))
$tok = ((curl.exe -s -m 30 -X POST -H "Content-Type: application/x-www-form-urlencoded" `
  --data-binary ("@" + $tmp) "https://identity.prod.jibble.io/connect/token") -join '' | ConvertFrom-Json).access_token

function Consultar($etiqueta, $url, $recorte = 1500) {
  $code = curl.exe -s -m 25 -o $tmp -w "%{http_code}" -H ("Authorization: Bearer " + $tok) $url
  $txt = [IO.File]::ReadAllText($tmp)
  Write-Host ("`n--- {0}  (HTTP {1})" -f $etiqueta, $code) -ForegroundColor Yellow
  if ($txt.Length -gt $recorte) { Write-Host ($txt.Substring(0, $recorte) + " ...(recortado)") } else { Write-Host $txt }
  return @{ code = $code; cuerpo = $txt }
}

$hoy    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$manana = (Get-Date).ToUniversalTime().AddDays(1).ToString("yyyy-MM-dd")

Write-Host "`n===== TrackedTimeReport con 'from' =====" -ForegroundColor Cyan
Consultar "solo from" "https://time-attendance.prod.jibble.io/v1/TrackedTimeReport?from=$hoy" | Out-Null
Consultar "from + to"  "https://time-attendance.prod.jibble.io/v1/TrackedTimeReport?from=$hoy&to=$manana" | Out-Null

Write-Host "`n===== Timesheets: que valores acepta Period? =====" -ForegroundColor Cyan
Consultar "period invalido a proposito" "https://time-attendance.prod.jibble.io/v1/Timesheets?period=XXX&from=$hoy&to=$manana" | Out-Null
Consultar "period=Custom" "https://time-attendance.prod.jibble.io/v1/Timesheets?period=Custom&from=$hoy&to=$manana" | Out-Null

Write-Host "`n===== Solo el grupo Secador, sin ex-empleados =====" -ForegroundColor Cyan
$grupoSecador = "ef74b0bf-ba86-4f90-ac29-05e9037dba7b"
$url = "https://workspace.prod.jibble.io/v1/People?`$select=id,fullName,status,latestTimeEntryTime,groupId" +
       "&`$filter=groupId eq $grupoSecador and status ne 'Removed'"
$r = Consultar "People filtrado" ([Uri]::EscapeUriString($url)) 400
if ($r.code -eq "200") {
  $gente = ($r.cuerpo | ConvertFrom-Json).value
  Write-Host "`n  === SECADORES ACTIVOS EN LA PLANTILLA ($($gente.Count)) ===" -ForegroundColor Green
  $gente | Sort-Object fullName | ForEach-Object {
    Write-Host ("    {0,-34} ultimo registro: {1}" -f $_.fullName, $_.latestTimeEntryTime)
  }
}
