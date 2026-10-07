# OBSERVACIÓN SILENCIOSA de "Bollinger bajo en diario Y semanal" (largos). NO envía nada: registra cada disparo en signals.jsonl (strat 'arranque-obs', id 'bbd-...') para medir qué habría pasado.
# Disparo: última vela DIARIA cerrada con %B(20,2) <= 0,05 y, a la vez, %B semanal (cierres cada 7 días, 20 semanas) <= 0,10, y RSI(14) diario < 35. Entrada a mercado en la apertura de la vela en curso, SL a 1,5 ATR diario, tercios 1R/2R/3R.
# Backtest (150 monedas, ~1000 días): diaria+semanal +0,10R y 56% TP1 (n=865); con RSI<35 +0,17R y 59% TP1 (n=646). Solo en diaria sin ventaja. Origen: criterio de Luis (LYN 07/10/2026). No se avisa hasta confirmar con >=30 casos reales y TP1 >60%.
function Get-BbPctB($vals, $px) {
    $w = @($vals | Select-Object -Last 20); $mean = ($w | Measure-Object -Average).Average
    $dev = [Math]::Sqrt((($w | ForEach-Object { ($_ - $mean) * ($_ - $mean) }) | Measure-Object -Sum).Sum / 20); if ($dev -le 0) { return 0.5 }
    return (($px - ($mean - 2 * $dev)) / (4 * $dev))
}
function Test-BollingerBajoTrigger($bars) {
    if ($bars.Count -lt 160) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $cur = $bars[$bars.Count - 1]; $n = $cl.Count; $i = $n - 1
    $closes = [double[]]($cl | ForEach-Object { $_.close }); $highs = [double[]]($cl | ForEach-Object { $_.high }); $lows = [double[]]($cl | ForEach-Object { $_.low })
    $pbD = Get-BbPctB $closes[($i - 19)..$i] $closes[$i]; if ($pbD -gt 0.05) { return $null }
    $wk = @(); for ($q = $i; $q -ge 0 -and $wk.Count -lt 20; $q -= 7) { $wk = @($closes[$q]) + $wk }; if ($wk.Count -lt 20) { return $null }
    $pbW = Get-BbPctB $wk $closes[$i]; if ($pbW -gt 0.10) { return $null }
    $gain = 0.0; $loss = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $dd = $closes[$q] - $closes[$q - 1]; if ($dd -gt 0) { $gain += $dd } else { $loss -= $dd } }
    $rsi = if ($loss -eq 0) { 100 } else { 100 - 100 / (1 + $gain / $loss) }; if ($rsi -ge 35) { return $null }
    $tr = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $tr += [Math]::Max($highs[$q] - $lows[$q], [Math]::Max([Math]::Abs($highs[$q] - $closes[$q - 1]), [Math]::Abs($lows[$q] - $closes[$q - 1]))) }
    $atr = $tr / 14; $entry = [double]$cur.open; if ($atr -le 0 -or $entry -le 0) { return $null }
    $risk = 1.5 * $atr; $riskPct = $risk / $entry * 100; if ($riskPct -lt 0.8 -or $riskPct -gt 30) { return $null }
    return @{ t = [long]$cl[$i].time; entry = $entry; sl = $entry - $risk; R = $risk; riskPct = $riskPct; pbD = $pbD; pbW = $pbW; rsi = $rsi; ret7 = (($closes[$i] / $closes[$i - 7] - 1) * 100) }
}
function Register-BollingerBajoObs($sym, $tr) {
    $id = "bbd-$sym-$($tr.t)"; if (@(Read-Signals | Where-Object { $_.id -eq $id }).Count) { return $false }
    Add-SignalRecord ([ordered]@{
        id = $id; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = "${sym}USDT"; tf = '1d'; strat = 'arranque-obs'; side = 1; entryType = 'market'; entry = $tr.entry; sl = $tr.sl
        tp1 = $tr.entry + $tr.R; tp2 = $tr.entry + 2 * $tr.R; tp3 = $tr.entry + 3 * $tr.R; riskAbs = $tr.R; slPct = $tr.riskPct; lev = 1; status = 'open'; stage = 0; realized = 0.0; age = 0
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = [Math]::Round($tr.rsi, 0); ctxFlags = ("pbD={0:N2};pbW={1:N2};ret7={2:N0}%" -f $tr.pbD, $tr.pbW, $tr.ret7).Replace(',', '.'); note = "observación silenciosa: Bollinger bajo diario+semanal"
    })
    return $true
}
function Run-BollingerBajoObsIfDue {      # una vez por día UTC (tras cerrar la vela diaria), por tandas de 25 monedas
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 86400); $idx = 0
    $st = Get-ReportState "bbd"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 150)
    if ($idx -ge $tk.Count) { return }; $end = [Math]::Min($idx + 25, $tk.Count); Set-ReportState "bbd" "${slot}:$end"; $found = 0
    foreach ($t in @($tk[$idx..($end - 1)])) {
        try { $sym = $t.symbol -replace 'USDT$', ''; $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=1d&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
            $tr = Test-BollingerBajoTrigger $b; if ($tr -and (Register-BollingerBajoObs $sym $tr)) { $found++ } } catch {}
        Start-Sleep -Milliseconds 120 }
    Write-Host ("  [bollinger-obs 1d] tanda {0}-{1} de {2} · disparos registrados: {3}" -f $idx, $end, $tk.Count, $found) -ForegroundColor DarkGray
}
