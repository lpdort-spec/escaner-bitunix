# CAPA DE TIMING EN 1h (cripto de Bitunix): lectura conjunta de Bollinger, RSI, volumen, velas y Fibonacci sobre las últimas velas de 1h CERRADAS.
# La puntuación de "buen momento" mira 4h y 1d (¿es buen activo?); esta capa mira CUÁNDO entrar: penaliza entrar tras un movimiento estirado o con señales de agotamiento y premia entrar en un retroceso sano.
# Ajuste final entre -6 y +2 sobre la puntuación de cada lado. Reglas fijas y visibles (cada factor se explica). Origen: API3 06/10/2026 (señal emitida con RSI 1h 84 y 3 cierres fuera de Bollinger 1h).
function Get-Timing1hFromBars($bars, [int]$sg, [double]$px = 0) {
    $b = @($bars); if ($b.Count -lt 40) { return $null }
    $cl = @($b | ForEach-Object { [double]$_.close }); $n = $b.Count; $last = $b[$n - 1]; $prev = $b[$n - 2]
    if ($px -le 0) { $px = $cl[$n - 1] }
    $fx = @(); $adj = 0; $dir = if ($sg -eq 1) { "largo" } else { "corto" }
    # ATR(14) de 1h
    $tr = @(); for ($i = $n - 14; $i -lt $n; $i++) { $h = [double]$b[$i].high; $l = [double]$b[$i].low; $pc = [double]$b[$i - 1].close; $tr += [Math]::Max($h - $l, [Math]::Max([Math]::Abs($h - $pc), [Math]::Abs($l - $pc))) }; $atr = ($tr | Measure-Object -Average).Average
    # Bollinger(20,2) y cierres fuera de banda en las últimas 3 velas (en la dirección del trade)
    $nOut = 0; $mid0 = $null
    for ($q = 0; $q -lt 3; $q++) { $sub = @($cl[0..($n - 1 - $q)]); $x20 = @($sub | Select-Object -Last 20); $m = ($x20 | Measure-Object -Average).Average; $sd = [Math]::Sqrt((($x20 | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Sum).Sum / 20)
        if ($q -eq 0) { $mid0 = $m }
        if (($sg -eq 1 -and $sub[-1] -gt $m + 2 * $sd) -or ($sg -eq -1 -and $sub[-1] -lt $m - 2 * $sd)) { $nOut++ } }
    $bbAdj = 0; if ($nOut -ge 2) { $bbAdj = -2; $fx += "⚠️ Timing 1h: $nOut de las últimas 3 velas cerraron fuera de la banda de Bollinger en la dirección del $dir (movimiento estirado)" } elseif ($nOut -eq 1) { $bbAdj = -1; $fx += "⚠️ Timing 1h: la última vela cerró fuera de la banda de Bollinger (algo estirado)" }
    # RSI(14) de 1h
    $g = 0.0; $ls = 0.0; for ($q = 1; $q -le 14; $q++) { $d = $cl[$q] - $cl[$q - 1]; if ($d -gt 0) { $g += $d } else { $ls -= $d } }; $g /= 14; $ls /= 14
    for ($q = 15; $q -lt $n; $q++) { $d = $cl[$q] - $cl[$q - 1]; $g = ($g * 13 + [Math]::Max($d, 0)) / 14; $ls = ($ls * 13 + [Math]::Max(-$d, 0)) / 14 }
    $rsi = if ($ls -eq 0) { 100.0 } else { 100 - 100 / (1 + $g / $ls) }; $r = if ($sg -eq 1) { $rsi } else { 100 - $rsi }; $rsiAdj = 0
    if ($r -ge 85) { $rsiAdj = -3 } elseif ($r -ge 75) { $rsiAdj = -2 } elseif ($r -ge 70) { $rsiAdj = -1 }
    if ($rsiAdj -lt 0) { $fx += ("⚠️ Timing 1h: RSI 1h {0:N0} ({1}): {2}" -f $rsi, $(if ($sg -eq 1) { "sobrecompra" } else { "sobreventa" }), $(if ($rsiAdj -le -2) { "zona extrema, el precio suele corregir" } else { "empieza a estar tenso" })) }
    $ext = [Math]::Max($bbAdj + $rsiAdj, -4); $adj += $ext
    # distancia a la media de 1h en ATR
    $distAtr = if ($atr -gt 0) { $sg * ($px - $mid0) / $atr } else { 0 }
    if ($distAtr -ge 5) { $adj -= 1; $fx += ("⚠️ Timing 1h: el precio está a {0:N1} ATR de la media de 1h: muy alejado (suele volver hacia {1})" -f $distAtr, (TaFp $mid0)) }
    # volumen: nuevo extremo con menos volumen (divergencia) en las últimas 6 velas
    $w = @($b | Select-Object -Last 6); $vol = { param($c) $x = [double]$c.baseVol; if ($x -le 0) { $x = [double]$c.volume }; $x }
    $ext6 = if ($sg -eq 1) { ($w | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum } else { ($w | ForEach-Object { [double]$_.low } | Measure-Object -Minimum).Minimum }
    $jx = $null; foreach ($c in $w) { if (([double]$(if ($sg -eq 1) { $c.high } else { $c.low })) -eq $ext6) { $jx = $c } }
    $vmax = ($w | ForEach-Object { & $vol $_ } | Measure-Object -Maximum).Maximum
    if ($jx -and $vmax -gt 0 -and (& $vol $jx) -lt 0.6 * $vmax -and $sg * ($px - $ext6) -gt -1.0 * $atr) { $adj -= 1; $fx += "⚠️ Timing 1h: el último extremo se hizo con bastante menos volumen que antes (el impulso pierde fuerza)" }
    # velas: mecha de rechazo y envolvente contraria en la última vela cerrada
    $o0 = [double]$last.open; $c0 = [double]$last.close; $h0 = [double]$last.high; $l0 = [double]$last.low; $rg = $h0 - $l0; $o1 = [double]$prev.open; $c1 = [double]$prev.close
    if ($rg -gt 0) {
        $wickAgainst = if ($sg -eq 1) { ($h0 - [Math]::Max($o0, $c0)) / $rg } else { ([Math]::Min($o0, $c0) - $l0) / $rg }
        $eng = if ($sg -eq 1) { ($c1 -gt $o1 -and $c0 -lt $o0 -and $o0 -ge $c1 -and $c0 -le $o1) } else { ($c1 -lt $o1 -and $c0 -gt $o0 -and $o0 -le $c1 -and $c0 -ge $o1) }
        if ($eng -and [Math]::Abs($c0 - $o0) -ge 0.6 * $atr) { $adj -= 2; $fx += "⚠️ Timing 1h: vela envolvente en contra del $dir (giro fuerte)" }
        elseif ($eng) { $adj -= 1; $fx += "⚠️ Timing 1h: vela envolvente en contra del $dir" }
        elseif ($wickAgainst -ge 0.55 -and $rg -ge 0.8 * $atr) { $adj -= 1; $fx += "⚠️ Timing 1h: mecha de rechazo larga en contra del $dir en la última vela" }
    }
    # Fibonacci del último impulso (72 velas de 1h): dónde está el precio respecto al impulso en la dirección del trade
    $w72 = @($b | Select-Object -Last 72); $iH = 0; $iL = 0; for ($i = 0; $i -lt $w72.Count; $i++) { if ([double]$w72[$i].high -ge [double]$w72[$iH].high) { $iH = $i }; if ([double]$w72[$i].low -le [double]$w72[$iL].low) { $iL = $i } }
    $H = [double]$w72[$iH].high; $Lw = [double]$w72[$iL].low
    if ($sg -eq 1 -and $iL -lt $iH -and ($H - $Lw) / $Lw -ge 0.06) { $ret = ($H - $px) / ($H - $Lw); $imp = ($H - $Lw) / $Lw * 100
        if ($ret -lt 0.236 -and $imp -ge 10) { $adj -= 1; $fx += ("⚠️ Fibonacci 1h: precio pegado al máximo de un impulso de +{0:N0}% (retroceso {1:N0}% < 23,6%): entrar aquí es perseguir" -f $imp, ($ret * 100)) }
        elseif ($ret -ge 0.382 -and $ret -le 0.618) { $adj += 1; $fx += ("✅ Fibonacci 1h: retroceso sano del {0:N0}% (zona 38,2-61,8%) del último impulso de +{1:N0}%" -f ($ret * 100), $imp) }
        elseif ($ret -gt 0.786) { $adj -= 2; $fx += ("⚠️ Fibonacci 1h: retroceso del {0:N0}% (>78,6%): el impulso se está perdiendo" -f ($ret * 100)) } }
    elseif ($sg -eq -1 -and $iH -lt $iL -and ($H - $Lw) / $H -ge 0.06) { $ret = ($px - $Lw) / ($H - $Lw); $imp = ($H - $Lw) / $H * 100
        if ($ret -lt 0.236 -and $imp -ge 10) { $adj -= 1; $fx += ("⚠️ Fibonacci 1h: precio pegado al mínimo de una caída de -{0:N0}% (rebote {1:N0}% < 23,6%): entrar aquí es perseguir" -f $imp, ($ret * 100)) }
        elseif ($ret -ge 0.382 -and $ret -le 0.618) { $adj += 1; $fx += ("✅ Fibonacci 1h: rebote sano del {0:N0}% (zona 38,2-61,8%) de la última caída de -{1:N0}%" -f ($ret * 100), $imp) }
        elseif ($ret -gt 0.786) { $adj -= 2; $fx += ("⚠️ Fibonacci 1h: rebote del {0:N0}% (>78,6%): la caída se está perdiendo" -f ($ret * 100)) } }
    $adj = [Math]::Max(-6, [Math]::Min(2, $adj))
    return @{ adj = $adj; fx = $fx; rsi = $rsi; nOut = $nOut; atr = $atr; mid = $mid0 }
}
function Get-Timing1hBoth($s, [double]$px = 0) {      # solo cripto de Bitunix; devuelve {lg, st} o $null si no hay datos
    try {
        if ($s.src -ne 'bitunix') { return $null }
        $sym = if ("$($s.sym)" -like '*USDT') { $s.sym } else { "$($s.sym)USDT" }
        $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$sym&interval=1h&limit=120" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); if ($k.Count -lt 45) { return $null }
        $closed = @($k[0..($k.Count - 2)])      # la última vela devuelta está en formación
        $pp = if ($px -gt 0) { $px } else { [double]$k[$k.Count - 1].close }
        return @{ lg = (Get-Timing1hFromBars $closed 1 $pp); st = (Get-Timing1hFromBars $closed -1 $pp) }
    } catch { return $null }
}
