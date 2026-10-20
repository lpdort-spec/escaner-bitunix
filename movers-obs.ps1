# OBSERVACIÓN SILENCIOSA "Movers diarios" (largos). NO envía nada: registra en signals.jsonl (strat 'arranque-obs', mode 'trail', id 'mov-1d-<moneda>-<vela>') los futuros que cierran el DÍA con una subida >= 20 % para medir si "subirse a la tendencia" tiene ventaja.
# Idea de Luis (20/10/2026): los que suben mucho en el día a veces siguen (+40 % -> +100 %) porque van a buscar una EMA diaria/semanal. Backtest (bt-movers-ema.ps1, ~117 pares, ~800 días, 197 casos, entrada en la apertura siguiente, stop dinámico 3 ATR, 20 días, neto 0,15 %):
#   - Ya sobre las 3 EMA (50/200/140 diaria): MFE a 10 días mediana +21 %, >=+50 % en el 22 % y >=+100 % en el 12 % de los casos; trailing: media +11,8 % pero mediana -5,1 % y 43 % ganadoras (pocas ganadoras enormes). Días de +35 % o más: >=+100 % en el 20-25 %.
#   - Con la EMA objetivo POR ENCIMA del precio (imán) hay muy pocos casos (34) para concluir; con la EMA a < 10 % por encima salió negativo (-1,1 %).
# Se registra con las distancias a las EMA en ctxFlags para medirlo en real. Pago asimétrico: muchas pequeñas pérdidas y pocas ganancias grandes; no se avisa hasta >=30 casos cerrados con esperanza neta positiva.
function Test-MoversTrigger($bars) {      # $bars = velas 1d ordenadas, la última es la vela EN CURSO (la real o la sintética de velas-cerradas.ps1)
    if ($bars.Count -lt 210) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $cur = $bars[$bars.Count - 1]; $i = $cl.Count - 1
    $h = [double[]]($cl | ForEach-Object { $_.high }); $l = [double[]]($cl | ForEach-Object { $_.low }); $c = [double[]]($cl | ForEach-Object { $_.close })
    $v = [double]($cl[$i].quoteVol); if ($v -le 0) { $v = [double]$cl[$i].baseVol * $c[$i] }; if ($v -lt 3e6) { return $null }
    $r1 = $c[$i] / $c[$i - 1] - 1; if ($r1 -lt 0.20) { return $null }
    $tr = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $tr += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $tr / 14
    $en = [double]$cur.open; if ($atr -le 0 -or $en -le 0) { return $null }
    $e50 = Get-EmaValue $c 50; $e200 = Get-EmaValue $c 200; $e140 = Get-EmaValue $c 140
    $above = @(); foreach ($e in $e50, $e200, $e140) { if ($e -gt $c[$i]) { $above += $e } }; $room = $(if ($above.Count) { (($above | Measure-Object -Minimum).Minimum / $c[$i] - 1) * 100 } else { -1 })
    $risk = 3 * $atr; $riskPct = $risk / $en * 100
    return @{ t = [long]$cl[$i].time; entry = $en; sl = ($en - $risk); risk = $risk; riskPct = $riskPct; atr = $atr; r1 = $r1 * 100; room = $room; d50 = (($c[$i] / $e50 - 1) * 100); d200 = (($c[$i] / $e200 - 1) * 100); d140 = (($c[$i] / $e140 - 1) * 100); vx = ($v / 1e6) }
}
function Register-MoversObs($sym, $tr) {
    $id = "mov-1d-$sym-$($tr.t)"; $all = @(Read-Signals); if (@($all | Where-Object { $_.id -eq $id }).Count) { return $false }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); if (@($all | Where-Object { "$($_.id)" -like "mov-1d-$sym-*" -and ($_.status -eq 'open' -or ($now - [long]$_.time) -lt 5 * 86400) }).Count) { return $false }      # enfriamiento de 5 días (como en el backtest)
    Add-SignalRecord ([ordered]@{
        id = $id; time = $now; sym = "${sym}USDT"; tf = '1d'; strat = 'arranque-obs'; side = 1; entryType = 'market'; entry = $tr.entry; sl = $tr.sl; sl0 = $tr.sl
        tp1 = $tr.entry + $tr.risk; tp2 = $tr.entry + 2 * $tr.risk; tp3 = $tr.entry + 3 * $tr.risk; riskAbs = $tr.risk; slPct = $tr.riskPct; lev = 1; status = 'open'; stage = 0; realized = 0.0; age = 0; mode = 'trail'; atr0 = $tr.atr; ext = $tr.entry
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = [Math]::Round($tr.vx, 1)
        ctxFlags = ("movers-1d;dia=+{0:N0}%;room={1:N0}%;d50={2:N0}%;d200={3:N0}%;d140={4:N0}%" -f $tr.r1, $tr.room, $tr.d50, $tr.d200, $tr.d140).Replace(',', '.'); note = "observación silenciosa: mover diario >= +20 % (trailing 3 ATR)"
    })
    return $true
}
function Run-MoversObsIfDue {      # una vez por día UTC, tras cerrar la vela diaria, por tandas de 25 monedas del top 150 por volumen
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 86400); $idx = 0
    $st = Get-ReportState "mov1"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 150)
    if ($idx -ge $tk.Count) { return }; $end = [Math]::Min($idx + 25, $tk.Count); Set-ReportState "mov1" "${slot}:$end"; $found = 0
    foreach ($t in @($tk[$idx..($end - 1)])) {
        try { $sym = $t.symbol -replace 'USDT$', ''; if ($sym -eq 'BTC') { continue }
            $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=1d&limit=220" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
            $tr = Test-MoversTrigger $b; if ($tr -and (Register-MoversObs $sym $tr)) { $found++ } } catch {}
        Start-Sleep -Milliseconds 120 }
    Write-Host ("  [movers-obs 1d] tanda {0}-{1} de {2} · disparos registrados: {3}" -f $idx, $end, $tk.Count, $found) -ForegroundColor DarkGray
}
