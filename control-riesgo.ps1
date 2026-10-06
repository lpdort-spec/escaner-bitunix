# Control de riesgo al registrar una operación propia con /operacion (solo chat privado de Luis). Avisa, NO bloquea: la decisión es siempre tuya.
# Reglas de Luis: margen <= 200 USDT, SL que cueste como máximo el 20% del margen (Get-SlMaxPct), comisiones controladas. Lecciones del diario de operaciones (01-06/10): cortos contra subidas verticales con RSI extremo,
# reentradas en menos de 15 minutos tras una pérdida y apalancamientos muy altos donde las comisiones se comen el margen.
function Get-RiskCheck($symR, [int]$sg, [double]$en, [double]$sl, [double]$tp, [double]$mg, [double]$lv) {
    $L = @(); $warn = 0
    $slPct = [Math]::Abs($en - $sl) / $en * 100; $loss = $slPct * $lv; $lossUsd = $mg * $loss / 100
    # 1) margen
    if ($mg -gt 200) { $L += ("⚠️ Margen {0:N0} USDT: supera tu límite de 200." -f $mg); $warn++ }
    # 2) coste del SL y liquidación
    $mx = Get-SlMaxPct
    if ($loss -gt $mx) { $L += ("⚠️ El SL está a {0:N2}% del precio: con x{1:N0} pierdes {2:N0}% del margen (≈ {3:N0} USDT). Tu regla es {5:N0}% como máximo: baja el apalancamiento a x{4:N0} o acerca el SL." -f $slPct, $lv, $loss, $lossUsd, [Math]::Max(1, [Math]::Floor($mx / $slPct)), $mx); $warn++ }
    else { $L += ("✔ El SL cuesta {0:N0}% del margen (≈ {1:N0} USDT), dentro de tu regla del {2:N0}%." -f $loss, $lossUsd, $mx) }
    $liq = 100.0 / $lv - 0.3; if ($slPct -ge 0.8 * $liq) { $L += ("⚠️ El SL queda muy cerca de la liquidación (≈ a {0:N1}% del precio): un pico puede liquidarte antes de que actúe el stop." -f $liq); $warn++ }
    # 3) comisiones con apalancamiento alto
    if ($lv -ge 30) { $L += ("⚠️ Con x{0:N0} las comisiones de ida y vuelta (~0,15% del nominal) cuestan ≈ {1:N1}% del margen: si el precio apenas se mueve, pierdes igualmente." -f $lv, (0.15 * $lv)); $warn++ }
    # 4) lectura del mercado
    try {
        $s = @{ src = 'bitunix'; sym = $symR }; $cd4 = Get-MomentoCd $s '4h'; $cd1 = Get-MomentoCd $s '1d'
        if ($cd4 -and $cd1) {
            $a4 = Analyze-TF $cd4 '4h' 100; $a1 = Analyze-TF $cd1 '1d' 90; $px = $en
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
