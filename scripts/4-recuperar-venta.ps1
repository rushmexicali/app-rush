# =====================================================================
# RUSH Car Wash — Rescate de ventas
# Trae una venta desde Zettle y la guarda en la tabla, para cuando el
# webhook no llego (internet caido, despliegue a media venta, un bug).
#
#     powershell -ExecutionPolicy Bypass -File .\scripts\4-recuperar-venta.ps1 -Uuid "e77fd9e1-..."
#
# Es seguro repetirlo: si la venta ya esta en la tabla, no la duplica.
# =====================================================================

param(
  [Parameter(Mandatory = $true)]
  [string]$Uuid
)

$ErrorActionPreference = "Stop"

$raiz = Split-Path -Parent $PSScriptRoot
$v = @{}
Get-Content (Join-Path $raiz ".env") | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
  $p = $_ -split '=', 2
  $v[$p[0].Trim()] = $p[1].Trim()
}

# --- 1) Pedirle la venta a Zettle -------------------------------------
Write-Host "Pidiendo token a Zettle..." -ForegroundColor DarkGray
$token = & (Join-Path $PSScriptRoot "2-token-zettle.ps1") -Mostrar

Write-Host "Buscando la venta $Uuid ..." -ForegroundColor DarkGray
$crudo = curl.exe -s -m 30 -H "Authorization: Bearer $token" `
  "https://purchase.izettle.com/purchase/v2/$Uuid"

$venta = $null
try { $venta = $crudo | ConvertFrom-Json } catch { }
if (-not $venta -or -not $venta.amount) {
  Write-Host "Zettle no devolvio la venta. Respondio:" -ForegroundColor Red
  Write-Host $crudo
  throw "No se pudo recuperar la venta $Uuid"
}

# El webhook usa purchaseUUID1 (el formato largo con guiones). Se usa el
# mismo aqui para que, si el aviso llega tarde, no entre duplicada.
$uuidWebhook = if ($venta.purchaseUUID1) { $venta.purchaseUUID1 } else { $Uuid }
$monto = [decimal]$venta.amount / 100

Write-Host "`n  producto : $($venta.products[0].name)"
Write-Host "  monto    : `$$monto $($venta.currency)"
Write-Host "  hora     : $($venta.timestamp)"
Write-Host "  cajero   : $($venta.userDisplayName)`n"

# --- 2) Guardarla -----------------------------------------------------
$fila = @{
  purchase_uuid = $uuidWebhook
  monto         = $monto
  recibido_en   = $venta.timestamp
  payload       = $venta   # la venta completa como la dio Zettle
} | ConvertTo-Json -Depth 20 -Compress

$tmp = Join-Path $env:TEMP "rush-rescate-$([guid]::NewGuid()).json"
# WriteAllText y no Set-Content: "-Encoding utf8" de PowerShell 5.1 mete un
# BOM (bytes invisibles al inicio) y PostgREST lo lee como JSON corrupto.
[IO.File]::WriteAllText($tmp, $fila, (New-Object Text.UTF8Encoding($false)))

try {
  $k = $v['SUPABASE_SECRET_KEY']
  # ignore-duplicates: si ya estaba, no truena ni la duplica.
  curl.exe -s -m 30 -w "`nHTTP %{http_code}`n" -X POST `
    -H "apikey: $k" -H "Authorization: Bearer $k" `
    -H "Content-Type: application/json" `
    -H "Prefer: resolution=ignore-duplicates,return=representation" `
    --data-binary "@$tmp" `
    "$($v['SUPABASE_URL'])/rest/v1/ventas?select=id,purchase_uuid,monto,recibido_en"
}
finally {
  Remove-Item $tmp -ErrorAction SilentlyContinue
}
