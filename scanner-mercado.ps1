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

# ---------- aviso informativo: cruce al alza de la EMA200 con volumen comprador (sesión diaria cerrada) ----------
# Backtest (348 activos, ~10 años): 54% llegan a TP1 y esperanza +0,1R aun con volumen y vela compradora: ventaja casi nula -> se avisa como CONTEXTO, sin plan de entrada, SL ni TP.
function Get-Ema200Cross($b) {
    $n = $b.n; if ($n -lt 230) { return $null }; $i = $n - 1; $c = $b.c; $o = $b.o; $h = $b.h; $l = $b.l; $v = $b.v
    $k = 2.0 / 201; $ema = New-Object 'double[]' $n; $ema[0] = $c[0]; for ($q = 1; $q -lt $n; $q++) { $ema[$q] = $c[$q] * $k + $ema[$q - 1] * (1 - $k) }
    if (-not ($c[$i] -gt $ema[$i] -and $c[$i - 1] -le $ema[$i - 1])) { return $null }
    $sv = 0.0; for ($q = $i - 20; $q -lt $i; $q++) { $sv += $v[$q] }; $av = $sv / 20; if ($av -le 0) { return $null }; $vr = $v[$i] / $av; if ($vr -lt 1.5) { return $null }
    $rng = $h[$i] - $l[$i]; if ($rng -le 0) { return $null }; $pos = ($c[$i] - $l[$i]) / $rng; if (-not ($c[$i] -gt $o[$i] -and $pos -ge 0.6)) { return $null }
    $up = 0.0; $dn = 0.0; for ($q = $i - 4; $q -le $i; $q++) { if ($c[$q] -ge $o[$q]) { $up += $v[$q] } else { $dn += $v[$q] } }; if ($up -le $dn) { return $null }
    $st = 0.0; for ($q = $i - 14; $q -lt $i; $q++) { $st += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $st / 14; if ($atr -gt 0 -and ($c[$i] - $ema[$i]) -gt 1.5 * $atr) { return $null }
    $rsi = (Mkt-Rsi $c)[$i]; $wk = $null; try { $W = Mkt-Weekly $b; $wk = Mkt-WeeklyContext $W $c[$i] } catch {}
    return @{ tkr = $b.tkr; px = $c[$i]; ema = $ema[$i]; vr = $vr; pos = $pos; rsi = $rsi; upDn = ($up / [Math]::Max($dn, 1)); wk = $wk; barTime = $b.t[$i] }
}
function Build-Ema200Message($b, $x) {
    $kind = if ($b.kind -eq "ETF") { "ETF" } elseif ($b.kind -eq "INDEX") { "ÍNDICE" } elseif ($b.kind -in "CURRENCY", "FUTURE", "CRYPTOCURRENCY") { "$($b.kind)" } else { "ACCIÓN" }
    $L = @(); $L += ("📈 ROMPE LA EMA200 AL ALZA · {0} · {1}" -f $x.tkr, $kind); if ($b.name -and $b.name -ne $x.tkr) { $L += "   $($b.name)" }
    $L += ("Cierre diario {0} sobre la EMA200 ({1}), +{2:N1}% por encima; el día anterior cerró por debajo." -f (MktF $x.px $b.cur), (MktF $x.ema $b.cur), (($x.px / $x.ema - 1) * 100))
    $L += ("Volumen {0:N1}x la media de 20 sesiones · vela alcista cerrando en el {1:N0}% alto del rango · RSI {2:N0}" -f $x.vr, ($x.pos * 100), $x.rsi)
    if ($x.wk -and $x.wk.ok) { $L += ("Tendencia semanal: {0} · estructura semanal: {1}" -f $(switch ($x.wk.trend) { 'up' { 'alcista' } 'down' { 'bajista' } default { 'lateral' } }), $(switch ($x.wk.struct) { 'up' { 'alcista' } 'down' { 'bajista' } default { 'mixta' } })); if ($null -ne $x.wk.resLv) { $L += ("Primera resistencia semanal: {0} ({1:+0.0;-0.0}%)" -f (MktF $x.wk.resLv $b.cur), (($x.wk.resLv / $x.px - 1) * 100)) } }
    $L += ""; $L += "⚠️ AVISO INFORMATIVO, NO ES UNA SEÑAL DE ENTRADA (sin SL ni TP). En el histórico (348 activos, ~10 años) este patrón, incluso con volumen comprador, solo llegó a su primer objetivo en el 54% de los casos con una ventaja media de +0,1R: casi una moneda al aire. Úsalo como contexto y confírmalo con /informe $($x.tkr) o /momento $($x.tkr)."
    return ($L -join "`n")
}
function MktF($x, $cur) { if ($x -ge 100) { return ("{0:N2}" -f $x) } elseif ($x -ge 1) { return ("{0:N3}" -f $x) } else { return ("{0:G5}" -f $x) } }
function Build-MktMessage($b, $s) {      # señal COMPACTA: puntuación, entrada, apalancamiento orientativo, SL y TP. El detalle se pide con /informe SIMBOLO.
    $sg = $s.side; $slPct = [Math]::Abs($s.sl / $s.entry - 1) * 100
    $kind = if ($b.kind -eq "ETF") { "ETF" } else { "accion" }
    $score = Get-SignalScore $b.tkr $kind $sg ([double]$s.px) $b.exch
    return (Format-CompactSignal $sg ("{0} · 1d" -f $b.tkr) $score $s.entry $true (Get-SuggestedLev $slPct $kind) $s.sl $s.tp1 $s.tp2 $s.tp3 $kind '1d')
}
# ---------- barrido diario del universo ----------
function Scan-Market([switch]$Dry) {
    $found = 0; $scanned = 0; $mkt = $null; $script:Ema200Sent = 0
    foreach ($tkr in $script:UniTodos) {
        if (($script:cmdTick++ % 10) -eq 0) { try { Poll-Commands } catch {} }
        $b = Get-MktBars $tkr; Start-Sleep -Milliseconds 120; if (-not $b) { continue }; $scanned++
        try { $ex = Get-Ema200Cross $b      # aviso informativo (una vez por sesión: el barrido diario corre una sola vez al día)
            if ($ex) { $em = Build-Ema200Message $b $ex; if ($Dry) { $script:MktDryOut += ,@($tkr, $em) } elseif ($script:MktChat -and $TelegramToken -and $script:Ema200Sent -lt 8) { Send-Tg $TelegramToken $script:MktChat $em $null; $script:Ema200Sent++ } }
        } catch {}
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
    $resumen = "🌍 Escaneo diario de mercado (acciones y ETFs, velas diarias) completado: $($script:MktLastScanned) activos analizados, $found señal(es) nueva(s) enviada(s) al grupo Alertas Mercados y $($script:Ema200Sent) aviso(s) informativo(s) de ruptura de la EMA200."
    if ($script:MktLastScanned -lt 100) { $resumen += " ⚠️ Pocos activos respondieron (Yahoo Finance puede estar limitando): revisa mañana."; }
    try { Send-ToSignalChats $resumen } catch {}
    if (-not (Get-ReportState "mercadook") -and $script:MktLastScanned -ge 100) {
        Set-ReportState "mercadook" $today
        try { Send-ToSignalChats "✅ ALERTAS MERCADOS OPERATIVO: el escáner diario de acciones y ETFs se ha ejecutado correctamente en la nube. Desde ahora publica en el grupo cuando aparezca una señal que cumpla las reglas (con pocas señales: la táctica es exigente), y el bot atiende allí /informe, /precio, /riesgo y /momento." } catch {}
    }
}
