# Análisis técnico avanzado (charting, Fibonacci, Bollinger, MACD, ADX, OBV, divergencias, soportes/resistencias) + lectura pública de TradingView.
# Todo se calcula con velas reales; los patrones de charting son HEURÍSTICAS automáticas (hay que confirmarlos en el gráfico). Nada es una garantía.
$script:TaBase = "https://fapi.bitunix.com/api/v1/futures/market"
$script:TaUA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' }
$script:TvH = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'; 'Accept' = 'application/json'; 'Origin' = 'https://www.tradingview.com'; 'Referer' = 'https://www.tradingview.com/' }
function TaFp($x) { if ($x -ge 100) { return ("{0:N2}" -f $x) } elseif ($x -ge 1) { return ("{0:N4}" -f $x) } elseif ($x -ge 0.01) { return ("{0:N5}" -f $x) } else { return (("{0:F10}" -f $x).TrimEnd('0')) } }
function TaMark($ok, $name) { if ($null -ne $script:PlatOK -and $null -ne $script:PlatFail) { if ($ok) { if ($name -notin $script:PlatOK) { $script:PlatOK += $name }; $script:PlatFail = @($script:PlatFail | Where-Object { $_ -ne $name }) } elseif ($name -notin $script:PlatOK -and $name -notin $script:PlatFail) { $script:PlatFail += $name } } }
function TaAvg($pts) { return (($pts | ForEach-Object { $_.p }) | Measure-Object -Average).Average }

# ---------- Velas ----------
function New-Cd($o, $h, $l, $c, $v) { return @{ o = [double[]]$o; h = [double[]]$h; l = [double[]]$l; c = [double[]]$c; v = [double[]]$v; n = @($c).Count } }
function Get-BitunixCd($sym, $tf) {
    try {
        $k = @((Invoke-RestMethod "$($script:TaBase)/kline?symbol=${sym}USDT&interval=$tf&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); if ($k.Count -lt 40) { return $null }
        $k = @($k[0..($k.Count - 2)])
        return (New-Cd ($k | ForEach-Object { [double]$_.open }) ($k | ForEach-Object { [double]$_.high }) ($k | ForEach-Object { [double]$_.low }) ($k | ForEach-Object { [double]$_.close }) ($k | ForEach-Object { if ($_.baseVol) { [double]$_.baseVol } else { [double]$_.volume } }))
    } catch { return $null }
}
function Get-YahooCd($tkr, $tf) {
    try {
        $rng = if ($tf -eq '1d') { "1y" } else { "3mo" }; $int = if ($tf -eq '1d') { "1d" } else { "1h" }
        $res = (Invoke-RestMethod ("https://query1.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($tkr) + "?range=$rng&interval=$int") -Headers $script:TaUA -TimeoutSec 25).chart.result[0]
        $q = $res.indicators.quote[0]; $idx = @(0..($res.timestamp.Count - 1) | Where-Object { $null -ne $q.close[$_] -and $null -ne $q.high[$_] -and $null -ne $q.low[$_] -and $null -ne $q.open[$_] })
        if ($idx.Count -lt 40) { return $null }
        $o = @($idx | ForEach-Object { [double]$q.open[$_] }); $h = @($idx | ForEach-Object { [double]$q.high[$_] }); $l = @($idx | ForEach-Object { [double]$q.low[$_] }); $c = @($idx | ForEach-Object { [double]$q.close[$_] }); $v = @($idx | ForEach-Object { [double]$q.volume[$_] })
        if ($tf -eq '4h') {      # velas de 4 sesiones horarias consecutivas
            $no = @(); $nh = @(); $nl = @(); $nc = @(); $nv = @()
            for ($i = 0; $i + 3 -lt $o.Count; $i += 4) { $no += $o[$i]; $nh += ($h[$i..($i + 3)] | Measure-Object -Maximum).Maximum; $nl += ($l[$i..($i + 3)] | Measure-Object -Minimum).Minimum; $nc += $c[$i + 3]; $nv += ($v[$i..($i + 3)] | Measure-Object -Sum).Sum }
            if ($no.Count -lt 40) { return $null }; return (New-Cd $no $nh $nl $nc $nv)
        }
        return (New-Cd $o $h $l $c $v)
    } catch { return $null }
}
function Get-BinanceSpotCd($sym, $tf) {                         # respaldo para cripto sin par en Bitunix (data-api.binance.vision no se bloquea desde EE. UU.)
    $sym = "$sym".ToUpper()
    foreach ($host1 in 'https://data-api.binance.vision', 'https://api.binance.com') {
        try {
            $raw = (Invoke-WebRequest "$host1/api/v3/klines?symbol=${sym}USDT&interval=$tf&limit=200" -UseBasicParsing -Headers $script:TaUA -TimeoutSec 20).Content
            $r = $raw | ConvertFrom-Json; if (@($r).Count -lt 40) { continue }
            $r = @($r[0..($r.Count - 2)])
            return (New-Cd ($r | ForEach-Object { [double]$_[1] }) ($r | ForEach-Object { [double]$_[2] }) ($r | ForEach-Object { [double]$_[3] }) ($r | ForEach-Object { [double]$_[4] }) ($r | ForEach-Object { [double]$_[5] }))
        } catch {}
    }
    return $null
}
function Get-GeckoCd($id) {
    try {
        $r = @(Invoke-RestMethod "https://api.coingecko.com/api/v3/coins/$id/ohlc?vs_currency=usd&days=30" -Headers $script:TaUA -TimeoutSec 25); if ($r.Count -lt 40) { return $null }
        $r = @($r[0..($r.Count - 2)]); return (New-Cd ($r | ForEach-Object { $_[1] }) ($r | ForEach-Object { $_[2] }) ($r | ForEach-Object { $_[3] }) ($r | ForEach-Object { $_[4] }) ($r | ForEach-Object { 1.0 }))
    } catch { return $null }
}

# ---------- Indicadores ----------
function TaEma($v, $n) { $k = 2.0 / ($n + 1); $o = @(); $e = $v[0]; foreach ($x in $v) { $e = $x * $k + $e * (1 - $k); $o += $e }; return $o }
function TaRsi($c, $n = 14) {
    $o = @(); $g = 0.0; $ls = 0.0
    for ($i = 1; $i -lt $c.Count; $i++) {
        $d = $c[$i] - $c[$i - 1]; $up = [Math]::Max($d, 0); $dn = [Math]::Max(-$d, 0)
        if ($i -le $n) { $g += $up / $n; $ls += $dn / $n } else { $g = ($g * ($n - 1) + $up) / $n; $ls = ($ls * ($n - 1) + $dn) / $n }
        $o += $(if ($i -lt $n) { 50.0 } elseif ($ls -eq 0) { 100.0 } else { 100 - 100 / (1 + $g / $ls) })
    }
    return @(50.0) + $o
}
function TaAtrArr($h, $l, $c, $n = 14) {
    $tr = @($h[0] - $l[0]); for ($i = 1; $i -lt $c.Count; $i++) { $tr += [Math]::Max($h[$i] - $l[$i], [Math]::Max([Math]::Abs($h[$i] - $c[$i - 1]), [Math]::Abs($l[$i] - $c[$i - 1]))) }
    $o = @(); $a = $tr[0]; for ($i = 0; $i -lt $tr.Count; $i++) { $a = if ($i -lt $n) { ($a * $i + $tr[$i]) / ($i + 1) } else { ($a * ($n - 1) + $tr[$i]) / $n }; $o += $a }; return $o
}
function TaAdx($h, $l, $c, $n = 14) {
    $atr = TaAtrArr $h $l $c $n; $pdm = @(0.0); $mdm = @(0.0)
    for ($i = 1; $i -lt $c.Count; $i++) { $up = $h[$i] - $h[$i - 1]; $dn = $l[$i - 1] - $l[$i]; $pdm += $(if ($up -gt $dn -and $up -gt 0) { $up } else { 0.0 }); $mdm += $(if ($dn -gt $up -and $dn -gt 0) { $dn } else { 0.0 }) }
    $sp = TaEma $pdm $n; $sm = TaEma $mdm $n
    $pdi = @(); $mdi = @(); $dx = @()
    for ($i = 0; $i -lt $c.Count; $i++) { $a = [Math]::Max($atr[$i], 1e-12); $p = 100 * $sp[$i] / $a; $m = 100 * $sm[$i] / $a; $pdi += $p; $mdi += $m; $dx += $(if ($p + $m -eq 0) { 0.0 } else { 100 * [Math]::Abs($p - $m) / ($p + $m) }) }
    $adx = TaEma $dx $n
    return @{ adx = $adx[-1]; pdi = $pdi[-1]; mdi = $mdi[-1] }
}
function TaBoll($c, $n = 20, $k = 2.0) {                       # últimas bandas y percentil del ancho (últimas 100 velas)
    $bw = @(); $last = $null
    for ($i = $n - 1; $i -lt $c.Count; $i++) {
        $w = $c[($i - $n + 1)..$i]; $m = ($w | Measure-Object -Average).Average; $sd = [Math]::Sqrt((($w | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Sum).Sum / $n)
        $bw += (2 * $k * $sd / $m * 100); $last = @{ mid = $m; up = $m + $k * $sd; lo = $m - $k * $sd }
    }
    $rec = @($bw | Select-Object -Last 100); $cur = $rec[-1]; $pct = 100.0 * @($rec | Where-Object { $_ -le $cur }).Count / $rec.Count
    return @{ mid = $last.mid; up = $last.up; lo = $last.lo; widthPct = $cur; widthPctile = $pct }
}
function TaPivots($h, $l, $n = 3) {
    $p = @(); for ($i = $n; $i -lt $h.Count - $n; $i++) {
        $isH = $true; $isL = $true
        foreach ($j in ($i - $n)..($i + $n)) { if ($j -eq $i) { continue }; if ($h[$j] -ge $h[$i]) { $isH = $false }; if ($l[$j] -le $l[$i]) { $isL = $false } }
        if ($isH) { $p += @{ i = $i; p = $h[$i]; t = 'H' } }; if ($isL) { $p += @{ i = $i; p = $l[$i]; t = 'L' } }
    }
    return $p
}
function TaSlope($pts) {                                        # pendiente por vela (regresión lineal) de una lista de pivotes
    $n = $pts.Count; $sx = 0.0; $sy = 0.0; $sxy = 0.0; $sxx = 0.0
    foreach ($q in $pts) { $sx += $q.i; $sy += $q.p; $sxy += $q.i * $q.p; $sxx += $q.i * $q.i }
    $d = $n * $sxx - $sx * $sx; if ($d -eq 0) { return 0.0 }; return ($n * $sxy - $sx * $sy) / $d
}

# ---------- Fibonacci ----------
function TaFib($cd, $lb) {
    $n = $cd.n; $from = [Math]::Max(0, $n - $lb); $hh = $cd.h[$from..($n - 1)]; $ll = $cd.l[$from..($n - 1)]
    $hi = ($hh | Measure-Object -Maximum).Maximum; $lo = ($ll | Measure-Object -Minimum).Minimum; $iH = [array]::IndexOf($hh, $hi); $iL = [array]::IndexOf($ll, $lo)
    $up = ($iL -lt $iH); $rg = $hi - $lo; if ($rg -le 0) { return $null }
    $lv = @(); foreach ($r in 0.236, 0.382, 0.5, 0.618, 0.786) { $lv += @{ n = ("{0:N1}%" -f ($r * 100)); p = $(if ($up) { $hi - $rg * $r } else { $lo + $rg * $r }); kind = 'ret' } }
    foreach ($r in 1.272, 1.618) { $lv += @{ n = ("ext {0:N1}%" -f ($r * 100)); p = $(if ($up) { $lo + $rg * $r } else { $hi - $rg * $r }); kind = 'ext' } }
    return @{ up = $up; hi = $hi; lo = $lo; levels = $lv }
}

# ---------- Análisis de una temporalidad ----------
function Analyze-TF($cd, $tfLabel, $fibLb) {
    if (-not $cd -or $cd.n -lt 50) { return $null }
    $c = $cd.c; $h = $cd.h; $l = $cd.l; $px = $c[-1]
    $atrA = TaAtrArr $h $l $c 14; $atr = $atrA[-1]; $piv = TaPivots $h $l 3
    $ph = @($piv | Where-Object { $_.t -eq 'H' }); $pl = @($piv | Where-Object { $_.t -eq 'L' })
    $o = @{ tf = $tfLabel; px = $px; atr = $atr; lines = @(); res = @(); sup = @(); patterns = @(); fib = $null; boll = $null }
    # estructura
    $st = "sin estructura clara"; $sstate = "flat"; $bos = $null
    if ($ph.Count -ge 2 -and $pl.Count -ge 2) {
        $hiUp = $ph[-1].p -gt $ph[-2].p; $loUp = $pl[-1].p -gt $pl[-2].p
        $st = if ($hiUp -and $loUp) { "máximos y mínimos crecientes (alcista)" } elseif (-not $hiUp -and -not $loUp) { "máximos y mínimos decrecientes (bajista)" } elseif ($hiUp -and -not $loUp) { "máximos crecientes pero mínimos decrecientes (expansión/transición)" } else { "máximos decrecientes con mínimos crecientes (compresión)" }
        $sstate = if ($hiUp -and $loUp) { "up" } elseif (-not $hiUp -and -not $loUp) { "down" } else { "flat" }
        if ($px -gt $ph[-1].p) { $st += " · ruptura de estructura al alza"; $bos = "up" } elseif ($px -lt $pl[-1].p) { $st += " · ruptura de estructura a la baja"; $bos = "down" }
    }
    $adx = TaAdx $h $l $c 14
    $fuerza = if ($adx.adx -ge 30) { "tendencia fuerte" } elseif ($adx.adx -ge 20) { "tendencia moderada" } else { "sin tendencia (rango)" }
    $o.lines += ("▸ {0} · estructura: {1} · ADX {2:N0} ({3}, {4})" -f $tfLabel, $st, $adx.adx, $fuerza, $(if ($adx.pdi -gt $adx.mdi) { "domina el comprador" } else { "domina el vendedor" }))
    # Bollinger
    $bb = TaBoll $c 20 2.0; $o.boll = $bb; $pb = ($px - $bb.lo) / [Math]::Max($bb.up - $bb.lo, 1e-12) * 100
    $bpos = if ($px -gt $bb.up) { "FUERA de la banda superior (extensión)" } elseif ($px -lt $bb.lo) { "FUERA de la banda inferior (extensión)" } elseif ($pb -ge 80) { "cerca de la banda superior" } elseif ($pb -le 20) { "cerca de la banda inferior" } else { "zona media" }
    $bsq = if ($bb.widthPctile -le 20) { "compresión (ancho en el percentil {0:N0}): suele preceder a una expansión de volatilidad, sin indicar dirección" -f $bb.widthPctile } elseif ($bb.widthPctile -ge 85) { "volatilidad ya expandida (percentil {0:N0})" -f $bb.widthPctile } else { "ancho normal (percentil {0:N0})" -f $bb.widthPctile }
    $o.lines += ("   Bollinger(20,2): precio al {0:N0}% de la banda ({1}) · bandas {2} - {3} · {4}" -f $pb, $bpos, (TaFp $bb.lo), (TaFp $bb.up), $bsq)
    # MACD y RSI
    $e12 = TaEma $c 12; $e26 = TaEma $c 26; $macd = @(); for ($i = 0; $i -lt $c.Count; $i++) { $macd += ($e12[$i] - $e26[$i]) }; $sig = TaEma $macd 9
    $hist = @(); for ($i = 0; $i -lt $c.Count; $i++) { $hist += ($macd[$i] - $sig[$i]) }
    $cross = ""; for ($j = 1; $j -le 6; $j++) { $a = $hist[-$j]; $b = $hist[-$j - 1]; if ($a -gt 0 -and $b -le 0) { $cross = "cruce alcista hace $($j - 1) vela(s)"; break } elseif ($a -lt 0 -and $b -ge 0) { $cross = "cruce bajista hace $($j - 1) vela(s)"; break } }
    $rs = TaRsi $c 14; $rsiV = $rs[-1]; $obvState = $null
    $div = ""
    if ($pl.Count -ge 2 -and ($c.Count - $pl[-1].i) -le 40) { $a = $pl[-2]; $b = $pl[-1]; if ($b.p -lt $a.p -and $rs[$b.i] -gt $rs[$a.i] + 2) { $div = " · divergencia ALCISTA RSI (precio hace mínimo más bajo, RSI más alto)" } }
    if ($ph.Count -ge 2 -and ($c.Count - $ph[-1].i) -le 40) { $a = $ph[-2]; $b = $ph[-1]; if ($b.p -gt $a.p -and $rs[$b.i] -lt $rs[$a.i] - 2) { $div = " · divergencia BAJISTA RSI (precio hace máximo más alto, RSI más bajo)" } }
    $o.lines += ("   MACD: histograma {0} y {1}{2} · RSI {3:N0}{4}" -f $(if ($hist[-1] -gt 0) { "positivo" } else { "negativo" }), $(if ($hist[-1] -gt $hist[-2]) { "creciente" } else { "decreciente" }), $(if ($cross) { " ($cross)" } else { "" }), $rsiV, $div)
    # OBV
    if (($cd.v | Measure-Object -Maximum).Maximum -gt 1) {
        $obv = @(0.0); for ($i = 1; $i -lt $c.Count; $i++) { $obv += $obv[-1] + $(if ($c[$i] -gt $c[$i - 1]) { $cd.v[$i] } elseif ($c[$i] -lt $c[$i - 1]) { -$cd.v[$i] } else { 0.0 }) }
        $kk = 20; $pUp = $c[-1] -gt $c[-1 - $kk]; $oUp = $obv[-1] -gt $obv[-1 - $kk]; $obvState = $(if ($pUp -eq $oUp) { "confirma" } elseif ($pUp) { "div-bajista" } else { "div-alcista" })
        $o.lines += ("   Volumen (OBV, {0} velas): {1}" -f $kk, $(if ($pUp -eq $oUp) { "acompaña al precio (confirma el movimiento)" } elseif ($pUp) { "DIVERGENCIA bajista: el precio sube y el volumen neto cae" } else { "DIVERGENCIA alcista: el precio baja y el volumen neto sube" }))
    }
    # Fibonacci
    $fib = TaFib $cd $fibLb; $o.fib = $fib
    if ($fib) {
        $ret = @($fib.levels | Where-Object { $_.kind -eq 'ret' }); $ext = @($fib.levels | Where-Object { $_.kind -eq 'ext' })
        $sorted = @($ret | Sort-Object { $_.p }); $below = @($sorted | Where-Object { $_.p -le $px } | Select-Object -Last 1); $above = @($sorted | Where-Object { $_.p -gt $px } | Select-Object -First 1)
        if ($below -and $above) { $posTxt = "precio entre {0} ({1}) y {2} ({3})" -f $below[0].n, (TaFp $below[0].p), $above[0].n, (TaFp $above[0].p) }
        elseif ($below) { $posTxt = "precio por encima de todos los retrocesos (sobre {0} {1}: retroceso leve, cerca del extremo del impulso)" -f $below[0].n, (TaFp $below[0].p) }
        else { $posTxt = "precio por debajo de todos los retrocesos (bajo {0} {1}: retroceso casi completo)" -f $above[0].n, (TaFp $above[0].p) }
        $gp = ""; $g618 = ($ret | Where-Object { $_.n -like '61,8*' -or $_.n -like '61.8*' } | Select-Object -First 1); if ($g618 -and [Math]::Abs($px - $g618.p) / $px -lt 0.008) { $gp = " · EN la zona 61,8% (la 'golden pocket' de Fibonacci)" }
        $o.lines += ("   Fibonacci (swing {0} {1} → {2}): {3} · extensiones {4}{5}" -f $(if ($fib.up) { "alcista" } else { "bajista" }), (TaFp $(if ($fib.up) { $fib.lo } else { $fib.hi })), (TaFp $(if ($fib.up) { $fib.hi } else { $fib.lo })), $posTxt, (($ext | ForEach-Object { "{0} {1}" -f $_.n, (TaFp $_.p) }) -join " · "), $gp)
        $o.lines += ("     Retrocesos: " + (($ret | ForEach-Object { "{0} {1}" -f $_.n, (TaFp $_.p) }) -join " · "))
    }
    # Soportes y resistencias por clusters de pivotes
    $tol = 0.6 * $atr; $cls = @()
    foreach ($q in $piv) { $placed = $false; foreach ($g in $cls) { if ([Math]::Abs($g.p - $q.p) -le $tol) { $g.p = ($g.p * $g.n + $q.p) / ($g.n + 1); $g.n++; $placed = $true; break } }; if (-not $placed) { $cls += @{ p = $q.p; n = 1 } } }
    $o.res = @($cls | Where-Object { $_.p -gt $px } | Sort-Object { $_.p } | Select-Object -First 3); $o.sup = @($cls | Where-Object { $_.p -lt $px } | Sort-Object { $_.p } -Descending | Select-Object -First 3)
    $fmtLv = { param($arr) if ($arr.Count) { ($arr | ForEach-Object { "{0} ({1} toque{2})" -f (TaFp $_.p), $_.n, $(if ($_.n -gt 1) { "s" } else { "" }) }) -join " · " } else { "ninguno cercano" } }
    $o.lines += ("   Soportes: {0} · Resistencias: {1}" -f (& $fmtLv $o.sup), (& $fmtLv $o.res))
    # Mapa de liquidez: EQH/EQL (>=2 pivotes a menos de 0,25 ATR = stops acumulados) + estructura interna (máximos/mínimos menores) + barrido reciente a la espera de confirmación
    $pv2 = @(TaPivots $h $l 2 | Where-Object { $_.i -ge $c.Count - 60 }); $lq = @()
    foreach ($q in $pv2) { $placed = $false; foreach ($g in $lq) { if ($g.t -eq $q.t -and [Math]::Abs($g.p - $q.p) -le 0.25 * $atr) { $g.p = ($g.p * $g.n + $q.p) / ($g.n + 1); $g.n++; $placed = $true; break } }; if (-not $placed) { $lq += @{ p = $q.p; n = 1; t = $q.t } } }
    $eqh = @($lq | Where-Object { $_.t -eq 'H' -and $_.n -ge 2 -and $_.p -gt $px } | Sort-Object { $_.p } | Select-Object -First 1); $eql = @($lq | Where-Object { $_.t -eq 'L' -and $_.n -ge 2 -and $_.p -lt $px } | Sort-Object { $_.p } -Descending | Select-Object -First 1)
    $inH = @($lq | Where-Object { $_.t -eq 'H' -and $_.n -eq 1 -and $_.p -gt $px } | Sort-Object { $_.p } | Select-Object -First 1); $inL = @($lq | Where-Object { $_.t -eq 'L' -and $_.n -eq 1 -and $_.p -lt $px } | Sort-Object { $_.p } -Descending | Select-Object -First 1)
    $liqTxt = @()
    if ($eqh) { $liqTxt += ("EQH {0} ({1} toques, {2:+0.0;-0.0}%: stops de cortos por encima)" -f (TaFp $eqh[0].p), $eqh[0].n, (($eqh[0].p / $px - 1) * 100)) }
    if ($eql) { $liqTxt += ("EQL {0} ({1} toques, {2:+0.0;-0.0}%: stops de largos por debajo)" -f (TaFp $eql[0].p), $eql[0].n, (($eql[0].p / $px - 1) * 100)) }
    if ($inH -or $inL) { $liqTxt += ("estructura interna: " + $(if ($inH) { "máx. " + (TaFp $inH[0].p) } else { "" }) + $(if ($inH -and $inL) { " / " } else { "" }) + $(if ($inL) { "mín. " + (TaFp $inL[0].p) } else { "" })) }
    $o.liq = @(); $o.liq += $(if ($liqTxt.Count) { "   Liquidez: " + ($liqTxt -join " · ") } else { "   Liquidez: sin máximos/mínimos iguales claros cerca del precio." })
    $n2 = $c.Count; $sw = $null
    for ($m = $n2 - 1; $m -ge $n2 - 3 -and -not $sw; $m--) {
        if ($m - 31 -lt 0) { break }; $win = ($m - 30)..($m - 1); $pHm = ($win | ForEach-Object { $h[$_] } | Measure-Object -Maximum).Maximum; $pLm = ($win | ForEach-Object { $l[$_] } | Measure-Object -Minimum).Minimum
        $rgm = $h[$m] - $l[$m]; if ($rgm -le 0) { continue }; $age = $n2 - 1 - $m
        $touchH = @($win | Where-Object { $h[$_] -ge $pHm - 0.25 * $atr }).Count; $touchL = @($win | Where-Object { $l[$_] -le $pLm + 0.25 * $atr }).Count
        if ($h[$m] -gt $pHm + 0.05 * $atr -and $h[$m] -le $pHm + 1.5 * $atr -and $c[$m] -lt $pHm -and ($h[$m] - [Math]::Max($cd.o[$m], $c[$m])) / $rgm -ge 0.5) {
            $edge = [Math]::Min($cd.o[$m], $c[$m]); $conf = $false; for ($z = $m + 1; $z -lt $n2; $z++) { if ($c[$z] -lt $edge) { $conf = $true } }
            $sw = "⚠️ BARRIDO de máximos en {0} hace {1} vela(s) (rompió {2}{3}); {4}" -f $tfLabel, $age, (TaFp $pHm), $(if ($touchH -ge 2) { ", $touchH toques = liquidez igual" } else { "" }), $(if ($conf) { "CONFIRMADO: cerró por debajo de " + (TaFp $edge) + " → posible búsqueda del extremo opuesto " + (TaFp $pLm) + " (invalidado si supera " + (TaFp $h[$m]) + ")" } else { "aún SIN confirmar: no anticiparse; confirma un cierre por debajo de " + (TaFp $edge) + " (invalidado si supera " + (TaFp $h[$m]) + ")" })
        } elseif ($l[$m] -lt $pLm - 0.05 * $atr -and $l[$m] -ge $pLm - 1.5 * $atr -and $c[$m] -gt $pLm -and ([Math]::Min($cd.o[$m], $c[$m]) - $l[$m]) / $rgm -ge 0.5) {
            $edge = [Math]::Max($cd.o[$m], $c[$m]); $conf = $false; for ($z = $m + 1; $z -lt $n2; $z++) { if ($c[$z] -gt $edge) { $conf = $true } }
            $sw = "⚠️ BARRIDO de mínimos en {0} hace {1} vela(s) (rompió {2}{3}); {4}" -f $tfLabel, $age, (TaFp $pLm), $(if ($touchL -ge 2) { ", $touchL toques = liquidez igual" } else { "" }), $(if ($conf) { "CONFIRMADO: cerró por encima de " + (TaFp $edge) + " → posible búsqueda del extremo opuesto " + (TaFp $pHm) + " (invalidado si pierde " + (TaFp $l[$m]) + ")" } else { "aún SIN confirmar: no anticiparse; confirma un cierre por encima de " + (TaFp $edge) + " (invalidado si pierde " + (TaFp $l[$m]) + ")" })
        }
    }
    if ($sw) { $o.liq += "   $sw" }
    $o.lines += $o.liq
    # Patrones de charting (heurísticas)
    $pat = @(); $recH = @($ph | Select-Object -Last 4); $recL = @($pl | Select-Object -Last 4)
    if ($ph.Count -ge 2) { $a = $ph[-2]; $b = $ph[-1]; $between = @($pl | Where-Object { $_.i -gt $a.i -and $_.i -lt $b.i }); if ([Math]::Abs($a.p - $b.p) / $a.p -le 0.012 -and ($b.i - $a.i) -ge 5 -and $between.Count) { $nk = (($between | ForEach-Object { $_.p }) | Measure-Object -Minimum).Minimum; $pat += $(if ($px -lt $nk) { "doble techo CONFIRMADO (rompió el cuello {0}; objetivo teórico ≈ {1})" -f (TaFp $nk), (TaFp ($nk - ($a.p - $nk))) } else { "posible doble techo en {0}-{1} (se confirma al perder {2})" -f (TaFp $a.p), (TaFp $b.p), (TaFp $nk) }) } }
    if ($pl.Count -ge 2) { $a = $pl[-2]; $b = $pl[-1]; $between = @($ph | Where-Object { $_.i -gt $a.i -and $_.i -lt $b.i }); if ([Math]::Abs($a.p - $b.p) / $a.p -le 0.012 -and ($b.i - $a.i) -ge 5 -and $between.Count) { $nk = (($between | ForEach-Object { $_.p }) | Measure-Object -Maximum).Maximum; $pat += $(if ($px -gt $nk) { "doble suelo CONFIRMADO (rompió el cuello {0}; objetivo teórico ≈ {1})" -f (TaFp $nk), (TaFp ($nk + ($nk - $a.p))) } else { "posible doble suelo en {0}-{1} (se confirma al superar {2})" -f (TaFp $a.p), (TaFp $b.p), (TaFp $nk) }) } }
    if ($ph.Count -ge 3) { $s1 = $ph[-3]; $hd = $ph[-2]; $s2 = $ph[-1]; if ($hd.p -gt $s1.p * 1.01 -and $hd.p -gt $s2.p * 1.01 -and [Math]::Abs($s1.p - $s2.p) / $hd.p -le 0.03) { $pat += ("posible hombro-cabeza-hombro (cabeza {0}, hombros ≈{1}): patrón de giro bajista si pierde el cuello" -f (TaFp $hd.p), (TaFp (($s1.p + $s2.p) / 2))) } }
    if ($pl.Count -ge 3) { $s1 = $pl[-3]; $hd = $pl[-2]; $s2 = $pl[-1]; if ($hd.p -lt $s1.p * 0.99 -and $hd.p -lt $s2.p * 0.99 -and [Math]::Abs($s1.p - $s2.p) / $hd.p -le 0.03) { $pat += ("posible hombro-cabeza-hombro INVERTIDO (cabeza {0}): patrón de giro alcista si supera el cuello" -f (TaFp $hd.p)) } }
    if ($recH.Count -ge 3 -and $recL.Count -ge 3) {
        $slH = (TaSlope $recH) / $atr; $slL = (TaSlope $recL) / $atr; $flat = 0.04
        $fH = if ([Math]::Abs($slH) -le $flat) { 0 } elseif ($slH -gt 0) { 1 } else { -1 }; $fL = if ([Math]::Abs($slL) -le $flat) { 0 } elseif ($slL -gt 0) { 1 } else { -1 }
        $name = $null
        if ($fH -eq 0 -and $fL -eq 0) { $name = "rango lateral entre {0} y {1} (la ruptura de cualquiera de los extremos marca la dirección)" -f (TaFp (TaAvg $recL)), (TaFp (TaAvg $recH)) }
        elseif ($fH -eq 0 -and $fL -eq 1) { $name = "triángulo ascendente (techo plano ≈{0}, mínimos crecientes): sesgo alcista si rompe el techo" -f (TaFp (TaAvg $recH)) }
        elseif ($fH -eq -1 -and $fL -eq 0) { $name = "triángulo descendente (suelo plano ≈{0}, máximos decrecientes): sesgo bajista si pierde el suelo" -f (TaFp (TaAvg $recL)) }
        elseif ($fH -eq -1 -and $fL -eq 1) { $name = "triángulo simétrico / compresión (máximos decrecientes y mínimos crecientes): la ruptura define la dirección" }
        elseif ($fH -eq 1 -and $fL -eq 1) { $name = $(if ($slL -gt $slH * 1.4) { "cuña ascendente (sesgo bajista)" } else { "canal alcista" }) }
        elseif ($fH -eq -1 -and $fL -eq -1) { $name = $(if ($slH -lt $slL * 1.4) { "cuña descendente (sesgo alcista)" } else { "canal bajista" }) }
        if ($name) { $pat += $name }
    }
    $o.patterns = $pat
    $o.m = @{ struct = $sstate; bos = $bos; adx = $adx.adx; pdi = $adx.pdi; mdi = $adx.mdi; macd = $hist[-1]; macdUp = ($hist[-1] -gt $hist[-2]); rsi = $rsiV; pctB = $pb; bandPos = $bpos; widthPctile = $bb.widthPctile; obv = $obvState; sweep = $sw; div = $div; ema21 = (TaEma $c 21)[-1] }
    $o.lines += $(if ($pat.Count) { "   Charting (heurística automática; confirmar en el gráfico): " + ($pat -join " | ") } else { "   Charting: sin patrón clásico claro en las últimas velas." })
    return $o
}

# ---------- TradingView ----------
function Get-TvLabel($v) { if ($null -eq $v) { return "n/d" }; $v = [double]$v; if ($v -ge 0.5) { return "Compra fuerte" } elseif ($v -ge 0.1) { return "Compra" } elseif ($v -gt -0.1) { return "Neutral" } elseif ($v -gt -0.5) { return "Venta" } else { return "Venta fuerte" } }
function Get-TvRating($market, $ticker) {
    $tfs = @(@{ k = '1h'; s = '|60' }, @{ k = '4h'; s = '|240' }, @{ k = '1d'; s = '' }, @{ k = '1 semana'; s = '|1W' })
    $cols = @(); foreach ($t in $tfs) { $cols += "Recommend.All$($t.s)"; $cols += "Recommend.MA$($t.s)"; $cols += "Recommend.Other$($t.s)"; $cols += "RSI$($t.s)" }
    try {
        $body = @{ symbols = @{ tickers = @($ticker) }; columns = $cols } | ConvertTo-Json -Depth 4 -Compress
        $r = Invoke-RestMethod -Uri "https://scanner.tradingview.com/$market/scan" -Method Post -ContentType "application/json" -Body $body -Headers $script:TvH -TimeoutSec 20
        if (-not $r.data -or @($r.data).Count -eq 0) { return $null }
        $d = @($r.data[0].d); $out = @(); for ($i = 0; $i -lt $tfs.Count; $i++) { $out += @{ tf = $tfs[$i].k; all = $d[$i * 4]; ma = $d[$i * 4 + 1]; osc = $d[$i * 4 + 2]; rsi = $d[$i * 4 + 3] } }
        return $out
    } catch { return $null }
}
function Resolve-TvTarget($src, $sym, $exch) {                  # devuelve @{ market; ticker; rating; link }
    $sym = "$sym".ToUpper()
    if ($src -in 'bitunix', 'gecko') {
        $cands = @(); if ($src -eq 'bitunix') { $cands += "BITUNIX:${sym}USDT.P" }; $cands += "BINANCE:${sym}USDT"; $cands += "BYBIT:${sym}USDT.P"
        foreach ($t in $cands) { $r = Get-TvRating 'crypto' $t; if ($r) { return @{ market = 'crypto'; ticker = $t; rating = $r; link = "https://www.tradingview.com/chart/?symbol=" + [uri]::EscapeDataString($t) } } }
        return @{ market = 'crypto'; ticker = $cands[0]; rating = $null; link = "https://www.tradingview.com/chart/?symbol=" + [uri]::EscapeDataString($cands[0]) }
    }
    $ex = @(); if ("$exch" -match 'Nas|NMS|NGM|NCM') { $ex += 'NASDAQ' } elseif ("$exch" -match 'NYQ|NYSE|NYS') { $ex += 'NYSE' } elseif ("$exch" -match 'ASE|AMEX|PCX') { $ex += 'AMEX' }; foreach ($e in 'NASDAQ', 'NYSE', 'AMEX') { if ($e -notin $ex) { $ex += $e } }
    if ($sym -notmatch '[.\-=^]') { foreach ($e in $ex) { $t = "${e}:$sym"; $r = Get-TvRating 'america' $t; if ($r) { return @{ market = 'america'; ticker = $t; rating = $r; link = "https://www.tradingview.com/chart/?symbol=" + [uri]::EscapeDataString($t) } } } }
    return @{ market = $null; ticker = $sym; rating = $null; link = "https://www.tradingview.com/chart/?symbol=" + [uri]::EscapeDataString($sym) }
}
function Get-TvLines($tv, [switch]$Short) {
    $L = @()
    if ($tv.rating) {
        TaMark $true "TradingView"
        $L += ("📺 TradingView ({0}) · lectura técnica agregada (medias móviles + osciladores): " -f $tv.ticker) + (($tv.rating | ForEach-Object { "{0}: {1}" -f $_.tf, (Get-TvLabel $_.all) }) -join " · ")
        if (-not $Short) { $L += "   Detalle por temporalidad (medias | osciladores | RSI): " + (($tv.rating | ForEach-Object { "{0}: {1} | {2} | {3:N0}" -f $_.tf, (Get-TvLabel $_.ma), (Get-TvLabel $_.osc), $_.rsi }) -join " · ") }
    } else { TaMark $false "TradingView"; $L += "📺 TradingView: no he podido leer su resumen técnico ahora (su endpoint público no respondió o no cubre este valor)." }
    $L += "   Gráfico en TradingView: $($tv.link)"
    return $L
}

# ---------- Checklist de contexto (principios del usuario): estructura superior, zoom out, base de acumulación, volumen no extremo ----------
# Es INFORMATIVO: en el backtest (98 series) estas condiciones mejoraron la constancia en 4h, pero con muestras pequeñas; se guarda cada resultado para validarlo con señales reales.
function Get-ContextChecklist($sym, $tf, [int]$sg, [double]$entry, [double]$risk, [bool]$baseOk, [double]$ratio) {
    $htf = if ($tf -eq '4h') { '1d' } else { '4h' }; $L = @(); $flags = @{ E = $null; Z = $null; B = $baseOk; V = ($ratio -lt 5) }; $score = 0; $total = 4
    $cdH = Get-BitunixCd $sym $htf
    if ($cdH) {
        $piv = TaPivots $cdH.h $cdH.l 3; $ph = @($piv | Where-Object { $_.t -eq 'H' }); $pl = @($piv | Where-Object { $_.t -eq 'L' })
        if ($ph.Count -ge 2 -and $pl.Count -ge 2) {
            $hu = $ph[-1].p -gt $ph[-2].p; $lu = $pl[-1].p -gt $pl[-2].p; $stt = if ($hu -and $lu) { "up" } elseif (-not $hu -and -not $lu) { "down" } else { "flat" }
            $counter = ($sg -eq 1 -and $stt -eq 'down') -or ($sg -eq -1 -and $stt -eq 'up'); $flags.E = (-not $counter)
            $stTxt = switch ($stt) { "up" { "máximos y mínimos crecientes" } "down" { "máximos y mínimos decrecientes" } default { "estructura mixta/lateral" } }
            $L += $(if ($counter) { "   ⚠️ Estructura $htf EN CONTRA ($stTxt): operar contra la temporalidad mayor reduce la probabilidad" } else { "   ✅ Estructura $htf sin contra ($stTxt)" })
        } else { $L += "   · Estructura ${htf}: sin pivotes suficientes para valorarla" }
        $aH = Analyze-TF $cdH $htf 100
        if ($aH -and $risk -gt 0) {
            $ob = if ($sg -eq 1) { @($aH.res | Where-Object { $_.p -gt $entry } | Sort-Object { $_.p } | Select-Object -First 1) } else { @($aH.sup | Where-Object { $_.p -lt $entry } | Sort-Object { $_.p } -Descending | Select-Object -First 1) }
            if ($ob) { $room = [Math]::Abs($ob[0].p - $entry) / $risk; $flags.Z = ($room -ge 2); $L += $(if ($room -ge 2) { "   ✅ Zoom out: el primer obstáculo en $htf ({0}) está a {1:N1}R, hay espacio para TP2" -f (TaFp $ob[0].p), $room } else { "   ⚠️ Zoom out: hay un obstáculo en $htf ({0}) a solo {1:N1}R de la entrada; el recorrido hacia TP2 queda cortado" -f (TaFp $ob[0].p), $room }) }
            else { $flags.Z = $true; $L += "   ✅ Zoom out: sin obstáculos relevantes en $htf por delante" }
        }
    } else { $L += "   · Zoom out ${htf}: sin velas para valorarlo" }
    $L += $(if ($baseOk) { "   ✅ Acumulación previa: venía de una base lateral estrecha (la ruptura sale de una compresión)" } else { "   · Sin base lateral estrecha previa (la ruptura no sale de una acumulación clara)" })
    $L += $(if ($ratio -lt 5) { "   ✅ Volumen de ruptura x{0:N1}: fuerte pero no extremo" -f $ratio } else { "   ⚠️ Volumen extremo x{0:N1}: puede indicar clímax o distribución" -f $ratio })
    foreach ($k in 'E', 'Z', 'B', 'V') { if ($flags[$k] -eq $true) { $score++ } }
    $tot = 4; if ($null -eq $flags.E) { $tot-- }; if ($null -eq $flags.Z) { $tot-- }
    $code = ($flags.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}{1}" -f $_.Name, $(if ($_.Value -eq $true) { 1 } elseif ($_.Value -eq $false) { 0 } else { "x" }) }) -join ""
    $head = "🧭 CONTEXTO (principios de la estrategia): {0}/{1} condiciones a favor" -f $score, $tot
    return @{ lines = (@($head) + $L + @("   (Informativo: en el backtest estas condiciones mejoraron la constancia en 4h, pero con muestras pequeñas; se registra cada resultado para comprobarlo con señales reales.)")); score = $score; total = $tot; code = $code }
}

# ---------- Secciones ----------
function Get-AdvancedTechSection($s, $tfs = @('4h', '1d')) {   # para /informe: $s = serie del informe (src, sym, exch, id)
    $L = @(); $L += "🧮 ANÁLISIS TÉCNICO AVANZADO (charting, Fibonacci, Bollinger, MACD, ADX, volumen)"
    $any = $false
    foreach ($tf in $tfs) {
        $cd = $null
        if ($s.src -eq 'bitunix') { $cd = Get-BitunixCd $s.sym $tf; if (-not $cd) { $cd = Get-BinanceSpotCd $s.sym $tf } }
        elseif ($s.src -eq 'yahoo') { $cd = Get-YahooCd $s.sym $tf }
        elseif ($s.src -eq 'gecko') { $cd = Get-BinanceSpotCd $s.sym $tf; if (-not $cd -and $tf -eq '4h' -and $s.id) { $cd = Get-GeckoCd $s.id } }
        $lb = if ($tf -eq '1d') { 90 } else { 100 }
        $a = if ($cd) { Analyze-TF $cd $tf $lb } else { $null }
        if ($a) { $any = $true; $L += $a.lines } else { $L += "▸ $tf · sin velas suficientes de la fuente para calcularlo." }
    }
    if ($any) { $L += "   (Los patrones y niveles se calculan automáticamente con las velas; son hipótesis para confirmar en el gráfico, no garantías.)" }
    $tv = Resolve-TvTarget $s.src $s.sym $s.exch
    $L += ""; $L += (Get-TvLines $tv)
    return $L
}
function Get-TradeTechNote($sym, [int]$sg, [double]$en, [double]$sl, [double]$tp, [switch]$Short) {   # /riesgo, señales y operaciones manuales (pares de Bitunix)
    $L = @(); $tfs = @('4h', '1d'); $res = @{}
    foreach ($tf in $tfs) { $cd = Get-BitunixCd $sym $tf; if ($cd) { $res[$tf] = Analyze-TF $cd $tf $(if ($tf -eq '1d') { 90 } else { 100 }) } }
    if ($res.Count -eq 0) { return @("🧮 Análisis técnico: sin velas de Bitunix para ${sym}USDT ahora.") }
    $L += "🧮 ANÁLISIS TÉCNICO (charting, Fibonacci, Bollinger…)"
    foreach ($tf in $tfs) { if ($res[$tf]) { if ($Short) { $L += $res[$tf].lines[0]; $L += $res[$tf].lines[1] } else { $L += $res[$tf].lines } } }
    $supL = @(); $resL = @(); $fibL = @()
    foreach ($tf in $tfs) { if ($res[$tf]) { foreach ($q in $res[$tf].sup) { $supL += @{ p = $q.p; n = $q.n; tf = $tf } }; foreach ($q in $res[$tf].res) { $resL += @{ p = $q.p; n = $q.n; tf = $tf } }; if ($res[$tf].fib) { foreach ($q in $res[$tf].fib.levels) { $fibL += @{ p = $q.p; n = $q.n; tf = $tf } } } } }
    $L += "🎯 Niveles técnicos frente a tu operación:"
    $slProfit = ($sg * ($sl - $en) -ge 0)
    if ($slProfit) { $L += ("   SL {0}: ya está en zona de beneficio (protege ganancia), no necesita apoyarse en un nivel técnico ✅" -f (TaFp $sl)) }
    if ($sg -eq 1) {
        if (-not $slProfit) { $prot = @($supL | Where-Object { $_.p -gt $sl -and $_.p -lt $en } | Sort-Object { $_.p } -Descending | Select-Object -First 1); $L += $(if ($prot) { "   SL {0}: queda por debajo del soporte {1} ({2}, {3} toque(s)) ✅" -f (TaFp $sl), (TaFp $prot[0].p), $prot[0].tf, $prot[0].n } else { "   SL {0}: ⚠️ no hay un soporte relevante entre la entrada y el SL; el stop no se apoya en un nivel técnico." -f (TaFp $sl) }) }
        $first = @($resL | Where-Object { $_.p -gt $en } | Sort-Object { $_.p } | Select-Object -First 1)
        $L += $(if ($first -and $first[0].p -lt $tp) { "   TP {0}: ⚠️ antes hay una resistencia en {1} ({2}, {3} toque(s)); es el primer obstáculo." -f (TaFp $tp), (TaFp $first[0].p), $first[0].tf, $first[0].n } elseif ($first) { "   TP {0}: ✅ queda antes de la primera resistencia relevante ({1})." -f (TaFp $tp), (TaFp $first[0].p) } else { "   TP {0}: sin resistencias relevantes por encima en las velas analizadas." -f (TaFp $tp) })
    } else {
        if (-not $slProfit) { $prot = @($resL | Where-Object { $_.p -lt $sl -and $_.p -gt $en } | Sort-Object { $_.p } | Select-Object -First 1); $L += $(if ($prot) { "   SL {0}: queda por encima de la resistencia {1} ({2}, {3} toque(s)) ✅" -f (TaFp $sl), (TaFp $prot[0].p), $prot[0].tf, $prot[0].n } else { "   SL {0}: ⚠️ no hay una resistencia relevante entre la entrada y el SL; el stop no se apoya en un nivel técnico." -f (TaFp $sl) }) }
        $first = @($supL | Where-Object { $_.p -lt $en } | Sort-Object { $_.p } -Descending | Select-Object -First 1)
        $L += $(if ($first -and $first[0].p -gt $tp) { "   TP {0}: ⚠️ antes hay un soporte en {1} ({2}, {3} toque(s)); es el primer obstáculo." -f (TaFp $tp), (TaFp $first[0].p), $first[0].tf, $first[0].n } elseif ($first) { "   TP {0}: ✅ queda antes del primer soporte relevante ({1})." -f (TaFp $tp), (TaFp $first[0].p) } else { "   TP {0}: sin soportes relevantes por debajo en las velas analizadas." -f (TaFp $tp) })
    }
    foreach ($pair in @(@('TP', $tp), @('SL', $sl), @('entrada', $en))) {
        $near = @($fibL | Where-Object { [Math]::Abs($_.p - $pair[1]) / $pair[1] -le 0.005 } | Sort-Object { [Math]::Abs($_.p - $pair[1]) } | Select-Object -First 1)
        if ($near) { $L += ("   Fibonacci: tu {0} ({1}) coincide con el nivel {2} de {3} ({4})." -f $pair[0], (TaFp $pair[1]), $near[0].n, $near[0].tf, (TaFp $near[0].p)) }
    }
    $tv = Resolve-TvTarget 'bitunix' $sym $null; $L += (Get-TvLines $tv -Short:$Short)
    return $L
}
