# Formato ÚNICO y breve de las señales de ENTRADA (grupo privado de Bitunix y grupo Alertas Mercados): TIPO DE ORDEN en grande al principio, dirección, activo, puntuación, entrada, apalancamiento, SL y TP parcial/final. Nada más.
# El detalle (análisis, contexto, noticias, resultados...) se pide con /informe SIMBOLO o /momento SIMBOLO.
# TIPO DE ORDEN según el horizonte de la operación (estilos de inversión):
#   SCALPING      · segundos a minutos (velas de 1-30 min)            -> el bot NO emite scalping: no hay una táctica validada en ese marco
#   DAY TRADING   · horas, se cierra en el día (velas de 1-2 horas)   -> rupturas cripto en 1h
#   SWING TRADING · días a semanas (velas de 4 h, diarias, semanales) -> rupturas cripto en 4h, acciones/ETFs diarios y avisos de buen momento (marcos de 4h/1d)

function Get-OrderStyle($tf) {
    $t = "$tf".ToLower()
    if ($t -in '1m', '3m', '5m', '15m', '30m') { return @{ name = 'SCALPING'; banner = "🟥🟥🟥 SCALPING 🟥🟥🟥 (minutos)" } }
    if ($t -in '1h', '2h') { return @{ name = 'DAY TRADING'; banner = "🟧🟧🟧 DAY TRADING 🟧🟧🟧 (horas)" } }
    return @{ name = 'SWING TRADING'; banner = "🟦🟦🟦 SWING TRADING 🟦🟦🟦 (días)" }
}
function Get-LevCap($kind) { if ($kind -eq 'cripto') { return 20 } else { return 5 } }
# Presupuesto de pérdida al saltar el SL (% del margen): el 20% (Get-SlMaxPct) solo cuando la lectura es muy clara; si es más dudosa, o el movimiento está estirado, o el SL es muy amplio,
# se baja el presupuesto y con él el apalancamiento (apalancamiento = presupuesto / distancia del SL). Regla fija de Luis (2026-10-06).
function Get-SlBudget($score, $tmg = 0, [double]$slPct = 0) {
    $mx = Get-SlMaxPct; if ($null -eq $score) { return $mx }
    $f = if ([int]$score -ge 8) { 1.0 } elseif ([int]$score -ge 7) { 0.75 } elseif ([int]$score -ge 4) { 0.5 } else { 0.35 }
    if ([int]$tmg -le -3) { $f *= 0.6 }; if ($slPct -ge 6) { $f *= 0.75 }
    return [Math]::Round($mx * $f, 1)
}
function Get-SuggestedLev([double]$slPct, $kind, $score = $null, $tmg = 0) {      # apalancamiento orientativo: el SL cuesta como máximo el presupuesto (<= 20% del margen); tope x20 en cripto y x5 en bolsa
    if ($slPct -le 0) { return 1 }; $l = [Math]::Floor((Get-SlBudget $score $tmg $slPct) / $slPct); return [int][Math]::Max(1, [Math]::Min((Get-LevCap $kind), $l))
}
function Get-SignalScore($sym, $kind, [int]$sg, [double]$px, $exch = '') {      # puntuación de /momento para el lado de la señal (o $null si no se puede calcular)
    try {
        if (-not (Get-Command Get-MomScores -ErrorAction SilentlyContinue)) { return $null }
        $base = "$sym" -replace 'USDT$', ''
        $s = if ($kind -eq 'cripto') { @{ src = 'bitunix'; sym = $base; name = "$base/USDT"; currency = 'USDT'; exch = ''; price = $px; extra = @{ funding = $null } } } else { @{ src = 'yahoo'; sym = $sym; name = $sym; currency = ''; exch = $exch; price = $px; extra = @{} } }
        $sc = Get-MomScores $s; if (-not $sc) { return $null }
        if ($sg -eq 1) { return [int]$sc.lg.score } else { return [int]$sc.st.score }
    } catch { return $null }
}
function Format-CompactSignal([int]$sg, $title, $score, [double]$entry, [bool]$limit, $lev, [double]$sl, [double]$tp1, [double]$tp2, [double]$tp3, $kind, $tf = '4h') {
    $icon = if ($sg -eq 1) { "🟢" } else { "🔴" }; $dir = if ($sg -eq 1) { "LARGO" } else { "CORTO" }; $st = Get-OrderStyle $tf
    $L = @()
    $L += $st.banner
    $L += ("{0} {1} · {2}{3}" -f $icon, $dir, $title, $(if ($null -ne $score) { " · Puntuación $score" } else { "" }))
    $L += ("Entrada: {0}{1}" -f (TaFp $entry), $(if ($limit) { " (orden limit)" } else { " (a mercado)" }))
    if ($lev) { $L += ("Apalancamiento: x{0}{1}" -f $lev, $(if ($kind -ne 'cripto') { " (orientativo)" } else { "" })) }
    $slPct = if ($entry -gt 0) { [Math]::Abs($entry - $sl) / $entry * 100 } else { 0 }
    if ($lev -and $slPct -gt 0) { $L += ("SL: {0} (si salta, ≈ {1:N0}% del margen)" -f (TaFp $sl), ($slPct * [double]$lev)) } else { $L += ("SL: {0}" -f (TaFp $sl)) }
    if ($slPct -gt (Get-SlMaxPct)) { $L += ("⚠️ SL a {0:N1}% del precio: supera el {1:N0}% del margen incluso sin apalancar; reduce el tamaño de la posición." -f $slPct, (Get-SlMaxPct)) }
    $L += ("TP1: {0} · TP2: {1} · TP final: {2}" -f (TaFp $tp1), (TaFp $tp2), (TaFp $tp3))
    return ($L -join "`n")
}
