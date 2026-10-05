# Escáner de MERCADO (acciones, ETFs y otros activos de Yahoo Finance) en velas DIARIAS para el grupo "Alertas Mercados".
# Es la misma táctica validada en backtest (variante S5: 137 activos, 10 años, velas diarias): ruptura del rango de 20 sesiones con volumen >= x2, entrada limit en el retesteo,
# SL en el nivel (0,5 ATR, entre 0,8 y 2 ATR), un tercio en 1R/2R/3R con SL a entrada tras TP1, tendencia semanal (EMA21) sin contra, estructura semanal sin contra
# y zoom out: >= 2R de espacio hasta el siguiente obstáculo semanal. SL mínimo 0,6%. Solo marco diario: en 1h no fue viable y en 4h fue débil.
. (Join-Path $PSScriptRoot "universo-mercado.ps1")
$script:MktUA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' }
$script:MktCfg = @{ vol = 2.0; look = 20; maxExt = 1.2; minSl = 0.6; zoom = 2.0; depth = 1.0; win = 4 }
$script:MktDay = 86400000L

function Get-MktBars($tkr) {      # velas diarias CERRADAS (sin la sesión en curso) + metadatos; $null si no hay datos suficientes
    try {
        $r = (Invoke-RestMethod ("https://query1.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($tkr) + "?range=2y&interval=1d&includePrePost=false") -Headers $script:MktUA -TimeoutSec 30).chart.result[0]
        $q = $r.indicators.quote[0]; $m = $r.meta; $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $idx = @(0..($r.timestamp.Count - 1) | Where-Object { $null -ne $q.close[$_] -and $null -ne $q.high[$_] -and $null -ne $q.low[$_] -and $null -ne $q.open[$_] -and $null -ne $q.volume[$_] })
        if ($idx.Count -lt 120) { return $null }
        # la última barra es la sesión en curso si empezó en el periodo regular actual y este aún no ha terminado
        $per = $m.currentTradingPeriod.regular; $lastTs = [long]$r.timestamp[$idx[-1]]
        if ($per -and $lastTs -ge [long]$per.start -and $nowS -lt [long]$per.end) { $idx = @($idx | Select-Object -SkipLast 1) }
        if ($idx.Count -lt 120) { return $null }
        return @{ tkr = $tkr; t = [long[]]($idx | ForEach-Object { [long]$r.timestamp[$_] * 1000 }); o = [double[]]($idx | ForEach-Object { [double]$q.open[$_] }); h = [double[]]($idx | ForEach-Object { [double]$q.high[$_] }); l = [double[]]($idx | ForEach-Object { [double]$q.low[$_] }); c = [double[]]($idx | ForEach-Object { [double]$q.close[$_] }); v = [double[]]($idx | ForEach-Object { [double]$q.volume[$_] }); n = $idx.Count
                  cur = "$($m.currency)"; name = $(if ($m.longName) { "$($m.longName)" } elseif ($m.shortName) { "$($m.shortName)" } else { $tkr }); exch = "$($m.fullExchangeName)"; kind = "$($m.instrumentType)" }
    } catch { return $null }
}
function Get-MktClosedForTracker($tkr) {      # para el seguimiento: objetos con time/high/low/close como las velas de Bitunix
    $b = Get-MktBars $tkr; if (-not $b) { return @() }
    return @(0..($b.n - 1) | ForEach-Object { [pscustomobject]@{ time = $b.t[$_]; open = $b.o[$_]; high = $b.h[$_]; low = $b.l[$_]; close = $b.c[$_] } })
}

# ---------- indicadores (misma definición que el backtest) ----------
function Mkt-Rsi($c) {
    $n = $c.Count; $rsi = New-Object 'double[]' $n; $g = 0.0; $ls = 0.0
    for ($i = 1; $i -le 14 -and $i -lt $n; $i++) { $d = $c[$i] - $c[$i - 1]; if ($d -gt 0) { $g += $d } else { $ls -= $d } }
    $g /= 14; $ls /= 14
    for ($i = 15; $i -lt $n; $i++) { $d = $c[$i] - $c[$i - 1]; $g = ($g * 13 + [Math]::Max($d, 0)) / 14; $ls = ($ls * 13 + [Math]::Max(-$d, 0)) / 14; $rsi[$i] = if ($ls -eq 0) { 100 } else { 100 - 100 / (1 + $g / $ls) } }
    return $rsi
}
function Mkt-Weekly($b) {                      # semanas COMPLETAS con retraso como en el backtest (disponibles >= 4 días después de su última sesión)
    $wk = 7 * $script:MktDay; $nowMs = if ($script:MktNowMs) { [long]$script:MktNowMs } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }; $groups = [ordered]@{}      # MktNowMs solo se usa en pruebas históricas
    for ($i = 0; $i -lt $b.n; $i++) { $g = [long][Math]::Floor(($b.t[$i] - $script:MktDay) / $wk); if (-not $groups.Contains($g)) { $groups[$g] = New-Object System.Collections.Generic.List[int] }; $groups[$g].Add($i) }
    $o = @(); $h = @(); $l = @(); $c = @()
    foreach ($g in $groups.Keys) {
        $ix = $groups[$g]; if ($ix.Count -lt 3) { continue }
        if ($b.t[$ix[$ix.Count - 1]] + 4 * $script:MktDay -gt $nowMs) { continue }
        $o += $b.o[$ix[0]]; $c += $b.c[$ix[$ix.Count - 1]]; $h += ($ix | ForEach-Object { $b.h[$_] } | Measure-Object -Maximum).Maximum; $l += ($ix | ForEach-Object { $b.l[$_] } | Measure-Object -Minimum).Minimum
    }
    return @{ o = [double[]]$o; h = [double[]]$h; l = [double[]]$l; c = [double[]]$c; n = $c.Count }
}
function Mkt-WeeklyContext($W, [double]$px) {   # tendencia EMA21 semanal, estructura (pivotes n=2) y obstáculos (pivotes n=3, últimas ~70 semanas)
    $res = @{ trend = "flat"; struct = "flat"; resLv = $null; supLv = $null; ok = $false }
    if ($W.n -lt 30) { return $res }
    $res.ok = $true; $j = $W.n - 1; $k = 2.0 / 22; $ema = New-Object 'double[]' $W.n; $ema[0] = $W.c[0]
    for ($i = 1; $i -lt $W.n; $i++) { $ema[$i] = $W.c[$i] * $k + $ema[$i - 1] * (1 - $k) }
    if ($W.c[$j] -gt $ema[$j] -and $ema[$j] -ge $ema[$j - 3]) { $res.trend = "up" } elseif ($W.c[$j] -lt $ema[$j] -and $ema[$j] -le $ema[$j - 3]) { $res.trend = "down" }
    $hs = @(); $ls = @(); $np = 2
    for ($i = $np; $i -le $j - $np; $i++) {
        $isH = $true; $isL = $true; for ($q = $i - $np; $q -le $i + $np; $q++) { if ($q -eq $i) { continue }; if ($W.h[$q] -ge $W.h[$i]) { $isH = $false }; if ($W.l[$q] -le $W.l[$i]) { $isL = $false } }
        if ($isH) { $hs += $W.h[$i] }; if ($isL) { $ls += $W.l[$i] }
    }
    if ($hs.Count -ge 2 -and $ls.Count -ge 2) { $hu = $hs[-1] -gt $hs[-2]; $lu = $ls[-1] -gt $ls[-2]; if ($hu -and $lu) { $res.struct = "up" } elseif (-not $hu -and -not $lu) { $res.struct = "down" } }
    $lo = [Math]::Max(3, $j - 70)
    for ($p = $lo; $p -le $j - 3; $p++) {
        $isH = $true; $isL = $true; for ($q = $p - 3; $q -le $p + 3; $q++) { if ($q -eq $p) { continue }; if ($W.h[$q] -ge $W.h[$p]) { $isH = $false }; if ($W.l[$q] -le $W.l[$p]) { $isL = $false } }
        if ($isH -and $W.h[$p] -gt $px -and ($null -eq $res.resLv -or $W.h[$p] -lt $res.resLv)) { $res.resLv = $W.h[$p] }
        if ($isL -and $W.l[$p] -lt $px -and ($null -eq $res.supLv -or $W.l[$p] -gt $res.supLv)) { $res.supLv = $W.l[$p] }
    }
    return $res
}

# ---------- detección sobre la última sesión cerrada ----------
function Get-MktSetup($b) {
    $cfg = $script:MktCfg; $n = $b.n; $i = $n - 1; if ($i -lt 70) { return $null }
    $c = $b.c; $h = $b.h; $l = $b.l; $o = $b.o; $v = $b.v
    $sv = 0.0; for ($q = $i - 20; $q -lt $i; $q++) { $sv += $v[$q] }; $av20 = $sv / 20; if ($av20 -le 0) { return $null }
    $ratio = $v[$i] / $av20; if ($ratio -lt $cfg.vol) { return $null }
    $st = 0.0; for ($q = $i - 14; $q -lt $i; $q++) { $st += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $st / 14; if ($atr -le 0) { return $null }
    $px = $c[$i]; $op = $o[$i]; $hi = $h[$i]; $lo = $l[$i]; $rng = $hi - $lo; if ($rng -le 0) { return $null }
    $pH = -1e18; $pL = 1e18; for ($q = $i - $cfg.look; $q -lt $i; $q++) { if ($h[$q] -gt $pH) { $pH = $h[$q] }; if ($l[$q] -lt $pL) { $pL = $l[$q] } }
    $rsi = (Mkt-Rsi $c)[$i]; $pos = ($px - $lo) / $rng; $sgn = 0; $lvl = 0.0
    if ($px -gt $pH -and $px -gt $op -and $pos -ge 0.65 -and $rsi -lt 72 -and $rsi -gt 40) { $sgn = 1; $lvl = $pH } elseif ($px -lt $pL -and $px -lt $op -and $pos -le 0.35 -and $rsi -gt 28 -and $rsi -lt 60) { $sgn = -1; $lvl = $pL }
    if ($sgn -eq 0) { return $null }
    $ext = $sgn * ($px - $lvl) / $atr; if ($ext -gt $cfg.maxExt -or $rng -gt 2.5 * $atr) { return $null }
    $sl = $lvl - $sgn * 0.5 * $atr; $risk = $sgn * ($px - $sl); if ($risk -lt 0.8 * $atr) { $sl = $px - $sgn * 0.8 * $atr }; if ($risk -gt 2.0 * $atr) { $sl = $px - $sgn * 2.0 * $atr }
    $W = Mkt-Weekly $b; $wc = Mkt-WeeklyContext $W $px; if (-not $wc.ok) { return $null }
    $aligned = ($sgn -eq 1 -and $wc.trend -eq "up") -or ($sgn -eq -1 -and $wc.trend -eq "down"); $counter = ($sgn -eq 1 -and $wc.trend -eq "down") -or ($sgn -eq -1 -and $wc.trend -eq "up")
    if (($sgn -eq 1 -and $counter) -or ($sgn -eq -1 -and -not $aligned)) { return $null }                                     # tendencia semanal 'smart'
    $sCounter = ($sgn -eq 1 -and $wc.struct -eq "down") -or ($sgn -eq -1 -and $wc.struct -eq "up"); if ($sCounter) { return $null }   # estructura semanal sin contra
    $lim = $px - $sgn * [Math]::Min($cfg.depth * $atr, [Math]::Abs($px - $lvl)); if ([Math]::Abs($px - $lim) -lt 0.05 * $atr) { return $null }   # retesteo del nivel roto
    $R = $sgn * ($lim - $sl); if ($R -le 0 -or ($R / $lim * 100) -lt $cfg.minSl) { return $null }
    $room = if ($sgn -eq 1) { if ($null -ne $wc.resLv) { ($wc.resLv - $lim) / $R } else { 99.0 } } else { if ($null -ne $wc.supLv) { ($lim - $wc.supLv) / $R } else { 99.0 } }
    if ($room -lt $cfg.zoom) { return $null }
    return @{ tkr = $b.tkr; side = $sgn; level = $lvl; entry = $lim; sl = $sl; R = $R; tp1 = $lim + $sgn * $R; tp2 = $lim + $sgn * 2 * $R; tp3 = $lim + $sgn * 3 * $R; px = $px; atr = $atr; ratio = $ratio; wk = $wc; room = $room; barTime = $b.t[$i]; rsi = $rsi }
}

function MktF($x, $cur) { if ($x -ge 100) { return ("{0:N2}" -f $x) } elseif ($x -ge 1) { return ("{0:N3}" -f $x) } else { return ("{0:G5}" -f $x) } }
function Build-MktMessage($b, $s) {
    $sg = $s.side; $dir = if ($sg -eq 1) { "LONG" } else { "SHORT" }; $icon = if ($sg -eq 1) { "🟢" } else { "🔴" }; $arrow = if ($sg -eq 1) { "📈" } else { "📉" }
    $kind = if ($b.kind -eq "ETF") { "ETF" } elseif ($b.tkr -like '*.MC') { "acción española" } else { "acción" }; $cur = $b.cur
    $pct = { param($x) ($x / $s.entry - 1) * 100 }
    $slPct = [Math]::Abs($s.sl / $s.entry - 1) * 100
    $cap = 10000.0; $risk1 = $cap * 0.01; $sh = [Math]::Floor($risk1 / $s.R); $posVal = $sh * $s.entry
    $L = @()
    $L += ("{0} {1} · {2} ({3} · {4}) {5} {6}  (1d · Ruptura con retesteo)" -f $icon, $b.tkr, $b.name, $kind, $b.exch, $dir, $arrow)
    $L += ""
    $L += ("Entrada: orden limit {0} {1}{2}" -f $(if ($sg -eq 1) { "de COMPRA a" } else { "de VENTA en corto a" }), (MktF $s.entry $cur), " $cur")
    $L += ("   Válida 4 sesiones. Se cancela si no se ejecuta en ese plazo, si el precio pierde el SL antes de entrar o si se va al TP1 sin dar la entrada.")
    $L += ""
    $L += ("🛑 SL: {0} ({1:+0.0;-0.0}%)" -f (MktF $s.sl $cur), (& $pct $s.sl))
    $L += ("🎯 TP1 (1:1): {0} ({1:+0.0;-0.0}%) · TP2 (1:2): {2} ({3:+0.0;-0.0}%) · TP3 (1:3): {4} ({5:+0.0;-0.0}%)" -f (MktF $s.tp1 $cur), (& $pct $s.tp1), (MktF $s.tp2 $cur), (& $pct $s.tp2), (MktF $s.tp3 $cur), (& $pct $s.tp3))
    $L += "Gestión: cierra un tercio en cada objetivo y mueve el SL a la entrada tras el TP1."
    $L += ""
    $L += ("💰 Tamaño (sin apalancamiento): arriesga como máximo el 1% de tu capital. Nº de acciones/participaciones = (capital × 1%) ÷ {0:N2} (distancia entrada-SL). Con 10.000 {1}: ≈ {2:N0} unidades (≈ {3:N0} {1} de posición, pérdida máxima ≈ {4:N0} {1})." -f $s.R, $cur, $sh, $posVal, ($sh * $s.R))
    if ($sg -eq -1) { $L += "   Los cortos requieren un bróker que permita vender en corto o CFD; si no, descártala." }
    $L += ""
    $L += ("Motivo: rompe el {0} de 20 sesiones ({1}) con volumen x{2:N1} y se entra en el retesteo del nivel roto." -f $(if ($sg -eq 1) { "máximo" } else { "mínimo" }), (MktF $s.level $cur), $s.ratio)
    $L += "🧭 Contexto (zoom out semanal):"
    $L += ("   ✅ Tendencia semanal {0} y estructura semanal {1}: sin contra" -f $(if ($s.wk.trend -eq "up") { "alcista" } elseif ($s.wk.trend -eq "down") { "bajista" } else { "lateral" }), $(if ($s.wk.struct -eq "up") { "de máximos y mínimos crecientes" } elseif ($s.wk.struct -eq "down") { "de máximos y mínimos decrecientes" } else { "mixta" }))
    $L += ("   ✅ Espacio hasta el siguiente obstáculo semanal: {0}" -f $(if ($s.room -ge 99) { "sin obstáculos relevantes" } else { ("{0:N1}R" -f $s.room) }))
    # sentimiento, análisis técnico y TradingView (informativos)
    if (Get-Command Get-MarketSentiment -ErrorAction SilentlyContinue) { try { $sent = Get-MarketSentiment $false; if ($sent) { $L += "🌡️ $sent" } } catch {} }
    if (Get-Command Analyze-TF -ErrorAction SilentlyContinue) {
        try { $cd = New-Cd $b.o $b.h $b.l $b.c $b.v; $an = Analyze-TF $cd "1d" 90; if ($an) { $L += ""; $L += "🧮 Análisis técnico (velas diarias):"; $L += @($an.lines | Select-Object -First 3); $L += @($an.liq) } } catch {}
        try { $tv = Resolve-TvTarget 'yahoo' $b.tkr $b.exch; $L += (Get-TvLines $tv -Short) } catch {}
    }
    $L += ""
    $L += "📊 Backtest de esta táctica en velas diarias (348 acciones y ETFs, ~10 años, 373 operaciones): llega a TP1 en ≈ 6 de cada 10 operaciones y da ≈ +0,3R de media por operación (≈ +0,1R en el último 40% del periodo), con rachas de hasta 6 pérdidas seguidas. Es un dato histórico, no una promesa."
    $L += "⚠️ Señal automática calculada con datos públicos; no es asesoramiento financiero. Comisiones y deslizamiento del bróker aparte. Pon siempre el stop loss y no arriesgues más de lo que puedas permitirte perder."
    return ($L -join "`n")
}

# ---------- barrido diario del universo ----------
function Scan-Market([switch]$Dry) {
    $found = 0; $scanned = 0; $mkt = $null
    foreach ($tkr in $script:UniTodos) {
        if (($script:cmdTick++ % 10) -eq 0) { try { Poll-Commands } catch {} }
        $b = Get-MktBars $tkr; Start-Sleep -Milliseconds 120; if (-not $b) { continue }; $scanned++
        $s = Get-MktSetup $b; if (-not $s) { continue }
        $key = "mkt-$tkr-1d-$($s.barTime)"
        if (@(Read-Signals | Where-Object { $_.id -eq $key }).Count) { continue }
        $msg = Build-MktMessage $b $s
        $found++
        if ($Dry) { $script:MktDryOut += ,@($tkr, $msg); continue }
        if ($script:MktChat -and $TelegramToken) { try { Send-Tg $TelegramToken $script:MktChat $msg $null } catch {} }
        Add-SignalRecord ([ordered]@{
            id = $key; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = $tkr; src = "yahoo"; tf = "1d"; strat = "ruptura-mercado"; side = $s.side
            entryType = "limit"; entry = $s.entry; sl = $s.sl; tp1 = $s.tp1; tp2 = $s.tp2; tp3 = $s.tp3; riskAbs = $s.R; slPct = ([Math]::Abs($s.sl / $s.entry - 1) * 100)
            ratio = [Math]::Round($s.ratio, 2); trend = $s.wk.trend; aligned = $null; btcAligned = $null; pool = ""; risk = "MERCADO"
            status = "pending"; stage = 0; realized = 0.0; age = 0; expiry = 4; lastLabel = [long]$s.barTime; lab0 = [long]$s.barTime; outcome = $null; R = $null; net = $null; cost = 0.0010
        })
    }
    Write-Host ("  [mercado 1d] activos analizados: {0} · señales nuevas: {1}" -f $scanned, $found) -ForegroundColor DarkGray
    $script:MktLastScanned = $scanned
    return $found
}
function Send-MarketScanIfDue {               # laborables a partir de las 22:30 (hora de España), una vez al día
    $now = Get-MadridNow; if ($now.DayOfWeek -in [DayOfWeek]::Saturday, [DayOfWeek]::Sunday) { return }
    $today = $now.ToString("yyyy-MM-dd"); if ($now.Hour -lt 22 -or ($now.Hour -eq 22 -and $now.Minute -lt 30)) { return }
    if ((Get-ReportState "mercado") -eq $today) { return }
    Set-ReportState "mercado" $today
    $found = Scan-Market
    # aviso SOLO al chat privado de Luis: resumen del escaneo y, la primera vez, confirmación de que Alertas Mercados está operativo
    $resumen = "🌍 Escaneo diario de mercado (acciones y ETFs, velas diarias) completado: $($script:MktLastScanned) activos analizados, $found señal(es) nueva(s) enviada(s) al grupo Alertas Mercados."
    if ($script:MktLastScanned -lt 100) { $resumen += " ⚠️ Pocos activos respondieron (Yahoo Finance puede estar limitando): revisa mañana."; }
    try { Send-ToSignalChats $resumen } catch {}
    if (-not (Get-ReportState "mercadook") -and $script:MktLastScanned -ge 100) {
        Set-ReportState "mercadook" $today
        try { Send-ToSignalChats "✅ ALERTAS MERCADOS OPERATIVO: el escáner diario de acciones y ETFs se ha ejecutado correctamente en la nube. Desde ahora publica en el grupo cuando aparezca una señal que cumpla las reglas (con pocas señales: la táctica es exigente), y el bot atiende allí /informe, /precio, /riesgo y /momento." } catch {}
    }
}
