# /consulta SIMBOLO [largo|corto]  (solo chat privado de Luis): ¿abro una operación en esta cripto de Bitunix? Veredicto claro (abrir / esperar retroceso / no abrir), plan con SL y parciales,
# apalancamiento para margen de 200 USDT en AISLADO (SL <= 20% del margen, Get-SlMaxPct) y la lectura conjunta de 1d/4h + timing de 1h (Bollinger, RSI, volumen, velas, Fibonacci). Reglas fijas y visibles.
function Get-ConsultaSide($sc, [string]$sideKey, [string]$px, $sym = $null) {
    $dir = if ($sideKey -eq 'L') { "LARGO" } else { "CORTO" }; $icon = if ($sideKey -eq 'L') { "📈" } else { "📉" }
    # SL frente a EMAs/soportes de 1h, 4h y 1d, EMAs como obstáculo del TP y contexto de EMAs clave (solo si el lado tiene plan)
    $slx = $null; if ($sym -and $sc.plan -and [int]$sc.score -ge 1 -and (Get-Command Apply-SlStructure -ErrorAction SilentlyContinue)) { try { $slx = Apply-SlStructure $sc.plan $sideKey $sym ([double]$px) } catch {}; if ($slx) { $sc.score = [int]$sc.score + [int]$slx.delta; if ($slx.ctx) { $sc.fx = @($sc.fx) + @($slx.ctx) } } }
    $score = [int]$sc.score; $tmg = if ($null -ne $sc.timing) { [int]$sc.timing } else { 0 }
    $score = [int]$sc.score
    $lv = if ($slx -and $slx.skip) { $null } else { Get-OrderLevels $sideKey $sc.plan 'cripto' $score $tmg }
    $rec = if ($slx -and $slx.skip) { "🟡 ESPERA: el plan no es operable ahora (mira el motivo abajo)" } elseif ($score -ge 7 -and $tmg -gt -3) { "✅ SE PUEDE ABRIR (con el plan de abajo)" } elseif ($score -ge 7) { "🟡 ESPERA: la lectura es buena pero el movimiento está estirado en 1h; entra en un retroceso" } elseif ($score -ge 4) { "🟡 ESPERA UN RETROCESO: aceptable pero sin ventaja clara ahora" } else { "⛔ NO LA ABRIRÍA AHORA" }
    $o = @(); $o += ("{0} {1}: puntuación {2}{3} → {4}" -f $icon, $dir, $score, $(if ($tmg -ne 0) { " (timing 1h {0:+0;-0})" -f $tmg } else { "" }), $rec)
    $neg = @($sc.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 4); $pos = @($sc.fx | Where-Object { $_ -like '✅*' } | Select-Object -First 4)
    if ($pos.Count) { $o += "   A favor:"; $pos | ForEach-Object { $o += "   $_" } }
    if ($neg.Count) { $o += "   En contra / cuidado:"; $neg | ForEach-Object { $o += "   $_" } }
    if ($lv -and $score -ge 1) {
        $lev = [int]$lv.lev; $mg = 200.0; $nom = $mg * $lev; $qty = $nom / $lv.entry; $loss = $nom * $lv.slPct / 100; $liq = 100.0 / [Math]::Max($lev, 1) - 0.3
        $o += ""; $o += "🎯 Plan ($dir, margen 200 USDT AISLADO):"
        $o += ("   Entrada {0}{1} · SL {2} ({3:N1}% del precio)" -f (TaFp $lv.entry), $(if ($sc.plan.pullback) { " (orden limit en el retroceso)" } else { " (cerca del precio actual)" }), (TaFp $lv.sl), $lv.slPct)
        $o += ("   Parciales: TP1 {0} (1R, cierra un tercio y SL a la entrada) · TP2 {1} (2R) · TP final {2} (3R)" -f (TaFp $lv.t1), (TaFp $lv.t2), (TaFp $lv.t3))
        $o += ("   Apalancamiento orientativo x{0}: posición ≈ {1:N0} USDT ({2} uds); si salta el SL pierdes ≈ {3:N0} USDT ({4:N0}% del margen); liquidación a ≈ {5:N1}% del precio" -f $lev, $nom, (TaFp $qty), $loss, ($lv.slPct * $lev), $liq)
        if ($sc.plan.ob) { $o += ("   Primer obstáculo en {0}{1}" -f (TaFp ([double]$sc.plan.ob)), $(if ($sc.plan.obTag) { " (" + $sc.plan.obTag + ")" } else { "" })) }
        if ($slx -and $slx.note) { $o += "   ℹ️ $($slx.note)" }
    }
    if ($slx -and $slx.skip) { $o += ""; $o += ("   ⚠️ Sin plan operable: {0}" -f $slx.note) }
    return $o
}
function Get-ConsultaReport($raw, $wantSide) {
    $rs = Resolve-SymbolText $raw; $q = ($rs.sym -replace '[^A-Za-z0-9]', '').ToUpper() -replace 'USDT$', ''
    if (-not $q) { return "Uso: /consulta SIMBOLO [largo|corto]  (ej.: /consulta SOL · /consulta API3 corto)" }
    $s = $null; try { $s = Get-BitunixSeries $q } catch {}
    if (-not $s) { return "No encuentro $q como futuro de Bitunix. Escribe el símbolo exacto (BTC, SOL, API3...). Para acciones o ETFs usa /momento." }
    $px = [double]$s.price; $sc = Get-MomScores $s; if (-not $sc) { return "No tengo velas suficientes de $q para una lectura fiable; no hago un veredicto sin datos." }
    $chg = ""; $fund = ""; try { $t = (Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data | Where-Object symbol -eq "${q}USDT" | Select-Object -First 1; if ($t -and [double]$t.open -gt 0) { $chg = " · {0:+0.0;-0.0}% en 24h" -f (([double]$t.lastPrice / [double]$t.open - 1) * 100) } } catch {}
    if ($s.extra -and $null -ne $s.extra.funding) { $fund = " · funding {0:+0.000;-0.000}%" -f ([double]$s.extra.funding) }
    $L = @(); if ($rs.note) { $L += $rs.note }
    $L += ("🔎 CONSULTA · {0}/USDT · precio {1}{2}{3}" -f $q, (TaFp $px), $chg, $fund); $L += ""
    $want = if ($wantSide -eq 'largo') { @('L') } elseif ($wantSide -eq 'corto') { @('S') } else { @('L', 'S') }
    foreach ($k in $want) { $L += (Get-ConsultaSide $(if ($k -eq 'L') { $sc.lg } else { $sc.st }) $k $px $q); $L += "" }
    $best = if ($sc.lg.score -ge $sc.st.score) { 'LARGO' } else { 'CORTO' }; $bs = [Math]::Max($sc.lg.score, $sc.st.score)
    if (-not $wantSide) { $L += $(if ($bs -ge 7) { "➡️ Mi lectura: lo mejor ahora sería un $best, solo con el plan y el SL de arriba." } elseif ($bs -ge 4) { "➡️ Mi lectura: el lado $best es el menos malo, pero espera un retroceso; no hay urgencia." } else { "➡️ Mi lectura: ninguno de los dos lados está claro; esperar también es una posición." }) }
    else { $other = if ($wantSide -eq 'largo') { $sc.st.score } else { $sc.lg.score }; $mine = if ($wantSide -eq 'largo') { $sc.lg.score } else { $sc.st.score }; if ($other -ge $mine + 3) { $L += ("➡️ Ojo: el lado contrario puntúa {0} frente a {1} del que preguntas." -f $other, $mine) } }
    try { if (Get-Command Get-MultiTfLine -ErrorAction SilentlyContinue) { $sgm = if ($wantSide -eq 'largo') { 1 } elseif ($wantSide -eq 'corto') { -1 } else { 0 }; $mt = Get-MultiTfLine $sgm $q $px; if ($mt) { $L += $mt; $L += "" } } } catch {}      # 15m, 1h, 4h, 1D, 1S y 1M
    try { if (Get-Command Get-SmartMoneyLines -ErrorAction SilentlyContinue) { $sm = @(Get-SmartMoneyLines $q); if ($sm.Count) { $L += $sm; $L += "" } } } catch {}
    $L += "🔒 Opera siempre en AISLADO (Bitunix puede ofrecerte cruzado por defecto en monedas nuevas), con SL puesto y parciales en tercios."
    $L += "ℹ️ Lectura de contexto con reglas fijas (estructura, ADX, MACD, RSI, Bollinger, volumen, obstáculos, funding y timing de 1h). No está validada como la táctica de rupturas con retesteo y no garantiza resultados. Si la abres, mándame la captura de la posición y la sigo en vivo."
    return ($L -join "`n")
}
function Handle-Consulta($ra) {
    $words = @($ra | ForEach-Object { "$_" }); $side = ""; $sym = @()
    foreach ($w in $words) { $lw = $w.ToLower(); if ($lw -in 'largo', 'long', 'compra') { $side = 'largo' } elseif ($lw -in 'corto', 'short', 'venta') { $side = 'corto' } elseif ($lw -in 'de', 'la', 'el', 'sobre', 'cripto', 'crypto', 'abrir') { } else { $sym += $w } }
    if (-not $sym.Count) { return "Uso: /consulta SIMBOLO [largo|corto]`nEjemplos: /consulta SOL · /consulta API3 corto · /consulta BTC largo`nTe digo si abrir ahora, esperar o no abrir, con plan de SL y parciales." }
    return (Get-ConsultaReport ($sym -join ' ') $side)
}
