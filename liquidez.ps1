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
            if ($c[0] -eq '4h') { $out.prof = @($k | ForEach-Object { , @([double]$_.low, [double]$_.high, [double]$_.quoteVol) }) }
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
function Get-PoolVol([double]$p) {      # volumen negociado (USD, ~33 días en 4h) dentro de ±0,3% del nivel, repartiendo el de cada vela por su rango; y cuántas veces supera al volumen medio de una banda igual de ese rango de precios
    $pr = $script:LiqProf; if (-not $pr -or -not $pr.Count) { return $null }
    $lo = $p * 0.997; $hi = $p * 1.003; $v = 0.0; $tot = 0.0; $mn = 1e18; $mx = 0.0
    foreach ($c in $pr) { $tot += $c[2]; if ($c[0] -lt $mn) { $mn = $c[0] }; if ($c[1] -gt $mx) { $mx = $c[1] }; $ov = [Math]::Min($hi, $c[1]) - [Math]::Max($lo, $c[0]); if ($ov -gt 0) { $rg = $c[1] - $c[0]; if ($rg -gt 0) { $v += $c[2] * [Math]::Min(1.0, $ov / $rg) } } }
    $bands = [Math]::Max(1.0, ($mx - $mn) / ($p * 0.006)); $avg = $tot / $bands
    return @{ usd = $v; x = $(if ($avg -gt 0) { $v / $avg } else { 0 }) }
}
function Fmt-Pools($list, [double]$px, [int]$max = 3) {      # une pozos que coinciden (<0,4%); muestra los más cercanos y marca el de MÁS VOLUMEN negociado alrededor (±12% del precio)
    $z = @($list | Sort-Object { $_.p }); $res = @()
    foreach ($e in $z) { if ($res.Count -and [Math]::Abs($e.p / $res[-1].p - 1) -lt 0.004) { $res[-1].tf += "+" + $e.tf; $res[-1].n += $e.n; $res[-1].s += $e.s; continue }; $res += @{ p = $e.p; n = $e.n; tf = $e.tf; s = $e.s } }
    if (-not $res.Count) { return @() }
    foreach ($r in $res) { $pv = Get-PoolVol $r.p; $r.vu = $(if ($pv) { $pv.usd } else { 0.0 }); $r.vx = $(if ($pv) { $pv.x } else { 0.0 }) }
    $cand = @($res | Where-Object { [Math]::Abs($_.p / $px - 1) -le 0.12 }); if (-not $cand.Count) { $cand = $res }
    $big = $cand | Sort-Object { $_.vu }, { -[Math]::Abs($_.p / $px - 1) } -Descending | Select-Object -First 1
    $pick = @($res | Sort-Object { [Math]::Abs($_.p / $px - 1) } | Select-Object -First 1)      # el más cercano + los 3 de más volumen (dentro de ±12%)
    foreach ($q in @($cand | Sort-Object { $_.vu } -Descending | Select-Object -First 3)) { if (-not ($pick | Where-Object { $_.p -eq $q.p })) { $pick += $q } }
    return @($pick | Sort-Object { [Math]::Abs($_.p / $px - 1) } | ForEach-Object { "{0} ({1:+0.0;-0.0}%, {2}{3}{4}){5}" -f (TaFp $_.p), (($_.p / $px - 1) * 100), $_.tf, $(if ($_.n -ge 3) { ", $($_.n) toques" } else { "" }), $(if ($_.vu -gt 0) { ", vol ≈ {0:N0} M USD (x{1:N1} la media)" -f ($_.vu / 1e6), $_.vx } else { "" }), $(if ($_.p -eq $big.p -and $_.vu -gt 0) { " ★ MÁS VOLUMEN" } else { "" }) })
}
function Get-LiquidityLine([int]$sg, $symR, [double]$px, [double]$sl = 0) {      # $sg: 1 largo, -1 corto, 0 sin dirección. Para altcoins añade el mapa de BTC
    if (-not (Get-Command TaFp -ErrorAction SilentlyContinue)) { return $null }
    $P = Get-LiqPools $symR $px; if (-not $P.up.Count -and -not $P.dn.Count) { return $null }
    $script:LiqProf = $P.prof; $L = @("💧 LIQUIDEZ de $symR (pozos de stops: donde el precio suele ir a 'tomar' liquidez)")
    $L += "   Encima (stops de cortos): " + $(if ($P.up.Count) { (Fmt-Pools $P.up $px) -join " · " } else { "sin pozos cercanos" })
    $L += "   Debajo (stops de largos): " + $(if ($P.dn.Count) { (Fmt-Pools $P.dn $px) -join " · " } else { "sin pozos cercanos" })
    if ($P.ext.dh) { $L += ("   Ayer: máx {0} · mín {1} · semana pasada: máx {2} · mín {3} · 30 días: máx {4} · mín {5}" -f (TaFp $P.ext.dh), (TaFp $P.ext.dl), (TaFp $P.ext.wh), (TaFp $P.ext.wl), (TaFp $P.ext.mh), (TaFp $P.ext.ml)) }
    if ($sl -gt 0 -and $sg -ne 0) {      # SL justo del lado de la entrada de un pozo (a <0,6%): barrer el pozo lo activaría
        $pool = if ($sg -eq 1) { @($P.dn | Where-Object { $_.p -le $px -and $_.p -ge $sl -and ($_.p / $sl - 1) -lt 0.006 }) } else { @($P.up | Where-Object { $_.p -ge $px -and $_.p -le $sl -and ($sl / $_.p - 1) -lt 0.006 }) }
        if ($pool.Count) { $z = $pool | Sort-Object { [Math]::Abs($_.p - $sl) } | Select-Object -First 1; $L += ("   ⚠️ Tu SL ({0}) queda justo antes del pozo de {1}: si el precio va a barrerlo te saca antes. Colócalo más allá del pozo (con el apalancamiento recalculado) o espera." -f (TaFp $sl), (TaFp $z.p)) } }
    if ($symR -ne 'BTC') { try { $b = [double]((Invoke-RestMethod "$($script:CmdBase)/tickers?symbols=BTCUSDT" -TimeoutSec 15).data[0].lastPrice); $PB = Get-LiqPools 'BTC' $b; $script:LiqProf = $PB.prof
            if ($PB.up.Count -or $PB.dn.Count) { $L += ("   BTC ({0}): encima {1} · debajo {2}" -f (TaFp $b), $(if ($PB.up.Count) { (Fmt-Pools $PB.up $b 2) -join " · " } else { "—" }), $(if ($PB.dn.Count) { (Fmt-Pools $PB.dn $b 2) -join " · " } else { "—" })) } } catch {} }
    $L += "   ★ MÁS VOLUMEN = el pozo donde más se ha negociado (±0,3% del nivel, últimos ~33 días); 'x1,8' = veces el volumen medio de una banda igual. Es volumen negociado, no órdenes pendientes ni liquidaciones reales (eso solo lo da un heatmap de pago).`n   Dato medido: en 20 días el precio barre un pozo cercano en ~3 de cada 4 casos, pero ir hacia uno u otro no predice la dirección posterior: sirve como imán/objetivo y para no poner el SL justo delante de un pozo."
    return ($L -join "`n")
}
