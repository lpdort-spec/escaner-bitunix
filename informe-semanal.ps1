# Informe semanal profundo: resultados de la semana, diagnóstico de cada fallo (por qué y cómo), patrones, oportunidades perdidas e hipótesis de mejora.
# Regla: los diagnósticos son HIPÓTESIS calculadas con datos de velas y de contexto; con pocas operaciones no son concluyentes y el informe lo dice.
# Las hipótesis de mejora nunca se aplican solas: se proponen para decidirlas con más muestra.
if (-not (Get-Command Fmt -ErrorAction SilentlyContinue)) { function Fmt($x) { if ($x -ge 100) { return ("{0:N2}" -f $x) } elseif ($x -ge 1) { return ("{0:N4}" -f $x) } else { return ("{0:G5}" -f $x) } } }

function Get-FailureDiagnosis($s) {
    $res = @{ cls = "sin datos de velas posteriores"; mfe = $null; bars = $null; recov = $null; backInside = $null }
    if (-not $s.lab0) { return $res }
    try { $k = @((Invoke-RestMethod "$($script:TrkBase)/kline?symbol=$($s.sym)&interval=$($s.tf)&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $k = @($k[0..($k.Count - 2)]) } catch { return $res }
    $sg = [int]$s.side; $risk = [double]$s.riskAbs; $en = [double]$s.entry; $sl = [double]$s.sl; $tp1 = [double]$s.tp1
    $post = @($k | Where-Object { [long]$_.time -gt [long]$s.lab0 }); if ($post.Count -eq 0) { return $res }
    $filled = ($s.entryType -ne 'limit'); $i0 = 0; $mfe = 0.0; $iSl = $null
    for ($i = 0; $i -lt $post.Count; $i++) {
        $hi = [double]$post[$i].high; $lo = [double]$post[$i].low
        if (-not $filled) { if (($sg -eq 1 -and $lo -le $en) -or ($sg -eq -1 -and $hi -ge $en)) { $filled = $true; $i0 = $i } else { continue } }
        $hitSl = if ($sg -eq 1) { $lo -le $sl } else { $hi -ge $sl }
        if ($hitSl) { $iSl = $i; break }
        $fav = if ($sg -eq 1) { ($hi - $en) / $risk } else { ($en - $lo) / $risk }
        if ($fav -gt $mfe) { $mfe = $fav }
    }
    if ($null -eq $iSl) { return $res }
    $bars = $iSl - $i0 + 1
    $recov = $false
    foreach ($c in @($post | Select-Object -Skip ($iSl + 1) -First 12)) { if (($sg -eq 1 -and [double]$c.high -ge $tp1) -or ($sg -eq -1 -and [double]$c.low -le $tp1)) { $recov = $true; break } }
    $back = $false
    for ($j = $i0; $j -lt $iSl; $j++) { $cl = [double]$post[$j].close; if (($sg -eq 1 -and $cl -lt $en) -or ($sg -eq -1 -and $cl -gt $en)) { $back = $true } }
    $cls = if ($mfe -ge 0.7) { "Reversión tras avance (casi llegó a TP1)" }
           elseif ($recov) { "Barrido de stop y recuperación (tocó el SL y luego llegó a TP1)" }
           elseif ($bars -le 3 -and $mfe -lt 0.3) { "Ruptura fallida (sin continuidad)" }
           else { "Pérdida gradual de estructura" }
    return @{ cls = $cls; mfe = $mfe; bars = $bars; recov = $recov; backInside = $back }
}

function Get-ContextFlags($s) {
    $f = @(); $sg = [int]$s.side
    if ($s.btcAligned -eq $false) { $f += "BTC en contra" }
    if ($s.aligned -eq $false) { $f += "sin tendencia superior a favor" }
    if ($null -ne $s.funding -and (($sg -eq 1 -and [double]$s.funding -ge 0.03) -or ($sg -eq -1 -and [double]$s.funding -le -0.03))) { $f += "funding saturado del mismo lado" }
    if ($null -ne $s.sentiment -and (($sg -eq 1 -and [double]$s.sentiment -ge 75) -or ($sg -eq -1 -and [double]$s.sentiment -le 25))) { $f += "sentimiento extremo a favor de la operación (FOMO/FUD tardío)" }
    if ($s.risk -in 'ALTO', 'MUY ALTO') { $f += "moneda de riesgo alto" }
    if ($null -ne $s.slPct -and [double]$s.slPct -lt 1.3) { $f += "SL ajustado (<1,3%)" }
    if ($null -ne $s.ratio -and [double]$s.ratio -lt 3) { $f += "volumen de ruptura moderado (<x3)" }
    if ($null -ne $s.book -and (($sg -eq 1 -and [double]$s.book -lt 45) -or ($sg -eq -1 -and [double]$s.book -gt 55))) { $f += "libro de órdenes en contra" }
    return $f
}

function Get-WeeklyDeepReport {
    $now = Get-MadridNow; $all = @(Read-Signals | Where-Object { $_.manual -ne $true -and $_.strat -ne 'barrido-obs' -and $_.strat -ne 'ruptura-mercado' })
    $wkStart = [DateTimeOffset]::UtcNow.AddDays(-7).ToUnixTimeSeconds()
    $week = @($all | Where-Object { [long]$_.time -ge $wkStart })
    $wkCl = @($week | Where-Object { $_.status -eq 'closed' }); $allCl = @($all | Where-Object { $_.status -eq 'closed' })
    $L = @(("📚 INFORME SEMANAL PROFUNDO · semana del {0:dd/MM} al {1:dd/MM/yyyy} (hora de España)" -f $now.AddDays(-7), $now))
    $L += ""
    # 1) Resumen
    $L += "1️⃣ RESUMEN EJECUTIVO"
    $nPend = @($week | Where-Object { $_.status -in 'open', 'pending' }).Count; $nUn = @($week | Where-Object { $_.status -eq 'unfilled' }).Count
    $L += ("• Señales emitidas esta semana: {0} · cerradas: {1} · abiertas/pendientes: {2} · sin ejecutar: {3}" -f $week.Count, $wkCl.Count, $nPend, $nUn)
    if ($wkCl.Count) {
        $w = @($wkCl | Where-Object { $_.outcome -ne 'SL' -and [double]$_.net -gt 0 }); $tp1 = @($wkCl | Where-Object { $_.outcome -in 'TP1 + BE', 'TP2 + BE', 'TP3' })
        $L += ("• Semana: llegan a TP1 {0:N0}% · ganadoras netas {1}/{2} · esperanza {3:+0.00;-0.00}R por operación (R = riesgo hasta el SL; comisiones descontadas)" -f (100.0 * $tp1.Count / $wkCl.Count), $w.Count, $wkCl.Count, ($wkCl | Measure-Object net -Average).Average)
    } else { $L += "• Semana sin operaciones cerradas: no hay resultados que analizar todavía." }
    if ($allCl.Count) { $L += ("• Acumulado: {0} cerradas · llegan a TP1 {1:N0}% · esperanza {2:+0.00;-0.00}R" -f $allCl.Count, (100.0 * @($allCl | Where-Object { $_.outcome -in 'TP1 + BE', 'TP2 + BE', 'TP3' }).Count / $allCl.Count), ($allCl | Measure-Object net -Average).Average) }
    $verd = if ($allCl.Count -lt 30) { "Muestra insuficiente (n={0}): con tan pocas operaciones el azar domina; NO se puede concluir que el método funcione ni que falle." -f $allCl.Count } elseif (($allCl | Measure-Object net -Average).Average -gt 0.1) { "Esperanza positiva sostenida con n={0}: señal alentadora, pendiente de más muestra para confirmarla." -f $allCl.Count } elseif (($allCl | Measure-Object net -Average).Average -lt -0.1) { "Esperanza negativa con n={0}: el método, tal como está, pierde dinero; hay que corregirlo antes de arriesgar capital." -f $allCl.Count } else { "Esperanza cercana a cero con n={0}: ni ventaja clara ni fallo claro." -f $allCl.Count }
    $L += "• Veredicto: $verd"
    # 2) Operaciones de la semana
    $L += ""; $L += "2️⃣ OPERACIONES DE LA SEMANA"
    if ($week.Count -eq 0) { $L += "• El escáner no encontró ningún setup que cumpliera todas las reglas (SL, potencial ≥25% ROI, comisiones, tendencia). Es esperable: las reglas son exigentes y no se fuerza operar." }
    foreach ($s in ($week | Sort-Object time)) {
        $when = [DateTimeOffset]::FromUnixTimeSeconds([long]$s.time).UtcDateTime; $when = [TimeZoneInfo]::ConvertTimeFromUtc($when, [TimeZoneInfo]::FindSystemTimeZoneById("Romance Standard Time"))
        $res = if ($s.status -eq 'closed') { "{0} → {1:+0.00;-0.00}R netos" -f $s.outcome, [double]$s.net } elseif ($s.status -eq 'unfilled') { "no ejecutada ($($s.note))" } else { "abierta" }
        $L += ("• {0:ddd HH:mm} · {1} {2} {3} · {4}" -f $when, ($s.sym -replace 'USDT$', ''), $(if ([int]$s.side -eq 1) { "LARGO" } else { "CORTO" }), $s.tf, $res)
    }
    # 3) Fallos
    $fails = @($allCl | Where-Object { $_.outcome -eq 'SL' })
    $L += ""; $L += "3️⃣ ANÁLISIS DE LOS FALLOS (stop loss)"
    $diag = @{}
    if ($fails.Count -eq 0) { $L += "• Ningún fallo registrado todavía." }
    foreach ($s in $fails) {
        $d = Get-FailureDiagnosis $s; $diag[$s.id] = $d; $fl = @(Get-ContextFlags $s)
        $esSemana = [long]$s.time -ge $wkStart
        if (-not $esSemana -and $fails.Count -gt 6) { continue }
        $when = [TimeZoneInfo]::ConvertTimeFromUtc([DateTimeOffset]::FromUnixTimeSeconds([long]$s.time).UtcDateTime, [TimeZoneInfo]::FindSystemTimeZoneById("Romance Standard Time"))
        $L += ("• {0:dd/MM HH:mm} · {1} {2} {3} · entrada {4} · SL {5} ({6:N2}%)" -f $when, ($s.sym -replace 'USDT$', ''), $(if ([int]$s.side -eq 1) { "LARGO" } else { "CORTO" }), $s.tf, (Fmt ([double]$s.entry)), (Fmt ([double]$s.sl)), [double]$s.slPct)
        $L += ("   Qué pasó: {0}{1}" -f $d.cls, $(if ($null -ne $d.mfe) { " · el precio avanzó {0:N2}R a favor antes de girar · SL tras {1} vela(s)" -f $d.mfe, $d.bars } else { "" }))
        if ($d.backInside) { $L += "   Cierres de vela de vuelta al otro lado del nivel de entrada antes del stop: la ruptura no fue aceptada por el mercado." }
        $L += $(if ($fl.Count) { "   Factores de contexto que pesaban en contra: " + ($fl -join "; ") + "." } else { "   Contexto al entrar: sin factores de riesgo registrados; fallo atribuible a la varianza normal del método." })
    }
    # 4) Patrones
    $L += ""; $L += "4️⃣ PATRONES"
    if ($fails.Count -ge 1) {
        $grp = $fails | Group-Object { if ($diag[$_.id]) { $diag[$_.id].cls } else { "n/d" } } | Sort-Object Count -Descending
        $L += "• Tipos de fallo (acumulado): " + (($grp | ForEach-Object { "{0} ×{1}" -f $_.Name, $_.Count }) -join " · ")
        $rec = @($fails | Where-Object { $diag[$_.id] -and $diag[$_.id].recov }).Count
        if ($rec -ge 2 -and $fails.Count -ge 5) { $L += ("   Hipótesis: {0} de {1} fallos fueron barridos de stop (el precio llegó a TP1 después). Posible SL demasiado pegado a la liquidez; a valorar un SL algo más amplio con menos apalancamiento." -f $rec, $fails.Count) }
    }
    if ($allCl.Count -ge 20) {
        $flagDefs = @(
            @{ n = "BTC en contra"; f = { param($s) $s.btcAligned -eq $false } }
            @{ n = "sin tendencia superior a favor"; f = { param($s) $s.aligned -eq $false } }
            @{ n = "funding saturado del mismo lado"; f = { param($s) (Get-ContextFlags $s) -contains "funding saturado del mismo lado" } }
            @{ n = "SL ajustado (<1,3%)"; f = { param($s) $null -ne $s.slPct -and [double]$s.slPct -lt 1.3 } }
            @{ n = "volumen de ruptura moderado (<x3)"; f = { param($s) $null -ne $s.ratio -and [double]$s.ratio -lt 3 } }
            @{ n = "moneda de riesgo alto"; f = { param($s) $s.risk -in 'ALTO', 'MUY ALTO' } }
        )
        $L += "• Factores de contexto (esperanza en R con el factor / sin él; solo si hay ≥6 operaciones con el factor):"
        $any = $false
        foreach ($fd in $flagDefs) {
            $with = @($allCl | Where-Object { & $fd.f $_ }); $without = @($allCl | Where-Object { -not (& $fd.f $_) })
            if ($with.Count -ge 6 -and $without.Count -ge 6) {
                $any = $true; $a = ($with | Measure-Object net -Average).Average; $b = ($without | Measure-Object net -Average).Average
                $L += ("   - {0}: {1:+0.00;-0.00}R (n={2}) frente a {3:+0.00;-0.00}R (n={4})" -f $fd.n, $a, $with.Count, $b, $without.Count)
            }
        }
        if (-not $any) { $L += "   (ningún factor tiene aún muestra suficiente para compararse)" }
    } else { $L += ("• Comparación por factores: no disponible hasta tener ≥20 operaciones cerradas (hay {0})." -f $allCl.Count) }
    # 5) No ejecutadas
    $un = @($all | Where-Object { $_.status -eq 'unfilled' })
    $L += ""; $L += "5️⃣ ÓRDENES NO EJECUTADAS Y OPORTUNIDADES PERDIDAS"
    if ($un.Count -eq 0) { $L += "• Ninguna orden limit quedó sin ejecutar." } else {
        $L += ("• {0} orden(es) sin ejecutar: " -f $un.Count) + (($un | Group-Object note | ForEach-Object { "{0} ×{1}" -f $_.Name, $_.Count }) -join " · ")
        $lost = @($un | Where-Object { $_.note -like '*sin dar entrada*' }).Count
        if ($lost) { $L += ("   {0} se fueron hacia el objetivo sin dar la entrada: el nivel de retesteo fue demasiado exigente en esos casos (coste de oportunidad; no es pérdida)." -f $lost) }
    }
    # 6) Manuales
    $man = @(Get-ManualSection); if ($man.Count -gt 2) { $L += ""; $L += "6️⃣ TUS OPERACIONES MANUALES (resultado en USDT; comisiones estimadas al 0,10%)"; $L += @($man | Select-Object -Skip 2) }
    try { $obs = @(Get-ObsSection); if ($obs.Count) { $L += $obs } } catch {}
    try { $mk = @(Get-MarketSection); if ($mk.Count) { $L += $mk } } catch {}
    # 7) Hipótesis y estado
    $L += ""; $L += "7️⃣ HIPÓTESIS DE MEJORA (no se aplican solas)"
    if ($allCl.Count -lt 20) { $L += "• Sin cambios recomendados: con menos de 20 operaciones cerradas cualquier ajuste sería ajustar al ruido. Se mantiene el método y se sigue acumulando datos." }
    else { $L += "• Revisar solo los factores de la sección 4 que muestren esperanza claramente peor con n≥6; si se confirma en las próximas semanas, penalizarlos o filtrarlos y validarlo con el backtest antes de aplicarlo." }
    $L += ""; $L += "8️⃣ ESTADO FRENTE AL OBJETIVO"
    $L += ("• Operaciones cerradas con el método actual: {0}. Para valorar con seriedad automatizar o arriesgar más capital se necesitan al menos 50-100, con esperanza positiva sostenida." -f $allCl.Count)
    $L += ""; $L += "Metodología: R = distancia al SL; resultados netos de comisiones (0,10% ida y vuelta); si una vela toca SL y TP, se asume SL primero (conservador); gestión simulada: un tercio en TP1/TP2/TP3 y SL a la entrada tras TP1. Los diagnósticos son hipótesis basadas en datos, no certezas. No es asesoramiento financiero."
    return ($L -join "`n")
}
