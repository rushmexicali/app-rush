# =====================================================================
# RUSH Car Wash — Fase 1, Paso 4
# Simula una venta de Zettle y confirma que llego a la tabla "ventas".
#
# Como correrlo (parado en la carpeta del proyecto):
#     powershell -ExecutionPolicy Bypass -File .\scripts\1-probar-webhook.ps1
#
# Para probar que los reintentos NO duplican el carro, corre dos veces
# con el mismo uuid:
#     ... -File .\scripts\1-probar-webhook.ps1 -Uuid "prueba-fija-123"
# =====================================================================

param(
  # Identificador de la venta. Por defecto uno nuevo en cada corrida.
  [string]$Uuid = "prueba-$([guid]::NewGuid())",
  # Monto en PESOS. El script lo convierte a centavos, como manda Zettle.
  [decimal]$Pesos = 150.00
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

$urlBase = $v['SUPABASE_URL']
$llave   = $v['SUPABASE_SECRET_KEY']
$urlFn   = if ($v['ZETTLE_WEBHOOK_URL']) { $v['ZETTLE_WEBHOOK_URL'] } else { "$urlBase/functions/v1/zettle-webhook" }

# --- Armar el aviso, igual a como lo manda Zettle ---------------------
# Ojo: Zettle mete los datos de la venta como TEXTO dentro del aviso.
$centavos = [int]($Pesos * 100)
$ahora    = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

$datosVenta = @{
  purchaseUUID = $Uuid
  amount       = $centavos
  timestamp    = $ahora
} | ConvertTo-Json -Compress

$aviso = @{
  eventName    = "PurchaseCreated"
  messageUuid  = [guid]::NewGuid().ToString()
  timestamp    = $ahora
  payload      = $datosVenta   # <- string, no objeto. A proposito.
} | ConvertTo-Json -Compress

# curl.exe y las comillas de Windows se llevan mal, asi que el JSON va
# por archivo temporal en lugar de ir en la linea de comando.
$tmp = Join-Path $env:TEMP "rush-aviso-$([guid]::NewGuid()).json"
Set-Content -Path $tmp -Value $aviso -Encoding utf8

try {
  Write-Host "`n=== 1) Mandando la venta simulada ===" -ForegroundColor Cyan
  Write-Host "    uuid : $Uuid"
  Write-Host "    monto: `$$Pesos  ($centavos centavos)"
  Write-Host "    hacia: $urlFn`n"

  curl.exe -s -m 30 -w "`nHTTP %{http_code}`n" -X POST `
    -H "Content-Type: application/json" `
    --data-binary "@$tmp" `
    "$urlFn"

  Write-Host "`n=== 2) Buscando la fila en la tabla ventas ===" -ForegroundColor Cyan
  Start-Sleep -Milliseconds 400
  curl.exe -s -m 30 `
    -H "apikey: $llave" -H "Authorization: Bearer $llave" `
    "$urlBase/rest/v1/ventas?purchase_uuid=eq.$Uuid&select=id,purchase_uuid,monto,recibido_en,creado_en"
  Write-Host ""
}
finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
