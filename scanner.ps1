# Escáner de rupturas tempranas en futuros Bitunix. Solo datos públicos, no opera.
# Detecta la vela en la que el precio SALE de un rango con volumen (no la consolidación ni el movimiento ya hecho).
#   Local:  powershell -ExecutionPolicy Bypass -File scanner.ps1 -EverySeconds 120 -StateFile local-seen.json
#   Una pasada:  ... -Once
param(
    [string[]]$Interval = @("15m", "1h"),   # temporalidades de detección
    [int]$TopN = 100,               # nº de pares con más volumen 24h
    [double]$VolMult = 2.5,         # volumen de la vela >= X veces la media de las 20 anteriores
    [int]$Lookback = 20,            # velas del rango que se rompe
    [double]$MaxExt = 1.2,          # la ruptura no puede haberse alejado más de X ATR del rango (si no, ya es tarde)
    [double]$MaxAgeFactor = 1.5,    # solo avisa si la vela cerró hace <= X veces su duración
    [int]$EverySeconds = 120,
    [string]$TelegramToken = "",
    [string]$TelegramChatId = "",
    [string]$StateFile = "",        # evita repetir alertas entre ejecuciones
    [switch]$Once
)
$base = "https://fapi.bitunix.com/api/v1/futures/market"
$log = Join-Path $PSScriptRoot "alertas.log"
$seen = @{}
if (-not $TelegramToken -and $env:TELEGRAM_TOKEN) { $TelegramToken = $env:TELEGRAM_TOKEN; $TelegramChatId = $env:TELEGRAM_CHAT_ID }
$cfg = Join-Path $PSScriptRoot "telegram.json"
if (-not $TelegramToken -and (Test-Path $cfg)) {
    $c = Get-Content $cfg -Raw | ConvertFrom-Json
    $TelegramToken = $c.token; $TelegramChatId = $c.chatId
}
if ($StateFile -and (Test-Path $StateFile)) { foreach ($k in @(Get-Content $StateFile -Raw | ConvertFrom-Json)) { $seen[$k] = $true } }

function Get-Rsi($closes, $n = 14) {
    if ($closes.Count -le $n) { return $null }
    $g = 0.0; $l = 0.0
    for ($i = 1; $i -le $n; $i++) { $d = $closes[$i] - $closes[$i-1]; if ($d -gt 0) { $g += $d } else { $l -= $d } }
    $g /= $n; $l /= $n
    for ($i = $n + 1; $i -lt $closes.Count; $i++) {
        $d = $closes[$i] - $closes[$i-1]
        $g = ($g * ($n - 1) + [Math]::Max($d, 0)) / $n
        $l = ($l * ($n - 1) + [Math]::Max(-$d, 0)) / $n
    }
    if ($l -eq 0) { return 100 }
    return 100 - 100 / (1 + $g / $l)
}

function Get-Ema($vals, $n) {
    $k = 2.0 / ($n + 1); $e = $vals[0]
    for ($i = 1; $i -lt $vals.Count; $i++) { $e = $vals[$i] * $k + $e * (1 - $k) }
    return $e
}

function Get-Atr($c, $from, $to) {          # media del rango verdadero de c[from..to]
    $s = 0.0; $n = 0
    for ($i = $from; $i -le $to; $i++) {
        $h = [double]$c[$i].high; $l = [double]$c[$i].low; $pc = [double]$c[$i-1].close
        $s += [Math]::Max($h - $l, [Math]::Max([Math]::Abs($h - $pc), [Math]::Abs($l - $pc))); $n++
    }
    return $s / $n
}

function Get-Trend4h($symbol) {             # "alcista" / "bajista" según EMA21 en 4h
    try {
        $k = (Invoke-RestMethod "$base/kline?symbol=$symbol&interval=4h&limit=60").data | Sort-Object { [long]$_.time }
        $cl = @($k[0..($k.Count - 2)] | ForEach-Object { [double]$_.close })
        $ema = Get-Ema $cl 21; $emaPrev = Get-Ema $cl[0..($cl.Count - 4)] 21
        if ($cl[-1] -gt $ema -and $ema -ge $emaPrev) { return "alcista" }
        if ($cl[-1] -lt $ema -and $ema -le $emaPrev) { return "bajista" }
        return "lateral"
    } catch { return "?" }
}

function Send-Alert($key, $msg) {
    if ($seen[$key]) { return }
    $seen[$key] = $true
    if ($StateFile) { ($seen.Keys | Select-Object -Last 600) | ConvertTo-Json | Set-Content $StateFile -Encoding utf8 }
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line -ForegroundColor Yellow
    Add-Content -Path $log -Value $line
    try { [console]::Beep(1000, 300) } catch {}
    if ($TelegramToken -and $TelegramChatId) {
        try {
            $json = @{ chat_id = $TelegramChatId; text = $msg } | ConvertTo-Json -Compress
            Invoke-RestMethod "https://api.telegram.org/bot$TelegramToken/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
        } catch {}
    }
}

function Scan($iv) {
    $dur = switch ($iv) { '5m' {5} '15m' {15} '30m' {30} '1h' {60} '4h' {240} default {60} }
    $tk = (Invoke-RestMethod "$base/tickers").data |
        Where-Object { $_.symbol -like "*USDT" } |
        Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $TopN
    foreach ($t in $tk) {
        try {
            $k = (Invoke-RestMethod "$base/kline?symbol=$($t.symbol)&interval=$iv&limit=120").data | Sort-Object { [long]$_.time }
            if ($k.Count -lt 60) { continue }
            $closed = @($k[0..($k.Count - 2)])                 # la última vela viene en curso
            $n = $closed.Count
            $last = $closed[-1]
            # Bitunix etiqueta cada vela con un intervalo de adelanto: cierra en (etiqueta + 2 x duración)
            $ageMin = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - ([long]$last.time + 2 * $dur * 60000)) / 60000
            if ($ageMin -gt $MaxAgeFactor * $dur) { continue }

            $px = [double]$last.close; $op = [double]$last.open; $hi = [double]$last.high; $lo = [double]$last.low
            $rng = $hi - $lo; if ($rng -le 0) { continue }
            $prior = $closed[($n - 1 - $Lookback)..($n - 2)]
            $pHigh = ($prior | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum
            $pLow  = ($prior | ForEach-Object { [double]$_.low }  | Measure-Object -Minimum).Minimum
            $avgVol = ($prior | ForEach-Object { [double]$_.quoteVol } | Measure-Object -Average).Average
            if ($avgVol -le 0) { continue }
            $ratio = [double]$last.quoteVol / $avgVol
            if ($ratio -lt $VolMult) { continue }

            $atr = Get-Atr $closed ($n - 15) ($n - 2)          # ATR previo a la vela de ruptura
            if ($atr -le 0) { continue }
            $atr5 = Get-Atr $closed ($n - 6) ($n - 2)
            $squeeze = $atr5 -le 0.85 * $atr
            $rsi = Get-Rsi @($closed | ForEach-Object { [double]$_.close })
            $posInCandle = ($px - $lo) / $rng                  # 1 = cierra en máximos, 0 = en mínimos

            $side = $null
            if ($px -gt $pHigh -and $px -gt $op -and $posInCandle -ge 0.65 -and $rsi -lt 72 -and $rsi -gt 40) { $side = "LONG" }
            elseif ($px -lt $pLow -and $px -lt $op -and $posInCandle -le 0.35 -and $rsi -gt 28 -and $rsi -lt 60) { $side = "SHORT" }
            if (-not $side) { continue }

            $sgn = if ($side -eq "LONG") { 1 } else { -1 }
            $level = if ($side -eq "LONG") { $pHigh } else { $pLow }   # nivel roto
            $ext = $sgn * ($px - $level) / $atr                        # cuánto se ha alejado ya del nivel
            if ($ext -gt $MaxExt -or $rng -gt 2.5 * $atr) { continue }  # ya es tarde / vela agotadora

            # Stop: vuelve dentro del rango = ruptura fallida
            $sl = $level - $sgn * 0.5 * $atr
            $risk = $sgn * ($px - $sl)
            if ($risk -lt 0.8 * $atr) { $sl = $px - $sgn * 0.8 * $atr }
            if ($risk -gt 2.0 * $atr) { $sl = $px - $sgn * 2.0 * $atr }
            $R = $sgn * ($px - $sl)
            $tp1 = $px + $sgn * 1.5 * $R
            $tp2 = $px + $sgn * 3.0 * $R
            $slPct = $R / $px * 100
            $zA = $px - $sgn * [Math]::Min(0.5 * $atr, [Math]::Abs($px - $level))   # retroceso hasta el nivel roto
            $zLow = [Math]::Min($px, $zA); $zHigh = [Math]::Max($px, $zA)

            $trend = Get-Trend4h $t.symbol
            $ok = ($side -eq "LONG" -and $trend -eq "alcista") -or ($side -eq "SHORT" -and $trend -eq "bajista")
            $trendTxt = if ($ok) { "Tendencia 4h: $trend (a favor) ✅" } elseif ($trend -eq "lateral" -or $trend -eq "?") { "Tendencia 4h: $trend" } else { "Tendencia 4h: $trend (en contra, más riesgo) ⚠️" }
            $name = $t.symbol -replace 'USDT$', ''
            $icon = if ($side -eq "LONG") { "🟢" } else { "🔴" }
            $what = if ($side -eq "LONG") { "máximo" } else { "mínimo" }
            $sq = if ($squeeze) { " tras compresión" } else { "" }
            $msg = "{0} {1} {2} ({3}) - ruptura temprana`nRompe el {4} de {5} velas con volumen x{6:N1}{7}`nEntrada aprox: {8:G6} - {9:G6}`nStop (SL): {10:G6} (-{11:N1}%)`nObjetivo 1 (TP1): {12:G6}`nObjetivo 2 (TP2): {13:G6}`n{14}" -f $icon, $side, $name, $iv, $what, $Lookback, $ratio, $sq, $zLow, $zHigh, $sl, $slPct, $tp1, $tp2, $trendTxt
            Send-Alert "$($t.symbol)-$iv-$($last.time)" $msg
        } catch { }
        Start-Sleep -Milliseconds 100
    }
}

Write-Host "Buscando rupturas tempranas en top $TopN pares Bitunix ($($Interval -join ', ')) cada $EverySeconds s. Ctrl+C para parar." -ForegroundColor Cyan
do {
    foreach ($iv in $Interval) { Scan $iv }
    Write-Host ("{0} pasada completada" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor DarkGray
    if (-not $Once) { Start-Sleep -Seconds $EverySeconds }
} while (-not $Once)
