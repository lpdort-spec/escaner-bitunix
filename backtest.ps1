# Backtest de teorías de entrada en futuros Bitunix con histórico real (velas de 15m, 1h y 4h).
# Mide aciertos y esperanza matemática en R (1R = distancia al stop) restando comisiones y deslizamiento.
param([int]$TopN = 50, [switch]$Refresh, [switch]$Weekly, [double]$Cost = 0.0015)
$base = "https://fapi.bitunix.com/api/v1/futures/market"
$cache = Join-Path $PSScriptRoot "cache"; New-Item -ItemType Directory -Force $cache | Out-Null
$durMs = @{ '15m' = 900000; '1h' = 3600000; '4h' = 14400000; '1d' = 86400000 }
$pages = @{ '15m' = 15; '1h' = 12; '4h' = 7; '1d' = 4 }
$out = Join-Path $PSScriptRoot "backtest-results.txt"
Set-Content $out "" -Encoding utf8
function Log($s) { Write-Host $s; Add-Content $out $s -Encoding utf8 }

function Get-History($sym, $iv) {
    $f = Join-Path $cache "$sym-$iv.json"
    if ((Test-Path $f) -and -not $Refresh -and ((Get-Item $f).LastWriteTime -gt (Get-Date).AddHours(-12))) { return Get-Content $f -Raw | ConvertFrom-Json }
    $all = @{}; $end = $null
    for ($p = 0; $p -lt $pages[$iv]; $p++) {
        $u = "$base/kline?symbol=$sym&interval=$iv&limit=200"; if ($end) { $u += "&endTime=$end" }
        try { $d = (Invoke-RestMethod $u).data } catch { break }
        if (-not $d -or $d.Count -eq 0) { break }
        $min = [long]::MaxValue
        foreach ($c in $d) { $all[[string]$c.time] = $c; if ([long]$c.time -lt $min) { $min = [long]$c.time } }
        $end = $min - 1
        Start-Sleep -Milliseconds 70
    }
    $s = @($all.Values | Sort-Object { [long]$_.time })
    if ($s.Count -lt 120) { return $null }
    $s = $s[0..($s.Count - 2)]                                   # descarta la vela en curso
    $o = @{ t = @($s | % { [long]$_.time }); o = @($s | % { [double]$_.open }); h = @($s | % { [double]$_.high }); l = @($s | % { [double]$_.low }); c = @($s | % { [double]$_.close }); v = @($s | % { [double]$_.quoteVol }) }
    $o | ConvertTo-Json -Compress | Set-Content $f
    return $o
}

function Prep($Dat) {
    $n = $Dat.t.Count; $c = $Dat.c; $h = $Dat.h; $l = $Dat.l; $v = $Dat.v
    $tr = New-Object 'double[]' $n; $ps = New-Object 'double[]' ($n + 1); $vp = New-Object 'double[]' ($n + 1)
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -gt 0) { $tr[$i] = [Math]::Max($h[$i] - $l[$i], [Math]::Max([Math]::Abs($h[$i] - $c[$i-1]), [Math]::Abs($l[$i] - $c[$i-1]))) } else { $tr[$i] = $h[$i] - $l[$i] }
        $ps[$i+1] = $ps[$i] + $tr[$i]; $vp[$i+1] = $vp[$i] + $v[$i]
    }
    $atr14 = New-Object 'double[]' $n; $atr5 = New-Object 'double[]' $n; $av20 = New-Object 'double[]' $n; $rsi = New-Object 'double[]' $n
    for ($i = 20; $i -lt $n; $i++) { $atr14[$i] = ($ps[$i] - $ps[$i-14]) / 14; $atr5[$i] = ($ps[$i] - $ps[$i-5]) / 5; $av20[$i] = ($vp[$i] - $vp[$i-20]) / 20 }
    $g = 0.0; $ls = 0.0
    for ($i = 1; $i -le 14 -and $i -lt $n; $i++) { $d = $c[$i] - $c[$i-1]; if ($d -gt 0) { $g += $d } else { $ls -= $d } }
    $g /= 14; $ls /= 14
    for ($i = 15; $i -lt $n; $i++) {
        $d = $c[$i] - $c[$i-1]; $g = ($g * 13 + [Math]::Max($d, 0)) / 14; $ls = ($ls * 13 + [Math]::Max(-$d, 0)) / 14
        $rsi[$i] = if ($ls -eq 0) { 100 } else { 100 - 100 / (1 + $g / $ls) }
    }
    $cand = New-Object System.Collections.Generic.List[int]
    for ($i = 60; $i -lt $n - 2; $i++) { if ($av20[$i] -gt 0 -and $v[$i] / $av20[$i] -ge 1.8) { $cand.Add($i) } }
    return @{ D = $Dat; n = $n; atr14 = $atr14; atr5 = $atr5; av20 = $av20; rsi = $rsi; cand = $cand }
}

function Prep-Trend($D4, $tfName) {                    # EMA21 en 4h y su hora de cierre (etiqueta + 2 duraciones)
    $n = $D4.t.Count; $k = 2.0 / 22; $ema = New-Object 'double[]' $n; $ct = New-Object 'long[]' $n
    $ema[0] = $D4.c[0]
    for ($i = 1; $i -lt $n; $i++) { $ema[$i] = $D4.c[$i] * $k + $ema[$i-1] * (1 - $k) }
    for ($i = 0; $i -lt $n; $i++) { $ct[$i] = $D4.t[$i] + 2 * $durMs[$tfName] }
    return @{ c = $D4.c; ema = $ema; ct = $ct }
}

function Get-TrendAt($T, [long]$time) {
    $j = [Array]::BinarySearch($T.ct, $time)
    if ($j -lt 0) { $j = (-bnot $j) - 1 }
    if ($j -lt 4) { return "flat" }
    if ($T.c[$j] -gt $T.ema[$j] -and $T.ema[$j] -ge $T.ema[$j-3]) { return "up" }
    if ($T.c[$j] -lt $T.ema[$j] -and $T.ema[$j] -le $T.ema[$j-3]) { return "down" }
    return "flat"
}

function Sim($D, $n, [int]$j0, [int]$sgn, [double]$entry, [double]$sl, [double]$R, [double]$r1, [double]$r2, [int]$H, [bool]$fc) {
    $tp1 = $entry + $sgn * $r1 * $R; $tp2 = $entry + $sgn * $r2 * $R
    $stage = 0; $A = $null; $B = $null; $last = [Math]::Min($n - 1, $j0 + $H)
    for ($k = $j0; $k -le $last; $k++) {
        $hi = $D.h[$k]; $lo = $D.l[$k]
        if ($sgn -eq 1) { $hitSL = $lo -le $sl; $hit1 = $hi -ge $tp1; $hit2 = $hi -ge $tp2; $hitBE = $lo -le $entry }
        else { $hitSL = $hi -ge $sl; $hit1 = $lo -le $tp1; $hit2 = $lo -le $tp2; $hitBE = $hi -ge $entry }
        if ($fc -and $k -eq $j0) { if ($hitSL) { return @(-1.0, -1.0, $k) }; continue }
        if ($stage -eq 0) {
            if ($hitSL) { return @(-1.0, -1.0, $k) }
            if ($hit1) { $A = $r1; $stage = 1; continue }
        } else {
            if ($hitBE) { return @($A, (0.5 * $r1 + 0.5 * 0.0), $k) }
            if ($hit2) { return @($A, (0.5 * $r1 + 0.5 * $r2), $k) }
        }
    }
    $m = $sgn * ($D.c[$last] - $entry) / $R
    if ($stage -eq 0) { $m = [Math]::Max(-1.0, [Math]::Min($r1, $m)); return @($m, $m, $last) }
    return @($A, (0.5 * $r1 + 0.5 * [Math]::Max(0.0, [Math]::Min($r2, $m))), $last)
}

function SimC($D, $n, [int]$j0, [int]$sgn, [double]$entry, [double]$sl, [double]$R, [int]$H, [double]$w1, [double]$w2, [double]$w3, [bool]$fc) {
    $tp1 = $entry + $sgn * $R; $tp2 = $entry + $sgn * 2 * $R; $tp3 = $entry + $sgn * 3 * $R
    $stage = 0; $real = 0.0; $rem = 1.0; $last = [Math]::Min($n - 1, $j0 + $H)
    for ($k = $j0; $k -le $last; $k++) {
        $hi = $D.h[$k]; $lo = $D.l[$k]
        if ($sgn -eq 1) { $hitSL = $lo -le $sl; $h1 = $hi -ge $tp1; $h2 = $hi -ge $tp2; $h3 = $hi -ge $tp3; $be = $lo -le $entry }
        else { $hitSL = $hi -ge $sl; $h1 = $lo -le $tp1; $h2 = $lo -le $tp2; $h3 = $lo -le $tp3; $be = $hi -ge $entry }
        if ($fc -and $k -eq $j0) { if ($hitSL) { return -1.0 }; continue }
        if ($stage -eq 0) { if ($hitSL) { return -1.0 }; if ($h1) { $real += $w1 * 1.0; $rem -= $w1; $stage = 1; if ($rem -le 0.0001) { return $real } } }
        elseif ($stage -eq 1) { if ($be) { return $real }; if ($h2) { $real += $w2 * 2.0; $rem -= $w2; $stage = 2; if ($rem -le 0.0001) { return $real } } }
        else { if ($be) { return $real }; if ($h3) { return $real + $rem * 3.0 } }
    }
    $m = [Math]::Max(-1.0, [Math]::Min(3.0, $sgn * ($D.c[$last] - $entry) / $R))
    return $real + $rem * $m
}
function Run-Config($cfg, $data) {
    $trades = New-Object System.Collections.Generic.List[object]
    foreach ($e in $data) {
        $hz = if ($e.tf -eq '4h') { 30 } else { $cfg.H }
        $F = $e.F; $D = $F.D; $n = $F.n; $T = $e.T
        foreach ($i in $F.cand) {
            $atr = $F.atr14[$i]; if ($atr -le 0) { continue }
            $ratio = $D.v[$i] / $F.av20[$i]; if ($ratio -lt $cfg.vol) { continue }
            $px = $D.c[$i]; $op = $D.o[$i]; $hi = $D.h[$i]; $lo = $D.l[$i]; $rng = $hi - $lo; if ($rng -le 0) { continue }
            $lk = $cfg.look; $pH = -1e18; $pL = 1e18
            for ($q = $i - $lk; $q -lt $i; $q++) { if ($D.h[$q] -gt $pH) { $pH = $D.h[$q] }; if ($D.l[$q] -lt $pL) { $pL = $D.l[$q] } }
            $rsi = $F.rsi[$i]; $pos = ($px - $lo) / $rng
            $squeeze = $F.atr5[$i] -le 0.85 * $atr
            if ($cfg.squeeze -and -not $squeeze) { continue }
            $sgn = 0; $sl = 0.0
            if ($cfg.strategy -eq 'break') {
                if ($px -gt $pH -and $px -gt $op -and $pos -ge 0.65 -and $rsi -lt 72 -and $rsi -gt 40) { $sgn = 1; $lvl = $pH }
                elseif ($px -lt $pL -and $px -lt $op -and $pos -le 0.35 -and $rsi -gt 28 -and $rsi -lt 60) { $sgn = -1; $lvl = $pL }
                if ($sgn -eq 0) { continue }
                $ext = $sgn * ($px - $lvl) / $atr
                if ($ext -gt $cfg.maxExt -or $rng -gt 2.5 * $atr) { continue }
                switch ($cfg.sl) {
                    'level' { $sl = $lvl - $sgn * 0.5 * $atr; $risk = $sgn * ($px - $sl); if ($risk -lt 0.8 * $atr) { $sl = $px - $sgn * 0.8 * $atr }; if ($risk -gt 2.0 * $atr) { $sl = $px - $sgn * 2.0 * $atr } }
                    'atr1' { $sl = $px - $sgn * 1.0 * $atr }
                    'atr15' { $sl = $px - $sgn * 1.5 * $atr }
                    'atr2' { $sl = $px - $sgn * 2.0 * $atr }
                }
            } else {                                                   # barrido de liquidez: mecha fuera del rango y cierre dentro
                if ($hi -gt $pH -and $px -lt $pH -and ($hi - [Math]::Max($op, $px)) / $rng -ge 0.5) { $sgn = -1; $sl = $hi + 0.2 * $atr; $lvl = $pH }
                elseif ($lo -lt $pL -and $px -gt $pL -and ([Math]::Min($op, $px) - $lo) / $rng -ge 0.5) { $sgn = 1; $sl = $lo - 0.2 * $atr; $lvl = $pL }
                if ($sgn -eq 0) { continue }
                $risk = $sgn * ($px - $sl); if ($risk -lt 0.5 * $atr -or $risk -gt 2.5 * $atr) { continue }
            }
            if ($cfg.side -eq 'long' -and $sgn -ne 1) { continue }; if ($cfg.side -eq 'short' -and $sgn -ne -1) { continue }
            $trend = if ($T) { Get-TrendAt $T ($D.t[$i] + 2 * $durMs[$e.tf]) } else { "flat" }
            $aligned = ($sgn -eq 1 -and $trend -eq "up") -or ($sgn -eq -1 -and $trend -eq "down")
            $counter = ($sgn -eq 1 -and $trend -eq "down") -or ($sgn -eq -1 -and $trend -eq "up")
            if ($cfg.trend -eq 'aligned' -and -not $aligned) { continue }
            if ($cfg.trend -eq 'counter' -and -not $counter) { continue }
            if ($cfg.trend -eq 'nocounter' -and $counter) { continue }
            if ($cfg.trend -eq 'smart' -and (($sgn -eq 1 -and $counter) -or ($sgn -eq -1 -and -not $aligned))) { continue }
            $entry = $px; $j0 = $i + 1
            if ($cfg.entry -eq 'retest') {
                $dpt = if ($cfg.depth) { $cfg.depth } else { 0.5 }; $wnd = if ($cfg.win) { $cfg.win } else { 4 }
                $lim = $px - $sgn * [Math]::Min($dpt * $atr, [Math]::Abs($px - $lvl) * $(if ($cfg.strategy -eq 'fade') { 0.5 } else { 1.0 }))
                if ([Math]::Abs($px - $lim) -lt 0.05 * $atr) { continue }
                $filled = $false
                for ($k = $i + 1; $k -le [Math]::Min($n - 1, $i + $wnd); $k++) {
                    if (($sgn -eq 1 -and $D.l[$k] -le $sl) -or ($sgn -eq -1 -and $D.h[$k] -ge $sl)) { break }
                    if (($sgn -eq 1 -and $D.l[$k] -le $lim) -or ($sgn -eq -1 -and $D.h[$k] -ge $lim)) { $filled = $true; $entry = $lim; $j0 = $k; break }
                }
                if (-not $filled) { continue }
            }
            $R = $sgn * ($entry - $sl); if ($R -le 0) { continue }; if ($cfg.minSl -and ($R / $entry * 100) -lt $cfg.minSl) { continue }
            $fc = ($cfg.entry -eq 'retest'); $res = Sim $D $n $j0 $sgn $entry $sl $R $cfg.r1 $cfg.r2 $hz $fc
            $cc = if ($cfg.cost) { $cfg.cost } else { $Cost }; $costR = $cc / ($R / $entry); $resC = SimC $D $n $j0 $sgn $entry $sl $R $hz (1/3) (1/3) (1/3) $fc; $resD = SimC $D $n $j0 $sgn $entry $sl $R $hz 0.5 0.3 0.2 $fc; $resE = SimC $D $n $j0 $sgn $entry $sl $R $hz 1.0 0.0 0.0 $fc; $resF = SimC $D $n $j0 $sgn $entry $sl $R $hz 0.7 0.2 0.1 $fc
            $hour = [DateTimeOffset]::FromUnixTimeMilliseconds($D.t[$i]).Hour
            $trades.Add([pscustomobject]@{ sym = $e.sym; tf = $e.tf; side = $sgn; time = $D.t[$i]; aligned = $aligned; counter = $counter; ratio = $ratio; squeeze = $squeeze; slPct = $R / $entry * 100; A = $res[0] - $costR; B = $res[1] - $costR; C = $resC - $costR; D = $resD - $costR; E = $resE - $costR; F = $resF - $costR; win = ($res[0] -gt 0) })
        }
    }
    return $trades
}

function Summ($trades, $label, $tf) {
    $t = @($trades | ? { $_.tf -eq $tf })
    if ($t.Count -eq 0) { return "{0,-34} {1,-4} n=0" -f $label, $tf }
    $n = $t.Count; $w = @($t | ? { $_.win }).Count
    $eA = ($t | Measure-Object A -Average).Average; $eB = ($t | Measure-Object B -Average).Average; $eC = ($t | Measure-Object C -Average).Average; $eD = ($t | Measure-Object D -Average).Average; $eE = ($t | Measure-Object E -Average).Average; $eF = ($t | Measure-Object F -Average).Average; $p1 = 100.0 * @($t | ? { $_.E -gt 0 }).Count / $n; $slm = ($t | Measure-Object slPct -Average).Average
    $sorted = @($t | Sort-Object time); $cut = [int]($n * 0.6)
    $te = @($sorted[$cut..($n - 1)]); $eTest = if ($te.Count -gt 0) { ($te | Measure-Object A -Average).Average } else { 0 }
    $gp = ($t | ? { $_.A -gt 0 } | Measure-Object A -Sum).Sum; $gl = -($t | ? { $_.A -le 0 } | Measure-Object A -Sum).Sum
    $pf = if ($gl -gt 0) { $gp / $gl } else { 99 }
    return "{0,-34} {1,-4} n={2,-5} acierto={3,5:N1}%  esperanzaA={4,6:N3}R  esperanzaB={5,6:N3}R  tercios={8,6:N3}R  50/30/20={9,6:N3}R  todoTP1={10,6:N3}R  70/20/10={11,6:N3}R  gana1R={12,4:N0}%  SLmedio={13,4:N1}%  PF={6,4:N2}  test={7,6:N3}R" -f $label, $tf, $n, (100.0 * $w / $n), $eA, $eB, $pf, $eTest, $eC, $eD, $eE, $eF, $p1, $slm
}

# ---------- carga de datos ----------
$tk = (Invoke-RestMethod "$base/tickers").data | ? { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $TopN
$data = New-Object System.Collections.Generic.List[object]
$idx = 0
foreach ($t in $tk) {
    $idx++; $sym = $t.symbol
    $D4 = Get-History $sym '4h'; if (-not $D4) { continue }
    $D1 = Get-History $sym '1d'
    $T4 = Prep-Trend $D4 '4h'; $T1 = if ($D1) { Prep-Trend $D1 '1d' } else { $null }
    $data.Add(@{ sym = $sym; tf = '4h'; F = (Prep $D4); T = $T1 })
    $Dh = Get-History $sym '1h'; if ($Dh) { $data.Add(@{ sym = $sym; tf = '1h'; F = (Prep $Dh); T = $T4 }) }
    if ($idx % 10 -eq 0) { Write-Host "datos: $idx/$($tk.Count)" }
}
$days15 = [math]::Round(($data | ? { $_.tf -eq '4h' } | Select-Object -First 1).F.n * 4 / 24, 0)
$days1h = [math]::Round(($data | ? { $_.tf -eq '1h' } | Select-Object -First 1).F.n / 24, 0)
Log "Series: $($data.Count) | historia aprox. 4h: $days15 dias, 1h: $days1h dias | comision+deslizamiento: $([math]::Round($Cost*100,2))% ida y vuelta"
Log "tercios = 1/3 en 1R, 1/3 en 2R, 1/3 en 3R con SL a entrada tras TP1 (el sistema de las senales) | esperanzaA = todo fuera en TP1 | esperanzaB = mitad en TP1 y mitad en TP2 con stop en entrada | test = ultimo 40% del tiempo (fuera de muestra)"
Log ""

$baseCfg = @{ strategy = 'break'; vol = 2.5; look = 20; maxExt = 1.2; squeeze = $false; trend = 'any'; sl = 'level'; r1 = 1.5; r2 = 3.0; entry = 'retest'; H = 48 }
function V($name, $over) { $c = $baseCfg.Clone(); foreach ($k in $over.Keys) { $c[$k] = $over[$k] }; return @{ name = $name; cfg = $c } }

# ---------- Backtest semanal automático ----------
# La primera variante es EXACTAMENTE la configuración que usa el bot; las demás sirven de comparación.
$variants = @(
    (V "ACTUAL (la que usa el bot)" @{ depth = 1.0; trend = 'smart'; minSl = 1.0; vol = 2.0; cost = 0.0010 }),
    (V "volumen minimo x2.5" @{ depth = 1.0; trend = 'smart'; minSl = 1.0; vol = 2.5; cost = 0.0010 }),
    (V "SL minimo 1.5%" @{ depth = 1.0; trend = 'smart'; minSl = 1.5; vol = 2.0; cost = 0.0010 }),
    (V "rango de 10 velas" @{ depth = 1.0; trend = 'smart'; minSl = 1.0; vol = 2.0; look = 10; cost = 0.0010 }),
    (V "sin filtro de tendencia" @{ depth = 1.0; minSl = 1.0; vol = 2.0; cost = 0.0010 }),
    (V "entrada a mercado (comparacion)" @{ entry = 'close'; trend = 'smart'; minSl = 1.0; vol = 2.0; cost = 0.0015 }),
    (V "barrido de liquidez (experimental)" @{ strategy = 'fade'; trend = 'smart'; minSl = 1.0; cost = 0.0010 })
)
function Compact($tr, $tf) {
    $t = @($tr | Where-Object { $_.tf -eq $tf }); if ($t.Count -eq 0) { return $null }
    $n = $t.Count; $w = @($t | Where-Object { $_.win }).Count
    $s = @($t | Sort-Object time); $cut = [int]($n * 0.6); $te = @($s[$cut..($n - 1)])
    return [pscustomobject]@{ n = $n; win = 100.0 * $w / $n; ec = ($t | Measure-Object C -Average).Average; et = $(if ($te.Count) { ($te | Measure-Object C -Average).Average } else { 0 }) }
}
function Fr($x) { return ("{0:+0.00;-0.00;0.00}R" -f $x) }

$res = @{}
foreach ($v in $variants) {
    $tr = Run-Config $v.cfg $data
    $res[$v.name] = @{ '1h' = (Compact $tr '1h'); '4h' = (Compact $tr '4h') }
    foreach ($tf in '1h', '4h') { Log (Summ $tr $v.name $tf) }
}

$fecha = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
$L = @("📈 BACKTEST SEMANAL · $fecha", "Datos reales de Bitunix: $($data.Count) series · historia ~$days1h días en 1h y ~$days15 días en 4h · comisiones 0,10-0,15% incluidas.", "Esperanza = ganancia media por operación en R (1R = lo que arriesgas hasta el SL), cerrando un tercio en TP1, TP2 y TP3. 'Fuera de muestra' = último 40% del tiempo.", "")
foreach ($v in $variants) {
    $L += "▶ " + $v.name
    foreach ($tf in '1h', '4h') {
        $c = $res[$v.name][$tf]
        if ($c) { $L += ("   {0}: {1} operaciones · llegan a 1,5R el {2:N0}% · esperanza {3} · fuera de muestra {4}" -f $tf, $c.n, $c.win, (Fr $c.ec), (Fr $c.et)) } else { $L += "   ${tf}: sin operaciones" }
    }
}
# veredicto automático sobre la configuración actual
$a1 = $res["ACTUAL (la que usa el bot)"]['1h']; $a4 = $res["ACTUAL (la que usa el bot)"]['4h']
$L += ""
if (-not $a1 -or -not $a4 -or $a1.n -lt 20 -or $a4.n -lt 20) { $L += "🔶 VEREDICTO: muestra insuficiente esta semana (menos de 20 operaciones en algún marco). No se puede concluir nada; se mantiene la configuración." }
elseif ($a1 -and $a4 -and $a1.ec -gt 0 -and $a4.ec -gt 0 -and $a1.et -gt 0 -and $a4.et -gt 0) { $L += "✅ VEREDICTO: la configuración actual sigue con esperanza positiva en 1h y 4h, también fuera de muestra." }
elseif ($a1 -and $a4 -and ($a1.ec -le 0 -or $a4.ec -le 0)) { $L += "⚠️ VEREDICTO: con los datos de esta semana la configuración actual NO sale positiva en alguno de los marcos. Hay que revisarla antes de fiarse de las nuevas señales." }
else { $L += "🔶 VEREDICTO: resultado mixto (positiva en conjunto pero no fuera de muestra, o muestra muy pequeña). Se mantiene en observación." }
# comparación con la semana anterior
$histFile = Join-Path $PSScriptRoot "backtest-history.jsonl"
if (Test-Path $histFile) {
    try { $prev = (Get-Content $histFile -Tail 1 -Encoding UTF8 | ConvertFrom-Json); if ($prev -and $a1 -and $a4) { $L += ("Semana anterior ({0}): 1h {1} · 4h {2}   →   ahora: 1h {3} · 4h {4}" -f $prev.fecha, (Fr $prev.ec1h), (Fr $prev.ec4h), (Fr $a1.ec), (Fr $a4.ec)) } } catch {}
}
if ($a1 -and $a4) { (@{ fecha = $fecha; n1h = $a1.n; n4h = $a4.n; ec1h = [Math]::Round($a1.ec, 3); ec4h = [Math]::Round($a4.ec, 3); et1h = [Math]::Round($a1.et, 3); et4h = [Math]::Round($a4.et, 3) } | ConvertTo-Json -Compress) | Add-Content $histFile -Encoding UTF8 }

# resultados REALES del bot (señales ya enviadas y resueltas)
$L += ""; $L += "📊 ACIERTOS REALES DEL BOT (señales enviadas, evaluadas con las velas posteriores):"
try { . (Join-Path $PSScriptRoot "tracker.ps1"); $L += (Get-Report) } catch { $L += "Aún no hay señales resueltas suficientes." }
$L += ""; $L += "Un backtest describe el pasado: no garantiza el futuro. Los cambios de reglas los decidimos con 50-100 señales reales como mínimo."
$text = $L -join "`n"
Set-Content (Join-Path $PSScriptRoot "backtest-ultimo.txt") $text -Encoding UTF8
Write-Host $text

# envío a Telegram (grupo de señales si existe; si no, los destinos generales)
$tok = $env:TELEGRAM_TOKEN
$dest = if ($env:TELEGRAM_SIGNAL_CHAT_ID) { $env:TELEGRAM_SIGNAL_CHAT_ID } else { $env:TELEGRAM_CHAT_ID }
if ($tok -and $dest) {
    $chunks = @(); $cur = ""
    foreach ($l in $L) { if (($cur.Length + $l.Length + 1) -gt 3800) { $chunks += $cur; $cur = "" }; $cur += $l + "`n" }
    if ($cur) { $chunks += $cur }
    foreach ($id in ($dest -split ',')) {
        foreach ($ch in $chunks) {
            try { $json = @{ chat_id = $id.Trim(); text = $ch } | ConvertTo-Json -Compress; Invoke-RestMethod -Uri "https://api.telegram.org/bot$tok/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null } catch {}
        }
    }
    Write-Host "Informe enviado a Telegram."
}
