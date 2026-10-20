# OBSERVACIÓN SILENCIOSA "Tendencia v2" (largos, velas de 4h y 1d). NO envía nada: registra cada disparo en signals.jsonl (strat 'arranque-obs', id 'tv2-<tf>-<moneda>-<vela>', mode 'trail') para medir qué habría pasado.
# Origen: investigación del 20/10/2026 (autopsia de 221 señales cerradas + bt-modelos / bt-gestion / bt-tendencia). Las entradas sin impulso eran la causa de la mayoría de SL; los tercios 1R/2R/3R con BE recortaban a los pocos ganadores.
# Disparo (vela cerrada): cierre por encima del máximo de las 20 velas previas, volumen >= 2x la media de 20 velas y movimiento previo >= 5% (4h: 6 velas ~24h; 1d: 3 velas).
# Entrada hipotética a mercado en la apertura de la vela siguiente. SL bajo la mínima de la vela de ruptura - 0,1 ATR(14) (riesgo máx. 4 ATR). Gestión: SIN tercios ni BE; stop dinámico Chandelier 3 ATR desde el máximo (lo calcula tracker.ps1, mode 'trail'); cierre por tiempo a 40 velas (4h) o 20 (1d).
# Backtest (bt-gestion.ps1, 67 pares, ~200 días, coste 0,15%): 4h +0,29R (1ª mitad +0,23 · 2ª +0,34), 1d +0,26R; con 102 pares y más periodo: 4h +0,16R, 1d +0,14R. Con tercios+BE salía ~0 a +0,16R. Ventaja pequeña, sin garantía; se mide en real antes de avisar.
# SEGUNDA TÁCTICA (solo 1d, largos): BARRIDO DE LIQUIDEZ CON CONFIRMACIÓN (idea estudiada del grupo Crypto Ballena VIP / SMC). Barrido del mínimo de 20 velas (mecha que lo supera y cierre de vuelta dentro) en las últimas 5 velas + vela de DESPLAZAMIENTO (alcista, cuerpo >= 0,75 ATR) que cierra por encima del último swing alto (cambio de estructura). SL bajo la mínima del barrido - 0,1 ATR (máx. 4 ATR); misma gestión trailing. Backtest (bt-sweep-conf.ps1, ~120 pares, ~3 años, 0,15%): +0,26R con tercios, +0,45R con trailing (n=84; 1ª mitad +0,21 · 2ª +0,58); sin confirmación salía -0,19R. Muestra pequeña (~30 casos/año): solo se mide. ids 'tv2s-1d-...'.
# Se registra SIEMPRE y se etiqueta el régimen de BTC (btcEma50 y btcEma200 en ctxFlags) para medir después si conviene exigirlo. No se avisa hasta >=30 casos cerrados por marco y esperanza neta positiva.
function Get-BtcRegimeTf([string]$iv) {      # BTC sobre su EMA50 / EMA200 en el mismo marco (cache 30 min)
    if (-not $script:TV2Btc) { $script:TV2Btc = @{} }; $c = $script:TV2Btc[$iv]; if ($c -and ((Get-Date) - $c.at).TotalMinutes -lt 30) { return $c }
    $r = @{ at = Get-Date; e50 = 0; e200 = 0 }
    try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=BTCUSDT&interval=$iv&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $cl = @($k[0..($k.Count - 2)] | ForEach-Object { [double]$_.close })
        $e5 = Get-EmaValue $cl 50; $e2 = Get-EmaValue $cl 200; $r.e50 = [int]($e5 -and $cl[-1] -gt $e5); $r.e200 = [int]($e2 -and $cl[-1] -gt $e2) } catch {}
    $script:TV2Btc[$iv] = $r; return $r
}
function Test-TendenciaV2Trigger($bars, [string]$iv) {      # $bars = velas ordenadas, la última es la vela EN CURSO; devuelve $null o el plan
    if ($bars.Count -lt 60) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $cur = $bars[$bars.Count - 1]; $i = $cl.Count - 1
    $o = [double[]]($cl | ForEach-Object { $_.open }); $h = [double[]]($cl | ForEach-Object { $_.high }); $l = [double[]]($cl | ForEach-Object { $_.low }); $c = [double[]]($cl | ForEach-Object { $_.close })
    $v = [double[]]($cl | ForEach-Object { $x = [double]$_.quoteVol; if ($x -le 0) { $x = [double]$_.baseVol }; $x })
    $hi20 = ($h[($i - 20)..($i - 1)] | Measure-Object -Maximum).Maximum; if (-not ($c[$i] -gt $hi20)) { return $null }
    $va = ($v[($i - 20)..($i - 1)] | Measure-Object -Average).Average; if ($va -le 0 -or $v[$i] -lt 2 * $va) { return $null }
    $rb = $(if ($iv -eq '1d') { 3 } else { 6 }); $ret = ($c[$i] - $c[$i - $rb]) / $c[$i] * 100; if ($ret -lt 5) { return $null }
    $tr = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $tr += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $tr / 14
    $en = [double]$cur.open; if ($atr -le 0 -or $en -le 0) { return $null }
    $risk = [Math]::Min(4 * $atr, $en - ($l[$i] - 0.1 * $atr)); if ($risk -lt 0.3 * $atr) { $risk = 0.3 * $atr }
    $riskPct = $risk / $en * 100; if ($riskPct -lt 0.5 -or $riskPct -gt 15) { return $null }
    return @{ t = [long]$cl[$i].time; entry = $en; sl = ($en - $risk); risk = $risk; riskPct = $riskPct; atr = $atr; ret = $ret; vx = ($v[$i] / $va) }
}
function Test-SweepConfTrigger($bars) {      # SOLO 1d, largos: barrido + desplazamiento + cambio de estructura; $bars = velas ordenadas, la última es la vela EN CURSO
    if ($bars.Count -lt 60) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $cur = $bars[$bars.Count - 1]; $i = $cl.Count - 1
    $o = [double[]]($cl | ForEach-Object { $_.open }); $h = [double[]]($cl | ForEach-Object { $_.high }); $l = [double[]]($cl | ForEach-Object { $_.low }); $c = [double[]]($cl | ForEach-Object { $_.close })
    $v = [double[]]($cl | ForEach-Object { $x = [double]$_.quoteVol; if ($x -le 0) { $x = [double]$_.baseVol }; $x })
    $tr = 0.0; for ($q = $i - 13; $q -le $i; $q++) { $tr += [Math]::Max($h[$q] - $l[$q], [Math]::Max([Math]::Abs($h[$q] - $c[$q - 1]), [Math]::Abs($l[$q] - $c[$q - 1]))) }; $atr = $tr / 14
    $en = [double]$cur.open; if ($atr -le 0 -or $en -le 0) { return $null }
    if (-not ($c[$i] -gt $o[$i] -and ($c[$i] - $o[$i]) -ge 0.75 * $atr)) { return $null }
    $s0 = -1; for ($s = $i; $s -ge $i - 4; $s--) { $ex = ($l[($s - 20)..($s - 1)] | Measure-Object -Minimum).Minimum; if ($l[$s] -lt $ex -and $c[$s] -gt $ex) { $s0 = $s; break } }
    if ($s0 -lt 0) { return $null }
    $sw = ($h[($s0 - 4)..($i - 1)] | Measure-Object -Maximum).Maximum; if (-not ($c[$i] -gt $sw)) { return $null }
    $ext = ($l[$s0..$i] | Measure-Object -Minimum).Minimum; $risk = [Math]::Min(4 * $atr, $en - ($ext - 0.1 * $atr)); if ($risk -lt 0.3 * $atr) { $risk = 0.3 * $atr }
    $riskPct = $risk / $en * 100; if ($riskPct -lt 0.5 -or $riskPct -gt 15) { return $null }
    $va = ($v[($i - 20)..($i - 1)] | Measure-Object -Average).Average
    return @{ t = [long]$cl[$i].time; entry = $en; sl = ($en - $risk); risk = $risk; riskPct = $riskPct; atr = $atr; ret = (($c[$i] - $c[$i - 3]) / $c[$i] * 100); vx = $(if ($va -gt 0) { $v[$i] / $va } else { 0 }) }
}function Register-TendenciaV2Obs($sym, $tr, [string]$iv, [string]$kind = 'tv2') {
    $id = "$kind-$iv-$sym-$($tr.t)"; $all = @(Read-Signals); if (@($all | Where-Object { $_.id -eq $id }).Count) { return $false }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $cool = 6 * $(if ($iv -eq '1d') { 86400 } else { 14400 })      # enfriamiento de 6 velas (como en el backtest) y nunca dos abiertas de la misma moneda y marco
    if (@($all | Where-Object { "$($_.id)" -like "$kind-$iv-$sym-*" -and ($_.status -eq 'open' -or ($now - [long]$_.time) -lt $cool) }).Count) { return $false }
    $rg = Get-BtcRegimeTf $iv
    Add-SignalRecord ([ordered]@{
        id = $id; time = $now; sym = "${sym}USDT"; tf = $iv; strat = 'arranque-obs'; side = 1; entryType = 'market'; entry = $tr.entry; sl = $tr.sl; sl0 = $tr.sl
        tp1 = $tr.entry + $tr.risk; tp2 = $tr.entry + 2 * $tr.risk; tp3 = $tr.entry + 3 * $tr.risk; riskAbs = $tr.risk; slPct = $tr.riskPct; lev = 1; status = 'open'; stage = 0; realized = 0.0; age = 0; mode = 'trail'; atr0 = $tr.atr; ext = $tr.entry
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = [Math]::Round($tr.vx, 1)
        ctxFlags = ("{3};ret={0:N1}%;btcEma50={1};btcEma200={2}" -f $tr.ret, $rg.e50, $rg.e200, $(if ($kind -eq 'tv2s') { 'barrido-conf' } else { 'tendencia-v2' })).Replace(',', '.'); note = $(if ($kind -eq 'tv2s') { "observación silenciosa: barrido de liquidez + desplazamiento + MSS $iv (trailing 3 ATR)" } else { "observación silenciosa: tendencia v2 $iv (ruptura larga + momentum, trailing 3 ATR)" })
    })
    return $true
}
function Run-TendenciaV2ObsIfDue {      # cada vez que cierra una vela de 4h (y de 1d), por tandas de 25 monedas del top 120 por volumen (el resto del bucle sigue atendiendo comandos)
    foreach ($iv in '4h', '1d') {
        $secs = $(if ($iv -eq '1d') { 86400 } else { 14400 }); $key = $(if ($iv -eq '1d') { 'tv1' } else { 'tv4' })
        $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / $secs); $idx = 0
        $st = Get-ReportState $key; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
        $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 120)
        if ($idx -ge $tk.Count) { continue }; $end = [Math]::Min($idx + 25, $tk.Count); Set-ReportState $key "${slot}:$end"; $found = 0
        foreach ($t in @($tk[$idx..($end - 1)])) {
            try { $sym = $t.symbol -replace 'USDT$', ''; if ($sym -eq 'BTC') { Start-Sleep -Milliseconds 100; continue }
                $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=$iv&limit=100" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
                $tr = Test-TendenciaV2Trigger $b $iv; if ($tr -and (Register-TendenciaV2Obs $sym $tr $iv)) { $found++ }
                if ($iv -eq '1d') { $ts = Test-SweepConfTrigger $b; if ($ts -and (Register-TendenciaV2Obs $sym $ts $iv 'tv2s')) { $found++ } } } catch {}
            Start-Sleep -Milliseconds 120 }
        Write-Host ("  [tendencia-v2-obs {0}] tanda {1}-{2} de {3} · disparos registrados: {4}" -f $iv, $idx, $end, $tk.Count, $found) -ForegroundColor DarkGray
    }
}
