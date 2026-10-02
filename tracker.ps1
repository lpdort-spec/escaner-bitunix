# Seguimiento de señales: registra cada señal, la resuelve con las velas posteriores y calcula estadísticas.
# Gestión simulada: se cierra un tercio en TP1 (1R), TP2 (2R) y TP3 (3R); tras TP1 el SL pasa a la entrada.
# Resultado en R (1R = distancia al SL), descontando comisiones y deslizamiento. Se asume SL primero si una vela toca SL y TP.
$script:SigFile = Join-Path $PSScriptRoot "signals.jsonl"
$script:CostRT = 0.0010      # 0,10% ida y vuelta sobre el nominal (entrada y objetivos limit + SL a mercado + deslizamiento)
$script:W1 = 1.0/3; $script:W2 = 1.0/3; $script:W3 = 1.0/3   # reparto de salidas: un tercio en TP1 (1R), TP2 (2R) y TP3 (3R)
$script:DurMin = @{ '5m' = 5; '15m' = 15; '30m' = 30; '1h' = 60; '4h' = 240 }

function Read-Signals {
    if (-not (Test-Path $script:SigFile)) { return @() }
    return @(Get-Content $script:SigFile -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Save-Signals($sigs) {
    ($sigs | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) | Set-Content $script:SigFile -Encoding UTF8
}
function Add-SignalRecord($rec) {
    ($rec | ConvertTo-Json -Compress -Depth 5) | Add-Content $script:SigFile -Encoding UTF8
}

function Update-Signals($base) {
    $sigs = Read-Signals; if ($sigs.Count -eq 0) { return }
    $changed = $false
    foreach ($s in $sigs) {
        if ($s.status -in 'closed', 'unfilled') { continue }
        try {
            $k = (Invoke-RestMethod "$base/kline?symbol=$($s.sym)&interval=$($s.tf)&limit=200").data | Sort-Object { [long]$_.time }
        } catch { continue }
        $closed = @($k[0..($k.Count - 2)])
        $sgn = [int]$s.side
        foreach ($c in $closed) {
            if ([long]$c.time -le [long]$s.lastLabel) { continue }
            $s.lastLabel = [long]$c.time; $changed = $true
            $hi = [double]$c.high; $lo = [double]$c.low; $cl = [double]$c.close
            $hitSL = if ($sgn -eq 1) { $lo -le $s.sl } else { $hi -ge $s.sl }
            $reachEntry = if ($sgn -eq 1) { $lo -le $s.entry } else { $hi -ge $s.entry }
            $reachTP = { param($lvl) if ($sgn -eq 1) { $hi -ge $lvl } else { $lo -le $lvl } }
            if ($s.status -eq 'pending') {
                $s.age = [int]$s.age + 1
                if ($hitSL) { $s.status = 'unfilled'; $s.note = 'invalidada antes de entrar'; break }
                if ($reachEntry) { $s.status = 'open'; $s.stage = 0; $s.age = 0; $s.realized = 0.0 }
                elseif (& $reachTP $s.tp1) { $s.status = 'unfilled'; $s.note = 'se fue sin dar entrada'; break }
                elseif ($s.age -ge 6) { $s.status = 'unfilled'; $s.note = 'orden limit no ejecutada'; break }
                if ($s.status -ne 'open') { continue }
                # la vela de entrada solo puede cerrar la operación si toca el SL
                if ($hitSL) { $s.status = 'closed'; $s.R = -1.0; $s.outcome = 'SL'; break }
                continue
            }
            $s.age = [int]$s.age + 1
            switch ([int]$s.stage) {
                0 { if ($hitSL) { $s.status = 'closed'; $s.R = -1.0; $s.outcome = 'SL' } elseif (& $reachTP $s.tp1) { $s.stage = 1; $s.realized = [double]$s.realized + $script:W1 * 1.0 } }
                1 { if ($reachEntry) { $s.status = 'closed'; $s.R = [double]$s.realized; $s.outcome = 'TP1 + BE' } elseif (& $reachTP $s.tp2) { $s.stage = 2; $s.realized = [double]$s.realized + $script:W2 * 2.0 } }
                2 { if ($reachEntry) { $s.status = 'closed'; $s.R = [double]$s.realized; $s.outcome = 'TP2 + BE' } elseif (& $reachTP $s.tp3) { $s.status = 'closed'; $s.R = [double]$s.realized + $script:W3 * 3.0; $s.outcome = 'TP3' } }
            }
            if ($s.status -eq 'closed') { break }
            if ($s.age -ge 48) {      # tiempo agotado: se cierra el resto a mercado
                $m = $sgn * ($cl - $s.entry) / $s.riskAbs
                $left = switch ([int]$s.stage) { 0 { 1.0 } 1 { 1.0 - $script:W1 } default { 1.0 - $script:W1 - $script:W2 } }
                $s.R = [double]$s.realized + $left * [Math]::Max(-1.0, [Math]::Min(3.0, $m)); $s.status = 'closed'; $s.outcome = 'tiempo'; break
            }
        }
        if ($s.status -eq 'closed' -and $null -eq $s.net) { $s.net = [double]$s.R - $script:CostRT / ([double]$s.slPct / 100); $s.closedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
    }
    if ($changed) { Save-Signals $sigs }
}

function Group-Stats($items, $label) {
    $n = $items.Count; if ($n -eq 0) { return $null }
    $w = @($items | Where-Object { $_.outcome -ne 'SL' -and [double]$_.net -gt 0 }).Count
    $tp1 = @($items | Where-Object { $_.outcome -in 'TP1 + BE', 'TP2 + BE', 'TP3' }).Count
    $exp = ($items | Measure-Object net -Average).Average
    return "{0,-26} n={1,-3} llegan a TP1={2,3:N0}%  esperanza={3,6:N2}R" -f $label, $n, (100.0 * $tp1 / $n), $exp
}

function Get-Report {
    $all = Read-Signals
    $cl = @($all | Where-Object { $_.status -eq 'closed' })
    $open = @($all | Where-Object { $_.status -in 'open', 'pending' }).Count
    $un = @($all | Where-Object { $_.status -eq 'unfilled' }).Count
    if ($cl.Count -eq 0) { return "Seguimiento: $($all.Count) señales registradas, $open abiertas, $un sin ejecutar. Aún no hay ninguna cerrada." }
    $lines = @("RESULTADOS DE LAS SEÑALES (descontando comisiones)", "Cerradas: $($cl.Count) | abiertas: $open | sin ejecutar: $un")
    $lines += (Group-Stats $cl "TOTAL")
    foreach ($g in ($cl | Group-Object strat)) { $lines += (Group-Stats @($g.Group) "estrategia $($g.Name)") }
    foreach ($g in ($cl | Group-Object tf)) { $lines += (Group-Stats @($g.Group) "temporalidad $($g.Name)") }
    foreach ($g in ($cl | Group-Object trend)) { $lines += (Group-Stats @($g.Group) "tendencia 4h $($g.Name)") }
    foreach ($g in ($cl | Group-Object risk)) { $lines += (Group-Stats @($g.Group) "riesgo moneda $($g.Name)") }
    foreach ($g in ($cl | Group-Object { if ([int]$_.side -eq 1) { 'LONG' } else { 'SHORT' } })) { $lines += (Group-Stats @($g.Group) "lado $($g.Name)") }
    $bt = $cl | Group-Object { if ($_.btcAligned -eq $true) { 'a favor de BTC' } elseif ($_.btcAligned -eq $false) { 'contra BTC' } else { 'BTC neutro' } }
    foreach ($g in $bt) { $lines += (Group-Stats @($g.Group) $g.Name) }
    $lines += ""; $lines += "Con un tercio en cada TP y SL a entrada tras TP1, el equilibrio exige llegar a TP1 en ~50% de las señales."
    return ($lines -join "`n")
}
