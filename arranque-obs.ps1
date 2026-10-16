# Táctica "Arranque" (largos, velas de 1h). Desde 16/10/2026 es SEÑAL REAL para las 40 monedas con más volumen (máx. 6 al día; strat 'arranque'); el resto sigue en observación silenciosa (strat 'arranque-obs').
# Motivo: 35 casos reales cerrados, 63% llegan a TP1 y +0,06R neto (cumple tus criterios: >=30 casos, >60% TP1, neto positivo).
# Disparo: la última vela de 1h cerrada rompe el máximo de las 48 anteriores, sube >= 3%, con volumen >= 3x la media de 24 velas y cierra en el 30% superior de su rango.
# Orden registrada: limit al 50% de la vela disparadora (se rellena si alguna de las 3 velas siguientes lo toca), SL en el mínimo de la vela, objetivos 1R/2R/3R con gestión en tercios (como el resto de señales).
# Backtest previo (60 monedas, 50 días): a mercado -0,03R (sin ventaja); limit 50%: +0,37R (79% llegan a TP1). Pendiente de validar con datos reales antes de emitir ningún aviso.
$script:ArqSent = 0
function Test-ArranqueTrigger($bars) {      # bars: velas ordenadas, la última es la que se está formando; se evalúa la última cerrada
    if ($bars.Count -lt 62) { return $null }
    $cl = @($bars[0..($bars.Count - 2)]); $i = $cl.Count - 1; $c0 = $cl[$i]
    $o = [double]$c0.open; $c = [double]$c0.close; $h = [double]$c0.high; $l = [double]$c0.low; if ($o -le 0 -or $h -le $l) { return $null }
    $ret = ($c / $o - 1) * 100; if ($ret -lt 3) { return $null }
    $pos = ($c - $l) / ($h - $l); if ($pos -lt 0.7) { return $null }
    $hh = ($cl[($i - 48)..($i - 1)] | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum; if ($c -le $hh) { return $null }
    $vol = [double]$c0.baseVol; if ($vol -le 0) { $vol = [double]$c0.volume }
    $va = ($cl[($i - 24)..($i - 1)] | ForEach-Object { $x = [double]$_.baseVol; if ($x -le 0) { $x = [double]$_.volume }; $x } | Measure-Object -Average).Average; if ($va -le 0 -or $vol -lt 3 * $va) { return $null }
    $mid = ($o + $c) / 2; $risk = ($mid - $l) / $mid * 100; if ($risk -gt 8 -or $risk -lt 0.4) { return $null }
    return @{ t = [long]$c0.time; o = $o; c = $c; h = $h; l = $l; ret = $ret; vx = $vol / $va; mid = $mid; risk = $risk }
}
function Register-ArranqueObs($sym, $tr, [bool]$real = $false) {
    $id = "arq-$sym-$($tr.t)"; if (@(Read-Signals | Where-Object { $_.id -eq $id }).Count) { return $false }
    $R = $tr.mid - $tr.l
    $lev = Get-SuggestedLev ([double]$tr.risk) 'cripto'      # apalancamiento orientativo: el SL cuesta como máximo el 20% del margen (regla de Luis)
    Add-SignalRecord ([ordered]@{
        id = $id; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = "${sym}USDT"; tf = '1h'; strat = $(if ($real) { 'arranque' } else { 'arranque-obs' }); side = 1; entryType = 'limit'; entry = $tr.mid; sl = $tr.l
        tp1 = $tr.mid + $R; tp2 = $tr.mid + 2 * $R; tp3 = $tr.mid + 3 * $R; riskAbs = $R; slPct = $tr.risk; lev = $(if ($real) { $lev } else { 1 }); status = 'pending'; stage = 0; realized = 0.0; age = 0; expiry = 3
        lastLabel = $tr.t; lab0 = $tr.t; cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = [Math]::Round($tr.vx, 1); ctxFlags = ("ret={0:N1}%" -f $tr.ret).Replace(',', '.'); note = $(if ($real) { "señal real: arranque 1h" } else { "observación silenciosa: arranque 1h" })
    })
    if ($real) {      # señal REAL (desde 16/10/2026, por decisión de Luis): solo las 40 monedas con más volumen y como máximo 6 al día; mismo formato compacto que el resto
        try { $n1 = ("ARRANQUE: la vela de 1h subió {0:N1}% con volumen x{1:N1} y rompió el máximo de 48 velas. Entra SOLO con la orden limit al 50% de esa vela (se rellena si el precio retrocede en las 3 velas siguientes; si no, se descarta). A mercado, perseguir, NO tiene ventaja." -f $tr.ret, $tr.vx)
            $n2 = "Medido en señales reales: 63% llegan a TP1, neto +0,06R tras comisiones (35 casos): ventaja pequeña."
            $n3 = "Gestión: margen aislado (máx. 200 USDT), SL puesto en Bitunix, un tercio en cada TP y SL a la entrada tras el TP1. Si no se ejecuta la orden en 3 velas, descártala."      # solo para tu chat privado
            $msgPriv = Format-CompactSignal 1 ("{0}/USDT · 1h" -f $sym) $null $tr.mid $true $lev $tr.l ($tr.mid + $R) ($tr.mid + 2 * $R) ($tr.mid + 3 * $R) 'cripto' '1h' @($n1, $n2, $n3)
            $msgGrp = Format-CompactSignal 1 ("{0}/USDT · 1h" -f $sym) $null $tr.mid $true $lev $tr.l ($tr.mid + $R) ($tr.mid + 2 * $R) ($tr.mid + 3 * $R) 'cripto' '1h' @($n1, $n2)      # grupo Alertas Mercados: misma señal, sin instrucciones personales ni mención a otros chats
            Send-ToSignalChats $msgPriv; if ($script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $msgGrp $null } } catch {}
    }
    return $true
}
function Run-ArranqueObsIfDue {      # cada vez que cierra una vela de 1h, por tandas de 25 monedas (el resto del bucle sigue atendiendo comandos)
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 3600); $idx = 0
    $st = Get-ReportState "arq"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $n = 150
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $n)
    if ($idx -ge $tk.Count) { return }
    $end = [Math]::Min($idx + 25, $tk.Count); Set-ReportState "arq" "${slot}:$end"; $found = 0
    $hoyIni = [DateTimeOffset]::new([DateTime]::UtcNow.Date, [TimeSpan]::Zero).ToUnixTimeSeconds(); $realHoy = @(Read-Signals | Where-Object { $_.strat -eq 'arranque' -and [long]$_.time -ge $hoyIni }).Count
    for ($q = $idx; $q -lt $end; $q++) { $t = $tk[$q]
        try {
            $sym = $t.symbol -replace 'USDT$', ''
            $b = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$($t.symbol)&interval=1h&limit=70" -TimeoutSec 20).data | Sort-Object { [long]$_.time })
            $tr = Test-ArranqueTrigger $b
            if ($tr) { $real = ($q -lt 40 -and $realHoy -lt 6); if (Register-ArranqueObs $sym $tr $real) { $found++; if ($real) { $realHoy++ } } }
        } catch {}
        Start-Sleep -Milliseconds 120
    }
    Write-Host ("  [arranque-obs] tanda {0}-{1} de {2} · disparos registrados: {3}" -f $idx, $end, $tk.Count, $found) -ForegroundColor DarkGray
}
