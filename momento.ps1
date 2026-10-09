# /momento SIMBOLO [largo|corto]: ¿es buen momento para abrir una operación a largo o a corto en este activo (acción, ETF, cripto...)?
# Puntúa cada lado con reglas FIJAS y visibles (estructura 1d y 4h, ADX, MACD, RSI, Bollinger, volumen, espacio hasta el siguiente obstáculo, barridos de liquidez, TradingView, sentimiento, funding).
# IMPORTANTE: es una lectura de contexto con reglas fijas; NO está validada en backtest (la táctica de rupturas con retesteo sí lo está, y esas señales las publica el bot).

function Resolve-SeriesM($raw, $mode) {      # mismo criterio de resolución que /informe
    $q = ($raw -replace '[^A-Za-z0-9.\-\^=]', '').ToUpper(); if (-not $q -or $q.Length -gt 15) { return $null }
    $base0 = $q -replace 'USDT$', ''; $isCrypto = $false; $s = $null
    if ($mode -eq "cripto" -or $q -like '*USDT') { $isCrypto = $true }
    elseif ($mode -ne "accion") { try { $g = Invoke-RestMethod "https://api.coingecko.com/api/v3/search?query=$([uri]::EscapeDataString($base0))" -Headers $script:UA -TimeoutSec 20; $hit = @($g.coins | Where-Object { $_.symbol -eq $base0 -and $_.market_cap_rank -and [int]$_.market_cap_rank -le 300 }); if ($hit.Count) { $isCrypto = $true } } catch {} }
    if ($isCrypto) { try { $s = Get-BitunixSeries $base0 } catch {}; if (-not $s) { try { $s = Get-GeckoSeries $base0 } catch {} }; if (-not $s -and $mode -ne "cripto") { try { $s = Get-YahooSeries $q } catch {} } }
    else { try { $s = Get-YahooSeries $q } catch {}; if (-not $s -and $mode -ne "accion") { try { $s = Get-BitunixSeries $base0 } catch {} }; if (-not $s -and $mode -ne "accion") { try { $s = Get-GeckoSeries $base0 } catch {} } }
    return $s
}
function Get-MomentoCd($s, $tf) {
    $cd = $null
    if ($s.src -eq 'bitunix') { $cd = Get-BitunixCd $s.sym $tf; if (-not $cd) { $cd = Get-BinanceSpotCd $s.sym $tf } }
    elseif ($s.src -eq 'yahoo') { $cd = Get-YahooCd $s.sym $tf }
    elseif ($s.src -eq 'gecko') { $cd = Get-BinanceSpotCd $s.sym $tf; if (-not $cd -and $tf -eq '4h' -and $s.id) { $cd = Get-GeckoCd $s.id } }
    return $cd
}

function Score-Momento([int]$sg, $a4, $a1, $tvR, [double]$px, $sentVal, $fund) {
    $pts = 0; $fx = @(); $dir = if ($sg -eq 1) { "largo" } else { "corto" }
    $add = { param([int]$p, [string]$txt) $script:__pts += $p; $script:__fx += ("{0} {1}" -f $(if ($p -gt 0) { "✅" } elseif ($p -lt 0) { "⚠️" } else { "·" }), $txt) }
    $script:__pts = 0; $script:__fx = @()
    $al = { param($st) (($sg -eq 1 -and $st -eq 'up') -or ($sg -eq -1 -and $st -eq 'down')) }; $co = { param($st) (($sg -eq 1 -and $st -eq 'down') -or ($sg -eq -1 -and $st -eq 'up')) }
    if ($a1) {
        $m = $a1.m
        if (& $al $m.struct) { & $add 2 "Estructura diaria a favor del $dir (máximos/mínimos en esa dirección)" } elseif (& $co $m.struct) { & $add -2 "Estructura diaria EN CONTRA del $dir" } else { & $add 0 "Estructura diaria mixta/lateral" }
        if ($m.adx -ge 20 -and (($sg -eq 1 -and $m.pdi -gt $m.mdi) -or ($sg -eq -1 -and $m.mdi -gt $m.pdi))) { & $add 1 ("Tendencia diaria con fuerza a favor (ADX {0:N0})" -f $m.adx) } elseif ($m.adx -ge 25 -and (($sg -eq 1 -and $m.mdi -gt $m.pdi) -or ($sg -eq -1 -and $m.pdi -gt $m.mdi))) { & $add -1 ("Tendencia diaria fuerte EN CONTRA (ADX {0:N0})" -f $m.adx) }
    } else { & $add 0 "Sin velas diarias suficientes: no se valora la estructura diaria" }
    if ($a4) {
        $m = $a4.m
        if (& $al $m.struct) { & $add 1 "Estructura 4h a favor" } elseif (& $co $m.struct) { & $add -1 "Estructura 4h en contra" } else { & $add 0 "Estructura 4h mixta" }
        if (($sg -eq 1 -and $m.macd -gt 0) -or ($sg -eq -1 -and $m.macd -lt 0)) { & $add 1 "MACD 4h a favor" } else { & $add -1 "MACD 4h en contra" }
        $r = [double]$m.rsi
        if ($sg -eq 1) { if ($r -ge 72) { & $add -1 ("RSI 4h en sobrecompra ({0:N0}): entrar ahora es perseguir" -f $r) } elseif ($r -ge 40) { & $add 1 ("RSI 4h sano ({0:N0})" -f $r) } else { & $add 0 ("RSI 4h débil ({0:N0})" -f $r) } }
        else { if ($r -le 28) { & $add -1 ("RSI 4h en sobreventa ({0:N0}): entrar ahora es perseguir" -f $r) } elseif ($r -le 60) { & $add 1 ("RSI 4h sano ({0:N0})" -f $r) } else { & $add 0 ("RSI 4h elevado ({0:N0})" -f $r) } }
        if (($sg -eq 1 -and $m.bandPos -like 'FUERA de la banda superior*') -or ($sg -eq -1 -and $m.bandPos -like 'FUERA de la banda inferior*')) { & $add -1 "Precio fuera de la banda de Bollinger 4h en tu dirección: extendido" }
        if ($m.obv -eq 'confirma') { & $add 1 "Volumen (OBV 4h) acompaña al precio" } elseif (($sg -eq 1 -and $m.obv -eq 'div-bajista') -or ($sg -eq -1 -and $m.obv -eq 'div-alcista')) { & $add -1 "Divergencia de volumen 4h en contra" }
        if ($m.sweep) { $sw = "$($m.sweep)"; $lowSweep = $sw -like '*mínimos*'; $conf = $sw -like '*CONFIRMADO*'
            if ($conf -and (($sg -eq 1 -and $lowSweep) -or ($sg -eq -1 -and -not $lowSweep))) { & $add 1 "Barrido de liquidez reciente CONFIRMADO a favor" }
            elseif ($conf) { & $add -1 "Barrido de liquidez reciente confirmado EN CONTRA" }
            else { & $add 0 "Barrido de liquidez reciente SIN confirmar: esperar el cierre de confirmación" } }
    } else { & $add 0 "Sin velas de 4h suficientes" }
    # TradingView
    if ($tvR) { $t4 = ($tvR | Where-Object { $_.tf -eq '4h' } | Select-Object -First 1).all; $t1 = ($tvR | Where-Object { $_.tf -eq '1d' } | Select-Object -First 1).all
        if ($null -ne $t4 -and $null -ne $t1) {
            if (($sg -eq 1 -and $t4 -ge 0.1 -and $t1 -ge 0.1) -or ($sg -eq -1 -and $t4 -le -0.1 -and $t1 -le -0.1)) { & $add 1 "TradingView (4h y 1d) a favor" }
            elseif (($sg -eq 1 -and $t4 -le -0.1 -and $t1 -le -0.1) -or ($sg -eq -1 -and $t4 -ge 0.1 -and $t1 -ge 0.1)) { & $add -1 "TradingView (4h y 1d) en contra" }
            else { & $add 0 "TradingView dividido entre 4h y 1d" } } }
    # sentimiento y funding
    if ($null -ne $sentVal) { if ($sg -eq 1 -and $sentVal -ge 75) { & $add -1 ("Sentimiento de euforia extrema ({0:N0}/100): los largos tardíos son vulnerables" -f $sentVal) } elseif ($sg -eq -1 -and $sentVal -le 25) { & $add -1 ("Sentimiento de pánico extremo ({0:N0}/100): riesgo de rebote contra el corto" -f $sentVal) } }
    if ($null -ne $fund) { if ($sg -eq 1 -and $fund -ge 0.03) { & $add -1 ("Funding alto ({0:N3}%): largos saturados" -f $fund) } elseif ($sg -eq -1 -and $fund -le -0.03) { & $add -1 ("Funding muy negativo ({0:N3}%): cortos saturados" -f $fund) } }
    # plan orientativo y espacio hasta el obstáculo
    $plan = $null
    if ($a4) {
        $atr = $a4.atr; $sups = @(); $ress = @(); foreach ($a in $a4, $a1) { if ($a) { $sups += $a.sup; $ress += $a.res } }
        $ext = ($a4.m.bandPos -like 'FUERA*') -or ($a4.m.pctB -ge 90 -and $sg -eq 1) -or ($a4.m.pctB -le 10 -and $sg -eq -1)
        if ($sg -eq 1) {
            $s0 = @($sups | Where-Object { $_.p -lt $px } | Sort-Object { $_.p } -Descending | Select-Object -First 1); $entry = if ($ext -and $s0) { [Math]::Max($s0[0].p, $px - 1.0 * $atr) } else { $px }
            $s1 = @($sups | Where-Object { $_.p -lt $entry } | Sort-Object { $_.p } -Descending | Select-Object -First 1); $sl = if ($s1) { $s1[0].p - 0.5 * $atr } else { $entry - 1.5 * $atr }
        } else {
            $r0 = @($ress | Where-Object { $_.p -gt $px } | Sort-Object { $_.p } | Select-Object -First 1); $entry = if ($ext -and $r0) { [Math]::Min($r0[0].p, $px + 1.0 * $atr) } else { $px }
            $r1 = @($ress | Where-Object { $_.p -gt $entry } | Sort-Object { $_.p } | Select-Object -First 1); $sl = if ($r1) { $r1[0].p + 0.5 * $atr } else { $entry + 1.5 * $atr }
        }
        $risk = $sg * ($entry - $sl); if ($risk -lt 1.5 * $atr) { $sl = $entry - $sg * 1.5 * $atr }; if ($risk -gt 2.5 * $atr) { $sl = $entry - $sg * 2.5 * $atr }; $R = $sg * ($entry - $sl)      # SL entre 1,5 y 2,5 ATR(4h): con 0,8-1,0 ATR el backtest da -0,14R/-0,10R y con 1,5 ATR -0,04R; en las señales reales 11 de 11 con SL < 2,5% fueron al SL (09/10/2026)
        if ($R -gt 0) {
            $ob = @(if ($sg -eq 1) { $ress | Where-Object { $_.p -gt $entry } | Sort-Object { $_.p } | Select-Object -First 1 } else { $sups | Where-Object { $_.p -lt $entry } | Sort-Object { $_.p } -Descending | Select-Object -First 1 })
            $room = if ($ob) { [Math]::Abs($ob[0].p - $entry) / $R } else { 99.0 }
            if ($room -ge 3) { & $add 2 ("Espacio hasta el siguiente obstáculo: {0}R" -f $(if ($room -ge 99) { ">3" } else { "{0:N1}" -f $room })) } elseif ($room -ge 2) { & $add 1 ("Espacio hasta el siguiente obstáculo: {0:N1}R" -f $room) } elseif ($room -ge 1.5) { & $add 0 ("Espacio justo hasta el obstáculo: {0:N1}R" -f $room) } else { & $add -2 ("Obstáculo muy cerca ({0:N1}R): recorrido cortado" -f $room) }
            $plan = @{ atr4h = $atr; entry = $entry; sl = $sl; R = $R; tp1 = $entry + $sg * $R; tp2 = $entry + $sg * 2 * $R; tp3 = $entry + $sg * 3 * $R; ob = $(if ($ob) { $ob[0].p } else { $null }); room = $room; pullback = ($entry -ne $px) }
        }
    }
    return @{ score = $script:__pts; fx = @($script:__fx); plan = $plan; dir = $dir }
}

function Get-MomentoReport($raw, $mode, $wantSide) {
    $rsM = Resolve-SymbolText $raw; $raw = $rsM.sym
    $s = Resolve-SeriesM $raw $mode
    if (-not $s -and $raw) { $rsM2 = Resolve-SymbolText $raw -Force; if ($rsM2.sym -and $rsM2.sym -ne $raw) { $s = Resolve-SeriesM $rsM2.sym $mode; if ($s) { $rsM = $rsM2 } } }
    if (-not $s) { return "No he podido obtener datos fiables de '$($raw.ToUpper())'. Prueba con el símbolo exacto (AAPL, MSFT, SAN.MC, BTC, SOL...). No voy a inventar datos." }
    $cd4 = Get-MomentoCd $s '4h'; $cd1 = Get-MomentoCd $s '1d'
    if (-not $cd4 -and -not $cd1) { return "Tengo el precio de $($s.name) pero no velas suficientes para una lectura fiable del momento. No hago un veredicto sin datos." }
    $a4 = if ($cd4) { Analyze-TF $cd4 '4h' 100 } else { $null }; $a1 = if ($cd1) { Analyze-TF $cd1 '1d' 90 } else { $null }
    $px = [double]$s.price
    $tv = $null; try { $tv = Resolve-TvTarget $(if ($s.src -eq 'yahoo') { 'yahoo' } else { $s.src }) $s.sym $s.exch } catch {}
    $sentTxt = $null; $sentVal = $null; try { $sentTxt = Get-MarketSentiment ($s.src -ne 'yahoo'); if ($sentTxt -match '(\d+)/100') { $sentVal = [double]$Matches[1] } } catch {}
    $fund = if ($s.extra -and $null -ne $s.extra.funding) { [double]$s.extra.funding } else { $null }
    $lg = Score-Momento 1 $a4 $a1 $(if ($tv) { $tv.rating } else { $null }) $px $sentVal $fund
    $st = Score-Momento -1 $a4 $a1 $(if ($tv) { $tv.rating } else { $null }) $px $sentVal $fund
    if (Get-Command Get-Timing1hBoth -ErrorAction SilentlyContinue) {      # capa de timing 1h (cripto de Bitunix)
        try { $tm = Get-Timing1hBoth $s $px
            if ($tm) { foreach ($pair in @(@($lg, $tm.lg), @($st, $tm.st))) { $sc = $pair[0]; $t = $pair[1]; if ($sc -and $t) { $sc.score = [int]$sc.score + [int]$t.adj; $sc.fx = @($sc.fx) + @($t.fx) } } }
        } catch {}
    }
    $verd = { param($p) if ($p -ge 7) { "🟢 BUEN MOMENTO RELATIVO" } elseif ($p -ge 4) { "🟡 ACEPTABLE CON CAUTELA (mejor entrando en un retroceso)" } elseif ($p -ge 1) { "🟠 POCO FAVORABLE: mejor esperar" } else { "🔴 NO ES BUEN MOMENTO" } }
    $L = @()
    if ($rsM.note) { $L += $rsM.note; $L += "" }
    $L += ("🧭 ¿ES BUEN MOMENTO? · {0} · precio {1} {2}" -f $s.name, (TaFp $px), $s.currency)
    $L += ""
    $L += ("📈 LARGO: {0} (puntuación {1})" -f (& $verd $lg.score), $lg.score)
    $L += ("📉 CORTO: {0} (puntuación {1})" -f (& $verd $st.score), $st.score)
    $best = if ($lg.score -ge $st.score) { $lg } else { $st }
    if ($wantSide -eq 'largo') { $best = $lg } elseif ($wantSide -eq 'corto') { $best = $st }
    $L += ""
    if ($wantSide) {
        $otro = if ($best.dir -eq "largo") { $st } else { $lg }
        if ($best.score -ge 4) { $L += ("➡️ Conclusión para el {0} que preguntas: sí es un momento razonable ({1}), siempre con el plan de abajo y stop loss." -f $best.dir.ToUpper(), $best.score) }
        else { $L += ("➡️ Conclusión para el {0} que preguntas: ahora NO es buen momento (puntuación {1}). {2}" -f $best.dir.ToUpper(), $best.score, $(if ($otro.score -ge 4) { "El lado " + $otro.dir.ToUpper() + " tiene " + $otro.score + " puntos; mira su plan antes de decidir." } else { "Esperar un retroceso a un nivel o una confirmación es lo más sensato." })) }
    }
    elseif ($best.score -ge 4) { $L += ("➡️ Conclusión: el lado más favorable ahora es el {0}, pero entra solo con el plan de abajo (retesteo/confirmación) y con stop loss." -f $best.dir.ToUpper()) }
    elseif ([Math]::Max($lg.score, $st.score) -ge 1) { $L += "➡️ Conclusión: no hay un lado claramente favorable; lo más sensato es esperar un retroceso a un nivel o una confirmación." }
    else { $L += "➡️ Conclusión: ahora mismo los dos lados tienen más factores en contra que a favor; esperar es una posición válida." }
    $L += ""; $L += ("Factores del {0}:" -f $best.dir); foreach ($f in $best.fx) { $L += "   $f" }
    if ($s.src -eq 'bitunix' -and (Get-Command Get-MultiTfLine -ErrorAction SilentlyContinue)) { try { $mt = Get-MultiTfLine $(if ($best.dir -eq 'largo') { 1 } else { -1 }) ($s.sym -replace 'USDT$', '') $px; if ($mt) { $L += ""; $L += $mt } } catch {} }      # 15m, 1h, 4h, 1D, 1S y 1M
    if ($best.plan -and $best.score -ge 1) {
        $p = $best.plan; $dirU = if ($best.dir -eq "largo") { "COMPRA" } else { "VENTA en corto" }
        $L += ""; $L += "🎯 Plan orientativo (si decides entrar; no es una señal validada):"
        $L += ("   Entrada {0}: {1}{2} · SL {3} ({4:N1}%) · TP1 {5} · TP2 {6} · TP3 {7}" -f $dirU, (TaFp $p.entry), $(if ($p.pullback) { " (orden limit en el retroceso; el precio actual está extendido)" } else { " (cerca del precio actual)" }), (TaFp $p.sl), ([Math]::Abs($p.sl / $p.entry - 1) * 100), (TaFp $p.tp1), (TaFp $p.tp2), (TaFp $p.tp3))
        $L += ("   Gestión: un tercio en cada objetivo (1R/2R/3R) y SL a la entrada tras el TP1. Arriesga como máximo ~1% de tu capital; el nº de unidades = riesgo ÷ ({0}).{1}" -f (TaFp $p.R), $(if ($p.ob) { " Primer obstáculo en " + (TaFp $p.ob) + "." } else { "" }))
    }
    $other = if ($best.dir -eq "largo") { $st } else { $lg }
    if ($other.fx.Count) { $L += ""; $L += ("Factores del {0} (resumen):" -f $other.dir); foreach ($f in ($other.fx | Where-Object { $_ -notlike '· *' } | Select-Object -First 4)) { $L += "   $f" } }
    if ($sentTxt) { $L += ""; $L += "🌡️ $sentTxt" }
    if ($tv) { $L += ""; $L += (Get-TvLines $tv -Short) }
    try { $L += ""; $L += (Get-NewsSection $s.sym $s.name ($s.src -ne 'yahoo') -Short) } catch {}
    $L += ""; $L += "ℹ️ Cómo leer esto: la puntuación suma factores a favor y resta los en contra con reglas fijas (estructura diaria y 4h, ADX, MACD, RSI, Bollinger, volumen, espacio hasta el obstáculo, barridos de liquidez, TradingView, sentimiento y funding). Es una lectura de CONTEXTO: no está validada en backtest como la táctica de rupturas con retesteo (esa sí lo está y sus señales las publica el bot). Ninguna lectura garantiza resultados. No es asesoramiento financiero."
    return ($L -join "`n")
}
