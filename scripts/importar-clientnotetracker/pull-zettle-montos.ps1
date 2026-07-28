# =====================================================================
# Jala TODAS las compras de Zettle (paginado) -> TSV con la bandera "Gratis".
#   Salida (TAB):  purchaseNumber  amount_centavos  YYYY-MM-DD  gz(0/1)
#   gz = 1 si algun producto de la venta se llama "gratis" (regex (?i)gratis).
#
#   .\pull-zettle-montos.ps1 -Salida "C:\ruta\zettle_gratis.tsv"
#
# Reusa scripts\2-token-zettle.ps1 para el token (dura 2 h). Read-only.
# =====================================================================
param([Parameter(Mandatory=$true)][string]$Salida)
$ErrorActionPreference = "Stop"

$token = & (Join-Path $PSScriptRoot "..\2-token-zettle.ps1") -Mostrar
if ([string]::IsNullOrWhiteSpace($token)) { throw "No se obtuvo token de Zettle." }

$sb = New-Object System.Text.StringBuilder
$hash = $null; $total = 0; $pag = 0; $gcount = 0
do {
  $url = "https://purchase.izettle.com/purchases/v2?limit=1000"
  if ($hash) { $url += "&lastPurchaseHash=$hash" }
  $j = (& curl.exe -s -m 60 -H "Authorization: Bearer $token" $url) | ConvertFrom-Json
  $n = $j.purchases.Count
  foreach ($p in $j.purchases) {
    $g = 0
    foreach ($pr in $p.products) { if ($pr.name -match '(?i)gratis') { $g = 1; break } }
    if ($g) { $gcount++ }
    [void]$sb.AppendLine(("{0}`t{1}`t{2}`t{3}" -f $p.purchaseNumber, $p.amount, $p.timestamp.Substring(0,10), $g))
  }
  $total += $n; $pag++; $hash = $j.lastPurchaseHash
} while ($n -eq 1000 -and $pag -lt 60)

[IO.File]::WriteAllText($Salida, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
Write-Host "compras: $total   con producto 'Gratis': $gcount   -> $Salida"
