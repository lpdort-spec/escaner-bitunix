# Avisos automáticos de "BUEN MOMENTO" para abrir un LARGO o un CORTO (misma puntuación de reglas fijas que el comando /momento).
#  - Cripto de Bitunix (las de mayor volumen): se revisa tras cada cierre de vela de 4h -> chat privado de señales y grupo Alertas Mercados.
#  - Acciones, ETFs y demás valores del universo de mercado: se revisa cada día tras el cierre -> solo grupo Alertas Mercados.
# Es una lectura de CONTEXTO con reglas fijas: NO está validada en backtest como la táctica de rupturas con retesteo. Se avisa solo al CRUZAR el umbral (puntuación >= 7)
# y no se repite hasta que el activo baje de (umbral - 3), para no inundar los chats. Ajustable en chats.json: "umbralMomento", "momentoCripto" (nº de criptos por volumen).

function Get-MomCfg($k, $def) { try { $c = Get-Content (Join-Path $PSScriptRoot "chats.json") -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $c.$k -and "$($c.$k)" -ne '') { return $c.$k } } catch {}; return $def }
function Get-MomAct { $v = Get-ReportState "momact"; if (-not $v) { return @() }; return @($v -split ',' | Where-Object { $_ }) }
function Set-MomAct($a) { Set-ReportState "momact" ((@($a) | Select-Object -Unique) -join ',') }

# Puntúa largo y corto de un activo ya resuelto ($s como las series de /informe). $null si faltan velas 4h o 1d.
function Get-MomScores($s) {
    $cd4 = Get-MomentoCd $s '4h'; $cd1 = Get-MomentoCd $s '1d'
    if (-not $cd4 -or -not $cd1) { return $null }
    $a4 = Analyze-TF $cd4 '4h' 100; $a1 = Analyze-TF $cd1 '1d' 90
    $tv = $null; try { $tv = Resolve-TvTarget $s.src $s.sym $s.exch } catch {}
    $sentVal = $null; try { $t = Get-MarketSentiment ($s.src -ne 'yahoo'); if ($t -match '(\d+)/100') { $sentVal = [double]$Matches[1] } } catch {}
    $fund = if ($s.extra -and $null -ne $s.extra.funding) { [double]$s.extra.funding } else { $null }
    $tvr = if ($tv) { $tv.rating } else { $null }; $px = [double]$s.price
    $lg = Score-Momento 1 $a4 $a1 $tvr $px $sentVal $fund; $st = Score-Momento -1 $a4 $a1 $tvr $px $sentVal $fund
    # capa de timing en 1h (cripto): Bollinger, RSI, volumen, velas y Fibonacci; penaliza entrar tarde/estirado
    if (Get-Command Get-Timing1hBoth -ErrorAction SilentlyContinue) {
        try { $tm = Get-Timing1hBoth $s $px
            if ($tm) { foreach ($pair in @(@($lg, $tm.lg), @($st, $tm.st))) { $sc = $pair[0]; $t = $pair[1]; if ($sc -and $t) { $sc.score = [int]$sc.score + [int]$t.adj; $sc.fx = @($sc.fx) + @($t.fx); $sc.timing = [int]$t.adj } } }
        } catch {}
    }
    return @{ lg = $lg; st = $st }
}

# Ficha de orden para copiar en Bitunix (SOLO chat privado): posición de 200 USDT de margen, apalancamiento orientativo para que el SL cueste como máximo el 35% del margen.
# El bot NO abre ni cierra operaciones: solo calcula los valores para que los pongas tú.
function Build-OrderCard($side, $plan) {
    if (-not $plan) { return $null }
    $sg = if ($side -eq 'L') { 1 } else { -1 }; $en = [double]$plan.entry; $sl = [double]$plan.sl; $mg = 200.0
    $slPct = [Math]::Abs($sl - $en) / $en * 100; if ($slPct -le 0) { return $null }
    $lev = [Math]::Min(20, [Math]::Floor(35.0 / $slPct))
    $L = @("📋 FICHA DE ORDEN · posición de 200 USDT de margen")
    if ($lev -lt 1) { $L += ("• El SL está a {0:N1}% del precio: con x1 ya perderías más del 35% del margen. Reduce el margen o descarta esta entrada." -f $slPct); return ($L -join "`n") }
    $nom = $mg * $lev; $qty = $nom / $en; $loss = $nom * $slPct / 100; $liq = 100.0 / $lev
    $roi = { param($p) $sg * ($p - $en) / $en * 100 * $lev }
    $t1 = $en + $sg * [Math]::Abs($en - $sl) * 1; $t2 = $en + $sg * [Math]::Abs($en - $sl) * 2; $t3 = $en + $sg * [Math]::Abs($en - $sl) * 3
    $R = [Math]::Abs($en - $sl); $obWarn = $false
    if ($plan.ob) { $ob = [double]$plan.ob
        if ($sg * ($ob - $en) -gt 1.05 * $R) { $fin = $ob - $sg * 0.1 * $R; if ($sg * ($t3 - $fin) -gt 0) { $t3 = $fin }; if ($sg * ($t2 - $t3) -ge 0) { $t2 = ($t1 + $t3) / 2 } }
        else { $obWarn = $true } }
    $L += ("• {0} · entrada {1}{2}" -f $(if ($sg -eq 1) { "LARGO" } else { "CORTO" }), (TaFp $en), $(if ($plan.pullback) { " (orden limit en el retroceso)" } else { " (a mercado o limit cerca del precio actual)" }))
    $L += ("• Apalancamiento orientativo: x{0:N0} · tamaño ≈ {1:N0} USDT ({2} uds)" -f $lev, $nom, (TaFp $qty))
    $L += ("• SL: {0} (-{1:N1}% del precio; pérdida ≈ {2:N0} USDT = {3:N0}% del margen)" -f (TaFp $sl), $slPct, $loss, ($loss / $mg * 100))
    $L += ("• TP parcial (1/3): {0} (ROI +{1:N0}%)" -f (TaFp $t1), (& $roi $t1))
    $L += ("• TP intermedio (1/3): {0} (ROI +{1:N0}%) · tras el TP parcial, mueve el SL a la entrada" -f (TaFp $t2), (& $roi $t2))
    $L += ("• TP final (1/3): {0} (ROI +{1:N0}%)" -f (TaFp $t3), (& $roi $t3))
    $L += ("• Liquidación ≈ a {0:N0}% del precio en contra: {1}" -f $liq, $(if ($slPct -lt $liq * 0.7) { "queda bastante más lejos que el SL ✔" } else { "⚠️ demasiado cerca del SL: baja el apalancamiento" }))
    if ($obWarn) { $L += "⚠️ Hay un obstáculo a menos de 1R: los objetivos pueden no llegar a cumplirse." }
    $L += "El bot no abre ni cierra operaciones: pon estas órdenes tú en Bitunix (botón TP/SL de la posición)."
    return ($L -join "`n")
}
function Get-OrderLevels($side, $plan, $kind) {      # entrada, apalancamiento orientativo, SL y tres objetivos (el final no pasa del siguiente obstáculo)
    if (-not $plan) { return $null }
    $sg = if ($side -eq 'L') { 1 } else { -1 }; $en = [double]$plan.entry; $sl = [double]$plan.sl; $R = [Math]::Abs($en - $sl); if ($R -le 0) { return $null }
    $slPct = $R / $en * 100; $t1 = $en + $sg * $R; $t2 = $en + $sg * 2 * $R; $t3 = $en + $sg * 3 * $R
    if ($plan.ob) { $ob = [double]$plan.ob
        if ($sg * ($ob - $en) -gt 1.05 * $R) { $fin = $ob - $sg * 0.1 * $R; if ($sg * ($t3 - $fin) -gt 0) { $t3 = $fin }; if ($sg * ($t2 - $t3) -ge 0) { $t2 = ($t1 + $t3) / 2 } } }
    return @{ sg = $sg; entry = $en; sl = $sl; t1 = $t1; t2 = $t2; t3 = $t3; slPct = $slPct; lev = (Get-SuggestedLev $slPct $kind) }
}
function Build-MomAlert($kind, $sym, $side, $score, $plan = $null, [switch]$Priv) {
    $lv = Get-OrderLevels $side $plan $kind; if (-not $lv) { return $null }
    return (Format-CompactSignal $lv.sg ($(if ($kind -eq 'cripto') { "$sym/USDT" } else { "$sym" })) $score $lv.entry ([bool]$plan.pullback) $lv.lev $lv.sl $lv.t1 $lv.t2 $lv.t3 $kind $(if ($kind -eq 'cripto') { '4h' } else { '1d' }))
}
function Register-MomSignal($kind, $sym, $lv, $plan) {      # cada aviso emitido queda registrado: se vigila (cambios de lectura, nuevos SL/TP) igual que las rupturas
    try {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $last = [long]0
        if ($kind -eq 'cripto') { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=4h&limit=3" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $last = [long]$k[$k.Count - 1].time }
        else { $b = Get-MktBars $sym; if ($b) { $last = [long]$b.t[$b.n - 1] } }
        Add-SignalRecord ([ordered]@{
            id = "mom-$sym-$($lv.sg)-$now"; time = $now; sym = $(if ($kind -eq 'cripto') { "${sym}USDT" } else { $sym }); src = $(if ($kind -eq 'cripto') { $null } else { 'yahoo' }); tf = $(if ($kind -eq 'cripto') { '4h' } else { '1d' }); strat = 'aviso-momento'; side = $lv.sg
            entryType = $(if ($plan.pullback) { 'limit' } else { 'market' }); entry = $lv.entry; sl = $lv.sl; tp1 = $lv.t1; tp2 = $lv.t2; tp3 = $lv.t3; riskAbs = [Math]::Abs($lv.entry - $lv.sl); slPct = $lv.slPct; lev = $lv.lev
            status = $(if ($plan.pullback) { 'pending' } else { 'open' }); stage = 0; realized = 0.0; age = 0; expiry = 6; lastLabel = $last; lab0 = $last; cost = $(if ($kind -eq 'cripto') { 0.0015 } else { 0.0010 }); outcome = $null; R = $null; net = $null
        })
    } catch {}
}
# Procesa una lista de elementos; devuelve nº de avisos enviados. -Dry: solo muestra puntuaciones, no envía ni guarda estado.
function Invoke-MomItems($kind, $items, [switch]$Dry) {
    $thr = [int](Get-MomCfg 'umbralMomento' 7); $act = @(Get-MomAct); $sent = 0; $cap = 8; $sigAll = @(); try { $sigAll = @(Read-Signals | Where-Object { $_.strat -eq 'aviso-momento' }) } catch {}
    foreach ($it in $items) {
        if (($script:cmdTick++ % 10) -eq 0) { try { Poll-Commands } catch {}; try { Watch-TakenOrders } catch {} }
        try {
            if ($kind -eq 'cripto') { $s = @{ src = 'bitunix'; sym = $it.sym; name = "$($it.sym)/USDT"; currency = 'USDT'; exch = ''; price = $it.px; extra = @{ funding = $it.fund } } }
            else { $s = Get-YahooSeries $it }
            if (-not $s) { continue }
            $sc = Get-MomScores $s; if (-not $sc) { continue }
            $sym = $s.sym -replace '\.MC$', '.MC'
            if ($Dry) { Write-Host ("  {0,-8} largo {1,3} · corto {2,3}" -f $sym, $sc.lg.score, $sc.st.score); continue }
            foreach ($side in 'L', 'S') {
                $score = if ($side -eq 'L') { $sc.lg.score } else { $sc.st.score }; $key = "${sym}:$side"
                if ($score -ge $thr -and $key -notin $act) {
                    if ($script:MomSent -ge $cap) { continue }
                    $plan = if ($side -eq 'L') { $sc.lg.plan } else { $sc.st.plan }
                    # entrada limit en un retroceso lejos del precio actual: no se emite (no es operable ahora); se reevalua en el siguiente cierre
                    if ($plan.pullback -and $s.price -and [Math]::Abs([double]$plan.entry - [double]$s.price) / [double]$s.price * 100 -gt 1.5) { continue }
                    $msg = Build-MomAlert $kind $sym $side $score $plan; if (-not $msg) { continue }
                    if ($kind -eq 'cripto') { Send-ToSignalChats $msg }
                    if ($script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $msg $null }
                    try { Register-MomSignal $kind $sym (Get-OrderLevels $side $plan $kind) $plan } catch {}
                    $act += $key; $sent++; $script:MomSent++
                } elseif ($score -lt ($thr - 3) -and $key -in $act) {
                    # un aviso recien emitido no se invalida con el ruido del precio en vivo: hace falta que haya cerrado al menos una vela nueva (4h cripto, 1d acciones)
                    $sgn = if ($side -eq 'L') { 1 } else { -1 }; $minAge = if ($kind -eq 'cripto') { 14400 } else { 86400 }
                    $emit = @($sigAll | Where-Object { $_.id -like "mom-$sym-$sgn-*" } | Sort-Object { [long]$_.time } -Descending | Select-Object -First 1)
                    if ($emit.Count -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$emit[0].time) -lt $minAge) { continue }
                    $act = @($act | Where-Object { $_ -ne $key })
                    # el aviso de buen momento ya no se cumple: se avisa de que, si se abrió, conviene valorar cerrarla o protegerla (mismos destinos que el aviso original)
                    $me = if ($side -eq 'L') { $sc.lg } else { $sc.st }; $neg = @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 4)
                    $cm = "⚠️ CAMBIO SIGNIFICATIVO · $sym $(if ($side -eq 'L') { 'LARGO' } else { 'CORTO' }) · valora CERRAR o proteger la operación`nEl aviso de buen momento ya no se cumple: la puntuación bajó de $thr o más a $score."
                    if ($neg.Count) { $cm += "`nFactores que ahora están en contra:`n" + (($neg | ForEach-Object { "   $_" }) -join "`n") }
                    $cm += "`nEl bot no cierra nada: decides tú. Si no abriste esa operación, simplemente deja de estar vigente el aviso."
                    if (-not $Dry) { if ($kind -eq 'cripto') { Send-ToSignalChats $cm }; if ($script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $cm $null } }
                }
            }
        } catch {}
        Start-Sleep -Milliseconds 150
    }
    if (-not $Dry) { Set-MomAct $act }
    return $sent
}

$script:MomSent = 0
function Run-MomentoCryptoIfDue {                  # tras cada cierre de vela de 4h, por tandas de 20 para seguir atendiendo comandos
    if (-not $TelegramToken) { return }
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); $idx = 0
    $st = Get-ReportState "momc"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $n = [int](Get-MomCfg 'momentoCripto' 100)
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $n)
    if ($idx -ge $tk.Count) { return }
    if ($idx -eq 0) { $script:MomSent = 0 }
    $fm = @{}; try { foreach ($f in (Invoke-RestMethod "$($script:CmdBase)/funding_rate/batch").data) { $fm[$f.symbol] = [double]$f.fundingRate } } catch {}
    $end = [Math]::Min($idx + 20, $tk.Count)
    $items = @($tk[$idx..($end - 1)] | ForEach-Object { @{ sym = ($_.symbol -replace 'USDT$', ''); px = [double]$_.lastPrice; fund = $(if ($fm.ContainsKey($_.symbol)) { $fm[$_.symbol] } else { $null }) } })
    Set-ReportState "momc" "${slot}:$end"
    $k = Invoke-MomItems 'cripto' $items
    Write-Host ("  [momento cripto] tanda {0}-{1} de {2} · avisos: {3}" -f $idx, $end, $tk.Count, $k) -ForegroundColor DarkGray
}
function Run-MomentoStocksIfDue {                  # laborables tras el cierre (desde las 22:50 hora de España), por tandas de 25
    if (-not $TelegramToken -or -not $script:MktChat) { return }
    $now = Get-MadridNow; $ref = $now.AddHours(-4)
    if ($ref.DayOfWeek -in [DayOfWeek]::Saturday, [DayOfWeek]::Sunday) { return }
    if (-not ($now.Hour -ge 23 -or $now.Hour -lt 4 -or ($now.Hour -eq 22 -and $now.Minute -ge 50))) { return }
    $day = $ref.ToString("yyyy-MM-dd"); $idx = 0
    $st = Get-ReportState "momm"; if ($st -match '^(\d{4}-\d{2}-\d{2}):(\d+)$' -and $Matches[1] -eq $day) { $idx = [int]$Matches[2] }
    $uni = @($script:UniTodos); if ($idx -ge $uni.Count) { return }
    if ($idx -eq 0) { $script:MomSent = 0 }
    $end = [Math]::Min($idx + 25, $uni.Count)
    Set-ReportState "momm" "${day}:$end"
    $k = Invoke-MomItems 'accion' @($uni[$idx..($end - 1)])
    Write-Host ("  [momento mercado] tanda {0}-{1} de {2} · avisos: {3}" -f $idx, $end, $uni.Count, $k) -ForegroundColor DarkGray
}
