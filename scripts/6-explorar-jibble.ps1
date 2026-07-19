# =====================================================================
# RUSH Car Wash — Fase 3, Paso 1: explorar la API de Jibble
#
#     powershell -ExecutionPolicy Bypass -File .\scripts\6-explorar-jibble.ps1
#
# No cambia nada: solo pregunta y reporta. Sirve para contestar con datos
# lo que la documentacion publica no dice:
#   - que endpoint dice quien esta checado AHORA
#   - si se distingue "en descanso" de "checado"
#   - si esta cuenta tiene webhooks
#   - que trae cada persona
# =====================================================================

$ErrorActionPreference = "Stop"

$raiz = Split-Path -Parent $PSScriptRoot
$v = @{}
Get-Content (Join-Path $raiz ".env") | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
  $p = $_ -split '=', 2
  $v[$p[0].Trim()] = $p[1].Trim()
}

$id  = $v['JIBBLE_CLIENT_ID']
$sec = $v['JIBBLE_CLIENT_SECRET']
if ([string]::IsNullOrWhiteSpace($id) -or [string]::IsNullOrWhiteSpace($sec)) {
  throw "Faltan JIBBLE_CLIENT_ID o JIBBLE_CLIENT_SECRET en el .env. Se crean en Jibble > Organization Settings > API Keys."
}

# Ruta fija que se sobrescribe. No se borra nada: en este entorno
# Remove-Item se bloquea y tumba el resto del script.
$tmp = Join-Path $env:TEMP "rush-jibble.txt"

# --- Token -----------------------------------------------------------
Write-Host "`n=== 1) Pidiendo token a Jibble ===" -ForegroundColor Cyan

$cuerpo = "grant_type=client_credentials" +
          "&client_id=" + [Uri]::EscapeDataString($id) +
          "&client_secret=" + [Uri]::EscapeDataString($sec)
[IO.File]::WriteAllText($tmp, $cuerpo, (New-Object Text.UTF8Encoding($false)))

$resp = curl.exe -s -m 30 -X POST `
  -H "Content-Type: application/x-www-form-urlencoded" `
  --data-binary ("@" + $tmp) `
  "https://identity.prod.jibble.io/connect/token"

$json = $null
try { $json = ($resp -join '') | ConvertFrom-Json } catch { }

if (-not $json -or -not $json.access_token) {
  Write-Host "Jibble rechazo la peticion:" -ForegroundColor Red
  Write-Host ($resp -join '')
  throw "No se obtuvo token."
}

$tok = $json.access_token
Write-Host "  token obtenido (dura $([math]::Round($json.expires_in/60)) minutos)" -ForegroundColor Green

function Probar($etiqueta, $url) {
  $r = curl.exe -s -m 25 -o $tmp -w "%{http_code}" -H ("Authorization: Bearer " + $tok) $url
  $cuerpo = [IO.File]::ReadAllText($tmp)
  $marca = if ($r -eq "200") { "OK " } else { "-- " }
  Write-Host ("  {0}{1,-42} HTTP {2}" -f $marca, $etiqueta, $r)
  if ($r -eq "200") { return $cuerpo } else { return $null }
}

# --- Quien hay ---------------------------------------------------------
Write-Host "`n=== 2) La gente de tu organizacion ===" -ForegroundColor Cyan
$gente = Probar "workspace /v1/People" "https://workspace.prod.jibble.io/v1/People"
if ($gente) {
  $g = $gente | ConvertFrom-Json
  $lista = if ($g.value) { $g.value } else { $g }
  Write-Host "`n  $($lista.Count) personas. Campos disponibles por persona:" -ForegroundColor DarkGray
  if ($lista.Count -gt 0) {
    Write-Host ("  " + (($lista[0].PSObject.Properties.Name | Sort-Object) -join ', '))
    Write-Host "`n  Primeras personas:" -ForegroundColor DarkGray
    $lista | Select-Object -First 8 | ForEach-Object {
      $nombre = if ($_.fullName) { $_.fullName } elseif ($_.name) { $_.name } else { "(sin nombre)" }
      $foto   = if ($_.pictureUrl -or $_.picture) { "con foto" } else { "sin foto" }
      Write-Host ("    - {0,-28} {1}" -f $nombre, $foto)
    }
  }
}

# --- Quien esta checado ahora -----------------------------------------
Write-Host "`n=== 3) Buscando el endpoint de 'quien esta checado ahora' ===" -ForegroundColor Cyan
Write-Host "  (se prueban varios; los que digan OK existen en tu plan)" -ForegroundColor DarkGray

$hoy = (Get-Date).ToString("yyyy-MM-dd")
$candidatos = @(
  @("time-attendance /v1/TimeEntries",        "https://time-attendance.prod.jibble.io/v1/TimeEntries"),
  @("time-attendance /v1/Timesheets",         "https://time-attendance.prod.jibble.io/v1/Timesheets"),
  @("time-attendance /v1/Activities",         "https://time-attendance.prod.jibble.io/v1/Activities"),
  @("time-attendance /v1/TrackedTimeReport",  "https://time-attendance.prod.jibble.io/v1/TrackedTimeReport?date=$hoy"),
  @("time-attendance /v1/AttendanceSummary",  "https://time-attendance.prod.jibble.io/v1/AttendanceSummary"),
  @("time-attendance /v1/PersonStatus",       "https://time-attendance.prod.jibble.io/v1/PersonStatus"),
  @("workspace /v1/PersonStatuses",           "https://workspace.prod.jibble.io/v1/PersonStatuses"),
  @("workspace /v1/Groups",                   "https://workspace.prod.jibble.io/v1/Groups")
)
$encontrados = @{}
foreach ($c in $candidatos) {
  $r = Probar $c[0] $c[1]
  if ($r) { $encontrados[$c[0]] = $r }
}

# --- Webhooks ----------------------------------------------------------
Write-Host "`n=== 4) Hay webhooks en tu plan? ===" -ForegroundColor Cyan
foreach ($c in @(
  @("workspace /v1/Webhooks",       "https://workspace.prod.jibble.io/v1/Webhooks"),
  @("workspace /v1/Subscriptions",  "https://workspace.prod.jibble.io/v1/Subscriptions"),
  @("time-attendance /v1/Webhooks", "https://time-attendance.prod.jibble.io/v1/Webhooks")
)) { Probar $c[0] $c[1] | Out-Null }

# --- Muestra de lo que si respondio ------------------------------------
Write-Host "`n=== 5) Que devuelve cada endpoint que funciono ===" -ForegroundColor Cyan
foreach ($k in $encontrados.Keys) {
  Write-Host "`n  --- $k ---" -ForegroundColor Yellow
  $d = $encontrados[$k] | ConvertFrom-Json
  $filas = if ($d.value) { $d.value } else { $d }
  if ($filas -is [array] -and $filas.Count -gt 0) {
    Write-Host "    $($filas.Count) registros. Campos:"
    Write-Host ("    " + (($filas[0].PSObject.Properties.Name | Sort-Object) -join ', '))
    Write-Host "    Ejemplo:"
    Write-Host ("    " + ($filas[0] | ConvertTo-Json -Depth 2 -Compress))
  } else {
    Write-Host "    (vacio o no es lista)"
  }
}

Write-Host "`nListo. Nada fue modificado en Jibble.`n" -ForegroundColor Green
