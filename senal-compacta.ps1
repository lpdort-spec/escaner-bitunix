# Formato ÚNICO y breve de las señales de ENTRADA (grupo privado de Bitunix y grupo Alertas Mercados): dirección, activo, puntuación, entrada, apalancamiento, SL y TP parcial/final. Nada más.
# El detalle (análisis, contexto, noticias, resultados...) se pide con /informe SIMBOLO o /momento SIMBOLO.

function Get-LevCap($kind) { if ($kind -eq 'cripto') { return 20 } else { return 5 } }
function Get-SuggestedLev([double]$slPct, $kind) {      # apalancamiento orientativo: el SL no debe costar más del 35% del margen (regla de Luis); tope x20 en cripto y x5 en bolsa
    if ($slPct -le 0) { return 1 }; $l = [Math]::Floor(35.0 / $slPct); return [int][Math]::Max(1, [Math]::Min((Get-LevCap $kind), $l))
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
function Format-CompactSignal([int]$sg, $title, $score, [double]$entry, [bool]$limit, $lev, [double]$sl, [double]$tp1, [double]$tp2, [double]$tp3, $kind) {
    $icon = if ($sg -eq 1) { "🟢" } else { "🔴" }; $dir = if ($sg -eq 1) { "LARGO" } else { "CORTO" }
    $L = @()
    $L += ("{0} {1} · {2}{3}" -f $icon, $dir, $title, $(if ($null -ne $score) { " · Puntuación $score" } else { "" }))
    $L += ("Entrada: {0}{1}" -f (TaFp $entry), $(if ($limit) { " (orden limit)" } else { " (a mercado)" }))
    if ($lev) { $L += ("Apalancamiento: x{0}{1}" -f $lev, $(if ($kind -ne 'cripto') { " (orientativo)" } else { "" })) }
    $L += ("SL: {0}" -f (TaFp $sl))
    $L += ("TP1: {0} · TP2: {1} · TP final: {2}" -f (TaFp $tp1), (TaFp $tp2), (TaFp $tp3))
    return ($L -join "`n")
}
