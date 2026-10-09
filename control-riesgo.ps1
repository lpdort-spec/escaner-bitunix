# Control de riesgo al registrar una operación propia con /operacion (solo chat privado de Luis). Avisa, NO bloquea: la decisión es siempre tuya.
# Reglas de Luis: margen <= 200 USDT, SL que cueste como máximo el 20% del margen (Get-SlMaxPct), comisiones controladas. Lecciones del diario de operaciones (01-06/10): cortos contra subidas verticales con RSI extremo,
# reentradas en menos de 15 minutos tras una pérdida y apalancamientos muy altos donde las comisiones se comen el margen.
function Get-MultiTfLine([int]$sg, $symR, [double]$px) {      # tendencia de cada marco (precio frente a EMA20 y EMA50) y RSI(14), frente a la dirección de la operación. Marcos: 15m, 1h, 4h, 1D, 1S (semanal) y 1M (mensual)
    if (-not (Get-Command Get-EmaValue -ErrorAction SilentlyContinue)) { return $null }
    $parts = @(); $fav = 0; $con = 0; $mix = 0
    foreach ($t in @(@('15m', '15m'), @('1h', '1h'), @('4h', '4h'), @('1d', '1D'), @('1w', '1S'), @('1M', '1M'))) {
        try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${symR}USDT&interval=$($t[0])&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); if ($k.Count -lt 22) { $parts += ("· {0} sin historia suficiente" -f $t[1]); continue }
            $cl = @($k | ForEach-Object { [double]$_.close }); $cl[$cl.Count - 1] = $px
            $e20 = Get-EmaValue $cl 20; $e50 = $null; if ($cl.Count -ge 50) { $e50 = Get-EmaValue $cl 50 }
            $up = ($px -gt $e20) -and ($null -eq $e50 -or $e20 -gt $e50); $dn = ($px -lt $e20) -and ($null -eq $e50 -or $e20 -lt $e50)
            $g = 0.0; $ls = 0.0; for ($q = $cl.Count - 14; $q -lt $cl.Count; $q++) { $d = $cl[$q] - $cl[$q - 1]; if ($d -gt 0) { $g += $d } else { $ls -= $d } }; $rsi = if ($ls -eq 0) { 100 } else { 100 - 100 / (1 + $g / $ls) }
            $st = if ($up) { "alcista" } elseif ($dn) { "bajista" } else { "mixto" }
            $ic = if ($sg -eq 0) { if ($up) { "↑" } elseif ($dn) { "↓" } else { "↔" } } elseif (($sg -eq 1 -and $up) -or ($sg -eq -1 -and $dn)) { $fav++; "✅" } elseif (($sg -eq 1 -and $dn) -or ($sg -eq -1 -and $up)) { $con++; "⚠️" } else { $mix++; "·" }
            $rn = if ($rsi -ge 70) { " (RSI {0:N0} sobrecompra)" -f $rsi } elseif ($rsi -le 30) { " (RSI {0:N0} sobreventa)" -f $rsi } else { "" }
            $parts += ("{0} {1} {2}{3}" -f $ic, $t[1], $st, $rn)
        } catch { $parts += ("· {0} sin datos" -f $t[1]) }
    }
    if (-not $parts.Count) { return $null }
    if ($sg -eq 0) { return ("🕒 Marcos temporales (precio frente a EMA20/EMA50; ↑ alcista · ↓ bajista · ↔ mixto)`n   " + ($parts -join " · ")) }
    $hi = if ($con -ge 4) { " ⚠️ la mayoría de marcos va en contra" } elseif ($fav -ge 4) { " ✔ la mayoría de marcos acompaña" } else { "" }
    return ("🕒 Marcos temporales frente a tu {0}: {1} a favor · {2} en contra · {3} mixtos{5}`n   {4}" -f $(if ($sg -eq 1) { "largo" } else { "corto" }), $fav, $con, $mix, ($parts -join " · "), $hi)
}
function Get-RiskCheck($symR, [int]$sg, [double]$en, [double]$sl, [double]$tp, [double]$mg, [double]$lv) {
    $L = @(); $warn = 0
    $cur = $en; try { $tt = @((Invoke-RestMethod "$($script:CmdBase)/tickers?symbols=${symR}USDT" -TimeoutSec 15).data | Select-Object -First 1); if ($tt.Count -and [double]$tt[0].lastPrice -gt 0) { $cur = [double]$tt[0].lastPrice } } catch {}      # lectura sobre el precio ACTUAL de mercado (la operación ya puede estar abierta desde hace horas)
    $slPct = [Math]::Abs($en - $sl) / $en * 100; $loss = $slPct * $lv; $lossUsd = $mg * $loss / 100
    # 1) margen
    if ($mg -gt 200) { $L += ("⚠️ Margen {0:N0} USDT: supera tu límite de 200." -f $mg); $warn++ }
    # 2) coste del SL y liquidación
    $mx = Get-SlMaxPct
    $inProfit = (($sg * ($sl - $en)) -gt 0)      # SL del lado del beneficio (corto con SL bajo la entrada / largo con SL sobre la entrada): si salta se GANA, no se pierde
    if ($inProfit) { $L += ("✔ SL en beneficio: si salta aseguras ≈ +{0:N0} USDT ({1:N0}% del margen), a {2:N1}% de tu entrada. No hay pérdida posible por el SL." -f $lossUsd, $loss, $slPct) }
    elseif ($loss -gt $mx) { $L += ("⚠️ El SL está a {0:N2}% del precio: con x{1:N0} pierdes {2:N0}% del margen (≈ {3:N0} USDT). Tu regla es {5:N0}% como máximo: baja el apalancamiento a x{4:N0} o acerca el SL." -f $slPct, $lv, $loss, $lossUsd, [Math]::Max(1, [Math]::Floor($mx / $slPct)), $mx); $warn++ }
    else { $L += ("✔ El SL cuesta {0:N0}% del margen (≈ {1:N0} USDT), dentro de tu regla del {2:N0}%." -f $loss, $lossUsd, $mx) }
    $liq = 100.0 / $lv - 0.3; if (-not $inProfit -and $slPct -ge 0.8 * $liq) { $L += ("⚠️ El SL queda muy cerca de la liquidación (≈ a {0:N1}% del precio): un pico puede liquidarte antes de que actúe el stop." -f $liq); $warn++ }
    # 3) comisiones con apalancamiento alto
    if ($lv -ge 30) { $L += ("⚠️ Con x{0:N0} las comisiones de ida y vuelta (~0,15% del nominal) cuestan ≈ {1:N1}% del margen: si el precio apenas se mueve, pierdes igualmente." -f $lv, (0.15 * $lv)); $warn++ }
    # 4a) todos los marcos temporales: 15m, 1h, 4h, 1d, 1S y 1M frente a la dirección de la operación
    try { $mt = Get-MultiTfLine $sg $symR $cur; if ($mt) { $L += $mt } } catch {}
    # 4) lectura del mercado
    try {
        $s = @{ src = 'bitunix'; sym = $symR }; $cd4 = Get-MomentoCd $s '4h'; $cd1 = Get-MomentoCd $s '1d'
        if ($cd4 -and $cd1) {
            $a4 = Analyze-TF $cd4 '4h' 100; $a1 = Analyze-TF $cd1 '1d' 90; $px = $cur
            $own = (Score-Momento $sg $a4 $a1 $null $px $null $null).score; $opp = (Score-Momento (-$sg) $a4 $a1 $null $px $null $null).score
            if ($own -le -1 -and $opp -ge 3) { $L += ("⚠️ La lectura del activo va EN CONTRA de tu operación: puntúa {0} para tu dirección y {1} para la contraria." -f $own, $opp); $warn++ }
            elseif ($own -ge 6) { $L += ("✔ La lectura va a tu favor (puntuación {0})." -f $own) }
            else { $L += ("· Lectura neutra para tu dirección (puntuación {0}; contraria {1})." -f $own, $opp) }
            $rsi = [double]$a4.m.rsi
            if ($sg -eq -1 -and $rsi -ge 80) { $L += ("⚠️ RSI 4h {0:N0}: shortear una subida vertical es lo que más veces te ha barrido (MOVR 01/10: -520 USDT). Mejor esperar un cierre de confirmación a la baja." -f $rsi); $warn++ }
            if ($sg -eq 1 -and $rsi -le 20) { $L += ("⚠️ RSI 4h {0:N0}: comprar una caída libre suele ser barrido; espera una vela de confirmación al alza." -f $rsi); $warn++ }
            if ($sg -eq 1 -and $rsi -ge 85) { $L += ("⚠️ RSI 4h {0:N0}: entrar largo tras un movimiento tan extendido es perseguir el precio." -f $rsi); $warn++ }
            $ad = [double]$a1.m.adx
            if ($ad -ge 25 -and (($sg -eq -1 -and $a1.m.struct -eq 'up') -or ($sg -eq 1 -and $a1.m.struct -eq 'down'))) { $L += ("⚠️ La tendencia diaria es {0} con fuerza (ADX {1:N0}): tu operación va contra ella." -f $(if ($a1.m.struct -eq 'up') { "alcista" } else { "bajista" }), $ad); $warn++ }
        }
    } catch { $L += "· No he podido leer la lectura del mercado ahora." }
    # 5) reentradas rápidas y pérdidas del día
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $hoy = (Get-MadridNow).Date
        $cerr = @(Read-Signals | Where-Object { $_.manual -eq $true -and $_.status -eq 'closed' -and $_.closedAt })
        $rec = @($cerr | Where-Object { $_.sym -eq "${symR}USDT" -and ($now - [long]$_.closedAt) -le 900 -and $null -ne $_.pnlUsd -and [double]$_.pnlUsd -lt 0 })
        if ($rec.Count) { $L += ("⚠️ Reentrada en {0} menos de 15 minutos después de cerrar con pérdida ({1:N0} USDT): es el patrón que más te ha costado. Respira un minuto y revisa si la entrada cumple las reglas." -f $symR, [double]$rec[0].pnlUsd); $warn++ }
        $perdHoy = @($cerr | Where-Object { [DateTimeOffset]::FromUnixTimeSeconds([long]$_.closedAt).ToOffset((New-TimeSpan -Hours 2)).Date -eq $hoy -and $null -ne $_.pnlUsd -and [double]$_.pnlUsd -lt 0 })
        if ($perdHoy.Count -ge 2) { $L += ("⚠️ Llevas {0} operaciones perdedoras hoy ({1:N0} USDT): considera parar por hoy." -f $perdHoy.Count, ($perdHoy | Measure-Object pnlUsd -Sum).Sum); $warn++ }
    } catch {}
    $head = if ($warn -eq 0) { "🛡️ CONTROL DE RIESGO · todo dentro de tus reglas" } else { "🛡️ CONTROL DE RIESGO · $warn aviso(s) (solo informativo: tú decides)" }
    return ($head + "`n" + ($L -join "`n"))
}
