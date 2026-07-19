# =====================================================================
# RUSH Car Wash — Fase 1, Paso 6
# Suscribe nuestra Edge Function a los avisos de venta de Zettle.
#
# SIN BANDERA = solo mira, no cambia nada (seguro de correr):
#     powershell -ExecutionPolicy Bypass -File .\scripts\3-suscribir-webhook.ps1
#
# CON -Crear = crea la suscripcion de verdad, en la cuenta real:
#     powershell -ExecutionPolicy Bypass -File .\scripts\3-suscribir-webhook.ps1 -Crear
#
# Se hace UNA SOLA VEZ. Dos suscripciones al mismo evento = cada venta
# llega dos veces. (No duplicaria carros, porque purchase_uuid es unico
# en la tabla, pero es ruido innecesario.)
# =====================================================================

param(
  # Sin esta bandera el script solo lista lo que ya existe.
  [switch]$Crear,
  # Correo al que Zettle avisa si el webhook empieza a fallar.
  [string]$Email = "luis.gonzalezr1@gmail.com"
)

$ErrorActionPreference = "Stop"

$raiz = Split-Path -Parent $PSScriptRoot
$rutaEnv = Join-Path $raiz ".env"
$v = @{}
Get-Content $rutaEnv | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
  $p = $_ -split '=', 2
  $v[$p[0].Trim()] = $p[1].Trim()
}

$destino = $v['ZETTLE_WEBHOOK_URL']
if ([string]::IsNullOrWhiteSpace($destino)) { throw "ZETTLE_WEBHOOK_URL esta vacia en el .env." }

# --- Conseguir el token (dura 2 horas) --------------------------------
Write-Host "Pidiendo token a Zettle..." -ForegroundColor DarkGray
$token = & (Join-Path $PSScriptRoot "2-token-zettle.ps1") -Mostrar
if ([string]::IsNullOrWhiteSpace($token)) { throw "No se pudo obtener el token." }

$api = "https://pusher.izettle.com/organizations/self/subscriptions"

# --- 1) Ver que hay ya ------------------------------------------------
Write-Host "`n=== Suscripciones que YA existen en tu cuenta ===" -ForegroundColor Cyan
$existentes = curl.exe -s -m 30 -H "Authorization: Bearer $token" "$api"

if ([string]::IsNullOrWhiteSpace($existentes) -or $existentes -eq '[]') {
  Write-Host "  (ninguna)`n"
}
else {
  Write-Host $existentes
  Write-Host ""
  if ($existentes -like "*$destino*") {
    Write-Host "OJO: ya hay una suscripcion apuntando a tu Edge Function." -ForegroundColor Yellow
    Write-Host "     Crear otra haria que cada venta llegue dos veces.`n" -ForegroundColor Yellow
  }
}

# --- 2) Crear (solo si se pidio) --------------------------------------
if (-not $Crear) {
  Write-Host "Modo consulta: no se creo nada." -ForegroundColor DarkGray
  Write-Host "Para crearla de verdad, vuelve a correr agregando  -Crear`n" -ForegroundColor DarkGray
  return
}

$cuerpo = @{
  uuid          = [guid]::NewGuid().ToString()
  transportName = "WEBHOOK"
  eventNames    = @("PurchaseCreated")
  destination   = $destino
  contactEmail  = $Email
} | ConvertTo-Json -Compress

Write-Host "=== Creando la suscripcion ===" -ForegroundColor Cyan
Write-Host "  evento  : PurchaseCreated"
Write-Host "  destino : $destino"
Write-Host "  contacto: $Email`n"

$tmp = Join-Path $env:TEMP "rush-sub-$([guid]::NewGuid()).json"
Set-Content -Path $tmp -Value $cuerpo -Encoding utf8 -NoNewline
try {
  $respuesta = curl.exe -s -m 30 -X POST `
    -H "Authorization: Bearer $token" `
    -H "Content-Type: application/json" `
    --data-binary "@$tmp" `
    "$api"
}
finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}

Write-Host "Respuesta de Zettle:" -ForegroundColor DarkGray
Write-Host $respuesta

# --- 3) El signingKey -------------------------------------------------
$json = $null
try { $json = $respuesta | ConvertFrom-Json } catch { }

if ($json -and $json.signingKey) {
  # Se escribe directo al .env en lugar de imprimirlo: es un secreto y no
  # tiene por que quedar en el historial de la terminal.
  $lineas = Get-Content $rutaEnv
  $nuevas = $lineas -replace '^ZETTLE_SIGNING_KEY=.*$', "ZETTLE_SIGNING_KEY=$($json.signingKey)"
  Set-Content -Path $rutaEnv -Value $nuevas -Encoding utf8

  Write-Host "`n=== signingKey guardado en el .env ===" -ForegroundColor Green
  Write-Host "  ZETTLE_SIGNING_KEY = <oculto, $($json.signingKey.Length) caracteres>"
  Write-Host "`nZettle solo lo muestra una vez, por eso se guardo automaticamente."
  Write-Host "Sirve para verificar que un aviso venga de Zettle de verdad y no"
  Write-Host "de alguien que descubrio tu URL. Se usa en una fase futura.`n"
}
else {
  Write-Host "`nNo vino signingKey en la respuesta. Revisa el mensaje de arriba." -ForegroundColor Yellow
}
