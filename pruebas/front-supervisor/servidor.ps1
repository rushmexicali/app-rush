# Servidor estatico minimo para probar el front en un navegador de verdad.
# Solo ASCII: PowerShell 5.1 lee estos archivos como ANSI.
param([string]$Raiz, [int]$Puerto = 8777)

$oyente = New-Object System.Net.HttpListener
$oyente.Prefixes.Add("http://localhost:$Puerto/")
$oyente.Start()
Write-Output "ARRIBA http://localhost:$Puerto/"

$tipos = @{ ".html" = "text/html; charset=utf-8"; ".js" = "text/javascript; charset=utf-8";
            ".json" = "application/json"; ".png" = "image/png"; ".webmanifest" = "application/manifest+json" }

while ($oyente.IsListening) {
  $ctx = $oyente.GetContext()
  $ruta = $ctx.Request.Url.LocalPath
  if ($ruta -eq "/") { $ruta = "/index.html" }
  $archivo = Join-Path $Raiz ($ruta.TrimStart("/"))
  if (Test-Path -LiteralPath $archivo -PathType Leaf) {
    $bytes = [System.IO.File]::ReadAllBytes($archivo)
    $ext = [System.IO.Path]::GetExtension($archivo)
    if ($tipos.ContainsKey($ext)) { $ctx.Response.ContentType = $tipos[$ext] }
    $ctx.Response.StatusCode = 200
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  } else {
    $ctx.Response.StatusCode = 404
  }
  $ctx.Response.Close()
}
