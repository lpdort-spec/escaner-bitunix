# OBSERVACIÓN SILENCIOSA "Barrido de liquidez con confirmación" en las 25 monedas con más volumen (1h y 4h, largos y cortos). NO envía nada: registra en signals.jsonl (strat 'arranque-obs', ids 'sw-<tf>-<moneda>-<L|S>-<vela>') con la gestión estándar (tercios 1R/2R/3R + BE).
# Idea de Luis (22/10/2026): el barrido de la liquidez de 82.800 en BTC y la caída posterior. Método (SMC): en las últimas 5 velas hay un BARRIDO del extremo de 20 velas (mecha que lo supera y cierre de vuelta dentro) y la vela actual es de DESPLAZAMIENTO (cuerpo >= 0,75 ATR a favor) que cierra rompiendo el último swing (cambio de estructura). SL tras la mecha del barrido (máx. 4 ATR).
# Backtest (bt-sweep-conf.ps1, 17 pares principales, ~100-270 días, 0,15 %): 1h CORTOS +0,24R (n=152; mitades +0,04/+0,45) pero 1h largos -0,17R; 4h largos +0,08R y 4h cortos -0,20R; resultados DISTINTOS por marco y lado -> no hay ventaja demostrada: se mide en real. En 120 pares el diario largo salió +0,26 a +0,45R (ya en observación como tv2s).
# Caso real BTC: barrido de 82.887 el 19/10 10:00Z (cierre 82.380, SL 83.185): TP1 (81.574) a las 14 h, luego volvió a la entrada (+0,33R con BE); el mínimo posterior 81.151 fue 1,5R, pero el máximo posterior 84.872 llegó a 3,1R en contra.
function Test-BarridoTrigger($bars, [int]$sg) {      # $bars = velas ordenadas, la última es la vela EN CURSO (la real o la sintética de velas-cerradas.ps1)
    if ($bars.Count -lt 60) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $cur = $bars[$bars.Count - 1]; $i = $cl.Count - 1
    $o = [double[]]($cl | ForEach-Object { $_.open }); $h = [double[]]($cl | ForEach-Object { $_.high }); $l = [double[]]($cl | ForEach-Object { $_.low }); $c = [double[]]($cl | ForEach-Object { $_.close })
    $tr = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $tr += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $tr / 14
    $en = [double]$cur.open; if ($atr -le 0 -or $en -le 0) { return $null }
    if ($sg -eq 1) { if (-not ($c[$i] -gt $o[$i] -and ($c[$i] - $o[$i]) -ge 0.75 * $atr)) { return $null } } else { if (-not ($c[$i] -lt $o[$i] -and ($o[$i] - $c[$i]) -ge 0.75 * $atr)) { return $null } }
    $s0 = -1; $lvl = 0.0
    for ($s = $i; $s -ge $i - 4; $s--) {
        if ($sg -eq 1) { $ex = ($l[($s - 20)..($s - 1)] | Measure-Object -Minimum).Minimum; if ($l[$s] -lt $ex -and $c[$s] -gt $ex) { $s0 = $s; $lvl = $ex; break } }
        else { $ex = ($h[($s - 20)..($s - 1)] | Measure-Object -Maximum).Maximum; if ($h[$s] -gt $ex -and $c[$s] -lt $ex) { $s0 = $s; $lvl = $ex; break } } }
    if ($s0 -lt 0) { return $null }
    if ($sg -eq 1) { $sw = ($h[($s0 - 4)..($i - 1)] | Measure-Object -Maximum).Maximum; if (-not ($c[$i] -gt $sw)) { return $null }; $ext = ($l[$s0..$i] | Measure-Object -Minimum).Minimum; $risk = $en - ($ext - 0.1 * $atr) }
    else { $sw = ($l[($s0 - 4)..($i - 1)] | Measure-Object -Minimum).Minimum; if (-not ($c[$i] -lt $sw)) { return $null }; $ext = ($h[$s0..$i] | Measure-Object -Maximum).Maximum; $risk = ($ext + 0.1 * $atr) - $en }
    if ($risk -gt 4 * $atr) { $risk = 4 * $atr }; if ($risk -lt 0.3 * $atr) { $risk = 0.3 * $atr }
    $riskPct = $risk / $en * 100; if ($riskPct -lt 0.5 -or $riskPct -gt 15) { return $null }
    return @{ t = [long]$cl[$i].time; sg = $sg; entry = $en; sl = ($en - $sg * $risk); risk = $risk; riskPct = $riskPct; atr = $atr; lvl = $lvl }
}
function Register-BarridoObs($sym, $tr, [string]$iv) {
    $lado = $(if ($tr.sg -eq 1) { 'L' } else { 'S' }); $id = "sw-$iv-$sym-$lado-$($tr.t)"; $all = @(Read-Signals); if (@($all | Where-Object { $_.id -eq $id }).Count) { return $false }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $cool = 6 * $(if ($iv -eq '4h') { 14400 } else { 3600 })
    if (@($all | Where-Object { "$($_.id)" -like "sw-$iv-$sym-$lado-*" -and ($_.status -in 'open', 'pending' -or ($now - [long]$_.time) -lt $cool) }).Count) { return $false }
    $sg = $tr.sg; $R = $tr.risk
    Add-SignalRecord ([ordered]@{
        id = $id; time = $now; sym = "${sym}USDT"; tf = $iv; strat = 'arranque-obs'; side = $sg; entryType = 'market'; entry = $tr.entry; sl = $tr.sl
        tp1 = $tr.entry + $sg * $R; tp2 = $tr.entry + $sg * 2 * $R; tp3 = $tr.entry + $sg * 3 * $R; riskAbs = $R; slPct = $tr.riskPct; lev = 1; status = 'open'; stage = 0; realized = 0.0; age = 0
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = $null
        ctxFlags = ("barrido-conf;lado={0};nivel_barrido={1}" -f $(if ($sg -eq 1) { 'LARGO' } else { 'CORTO' }), $tr.lvl).Replace(',', '.'); note = "observación silenciosa: barrido de liquidez + desplazamiento + MSS $iv ($(if ($sg -eq 1) { 'largo' } else { 'corto' }))"
    })
    return $true
}
function Run-BarridoObsIfDue {      # una vez por cada vela cerrada de 1h y de 4h, sobre las 25 monedas con más volumen
    foreach ($iv in '1h', '4h') {
        $secs = $(if ($iv -eq '4h') { 14400 } else { 3600 }); $key = $(if ($iv -eq '4h') { 'sw4' } else { 'sw1' }); $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / $secs)
        if ((Get-ReportState $key) -eq "$slot") { continue }; Set-ReportState $key "$slot"; $found = 0
        $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 25)
        foreach ($t in $tk) {
            try { $sym = $t.symbol -replace 'USDT$', ''
                $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=$iv&limit=100" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
                foreach ($sg in 1, -1) { $tr = Test-BarridoTrigger $b $sg; if ($tr -and (Register-BarridoObs $sym $tr $iv)) { $found++ } } } catch {}
            Start-Sleep -Milliseconds 120 }
        Write-Host ("  [barrido-obs {0}] 25 monedas revisadas · disparos registrados: {1}" -f $iv, $found) -ForegroundColor DarkGray
    }
}
