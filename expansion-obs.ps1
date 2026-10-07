# OBSERVACIÓN SILENCIOSA de la táctica "Expansión de volumen" en velas de 4h (largos). NO envía nada: registra cada disparo en signals.jsonl (strat 'arranque-obs', id 'exp4-...') para medir qué habría pasado.
# Disparo: última vela de 4h cerrada con subida >= 6%, volumen >= 3x la media de 20 velas y cierre en el 40% superior de su rango. Orden hipotética: limit al 50% de la vela (3 velas para llenarse), SL en su mínimo, tercios 1R/2R/3R.
# Backtest (120 monedas, 4h, ~200 días): a mercado +0,09R (52% TP1, sin ventaja); limit al 50%: +0,15R y 68% TP1 (n=154); con volumen creciente previo 72% y +0,26R. Solo se registra la versión limit; no se avisa hasta confirmar con datos reales.
function Test-Expansion4hTrigger($bars) {
    if ($bars.Count -lt 40) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $i = $cl.Count - 1; $c0 = $cl[$i]
    $o = [double]$c0.open; $c = [double]$c0.close; $h = [double]$c0.high; $l = [double]$c0.low; if ($o -le 0 -or $h -le $l) { return $null }
    $ret = ($c / $o - 1) * 100; if ($ret -lt 6) { return $null }; if (($c - $l) / ($h - $l) -lt 0.6) { return $null }
    $vol = [double]$c0.baseVol; if ($vol -le 0) { $vol = [double]$c0.volume }
    $va = ($cl[($i - 20)..($i - 1)] | ForEach-Object { $x = [double]$_.baseVol; if ($x -le 0) { $x = [double]$_.volume }; $x } | Measure-Object -Average).Average; if ($va -le 0 -or $vol -lt 3 * $va) { return $null }
    $mid = ($o + $c) / 2; $risk = ($mid - $l) / $mid * 100; if ($risk -gt 12 -or $risk -lt 0.5) { return $null }
    $v3 = (($cl[($i - 3)..($i - 1)] | ForEach-Object { $x = [double]$_.baseVol; if ($x -le 0) { $x = [double]$_.volume }; $x }) | Measure-Object -Average).Average
    $vOld = ($cl[($i - 23)..($i - 4)] | ForEach-Object { $x = [double]$_.baseVol; if ($x -le 0) { $x = [double]$_.volume }; $x } | Measure-Object -Average).Average
    return @{ t = [long]$c0.time; o = $o; c = $c; h = $h; l = $l; ret = $ret; vx = $vol / $va; mid = $mid; risk = $risk; ramp = ($vOld -gt 0 -and $v3 -ge 1.3 * $vOld) }
}
function Register-Expansion4hObs($sym, $tr) {
    $id = "exp4-$sym-$($tr.t)"; if (@(Read-Signals | Where-Object { $_.id -eq $id }).Count) { return $false }
    $R = $tr.mid - $tr.l
    Add-SignalRecord ([ordered]@{
        id = $id; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = "${sym}USDT"; tf = '4h'; strat = 'arranque-obs'; side = 1; entryType = 'limit'; entry = $tr.mid; sl = $tr.l
        tp1 = $tr.mid + $R; tp2 = $tr.mid + 2 * $R; tp3 = $tr.mid + 3 * $R; riskAbs = $R; slPct = $tr.risk; lev = 1; status = 'pending'; stage = 0; realized = 0.0; age = 0; expiry = 3
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = [Math]::Round($tr.vx, 1); ctxFlags = ("ret={0:N1}%;ramp={1}" -f $tr.ret, $tr.ramp).Replace(',', '.'); note = "observación silenciosa: expansión de volumen 4h"
    })
    return $true
}
function Run-Expansion4hObsIfDue {      # cada vez que cierra una vela de 4h, por tandas de 25 monedas
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); $idx = 0
    $st = Get-ReportState "arq4"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 150)
    if ($idx -ge $tk.Count) { return }; $end = [Math]::Min($idx + 25, $tk.Count); Set-ReportState "arq4" "${slot}:$end"; $found = 0
    foreach ($t in @($tk[$idx..($end - 1)])) {
        try { $sym = $t.symbol -replace 'USDT$', ''; $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=4h&limit=60" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
            $tr = Test-Expansion4hTrigger $b; if ($tr -and (Register-Expansion4hObs $sym $tr)) { $found++ } } catch {}
        Start-Sleep -Milliseconds 120 }
    Write-Host ("  [expansión-obs 4h] tanda {0}-{1} de {2} · disparos registrados: {3}" -f $idx, $end, $tk.Count, $found) -ForegroundColor DarkGray
}
