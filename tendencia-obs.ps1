# OBSERVACIÓN SILENCIOSA de dos tácticas de TENDENCIA en velas DIARIAS (largos, swing). NO envía nada: registra cada disparo en signals.jsonl (strat 'arranque-obs', ids 'sqz-' y 'don-') para medir qué habría pasado.
# 1) Squeeze + ruptura al alza: ancho de Bollinger(20,2) en el 25% más bajo de los últimos 120 días y cierre diario por encima de la banda superior de las 20 velas previas. Backtest (150 futuros, ~1000 días, SL 2 ATR, salida a 10 días, coste 0,15%): +0,18R (45% ganadoras, n=740);
#    con BTC sobre su EMA200 diaria +0,27R (48%, n=388; 1ª mitad +0,25 · 2ª +0,36). Solo se registra con BTC sobre su EMA200 diaria.
# 2) Donchian 20 al alza: cierre diario por encima del máximo de las 20 velas previas. Backtest +0,08R (n=1492); con BTC sobre su EMA200 diaria +0,14R (42%, n=990; 1ª +0,17 · 2ª +0,06). Solo con BTC sobre su EMA200 diaria.
# Tendencia con rupturas de Donchian es lo mejor respaldado públicamente (Zarattini et al. 2025, working paper). Entrada a mercado en la apertura de la vela en curso, SL 2 ATR(14) diario, tercios 1R/2R/3R (el backtest salía a 10 días: la gestión real puede dar otro resultado, por eso se mide).
# 3) RSI diario <= 30 (largo, sin filtro de BTC): backtest +0,16R y 64% ganadoras (n=430; 1ª mitad +0,27 · 2ª +0,09). Es lo único del RSI con ventaja medida (bt-rsi-marcos.ps1).
# No se avisa hasta >=30 casos reales por táctica, >60% TP1 y esperanza neta positiva.
function Get-BtcDailyOk {      # BTC sobre su EMA200 diaria (cache por hora)
    if ($script:BtcOkAt -and ((Get-Date) - $script:BtcOkAt).TotalMinutes -lt 60) { return $script:BtcOk }
    try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=BTCUSDT&interval=1d&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $cl = @($k[0..($k.Count - 2)] | ForEach-Object { [double]$_.close }); $e = Get-EmaValue $cl 200
        $script:BtcOk = ($e -and $cl[-1] -gt $e); $script:BtcOkAt = Get-Date } catch { $script:BtcOk = $false; $script:BtcOkAt = Get-Date }
    return $script:BtcOk
}
function Get-RsiWilder($c, [int]$i) {      # RSI(14) de Wilder sobre los cierres c[0..i]
    $g = 0.0; $ls = 0.0; for ($q = 1; $q -le 14; $q++) { $d = $c[$q] - $c[$q - 1]; if ($d -gt 0) { $g = $g + $d } else { $ls = $ls - $d } }
    $g = $g * 1.0 / 14; $ls = $ls * 1.0 / 14
    for ($q = 15; $q -le $i; $q++) { $d = $c[$q] - $c[$q - 1]; $g = ($g * 13 + [Math]::Max($d, 0)) * 1.0 / 14; $ls = ($ls * 13 + [Math]::Max(-$d, 0)) * 1.0 / 14 }
    if ($ls -eq 0) { return 100.0 }; return (100 - 100 / (1 + $g / $ls))
}
function Get-BwSeries($cl) { $n = $cl.Count; $bw = New-Object 'double[]' $n; for ($z = 19; $z -lt $n; $z++) { $w = $cl[($z - 19)..$z]; $m = ($w | Measure-Object -Average).Average; $sd = [Math]::Sqrt((($w | ForEach-Object { ($_ - $m) * ($_ - $m) }) | Measure-Object -Sum).Sum / 20); $bw[$z] = $(if ($m -gt 0) { 4 * $sd / $m } else { 1 }) }; return $bw }
function Test-TendenciaTrigger($bars) {      # devuelve @{ sqz; don; ... } o $null
    if ($bars.Count -lt 160) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $cur = $bars[$bars.Count - 1]; $n = $cl.Count; $i = $n - 1
    $c = [double[]]($cl | ForEach-Object { $_.close }); $h = [double[]]($cl | ForEach-Object { $_.high }); $l = [double[]]($cl | ForEach-Object { $_.low })
    $tr = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $tr += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $tr / 14; $entry = [double]$cur.open; if ($atr -le 0 -or $entry -le 0) { return $null }
    $risk = 2.0 * $atr; $riskPct = $risk / $entry * 100; if ($riskPct -lt 1 -or $riskPct -gt 40) { return $null }
    $don = ($c[$i] -gt (($h[($i - 20)..($i - 1)] | Measure-Object -Maximum).Maximum))
    $sqz = $false; $bw = Get-BwSeries $c; $cnt = 0; for ($z = $i - 120; $z -lt $i; $z++) { if ($bw[$z] -lt $bw[$i]) { $cnt++ } }; $rank = $cnt / 120.0
    if ($rank -le 0.25) { $wp = $c[($i - 20)..($i - 1)]; $mp = ($wp | Measure-Object -Average).Average; $sp = [Math]::Sqrt((($wp | ForEach-Object { ($_ - $mp) * ($_ - $mp) }) | Measure-Object -Sum).Sum / 20); if ($c[$i] -gt $mp + 2 * $sp) { $sqz = $true } }
    $rsi = Get-RsiWilder $c $i; $os = ($rsi -le 30)
    if (-not ($don -or $sqz -or $os)) { return $null }
    return @{ t = [long]$cl[$i].time; entry = $entry; sl = $entry - $risk; R = $risk; riskPct = $riskPct; don = $don; sqz = $sqz; os = $os; rsi = $rsi; rank = $rank }
}
function Register-TendenciaObs($sym, $tr, $kind) {
    $id = "$kind-$sym-$($tr.t)"; if (@(Read-Signals | Where-Object { $_.id -eq $id }).Count) { return $false }
    Add-SignalRecord ([ordered]@{
        id = $id; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = "${sym}USDT"; tf = '1d'; strat = 'arranque-obs'; side = 1; entryType = 'market'; entry = $tr.entry; sl = $tr.sl
        tp1 = $tr.entry + $tr.R; tp2 = $tr.entry + 2 * $tr.R; tp3 = $tr.entry + 3 * $tr.R; riskAbs = $tr.R; slPct = $tr.riskPct; lev = 1; status = 'open'; stage = 0; realized = 0.0; age = 0
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = $null; ctxFlags = ("{0};btcEma200={2};sqzRank={1:N2};rsi={3:N0}" -f $(if ($kind -eq 'sqz') { 'squeeze' } elseif ($kind -eq 'rsi') { 'rsi-sobreventa' } else { 'donchian20' }), $tr.rank, $(if (Get-BtcDailyOk) { 1 } else { 0 }), $tr.rsi).Replace(',', '.'); note = "observación silenciosa: tendencia diaria ($kind)"
    })
    return $true
}
function Run-TendenciaObsIfDue {      # una vez por día UTC (tras cerrar la vela diaria), por tandas de 25 monedas
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 86400); $idx = 0
    $st = Get-ReportState "sqz"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $btcOk = Get-BtcDailyOk      # squeeze y Donchian solo con BTC sobre su EMA200 diaria; el largo por RSI diario <= 30 se registra siempre
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 150)
    if ($idx -ge $tk.Count) { return }; $end = [Math]::Min($idx + 25, $tk.Count); Set-ReportState "sqz" "${slot}:$end"; $found = 0
    foreach ($t in @($tk[$idx..($end - 1)])) {
        try { $sym = $t.symbol -replace 'USDT$', ''; if ($sym -eq 'BTC') { continue }
            $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=1d&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
            $tr = Test-TendenciaTrigger $b; if ($tr) { if ($btcOk -and $tr.sqz -and (Register-TendenciaObs $sym $tr 'sqz')) { $found++ }; if ($btcOk -and $tr.don -and (Register-TendenciaObs $sym $tr 'don')) { $found++ }; if ($tr.os -and (Register-TendenciaObs $sym $tr 'rsi')) { $found++ } } } catch {}
        Start-Sleep -Milliseconds 120 }
    Write-Host ("  [tendencia-obs 1d] tanda {0}-{1} de {2} · disparos registrados: {3}" -f $idx, $end, $tk.Count, $found) -ForegroundColor DarkGray
}
