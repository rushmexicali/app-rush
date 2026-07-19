# =====================================================================
# RUSH Car Wash — Fase 1, Paso 5
# Cambia la API key de Zettle por un "access token" (permiso temporal).
#
# Como correrlo:
#     powershell -ExecutionPolicy Bypass -File .\scripts\2-token-zettle.ps1
#
# Por que hace falta: la API key es la llave permanente y no se manda en
# cada llamada. Se cambia por un token que dura 2 HORAS. No hay refresh
# token: cuando expira, se vuelve a pedir con la misma API key.
#
# El token NO se imprime en pantalla (es un secreto). Solo se muestra
# confirmacion y cuando expira. Otros scripts lo piden con -Mostrar.
# =====================================================================

param(
  # Devuelve el token en crudo para que otro script lo capture.
  # Sin esta bandera, solo se ve un resumen sin secretos.
  [switch]$Mostrar
)

$ErrorActionPreference = "Stop"

# --- Leer el .env -----------------------------------------------------
$raiz = Split-Path -Parent $PSScriptRoot
$rutaEnv = Join-Path $raiz ".env"
if (-not (Test-Path $rutaEnv)) { throw "No encuentro el archivo .env en $raiz" }

$v = @{}
Get-Content $rutaEnv | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
  $p = $_ -split '=', 2
  $v[$p[0].Trim()] = $p[1].Trim()
}

$apiKey = $v['ZETTLE_API_KEY']
if ([string]::IsNullOrWhiteSpace($apiKey)) {
  throw "ZETTLE_API_KEY esta vacia en el .env. Creala en https://my.zettle.com/apps/api-keys con el permiso READ:PURCHASE."
}

# --- Sacar el client_id de adentro de la API key ----------------------
# La API key es un JWT: tres bloques separados por puntos. El de en medio
# trae datos legibles (no secretos), entre ellos el client_id.
function Abrir-BloqueJwt([string]$bloque) {
  $t = $bloque.Replace('-', '+').Replace('_', '/')
  switch ($t.Length % 4) { 2 { $t += '==' } 3 { $t += '=' } }
  [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t))
}

$clientId = $v['ZETTLE_CLIENT_ID']
if ([string]::IsNullOrWhiteSpace($clientId)) {
  $partes = $apiKey -split '\.'
  if ($partes.Count -lt 2) {
    throw "La ZETTLE_API_KEY no tiene forma de JWT (deberia traer puntos en medio). Revisa que se haya pegado completa."
  }
  $datos = Abrir-BloqueJwt $partes[1] | ConvertFrom-Json

  # Zettle no siempre usa el mismo nombre para este dato.
  foreach ($campo in 'clientId', 'client_id', 'sub', 'iss') {
    if ($datos.PSObject.Properties.Name -contains $campo -and $datos.$campo) {
      $clientId = [string]$datos.$campo
      Write-Host "client_id encontrado dentro de la API key (campo '$campo')." -ForegroundColor DarkGray
      break
    }
  }

  if (-not $clientId) {
    Write-Host "No reconoci el client_id. Campos disponibles en la llave:" -ForegroundColor Yellow
    $datos.PSObject.Properties.Name -join ', ' | Write-Host
    throw "Agrega ZETTLE_CLIENT_ID al .env a mano."
  }
}

# --- Pedir el token ---------------------------------------------------
# "assertion grant": se presenta la API key como prueba de identidad.
$cuerpo = @(
  "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer",
  "client_id=$([Uri]::EscapeDataString($clientId))",
  "assertion=$([Uri]::EscapeDataString($apiKey))"
) -join '&'

# Va por archivo temporal: el cuerpo es larguisimo y no cabe comodo en
# la linea de comando de Windows.
$tmp = Join-Path $env:TEMP "rush-token-$([guid]::NewGuid()).txt"
Set-Content -Path $tmp -Value $cuerpo -Encoding ascii -NoNewline

try {
  $respuesta = curl.exe -s -m 30 -X POST `
    -H "Content-Type: application/x-www-form-urlencoded" `
    --data-binary "@$tmp" `
    "https://oauth.zettle.com/token"
}
finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($respuesta)) {
  throw "Zettle no respondio nada. Revisa tu conexion a internet."
}

$json = $null
try { $json = $respuesta | ConvertFrom-Json } catch { }

if (-not $json -or -not $json.access_token) {
  Write-Host "`nZettle rechazo la peticion. Respondio:" -ForegroundColor Red
  Write-Host $respuesta
  Write-Host "`nCausas comunes:" -ForegroundColor Yellow
  Write-Host "  - La API key se pego incompleta (se corto al copiar)."
  Write-Host "  - La llave fue revocada o se creo sin el permiso READ:PURCHASE."
  throw "No se obtuvo el access token."
}

# --- Resultado --------------------------------------------------------
if ($Mostrar) {
  # Modo para otros scripts: devuelve el token limpio, sin adornos.
  $json.access_token
}
else {
  $expiraEn = if ($json.expires_in) { [int]$json.expires_in } else { 0 }
  Write-Host "`n=== Token obtenido correctamente ===" -ForegroundColor Green
  Write-Host "  client_id : $clientId"
  Write-Host "  token     : <oculto, $($json.access_token.Length) caracteres>"
  Write-Host "  expira en : $([math]::Round($expiraEn / 60)) minutos"
  Write-Host "`nNo hace falta guardarlo: se vuelve a pedir cuando se necesite.`n"
}
