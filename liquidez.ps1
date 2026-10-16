# Mapa de LIQUIDEZ (bolsas de stops) a partir de velas: máximos/mínimos de oscilación agrupados (equal highs/lows) en 4h, 1D y 1S, más extremos de ayer, semana pasada y 30 días.
# Medido (bt-liquidez.ps1, 30 futuros, ~1000 días): el pozo más cercano se barre primero el 72% de las veces y en 20 días se barre arriba el 75% y abajo el 80%, pero NO predice la dirección
# (más toques no cambia cuál se barre antes; rendimiento a 10 días sin diferencia). Se usa como contexto: objetivo/imán y lugar donde NO poner el SL, no como señal.
function Get-LiqPools($symR, [double]$px) {
    $out = @{ up = @(); dn = @(); ext = @{} }
    $cfgs = @(@('4h', 2, 150, 0.003, '4h'), @('1d', 3, 120, 0.006, '1D'), @('1w', 2, 60, 0.012, '1S'))
    foreach ($c in $cfgs) {
        try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${symR}USDT&interval=$($c[0])&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $n = $k.Count; if ($n -lt 30) { continue }
            $hi = [double[]]($k | ForEach-Object { $_.high }); $lo = [double[]]($k | ForEach-Object { $_.low }); $np = $c[1]; $hs = @(); $ls = @()
            for ($i = [Math]::Max($np, $n - $c[2]); $i -le $n - 1 - $np; $i++) { $ih = $true; $il = $true
                for ($q = $i - $np; $q -le $i + $np; $q++) { if ($q -eq $i) { continue }; if ($hi[$q] -ge $hi[$i]) { $ih = $false }; if ($lo[$q] -le $lo[$i]) { $il = $false } }
                if ($ih -and $hi[$i] -gt $px) { $hs += $hi[$i] }; if ($il -and $lo[$i] -lt $px) { $ls += $lo[$i] } }
            foreach ($side in @('u', 'd')) { $vals = if ($side -eq 'u') { $hs } else { $ls }; $cl = @()
                foreach ($v in ($vals | Sort-Object)) { if ($cl.Count -and [Math]::Abs($v / $cl[-1].p - 1) -le $c[3]) { $cl[-1].n++; $cl[-1].p = ($cl[-1].p * ($cl[-1].n - 1) + $v) / $cl[-1].n } else { $cl += @{ p = $v; n = 1 } } }
                foreach ($z in $cl) { $wt = switch ($c[4]) { '4h' { 1 } '1D' { 3 } default { 8 } }; $e = @{ p = [double]$z.p; n = [int]$z.n; tf = $c[4]; s = ([int]$z.n * $wt) }; if ($side -eq 'u') { $out.up += , $e } else { $out.dn += , $e } } }
            if ($c[0] -eq '1d' -and $n -ge 32) { $out.ext.dh = [double]$k[$n - 2].high; $out.ext.dl = [double]$k[$n - 2].low; $out.ext.mh = ($hi[($n - 31)..($n - 2)] | Measure-Object -Maximum).Maximum; $out.ext.ml = ($lo[($n - 31)..($n - 2)] | Measure-Object -Minimum).Minimum }
            if ($c[0] -eq '1w' -and $n -ge 3) { $out.ext.wh = [double]$k[$n - 2].high; $out.ext.wl = [double]$k[$n - 2].low }
        } catch {}
    }
    foreach ($x in @(@('mh', '30d', 5), @('ml', '30d', 5), @('wh', 'sem', 4), @('wl', 'sem', 4), @('dh', 'ayer', 2), @('dl', 'ayer', 2))) { $v = $out.ext[$x[0]]; if ($v) { $e = @{ p = [double]$v; n = 1; tf = $x[1]; s = [int]$x[2] }; if ($v -gt $px) { $out.up += , $e } elseif ($v -lt $px) { $out.dn += , $e } } }
    return $out
}
function Fmt-Pools($list, [double]$px, [int]$max = 3) {      # une pozos que coinciden (<0,4%) sumando su fuerza (toques x peso del marco: 4h=1, 1D=3, 1S=8; extremos 30d/semana/ayer); muestra los más cercanos y marca el MAYOR de ese lado
    $z = @($list | Sort-Object { $_.p }); $res = @()
    foreach ($e in $z) { if ($res.Count -and [Math]::Abs($e.p / $res[-1].p - 1) -lt 0.004) { $res[-1].tf += "+" + $e.tf; $res[-1].n += $e.n; $res[-1].s += $e.s; continue }; $res += @{ p = $e.p; n = $e.n; tf = $e.tf; s = $e.s } }
    if (-not $res.Count) { return @() }
    $cand = @($res | Where-Object { [Math]::Abs($_.p / $px - 1) -le 0.12 }); if (-not $cand.Count) { $cand = $res }      # el mayor se busca dentro de ±12% (más lejos ya no es accionable)
    $big = $cand | Sort-Object { $_.s }, { -[Math]::Abs($_.p / $px - 1) } -Descending | Select-Object -First 1
    $near = @($res | Sort-Object { [Math]::Abs($_.p / $px - 1) } | Select-Object -First ([Math]::Max(1, $max - 1)))
    $pick = @($near); if (-not ($pick | Where-Object { $_.p -eq $big.p })) { $pick += $big }
    return @($pick | Sort-Object { [Math]::Abs($_.p / $px - 1) } | ForEach-Object { "{0} ({1:+0.0;-0.0}%, {2}{3}){4}" -f (TaFp $_.p), (($_.p / $px - 1) * 100), $_.tf, $(if ($_.n -ge 3) { ", $($_.n) toques" } else { "" }), $(if ($_.p -eq $big.p) { " ★ MAYOR (fuerza $($_.s))" } else { "" }) })
}
function Get-LiquidityLine([int]$sg, $symR, [double]$px, [double]$sl = 0) {      # $sg: 1 largo, -1 corto, 0 sin dirección. Para altcoins añade el mapa de BTC
    if (-not (Get-Command TaFp -ErrorAction SilentlyContinue)) { return $null }
    $P = Get-LiqPools $symR $px; if (-not $P.up.Count -and -not $P.dn.Count) { return $null }
    $L = @("💧 LIQUIDEZ de $symR (pozos de stops: donde el precio suele ir a 'tomar' liquidez)")
    $L += "   Encima (stops de cortos): " + $(if ($P.up.Count) { (Fmt-Pools $P.up $px) -join " · " } else { "sin pozos cercanos" })
    $L += "   Debajo (stops de largos): " + $(if ($P.dn.Count) { (Fmt-Pools $P.dn $px) -join " · " } else { "sin pozos cercanos" })
    if ($P.ext.dh) { $L += ("   Ayer: máx {0} · mín {1} · semana pasada: máx {2} · mín {3} · 30 días: máx {4} · mín {5}" -f (TaFp $P.ext.dh), (TaFp $P.ext.dl), (TaFp $P.ext.wh), (TaFp $P.ext.wl), (TaFp $P.ext.mh), (TaFp $P.ext.ml)) }
    if ($sl -gt 0 -and $sg -ne 0) {      # SL justo del lado de la entrada de un pozo (a <0,6%): barrer el pozo lo activaría
        $pool = if ($sg -eq 1) { @($P.dn | Where-Object { $_.p -le $px -and $_.p -ge $sl -and ($_.p / $sl - 1) -lt 0.006 }) } else { @($P.up | Where-Object { $_.p -ge $px -and $_.p -le $sl -and ($sl / $_.p - 1) -lt 0.006 }) }
        if ($pool.Count) { $z = $pool | Sort-Object { [Math]::Abs($_.p - $sl) } | Select-Object -First 1; $L += ("   ⚠️ Tu SL ({0}) queda justo antes del pozo de {1}: si el precio va a barrerlo te saca antes. Colócalo más allá del pozo (con el apalancamiento recalculado) o espera." -f (TaFp $sl), (TaFp $z.p)) } }
    if ($symR -ne 'BTC') { try { $b = [double]((Invoke-RestMethod "$($script:CmdBase)/tickers?symbols=BTCUSDT" -TimeoutSec 15).data[0].lastPrice); $PB = Get-LiqPools 'BTC' $b
            if ($PB.up.Count -or $PB.dn.Count) { $L += ("   BTC ({0}): encima {1} · debajo {2}" -f (TaFp $b), $(if ($PB.up.Count) { (Fmt-Pools $PB.up $b 2) -join " · " } else { "—" }), $(if ($PB.dn.Count) { (Fmt-Pools $PB.dn $b 2) -join " · " } else { "—" })) } } catch {} }
    $L += "   ★ MAYOR = el pozo con más fuerza estimada de ese lado (toques x peso del marco, más extremos de 30 días/semana). Es una estimación con velas, no un heatmap de liquidaciones.`n   Dato medido: en 20 días el precio barre un pozo cercano en ~3 de cada 4 casos, pero ir hacia uno u otro no predice la dirección posterior: sirve como imán/objetivo y para no poner el SL justo delante de un pozo."
    return ($L -join "`n")
}
