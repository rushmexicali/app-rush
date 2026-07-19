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
  # Borra las suscripciones que apunten a nuestra Edge Function y crea una
  # nueva. Se usa para cambiar el signingKey: no se puede cambiar solo,
  # nace junto con la suscripcion.
  [switch]$Rotar,
  # Correo al que Zettle avisa si el webhook empieza a fallar.
  [string]$Email = "rushmexicali@gmail.com"
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

# --- 1.5) Rotar: borrar las que apunten a nuestro destino --------------
if ($Rotar) {
  Write-Host "=== Borrando suscripciones que apuntan a nuestra funcion ===" -ForegroundColor Cyan
  $lista = $null
  try { $lista = $existentes | ConvertFrom-Json } catch { }

  $aBorrar = @($lista | Where-Object { $_.destination -eq $destino })
  if ($aBorrar.Count -eq 0) {
    Write-Host "  (no habia ninguna que borrar)`n"
  }
  foreach ($s in $aBorrar) {
    $r = curl.exe -s -m 30 -o NUL -w "%{http_code}" -X DELETE `
      -H "Authorization: Bearer $token" "$api/$($s.uuid)"
    Write-Host "  borrada $($s.uuid) -> HTTP $r"
  }
  Write-Host ""
  # Rotar implica crear la nueva enseguida; si no, quedaria sin webhook.
  $Crear = $true
}

# --- 2) Crear (solo si se pidio) --------------------------------------
if (-not $Crear) {
  Write-Host "Modo consulta: no se creo nada." -ForegroundColor DarkGray
  Write-Host "Para crearla de verdad, vuelve a correr agregando  -Crear`n" -ForegroundColor DarkGray
  return
}

# Zettle exige un UUID "version 1" (el que lleva la fecha codificada adentro).
# PowerShell solo sabe hacer los de version 4 (puro azar), asi que se arma a mano.
function New-UuidV1 {
  # Los UUID v1 cuentan intervalos de 100 nanosegundos desde el 15/oct/1582
  # (cuando entro en vigor el calendario gregoriano).
  $origen = [datetime]::new(1582, 10, 15, 0, 0, 0, [DateTimeKind]::Utc)
  $ts = [uint64]([datetime]::UtcNow - $origen).Ticks

  # Ojo: la "L" es obligatoria. Sin ella PowerShell lee 0xFFFFFFFF como -1
  # y la mascara no recorta nada.
  $timeLow = [uint32]($ts -band 0xFFFFFFFFL)
  $timeMid = [uint16](($ts -shr 32) -band 0xFFFF)
  # El "1" de la version va en los 4 bits altos de este bloque.
  $timeHi  = [uint16]((($ts -shr 48) -band 0x0FFF) -bor 0x1000)
  # Los dos bits altos en "10" marcan la variante estandar.
  $clockSeq = [uint16]((Get-Random -Minimum 0 -Maximum 0x4000) -bor 0x8000)

  $nodo = New-Object byte[] 6
  (New-Object System.Random).NextBytes($nodo)
  $nodo[0] = $nodo[0] -bor 0x01  # marca "nodo aleatorio", no una MAC real

  '{0:x8}-{1:x4}-{2:x4}-{3:x4}-{4}' -f $timeLow, $timeMid, $timeHi, $clockSeq,
    (($nodo | ForEach-Object { $_.ToString('x2') }) -join '')
}

$cuerpo = @{
  uuid          = New-UuidV1
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
# Se tapa el signingKey antes de imprimir: es un secreto y no debe quedar
# en el historial de la terminal. Mas abajo se guarda en el .env.
Write-Host ($respuesta -replace '("signingKey"\s*:\s*")[^"]+(")', '$1<oculto>$2')

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
