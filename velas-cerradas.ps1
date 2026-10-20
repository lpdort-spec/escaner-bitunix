# CORRECCIÓN DE UNA VELA DE RETRASO (20/10/2026). La API de velas de Bitunix SOLO devuelve velas CERRADAS (comprobado: a las 20:12Z la última de 1h es la de las 19:00 y la de 4h la de las 16:00; la vela en curso no viene).
# Todo el código del bot asume lo contrario ("la última vela viene en curso" -> la descarta con [0..Count-2]), así que evaluaba SIEMPRE la penúltima vela cerrada: señales con 1 vela de retraso (1h en Arranque, 4h, 1d), entradas calculadas
# con la apertura de una vela ya cerrada (hasta un 2,8% por encima del precio real en CL del 17/10) y órdenes limit "llenadas" por velas anteriores al envío (Q, ARIA, JCT, PEPE: resultados que nadie podía cobrar).
# Arreglo central: este fichero sustituye Invoke-RestMethod para las peticiones /kline (sin endTime/startTime) y añade una vela "en curso" SINTÉTICA (apertura = último cierre, sin volumen) cuando la última devuelta ya está cerrada.
# Así todo el código existente (que descarta la última) pasa a evaluar la última vela cerrada real y a usar como entrada el precio actual. No cambia las demás peticiones (Telegram, tickers, etc.). Conserva el orden devuelto por la API.
$script:FormingDur = @{ '1m' = 60000; '3m' = 180000; '5m' = 300000; '15m' = 900000; '30m' = 1800000; '1h' = 3600000; '2h' = 7200000; '4h' = 14400000; '6h' = 21600000; '8h' = 28800000; '12h' = 43200000; '1d' = 86400000 }
function Add-FormingKline($resp, [string]$uri) {
    $m = [regex]::Match($uri, 'interval=([0-9]+[mhd])'); if (-not $m.Success) { return $resp }; $dur = $script:FormingDur[$m.Groups[1].Value]; if (-not $dur) { return $resp }
    $d = @($resp.data); if ($d.Count -eq 0) { return $resp }
    $newest = $d[0]; foreach ($x in $d) { if ([long]$x.time -gt [long]$newest.time) { $newest = $x } }
    if (([long]$newest.time + $dur) -gt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { return $resp }      # la API sí devolvió la vela en curso: no se toca
    $syn = [pscustomobject]@{ time = [string]([long]$newest.time + $dur); open = $newest.close; high = $newest.close; low = $newest.close; close = $newest.close; baseVol = '0'; quoteVol = '0'; volume = '0' }
    $desc = ([long]$d[0].time -gt [long]$d[$d.Count - 1].time)
    $resp.data = $(if ($desc) { @($syn) + $d } else { $d + @($syn) })
    return $resp
}
function Invoke-RestMethod {      # envoltorio: reenvía TODOS los argumentos al cmdlet original y solo retoca las respuestas de /kline
    $uri = $null
    for ($i = 0; $i -lt $args.Count; $i++) { if ("$($args[$i])" -eq '-Uri' -and $i + 1 -lt $args.Count) { $uri = "$($args[$i + 1])"; break } }
    if (-not $uri -and $args.Count -gt 0 -and "$($args[0])" -notmatch '^-') { $uri = "$($args[0])" }
    $r = Microsoft.PowerShell.Utility\Invoke-RestMethod @args
    if ($uri -and $uri -match 'futures/market/kline\?' -and $uri -notmatch 'endTime=|startTime=') { try { $r = Add-FormingKline $r $uri } catch {} }
    return $r
}
