# Escáner de futuros Bitunix: rupturas con retesteo y barridos de liquidez de ALTO POTENCIAL. Solo datos públicos, no opera.
#   Local:  powershell -ExecutionPolicy Bypass -File scanner.ps1 -EverySeconds 120 -StateFile local-seen.json
#   Una pasada:  ... -Once
param(
    [string[]]$Interval = @("1h", "4h"),
    [int]$TopN = 100,
    [double]$VolMult = 2.0,         # volumen de la vela >= X veces la media de las 20 anteriores
    [int]$Lookback = 20,            # velas del rango cuya liquidez se rompe o barre
    [double]$MaxExt = 1.2,          # ruptura: máximo alejamiento del nivel en ATR (si no, ya es tarde)
    [double]$MaxAgeFactor = 1.5,    # solo avisa si la vela cerró hace <= X veces su duración
    [string[]]$Strategies = @("ruptura"),
    [double]$MinSlPct = 1.0,        # SL mínimo en % del precio (las comisiones se comen los SL pequeños)
    [double]$MinRoiTp2 = 25,        # ganancia mínima en TP2 sobre el margen (%) con el apalancamiento recomendado
    [double]$MaxFeeShare = 20,      # descarta si las comisiones superan este % de la ganancia en TP1
    [double]$FeeRT = 0.10,          # comisiones + deslizamiento de ida y vuelta (% del nominal, órdenes limit)
    [int]$EverySeconds = 120,
    [string]$TelegramToken = "",
    [string]$TelegramChatId = "",
    [double]$MaxMargin = 200,       # margen máximo por operación (USDT)
    [double]$MaxLossPct = 35,       # el SL nunca debe perder más de este % del margen
    [string]$StateFile = "",
    [int]$MaxMinutes = 0,           # 0 = sin límite; en la nube se limita a ~5h45 y el siguiente turno continúa
    [switch]$NoChart,
    [switch]$Once
)
try { [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo("es-ES") } catch {}   # formato español también en la nube (2.664,24)
$base = "https://fapi.bitunix.com/api/v1/futures/market"
$log = Join-Path $PSScriptRoot "alertas.log"
$seen = @{}
if (-not $TelegramToken -and $env:TELEGRAM_TOKEN) { $TelegramToken = $env:TELEGRAM_TOKEN; $TelegramChatId = $env:TELEGRAM_CHAT_ID }
$cfg = Join-Path $PSScriptRoot "telegram.json"
if (-not $TelegramToken -and (Test-Path $cfg)) { $c = Get-Content $cfg -Raw | ConvertFrom-Json; $TelegramToken = $c.token; $TelegramChatId = $c.chatId }
if ($StateFile -and (Test-Path $StateFile)) { foreach ($k in @(Get-Content $StateFile -Raw | ConvertFrom-Json)) { $seen[$k] = $true } }
. (Join-Path $PSScriptRoot "tracker.ps1")
if (Test-Path (Join-Path $PSScriptRoot "tracker-extra.ps1")) { . (Join-Path $PSScriptRoot "tracker-extra.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "informe-semanal.ps1")) { . (Join-Path $PSScriptRoot "informe-semanal.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "analisis-tecnico.ps1")) { . (Join-Path $PSScriptRoot "analisis-tecnico.ps1") }
$hasCmds = $false
if (Test-Path (Join-Path $PSScriptRoot "commands.ps1")) { . (Join-Path $PSScriptRoot "commands.ps1"); $hasCmds = $true }
if (Test-Path (Join-Path $PSScriptRoot "scanner-mercado.ps1")) { . (Join-Path $PSScriptRoot "scanner-mercado.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "vigilancia.ps1")) { . (Join-Path $PSScriptRoot "vigilancia.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "avisos-momento.ps1")) { . (Join-Path $PSScriptRoot "avisos-momento.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "seguimiento-grupo.ps1")) { . (Join-Path $PSScriptRoot "seguimiento-grupo.ps1") }
$TelegramSignalChatId = $env:TELEGRAM_SIGNAL_CHAT_ID
if (-not $TelegramSignalChatId -and (Test-Path $cfg)) { try { $TelegramSignalChatId = (Get-Content $cfg -Raw | ConvertFrom-Json).signalChatId } catch {} }
# destinos de las señales: el secreto del chat privado; si no está configurado, SOLO chats privados (id positivo), nunca grupos (id negativo)
$sigChats = @($(if ($TelegramSignalChatId) { $TelegramSignalChatId } else { $TelegramChatId }) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $TelegramSignalChatId) { $priv = @($sigChats | Where-Object { $_ -notmatch '^-' }); if ($priv.Count) { $sigChats = $priv } }
$allowedChats = @(($TelegramChatId + "," + $TelegramSignalChatId) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)   # chats que pueden dar órdenes al bot
# grupo "Alertas Mercados" (acciones, ETFs y cripto en formato genérico): su id no es secreto y vive en chats.json; ahí el bot atiende comandos y publica las señales de mercado
$script:MktChat = $null; $chatsFile = Join-Path $PSScriptRoot "chats.json"
if (Test-Path $chatsFile) { try { $script:MktChat = "$((Get-Content $chatsFile -Raw -Encoding UTF8 | ConvertFrom-Json).mercado)".Trim() } catch {} }
if ($script:MktChat) { $allowedChats = @($allowedChats + $script:MktChat | Select-Object -Unique) }
$offsetFile = Join-Path $PSScriptRoot "bot-offset.txt"
$script:cmdTick = 0
$script:PrivateChats = $sigChats     # comandos reservados (resultados, semanal, operación...) solo en el chat privado de señales
function Poll-Commands { if ($hasCmds -and $TelegramToken -and $allowedChats.Count) { try { Handle-Commands $TelegramToken $allowedChats $offsetFile } catch {} } }
$hasChart = $false
if (-not $NoChart -and (Test-Path (Join-Path $PSScriptRoot "chart.ps1")) -and $PSVersionTable.PSEdition -ne 'Core') { . (Join-Path $PSScriptRoot "chart.ps1"); $hasChart = $true }
$trendCache = @{}; $drCache = @{}; $fundCache = $null; $fundAt = [datetime]::MinValue
$W1 = $script:W1; $W2 = $script:W2; $W3 = $script:W3

function Get-Rsi($closes, $n = 14) {
    if ($closes.Count -le $n) { return $null }
    $g = 0.0; $l = 0.0
    for ($i = 1; $i -le $n; $i++) { $d = $closes[$i] - $closes[$i-1]; if ($d -gt 0) { $g += $d } else { $l -= $d } }
    $g /= $n; $l /= $n
    for ($i = $n + 1; $i -lt $closes.Count; $i++) {
        $d = $closes[$i] - $closes[$i-1]
        $g = ($g * ($n - 1) + [Math]::Max($d, 0)) / $n; $l = ($l * ($n - 1) + [Math]::Max(-$d, 0)) / $n
    }
    if ($l -eq 0) { return 100 }
    return 100 - 100 / (1 + $g / $l)
}
function Get-Ema($vals, $n) { $k = 2.0 / ($n + 1); $e = $vals[0]; for ($i = 1; $i -lt $vals.Count; $i++) { $e = $vals[$i] * $k + $e * (1 - $k) }; return $e }
function Get-Atr($c, $from, $to) {
    $s = 0.0; $n = 0
    for ($i = $from; $i -le $to; $i++) {
        $h = [double]$c[$i].high; $l = [double]$c[$i].low; $pc = [double]$c[$i-1].close
        $s += [Math]::Max($h - $l, [Math]::Max([Math]::Abs($h - $pc), [Math]::Abs($l - $pc))); $n++
    }
    return $s / $n
}
function Get-TrendHtf($symbol, $iv) {            # tendencia en la temporalidad superior (1h -> 4h, 4h -> 1d)
    $htf = if ($iv -eq "4h") { "1d" } else { "4h" }
    $key = "$symbol-$htf"
    if ($trendCache[$key] -and ((Get-Date) - $trendCache[$key].at).TotalMinutes -lt 20) { return $trendCache[$key].v }
    $v = "?"
    try {
        $k = (Invoke-RestMethod "$base/kline?symbol=$symbol&interval=$htf&limit=60").data | Sort-Object { [long]$_.time }
        $cl = @($k[0..($k.Count - 2)] | ForEach-Object { [double]$_.close })
        $ema = Get-Ema $cl 21; $emaPrev = Get-Ema $cl[0..($cl.Count - 4)] 21
        $v = if ($cl[-1] -gt $ema -and $ema -ge $emaPrev) { "alcista" } elseif ($cl[-1] -lt $ema -and $ema -le $emaPrev) { "bajista" } else { "lateral" }
    } catch {}
    $trendCache[$key] = @{ v = $v; at = Get-Date }
    return $v
}
function Get-DailyRangePct($symbol) {
    if ($drCache[$symbol]) { return $drCache[$symbol] }
    try {
        $k = (Invoke-RestMethod "$base/kline?symbol=$symbol&interval=1d&limit=20").data | Sort-Object { [long]$_.time }
        $d = @($k[0..($k.Count - 2)]) | Select-Object -Last 14
        $r = ($d | ForEach-Object { ([double]$_.high - [double]$_.low) / [double]$_.close * 100 } | Measure-Object -Average).Average
        $drCache[$symbol] = $r; return $r
    } catch { return $null }
}
function Get-Funding($symbol) {                    # % por periodo de 8h (positivo = los largos pagan)
    if (-not $script:fundCache -or ((Get-Date) - $script:fundAt).TotalMinutes -gt 15) {
        try { $script:fundCache = @{}; foreach ($f in (Invoke-RestMethod "$base/funding_rate/batch").data) { $script:fundCache[$f.symbol] = [double]$f.fundingRate }; $script:fundAt = Get-Date } catch {}
    }
    return $script:fundCache[$symbol]
}
function Get-BookBias($symbol) {                   # % de liquidez compradora en los 50 primeros niveles del libro
    try {
        $d = (Invoke-RestMethod "$base/depth?symbol=$symbol&limit=50").data
        $b = ($d.bids | ForEach-Object { [double]$_[0] * [double]$_[1] } | Measure-Object -Sum).Sum
        $a = ($d.asks | ForEach-Object { [double]$_[0] * [double]$_[1] } | Measure-Object -Sum).Sum
        if (($a + $b) -gt 0) { return 100 * $b / ($a + $b) }
    } catch {}
    return $null
}

$script:sentCache = $null
function Get-SentimentLine($side) {                 # índice Crypto Fear & Greed (Alternative.me), caché 30 min. Solo informativo.
    if (-not $script:sentCache -or ((Get-Date) - $script:sentCache.at).TotalMinutes -gt 30) {
        $script:sentCache = @{ at = Get-Date; v = $null; y = $null }
        try { $d = (Invoke-RestMethod "https://api.alternative.me/fng/?limit=2" -TimeoutSec 15).data; $script:sentCache.v = [double]$d[0].value; $script:sentCache.y = [double]$d[1].value } catch {}
    }
    $v = $script:sentCache.v; if ($null -eq $v) { return $null }
    $lab = if ($v -ge 75) { "FOMO extremo" } elseif ($v -ge 56) { "FOMO (codicia)" } elseif ($v -ge 45) { "neutral" } elseif ($v -ge 25) { "FUD (miedo)" } else { "FUD extremo" }
    $warn = if ($v -ge 75 -and $side -eq "LONG") { " ⚠️ largos tardíos vulnerables" } elseif ($v -le 25 -and $side -eq "SHORT") { " ⚠️ pánico: riesgo de rebote" } else { "" }
    return ("Sentimiento mercado: {0:N0}/100 · {1} (ayer {2:N0}){3}" -f $v, $lab, $script:sentCache.y, $warn)
}
function Get-KeyLevels($symbol, $price) {          # soportes/resistencias (pivotes) por temporalidad + liquidez (máximos/mínimos iguales y muros del libro). Solo informativo.
    $out = @(); $hi = @(); $lo = @()
    foreach ($tf in @("1h", "4h", "1d")) {
        try {
            $k = @((Invoke-RestMethod "$base/kline?symbol=$symbol&interval=$tf&limit=200").data | Sort-Object { [long]$_.time })
            $k = @($k[0..($k.Count - 2)]); $n = $k.Count; $res = @(); $sup = @()
            for ($i = 3; $i -lt $n - 3; $i++) {
                $h = [double]$k[$i].high; $l = [double]$k[$i].low; $isH = $true; $isL = $true
                foreach ($j in ($i - 3)..($i + 3)) { if ($j -eq $i) { continue }; if ([double]$k[$j].high -ge $h) { $isH = $false }; if ([double]$k[$j].low -le $l) { $isL = $false } }
                if ($isH) { $res += $h; $hi += $h }; if ($isL) { $sup += $l; $lo += $l }
            }
            $r = $res | Where-Object { $_ -gt $price } | Sort-Object | Select-Object -First 1
            $s = $sup | Where-Object { $_ -lt $price } | Sort-Object -Descending | Select-Object -First 1
            $txt = @(); if ($s) { $txt += ("soporte {0}" -f (Fmt $s)) }; if ($r) { $txt += ("resistencia {0}" -f (Fmt $r)) }
            if ($txt.Count) { $out += ("Clave {0}: {1}" -f $tf, ($txt -join " · ")) }
        } catch {}
    }
    # liquidez: grupos de >=2 máximos (o mínimos) con diferencia <0,3% => stops acumulados encima/debajo
    $pool = {
        param($vals, $above)
        $c = @($vals | Where-Object { if ($above) { $_ -gt $price } else { $_ -lt $price } } | Sort-Object); $best = $null
        foreach ($v in $c) { $g = @($c | Where-Object { [Math]::Abs($_ / $v - 1) -lt 0.003 }); if ($g.Count -ge 2 -and ($null -eq $best -or [Math]::Abs($v - $price) -lt [Math]::Abs($best.p - $price))) { $best = @{ p = ($g | Measure-Object -Average).Average; n = $g.Count } } }
        return $best
    }
    $up = & $pool $hi $true; $dn = & $pool $lo $false
    $lq = @(); if ($up) { $lq += ("máximos iguales ~{0} ({1} toques, stops de cortos encima)" -f (Fmt $up.p), $up.n) }; if ($dn) { $lq += ("mínimos iguales ~{0} ({1} toques, stops de largos debajo)" -f (Fmt $dn.p), $dn.n) }
    if ($lq.Count) { $out += ("Liquidez: " + ($lq -join " · ")) }
    return $out
}
function Get-LeveragePlan($vol24h, $dailyRange, $slPct) {
    $lSl = [Math]::Floor(($MaxLossPct / 100) / ($slPct / 100))
    $lLiq = if ($vol24h -ge 500e6) { 25 } elseif ($vol24h -ge 100e6) { 20 } elseif ($vol24h -ge 20e6) { 12 } elseif ($vol24h -ge 5e6) { 8 } elseif ($vol24h -ge 1e6) { 5 } else { 3 }
    $lVol = if ($dailyRange -and $dailyRange -gt 0) { [Math]::Floor(30 / $dailyRange) } else { 5 }
    $lev = [Math]::Max(1, [Math]::Min(50, [Math]::Min($lSl, [Math]::Min($lLiq, $lVol))))
    $why = if ($lev -eq $lSl) { "tope por tu regla del SL" } elseif ($lev -eq $lLiq) { "tope por liquidez" } else { "tope por volatilidad diaria" }
    $score = 0
    if ($vol24h -lt 1e6) { $score += 3 } elseif ($vol24h -lt 5e6) { $score += 2 } elseif ($vol24h -lt 20e6) { $score += 1 }
    if ($dailyRange -ge 12) { $score += 3 } elseif ($dailyRange -ge 7) { $score += 2 } elseif ($dailyRange -ge 4) { $score += 1 }
    $risk = if ($score -ge 5) { "MUY ALTO" } elseif ($score -ge 3) { "ALTO" } elseif ($score -ge 1) { "MEDIO" } else { "BAJO" }
    return @{ Lev = [int]$lev; LSl = [int]$lSl; Why = $why; Risk = $risk }
}

function Send-Alert($key, $msg, $photo = $null) {
    if ($seen[$key]) { return $false }
    $seen[$key] = $true
    if ($StateFile) { ($seen.Keys | Select-Object -Last 800) | ConvertTo-Json | Set-Content $StateFile -Encoding utf8 }
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg
    Write-Host $line -ForegroundColor Yellow
    Add-Content -Path $log -Value $line
    try { [console]::Beep(1000, 300) } catch {}
    if ($TelegramToken -and $TelegramChatId) {
        foreach ($cid in $sigChats) {          # destinos de las señales: solo el grupo privado de futuros (o todos si no se ha configurado)
            $cid = $cid.Trim(); if (-not $cid) { continue }
            if ($photo -and $hasChart) { try { [void](Send-TelegramPhoto $TelegramToken $cid $photo (($msg -split "`n")[0])) } catch {} }      # el gráfico va primero con el título; el detalle completo va en el mensaje
            $sent = $false
            if (-not $sent) {
                try {
                    $txt = if ($msg.Length -gt 3900) { $msg.Substring(0, 3890) + "…" } else { $msg }
                    $json = @{ chat_id = $cid; text = $txt } | ConvertTo-Json -Compress
                    Invoke-RestMethod "https://api.telegram.org/bot$TelegramToken/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
                } catch {}
            }
        }
    }
    return $true
}

function Fmt($x) { if ($x -ge 100) { return ("{0:N2}" -f $x) } elseif ($x -ge 1) { return ("{0:N4}" -f $x) } else { return ("{0:G5}" -f $x) } }

function Scan($iv) {
    $dur = $script:DurMin[$iv]; if (-not $dur) { $dur = 60 }
    $rej = @{ sl = 0; roi = 0; fee = 0; trend = 0; tarde = 0 }
    $tk = (Invoke-RestMethod "$base/tickers").data | Where-Object { $_.symbol -like "*USDT" } |
        Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $TopN
    foreach ($t in $tk) {
        if (($script:cmdTick++ % 10) -eq 0) { Poll-Commands }                 # atiende los comandos de Telegram mientras escanea
        try {
            $k = (Invoke-RestMethod "$base/kline?symbol=$($t.symbol)&interval=$iv&limit=120").data | Sort-Object { [long]$_.time }
            if ($k.Count -lt 60) { continue }
            $closed = @($k[0..($k.Count - 2)])                       # la última vela viene en curso
            $n = $closed.Count; $last = $closed[-1]
            $ageMin = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - ([long]$last.time + 2 * $dur * 60000)) / 60000   # Bitunix etiqueta con 1 intervalo de adelanto
            if ($ageMin -gt $MaxAgeFactor * $dur) { continue }
            $key = "$($t.symbol)-$iv-$($last.time)"
            if ($seen[$key]) { continue }

            $px = [double]$last.close; $op = [double]$last.open; $hi = [double]$last.high; $lo = [double]$last.low
            $rng = $hi - $lo; if ($rng -le 0) { continue }
            $prior = $closed[($n - 1 - $Lookback)..($n - 2)]
            $pHigh = ($prior | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum
            $pLow  = ($prior | ForEach-Object { [double]$_.low }  | Measure-Object -Minimum).Minimum
            $avgVol = ($prior | ForEach-Object { [double]$_.quoteVol } | Measure-Object -Average).Average
            if ($avgVol -le 0) { continue }
            $ratio = [double]$last.quoteVol / $avgVol
            if ($ratio -lt $VolMult) { continue }
            $atr = Get-Atr $closed ($n - 15) ($n - 2); if ($atr -le 0) { continue }
            $squeeze = (Get-Atr $closed ($n - 6) ($n - 2)) -le 0.85 * $atr
            $rsi = Get-Rsi @($closed | ForEach-Object { [double]$_.close })
            $pos = ($px - $lo) / $rng

            $side = $null; $strat = ""; $level = 0.0; $sl = 0.0; $why = ""; $pool = ""
            # --- Barrido de liquidez: mecha fuera del rango, cierre dentro, con volumen (spring / upthrust) ---
            if ("barrido" -in $Strategies) {
                if ($hi -gt $pHigh -and $px -lt $pHigh -and ($hi - [Math]::Max($op, $px)) / $rng -ge 0.5) {
                    $side = "SHORT"; $strat = "barrido"; $level = $pHigh; $sl = $hi + 0.2 * $atr
                    $eq = @($prior | Where-Object { [double]$_.high -ge $pHigh - 0.25 * $atr }).Count
                    $pool = if ($eq -ge 2) { "máximos iguales ($eq)" } else { "máximo del rango" }
                    $why = "barre la liquidez sobre {0} velas y vuelve a entrar al rango con volumen x{1:N1}" -f $Lookback, $ratio
                } elseif ($lo -lt $pLow -and $px -gt $pLow -and ([Math]::Min($op, $px) - $lo) / $rng -ge 0.5) {
                    $side = "LONG"; $strat = "barrido"; $level = $pLow; $sl = $lo - 0.2 * $atr
                    $eq = @($prior | Where-Object { [double]$_.low -le $pLow + 0.25 * $atr }).Count
                    $pool = if ($eq -ge 2) { "mínimos iguales ($eq)" } else { "mínimo del rango" }
                    $why = "barre la liquidez bajo {0} velas y vuelve a entrar al rango con volumen x{1:N1}" -f $Lookback, $ratio
                }
                if ($side) { $rk = [Math]::Abs($px - $sl); if ($rk -lt 0.5 * $atr -or $rk -gt 2.5 * $atr) { $side = $null } }
            }
            # --- Ruptura: cierra fuera del rango con volumen y sin haberse alejado ya; se entra en el RETESTEO del nivel roto ---
            if (-not $side -and "ruptura" -in $Strategies) {
                if ($px -gt $pHigh -and $px -gt $op -and $pos -ge 0.65 -and $rsi -lt 72 -and $rsi -gt 40) { $side = "LONG"; $level = $pHigh }
                elseif ($px -lt $pLow -and $px -lt $op -and $pos -le 0.35 -and $rsi -gt 28 -and $rsi -lt 60) { $side = "SHORT"; $level = $pLow }
                if ($side) {
                    $sg = if ($side -eq "LONG") { 1 } else { -1 }
                    $ext = $sg * ($px - $level) / $atr
                    if ($ext -gt $MaxExt -or $rng -gt 2.5 * $atr) { $side = $null; $rej.tarde++ }
                    else {
                        $strat = "ruptura"; $sl = $level - $sg * 0.5 * $atr
                        $rk = $sg * ($px - $sl); if ($rk -lt 0.8 * $atr) { $sl = $px - $sg * 0.8 * $atr }; if ($rk -gt 2.0 * $atr) { $sl = $px - $sg * 2.0 * $atr }
                        $why = "rompe el {0} de {1} velas con volumen x{2:N1} y se entra en el retesteo del nivel" -f $(if ($side -eq "LONG") { "máximo" } else { "mínimo" }), $Lookback, $ratio
                        $pool = if ($squeeze) { "tras compresión" } else { "" }
                    }
                }
            }
            if (-not $side) { continue }

            $sgn = if ($side -eq "LONG") { 1 } else { -1 }
            # --- Entrada: orden limit en el nivel roto (retesteo) ---
            $dist = if ($strat -eq "barrido") { [Math]::Min(0.5 * $atr, 0.5 * [Math]::Abs($px - $level)) } else { [Math]::Min(1.0 * $atr, [Math]::Abs($px - $level)) }
            $entryType = "mercado"; $entry = $px
            if ($dist -gt 0.05 * $atr) { $entryType = "limit"; $entry = $px - $sgn * $dist }
            $risk = $sgn * ($entry - $sl); if ($risk -le 0) { continue }
            $slPct = $risk / $entry * 100
            if ($slPct -gt 12) { continue }
            if ($slPct -lt $MinSlPct) { $rej.sl++; continue }               # comisiones demasiado grandes frente al recorrido
            $tp1 = $entry + $sgn * 1.0 * $risk; $tp2 = $entry + $sgn * 2.0 * $risk; $tp3 = $entry + $sgn * 3.0 * $risk
            $tpPct = [Math]::Abs($tp3 - $entry) / $entry * 100

            # --- Contexto de ballenas / mercado ---
            $trend = Get-TrendHtf $t.symbol $iv
            $aligned = ($side -eq "LONG" -and $trend -eq "alcista") -or ($side -eq "SHORT" -and $trend -eq "bajista")
            $counter = ($side -eq "LONG" -and $trend -eq "bajista") -or ($side -eq "SHORT" -and $trend -eq "alcista")
            # filtro validado en backtest: LONG sin tendencia en contra, SHORT solo a favor de la tendencia superior
            if (($side -eq "LONG" -and $counter) -or ($side -eq "SHORT" -and -not $aligned)) { $rej.trend++; continue }
            $htfName = if ($iv -eq "4h") { "diaria" } else { "4h" }
            $btcT = if ($t.symbol -eq "BTCUSDT") { $trend } else { Get-TrendHtf "BTCUSDT" $iv }
            $btcAl = if ($btcT -eq "alcista" -and $side -eq "LONG" -or $btcT -eq "bajista" -and $side -eq "SHORT") { $true } elseif ($btcT -eq "alcista" -and $side -eq "SHORT" -or $btcT -eq "bajista" -and $side -eq "LONG") { $false } else { $null }

            # --- Apalancamiento, potencial y comisiones ---
            $dr = Get-DailyRangePct $t.symbol
            $plan = Get-LeveragePlan ([double]$t.quoteVol) $dr $slPct
            $lev = $plan.Lev
            $roi1 = $lev * $slPct; $roi2 = 2 * $roi1; $roi3 = 3 * $roi1; $roiSl = $roi1
            if ($roi2 -lt $MinRoiTp2) { $rej.roi++; continue }              # sin recorrido suficiente para el apalancamiento seguro
            $feeShare = $FeeRT / $slPct * 100                               # comisiones / ganancia en TP1
            if ($feeShare -gt $MaxFeeShare) { $rej.fee++; continue }

            $fund = Get-Funding $t.symbol
            $book = Get-BookBias $t.symbol
            $ctx = @()
            $ctx += if ($aligned) { "Tendencia $htfName $trend (a favor) ✅" } else { "Tendencia $htfName $trend" }
            if ($t.symbol -ne "BTCUSDT") { $ctx += if ($btcAl -eq $true) { "BTC a favor ✅" } elseif ($btcAl -eq $false) { "BTC en contra ⚠️" } else { "BTC lateral" } }
            if ($null -ne $fund) {
                $fx = if ($fund -ge 0.03 -and $side -eq "SHORT") { " (largos saturados: favorece el SHORT ✅)" } elseif ($fund -le -0.03 -and $side -eq "LONG") { " (cortos saturados: favorece el LONG ✅)" } elseif ($fund -ge 0.03 -and $side -eq "LONG") { " (largos saturados ⚠️)" } elseif ($fund -le -0.03 -and $side -eq "SHORT") { " (cortos saturados ⚠️)" } else { "" }
                $ctx += ("Funding {0:N3}%{1}" -f $fund, $fx)
            }
            if ($null -ne $book) { $ctx += ("Libro: {0:N0}% compradores / {1:N0}% vendedores" -f $book, (100 - $book)) }
            $sentTxt = Get-SentimentLine $side; if ($sentTxt) { $ctx += $sentTxt }
            $ctx += @(Get-KeyLevels $t.symbol $entry)
            $ctxCode = $null; $ctxScore = $null
            if (Get-Command Get-ContextChecklist -ErrorAction SilentlyContinue) {
                try {
                    $rangeA = ($pHigh - $pLow) / $atr; $netA = [Math]::Abs([double]$closed[$n - 2].close - [double]$closed[$n - 1 - $Lookback].close) / [Math]::Max($pHigh - $pLow, 1e-12)
                    $chk = Get-ContextChecklist ($t.symbol -replace 'USDT$', '') $iv $sgn $entry $risk ($rangeA -le 8 -and $netA -le 0.5) $ratio
                    $ctx += @(""; $chk.lines); $ctxCode = $chk.code; $ctxScore = $chk.score
                } catch {}
            }
            if (Get-Command Get-TradeTechNote -ErrorAction SilentlyContinue) { try { $ctx += @(""; Get-TradeTechNote ($t.symbol -replace 'USDT$', '') $sgn $entry $sl $tp3 -Short) } catch {} }      # charting, Fibonacci, Bollinger y TradingView (informativo)

            $q = 0.6
            if ($aligned) { $q += 0.2 }
            if ($squeeze -or $pool -like "*iguales*") { $q += 0.1 }
            if ($ratio -ge 4) { $q += 0.1 }
            if ($btcAl -eq $true) { $q += 0.05 } elseif ($btcAl -eq $false) { $q -= 0.1 }
            $q = [Math]::Max(0.3, [Math]::Min(1.0, $q))
            $cf = switch ($plan.Risk) { "BAJO" { 1.0 } "MEDIO" { 0.8 } "ALTO" { 0.55 } default { 0.35 } }
            $tfF = if ($iv -eq "1h") { 0.6 } else { 1.0 }                   # 1h: esperanza débil y negativa fuera de muestra en el backtest -> menos margen hasta que las señales reales la confirmen
            $margin = [Math]::Max(20, [Math]::Min($MaxMargin, [Math]::Round($MaxMargin * $q * $cf * $tfF / 10) * 10))
            $notional = $margin * $lev
            $lossUsd = $notional * $slPct / 100
            $u1 = $lossUsd; $u2 = 2 * $lossUsd; $u3 = 3 * $lossUsd
            $planGain = $lossUsd * ($W1 * 1 + $W2 * 2 + $W3 * 3)            # si llega a los tres objetivos
            $feeUsd = $notional * $FeeRT / 100
            $volTxt = if ([double]$t.quoteVol -ge 1e6) { "{0:N1}M" -f ([double]$t.quoteVol / 1e6) } else { "{0:N0}k" -f ([double]$t.quoteVol / 1e3) }
            $name = $t.symbol -replace 'USDT$', ''
            $icon = if ($side -eq "LONG") { "🟢" } else { "🔴" }; $arrow = if ($side -eq "LONG") { "📈" } else { "📉" }
            $stratName = if ($strat -eq "barrido") { "Barrido de liquidez" } else { "Ruptura con retesteo" }
            $poolTxt = if ($pool) { " · $pool" } else { "" }
            $valid = [int](4 * $dur / 60)
            # --- Riesgo/beneficio, acierto mínimo y distancia a la liquidación ---
            $rPlan = $W1 * 1 + $W2 * 2 + $W3 * 3
            $feeR = $FeeRT / $slPct                                          # comisión en unidades de riesgo (R)
            $pBe2 = (1 + $feeR) / 3 * 100; $pBeP = (1 + $feeR) / ($rPlan + 1) * 100
            $liqPx = $entry * (1 - $sgn * (1 / $lev - 0.003)); $liqDist = [Math]::Abs($entry - $liqPx) / $entry * 100
            $slShare = $slPct / $liqDist * 100
            $rbTxt = ("Riesgo/beneficio: TP1 1:1 · TP2 1:2 · TP3 1:3 · plan completo 1:{0:N1}`nAcierto mínimo para no perder (comisiones incl.): {1:N0}% si el objetivo es TP2 · {2:N0}% con el plan completo`nLiquidación aprox.: {3} ({4:N1}% desde la entrada); el SL queda al {5:N0}% de ese camino {6}" -f $rPlan, $pBe2, $pBeP, (Fmt $liqPx), $liqDist, $slShare, $(if ($slShare -le 50) { "✅" } else { "⚠️" }))
            $msg = ("{0} {1}/USDT {2} {3}  ({4} · {5}){6}`n" +
                "Apalancamiento: x{7} ({8}; por tu SL llegaría a x{9})`n" +
                "{10}`n`n" +
                "Entrada: {11}{12}`n`n" +
                "TP:`n1) {13} (1:1)  +{14:N0}% s/margen`n2) {15} (1:2)  +{16:N0}% s/margen`n`nTP final: {17} (1:3)  +{18:N0}% s/margen (movimiento +{19:N1}%)`n`n" +
                "🛑 SL: {20} (-{21:N1}%)  -{22:N0}% s/margen`n`n" +
                "💰 Margen sugerido: {23:N0} USDT (máx. {24:N0}) -> posición {25:N0} USDT`n" +
                "Si salta el SL: -{26:N0} USDT`n" +
                "Si llega a TP1 / TP2 / TP3: +{27:N0} / +{28:N0} / +{29:N0} USDT`n" +
                "Gestión: cierra {30:N0}% en TP1, {31:N0}% en TP2 y {32:N0}% en TP3, y mueve el SL a la entrada tras el TP1 (ganancia total ~+{33:N0} USDT).`n" +
                "Comisiones estimadas: {34:N1} USDT ({35:N0}% de la ganancia en TP1)`n{41}`n`n" +
                "Riesgo de la moneda: {36} (vol. 24h {37} USDT, rango diario medio {38:N1}%)`n" +
                "Motivo: {39}`n{40}") -f
                $icon, $name, $side, $arrow, $iv, $stratName, $poolTxt, $lev, $plan.Why, $plan.LSl,
                $(if ($entryType -eq "limit") { "Operación con orden limit (válida unas $valid h; si no se ejecuta, se cancela)" } else { "Entrada a mercado" }),
                (Fmt $entry), $(if ($entryType -eq "limit") { " (orden limit)" } else { "" }),
                (Fmt $tp1), $roi1, (Fmt $tp2), $roi2, (Fmt $tp3), $roi3, $tpPct, (Fmt $sl), $slPct, $roiSl, $margin, $MaxMargin, $notional,
                $lossUsd, $u1, $u2, $u3, ($W1 * 100), ($W2 * 100), ($W3 * 100), $planGain, $feeUsd, $feeShare, $plan.Risk, $volTxt, $dr, $why, ($ctx -join "`n"), $rbTxt

            # --- Versión GENÉRICA para el grupo Alertas Mercados (solo cripto en 4h, el marco validado): sin margen, apalancamiento ni cifras privadas de Luis ---
            $genMsg = $null
            if ($iv -eq "4h" -and $strat -eq "ruptura" -and $script:MktChat) {
                $posEx = 10000 * 0.01 / ($slPct / 100)
                $genMsg = (@(
                    ("{0} {1}/USDT {2} {3}  ({4} · {5}) · cripto (futuros)" -f $icon, $name, $side, $arrow, $iv, $stratName),
                    "",
                    $(if ($entryType -eq "limit") { "Entrada: orden limit en {0} (válida unas {1} h; si no se ejecuta, se cancela)" -f (Fmt $entry), $valid } else { "Entrada a mercado cerca de {0}" -f (Fmt $entry) }),
                    ("🛑 SL: {0} (-{1:N1}%)" -f (Fmt $sl), $slPct),
                    ("🎯 TP1 (1:1): {0} · TP2 (1:2): {1} · TP3 (1:3): {2} (hasta +{3:N1}% de movimiento)" -f (Fmt $tp1), (Fmt $tp2), (Fmt $tp3), $tpPct),
                    "Gestión: cierra un tercio en cada objetivo y mueve el SL a la entrada tras el TP1.",
                    "",
                    ("💰 Tamaño: arriesga como máximo el 1% de tu capital. Posición = (capital × 1%) ÷ ({0:N1}% de distancia al SL). Con 10.000 USDT de capital: posición ≈ {1:N0} USDT. Usa el apalancamiento mínimo necesario; la liquidación debe quedar mucho más lejos que el SL." -f $slPct, $posEx),
                    ("Motivo: {0}" -f $why),
                    ($ctx -join "`n"),
                    "",
                    "📊 Backtest de esta táctica en cripto 4h (98 series, ~200 días): llega a TP1 en ≈ 7 de cada 10 operaciones y da ≈ +0,4R de media por operación, con rachas de hasta 3 pérdidas. Dato histórico, no una promesa.",
                    "⚠️ Señal automática calculada con datos públicos; no es asesoramiento financiero. Pon siempre el stop loss y no arriesgues más de lo que puedas permitirte perder."
                ) -join "`n")
                if ($genMsg.Length -gt 3900) { $genMsg = $genMsg.Substring(0, 3890) + "…" }
            }
            # --- Gráfico estilo TradingView ---
            $photo = $null
            if ($hasChart) {
                $cs = @($closed | Select-Object -Last 70 | ForEach-Object { [pscustomobject]@{ o = [double]$_.open; h = [double]$_.high; l = [double]$_.low; c = [double]$_.close } })
                $photo = New-SignalChart $cs $side $entry $sl $tp1 $tp2 $tp3 ("{0}/USDT {1} · {2} · {3}" -f $name, $iv, $side, $stratName) (Join-Path ([IO.Path]::GetTempPath()) ("senal-" + $t.symbol + ".png")) $level
            }
            if (Send-Alert $key $msg $photo) {
                if ($genMsg -and $TelegramToken) { try { Send-Tg $TelegramToken $script:MktChat $genMsg $null } catch {} }
                Add-SignalRecord ([ordered]@{
                    id = $key; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = $t.symbol; tf = $iv; strat = $strat; side = $sgn
                    entryType = $entryType; entry = $entry; sl = $sl; tp1 = $tp1; tp2 = $tp2; tp3 = $tp3; riskAbs = $risk; slPct = $slPct
                    lev = $lev; margin = $margin; ratio = [Math]::Round($ratio, 2); trend = $trend; aligned = $aligned; btcAligned = $btcAl
                    squeeze = $squeeze; pool = $pool; funding = $fund; book = $book; risk = $plan.Risk; roiTp2 = [Math]::Round($roi2, 1)
                    status = $(if ($entryType -eq "limit") { "pending" } else { "open" }); stage = 0; realized = 0.0; age = 0; lastLabel = [long]$last.time; lab0 = [long]$last.time; sentiment = $script:sentCache.v; ctxScore = $ctxScore; ctxFlags = $ctxCode; outcome = $null; R = $null; net = $null
                })
            }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ("  [{0}] descartadas: SL<{1}% -> {2} | potencial<{3}% -> {4} | comisiones -> {5} | tendencia -> {6} | ya tarde -> {7}" -f $iv, $MinSlPct, $rej.sl, $MinRoiTp2, $rej.roi, $rej.fee, $rej.trend, $rej.tarde) -ForegroundColor DarkGray
}

function Send-ToSignalChats($text) {
    if (-not ($TelegramToken -and $sigChats.Count)) { return }
    foreach ($cid in $sigChats) { try { Send-Tg $TelegramToken $cid $text $null } catch {} }
}
# Informe diario sencillo: todos los días a las 22:00 (hora de España) o en cuanto el bot esté activo después. Solo al chat privado de señales.
function Send-DailyReport {
    $now = Get-MadridNow; $today = $now.ToString("yyyy-MM-dd")
    if ($now.Hour -lt 22 -or (Get-ReportState "daily") -eq $today) { return }
    Set-ReportState "daily" $today
    $rep = Get-DailyReport
    Write-Host $rep -ForegroundColor Cyan
    Send-ToSignalChats $rep
}
# Informe semanal profundo: domingos a partir de las 22:00 (hora de España), una vez por semana.
function Send-WeeklyReport {
    $now = Get-MadridNow
    if ($now.DayOfWeek -ne [DayOfWeek]::Sunday -or $now.Hour -lt 22) { return }
    $week = $now.ToString("yyyy-MM-dd")
    if ((Get-ReportState "weekly") -eq $week) { return }
    Set-ReportState "weekly" $week
    $rep = Get-WeeklyDeepReport
    Write-Host $rep -ForegroundColor Cyan
    Send-ToSignalChats $rep
}

# Estrategia EN OBSERVACIÓN (no envía señales): barrido de liquidez en 4h. Liquidez igual (EQH/EQL >= 2 toques) -> barrido -> confirmación (la vela siguiente cierra más allá del cuerpo)
# -> entrada a mercado, SL detrás del extremo, objetivo en la liquidez opuesta (R:B >= 1,5), tendencia diaria (EMA21) sin contra. Criterios fijados ANTES de ver resultados reales.
function Scan-SweepObs {
    $iv = "4h"; $dur = 240; $look = 30; $added = 0
    $tk = (Invoke-RestMethod "$base/tickers").data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $TopN
    foreach ($t in $tk) {
        if (($script:cmdTick++ % 10) -eq 0) { Poll-Commands }
        try {
            $k = @((Invoke-RestMethod "$base/kline?symbol=$($t.symbol)&interval=$iv&limit=120").data | Sort-Object { [long]$_.time }); if ($k.Count -lt 70) { continue }
            $closed = @($k[0..($k.Count - 2)]); $n = $closed.Count; $kk = $n - 1
            $ageMin = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - ([long]$closed[$kk].time + 2 * $dur * 60000)) / 60000; if ($ageMin -gt 1.5 * $dur) { continue }
            foreach ($back in 1, 2) {
                $s = $kk - $back; if ($s -lt $look + 16) { continue }
                $pH = -1e18; $pL = 1e18; for ($q = $s - $look; $q -lt $s; $q++) { if ([double]$closed[$q].high -gt $pH) { $pH = [double]$closed[$q].high }; if ([double]$closed[$q].low -lt $pL) { $pL = [double]$closed[$q].low } }
                $hi = [double]$closed[$s].high; $lo = [double]$closed[$s].low; $op = [double]$closed[$s].open; $cs = [double]$closed[$s].close; $rg = $hi - $lo; if ($rg -le 0) { continue }
                $atr = Get-Atr $closed ($s - 14) ($s - 1); if ($atr -le 0) { continue }
                $sg = 0; $ext = 0.0; $eq = 0
                if ($hi -gt $pH + 0.05 * $atr -and $hi -le $pH + 1.5 * $atr -and $cs -lt $pH -and ($hi - [Math]::Max($op, $cs)) / $rg -ge 0.5) { $sg = -1; $ext = $hi; for ($q = $s - $look; $q -lt $s; $q++) { if ([double]$closed[$q].high -ge $pH - 0.25 * $atr) { $eq++ } } }
                elseif ($lo -lt $pL - 0.05 * $atr -and $lo -ge $pL - 1.5 * $atr -and $cs -gt $pL -and ([Math]::Min($op, $cs) - $lo) / $rg -ge 0.5) { $sg = 1; $ext = $lo; for ($q = $s - $look; $q -lt $s; $q++) { if ([double]$closed[$q].low -le $pL + 0.25 * $atr) { $eq++ } } }
                if ($sg -eq 0 -or $eq -lt 2) { continue }
                $body = if ($sg -eq -1) { [Math]::Min($op, $cs) } else { [Math]::Max($op, $cs) }; $slv = $ext - $sg * 0.1 * $atr
                $firstConf = $null; $invalid = $false
                for ($z = $s + 1; $z -le $kk; $z++) {
                    $zh = [double]$closed[$z].high; $zl = [double]$closed[$z].low; $zc = [double]$closed[$z].close
                    if (($sg -eq 1 -and $zl -le $slv) -or ($sg -eq -1 -and $zh -ge $slv)) { $invalid = $true; break }
                    if (($sg -eq 1 -and $zc -gt $body) -or ($sg -eq -1 -and $zc -lt $body)) { $firstConf = $z; break }
                    if ($z - $s -ge 2) { break }
                }
                if ($invalid -or $firstConf -ne $kk) { continue }
                $entry = [double]$closed[$kk].close; $R = $sg * ($entry - $slv); if ($R -le 0 -or $R -lt 0.4 * $atr -or $R -gt 2.5 * $atr -or ($R / $entry * 100) -lt 1.0) { continue }
                $target = if ($sg -eq -1) { $pL } else { $pH }; if ($sg * ($target - $entry) / $R -lt 1.5) { continue }
                $trend = Get-TrendHtf $t.symbol $iv
                if (($sg -eq 1 -and $trend -eq "bajista") -or ($sg -eq -1 -and $trend -ne "bajista")) { continue }
                $key = "obs-$($t.symbol)-4h-$($closed[$kk].time)"
                if (@(Read-Signals | Where-Object { $_.id -eq $key }).Count) { continue }
                Add-SignalRecord ([ordered]@{
                    id = $key; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = $t.symbol; tf = $iv; strat = "barrido-obs"; side = $sg
                    entryType = "mercado"; entry = $entry; sl = $slv; tp1 = $target; tp2 = $target; tp3 = $target; riskAbs = $R; slPct = ($R / $entry * 100)
                    ratio = $null; trend = $trend; aligned = $null; btcAligned = $null; pool = "EQ $eq toques"; risk = "OBS"
                    status = "open"; stage = 0; realized = 0.0; age = 0; lastLabel = [long]$closed[$kk].time; lab0 = [long]$closed[$kk].time
                    mode = "single"; cost = 0.0015; outcome = $null; R = $null; net = $null
                })
                $added++
            }
        } catch { }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ("  [observación 4h] barridos con confirmación registrados en silencio: {0}" -f $added) -ForegroundColor DarkGray
}
$script:obsAt = [datetime]::MinValue
function Run-SweepObsIfDue {                       # solo cuando acaba de cerrar una vela de 4h (y como máximo cada 20 min)
    if (((Get-Date) - $script:obsAt).TotalMinutes -lt 20) { return }
    $script:obsAt = Get-Date
    try { $kb = @((Invoke-RestMethod "$base/kline?symbol=BTCUSDT&interval=4h&limit=5").data | Sort-Object { [long]$_.time }); $lastB = $kb[$kb.Count - 2]
          $ageB = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - ([long]$lastB.time + 2 * 240 * 60000)) / 60000; if ($ageB -gt 45) { return } } catch { return }
    Scan-SweepObs
}

Write-Host "Buscando setups de alto potencial en top $TopN pares Bitunix ($($Interval -join ', ')) [$($Strategies -join ', ')] cada $EverySeconds s. Ctrl+C para parar." -ForegroundColor Cyan
$script:startAt = Get-Date
try { Import-ManualTrades (Join-Path $PSScriptRoot "operaciones-manuales.json") } catch {}
try { Import-GroupTracking (Join-Path $PSScriptRoot "seguimiento-grupo.json") } catch {}      # tus operaciones reales entran en el seguimiento (solo se importan una vez)
do {
    try { Update-Signals $base } catch {}
    foreach ($iv in $Interval) { Scan $iv }
    try { Run-SweepObsIfDue } catch {}
    try { Send-MarketScanIfDue } catch {}
    try { Send-WatchAlertsIfDue } catch {}
    try { Send-IrenWeeklyIfDue } catch {}
    try { Run-MomentoCryptoIfDue } catch {}
    try { Run-MomentoStocksIfDue } catch {}
    try { Notify-GroupTracking } catch {}
    try { Check-SignalHealth } catch {}
    try { Send-DailyReport } catch {}
    try { Send-WeeklyReport } catch {}
    Write-Host ("{0} pasada completada" -f (Get-Date -Format "HH:mm:ss")) -ForegroundColor DarkGray
    if (-not $Once) { $until = (Get-Date).AddSeconds($EverySeconds); while ((Get-Date) -lt $until) { Poll-Commands; Start-Sleep -Seconds 6 } } else { Poll-Commands }
} while (-not $Once -and ($MaxMinutes -le 0 -or ((Get-Date) - $script:startAt).TotalMinutes -lt $MaxMinutes))
