# =====================================================================
# Backfill de TODAS las compras de Zettle a public.zettle_compras, para
# consultar el detalle de cualquier ticket al instante (sin ir a la API).
# Guarda el payload YA estructurado (productos/descuentos/pago).
#
#   .\pull-zettle-compras.ps1
#
# Idempotente: Prefer resolution=ignore-duplicates (por purchase_number).
# Read-only sobre Zettle; solo escribe en zettle_compras.
# Requiere en .env: ZETTLE_*, SUPABASE_URL, SUPABASE_SECRET_KEY.
# =====================================================================
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot | Split-Path -Parent
$v = @{}
Get-Content (Join-Path $root ".env") | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object { $p=$_ -split '=',2; $v[$p[0].Trim()]=$p[1].Trim() }
$supaUrl = $v['SUPABASE_URL']; $key = $v['SUPABASE_SECRET_KEY']
$token = & (Join-Path $PSScriptRoot "..\2-token-zettle.ps1") -Mostrar

function PostBatch($rows) {
  if ($rows.Count -eq 0) { return }
  # ConvertTo-Json de PS 5.1 falla con el objeto crudo de la API; por eso se
  # arman hashtables limpias (primitivos) antes de serializar.
  $json = ConvertTo-Json -InputObject $rows -Depth 12 -Compress
  $tmp = "$env:TEMP\rush_zc.json"; [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
  & curl.exe -s -o NUL -X POST "$supaUrl/rest/v1/zettle_compras" -H "apikey: $key" -H "Authorization: Bearer $key" -H "Content-Type: application/json" -H "Prefer: resolution=ignore-duplicates" --data-binary "@$tmp"
}

$batch = New-Object System.Collections.ArrayList
$hash = $null; $pag = 0; $total = 0
do {
  $url = "https://purchase.izettle.com/purchases/v2?limit=1000"; if ($hash) { $url += "&lastPurchaseHash=$hash" }
  $j = (& curl.exe -s -m 60 -H "Authorization: Bearer $token" $url) | ConvertFrom-Json
  $n = $j.purchases.Count
  foreach ($p in $j.purchases) {
    $prods = @(); foreach ($pr in $p.products) { $prods += @{ nombre="$($pr.name)"; variante="$($pr.variantName)"; cantidad="$($pr.quantity)"; precio=[double]($pr.unitPrice/100) } }
    $descs = @(); foreach ($d in $p.discounts) { $descs += @{ nombre="$($d.name)"; monto=[double]($d.amount/100) } }
    $pago = (@($p.payments | ForEach-Object { "$($_.type)" }) -join ", ")
    [void]$batch.Add(@{
      purchase_number = [int]$p.purchaseNumber; purchase_uuid = "$($p.purchaseUUID)"
      monto = [double]($p.amount/100); cajero = "$($p.userDisplayName)"; hora = "$($p.timestamp)"
      payload = @{ productos = $prods; descuentos = $descs; pago = $pago }
    })
    if ($batch.Count -ge 500) { PostBatch $batch; $total += $batch.Count; $batch.Clear() }
  }
  $pag++; $hash = $j.lastPurchaseHash
} while ($n -eq 1000 -and $pag -lt 60)
if ($batch.Count -gt 0) { PostBatch $batch; $total += $batch.Count }
Write-Host "compras cargadas a zettle_compras: $total"
