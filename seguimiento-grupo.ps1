# Seguimiento de oportunidades NO operadas, comunicado SOLO al grupo Alertas Mercados: se registra la oportunidad con su entrada, SL, TP parcial y TP final,
# se sigue con las velas reales (mismo seguimiento que las señales: tercios en 1R/2R/3R, SL a la entrada tras el TP parcial) y se avisa de cada hecho con un análisis de por qué.
# Registro: seguimiento-grupo.json (se importa una sola vez por id). Los registros usan strat 'seg-grupo' y NO entran en las estadísticas privadas.

function Import-GroupTracking($file) {
    if (-not (Test-Path $file)) { return }
    $items = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json; $have = @(Read-Signals | ForEach-Object { $_.id })
    foreach ($i in $items) {
        if ($i.id -in $have) { continue }
        $lastLabel = [long]0
        try { $k = @((Invoke-RestMethod "$($script:TrkBase)/kline?symbol=$($i.sym)USDT&interval=4h&limit=5" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $lastLabel = [long]$k[$k.Count - 2].time } catch { continue }
        $sg = [int]$i.side; $en = [double]$i.entry; $sl = [double]$i.sl; $risk = [Math]::Abs($en - $sl)
        Add-SignalRecord ([ordered]@{
            id = $i.id; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = "$($i.sym)USDT"; tf = "4h"; strat = "seg-grupo"; side = $sg
            entryType = "limit"; entry = $en; sl = $sl; tp1 = [double]$i.tp1; tp2 = [double]$i.tp2; tp3 = [double]$i.tp3; riskAbs = $risk; slPct = ($risk / $en * 100)
            ratio = $null; trend = $null; aligned = $null; btcAligned = $null; pool = ""; risk = "SEGUIMIENTO"
            status = "pending"; stage = 0; realized = 0.0; age = 0; lastLabel = $lastLabel; lab0 = $lastLabel; expiry = $(if ($i.expiry) { [int]$i.expiry } else { 12 })
            cost = 0.0015; outcome = $null; R = $null; net = $null; note = $i.note
        })
    }
}

function Get-GtCandles($sym, [long]$sinceMs) {
    try { $k = @((Invoke-RestMethod "$($script:TrkBase)/kline?symbol=$sym&interval=4h&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $k = @($k[0..($k.Count - 2)])
          return @($k | Where-Object { [long]$_.time -ge $sinceMs }) } catch { return @() }
}

# Análisis de lo ocurrido con datos reales (hechos medidos, no causas inventadas)
function Explain-GroupOutcome($s) {
    $sg = [int]$s.side; $en = [double]$s.entry; $sl = [double]$s.sl; $R = [double]$s.riskAbs; $sym = $s.sym -replace 'USDT$', ''
    $L = @()
    $bars = @(Get-GtCandles $s.sym ([long]$s.lab0 + 1))
    if ($bars.Count) {
        $mfe = 0.0; $mae = 0.0; $hitBar = $null
        foreach ($b in $bars) { $fav = $sg * (($(if ($sg -eq 1) { [double]$b.high } else { [double]$b.low })) - $en) / $R; $adv = -$sg * (($(if ($sg -eq 1) { [double]$b.low } else { [double]$b.high })) - $en) / $R
            if ($fav -gt $mfe) { $mfe = $fav }; if ($adv -gt $mae) { $mae = $adv }
            if (-not $hitBar -and (($sg -eq 1 -and [double]$b.low -le $sl) -or ($sg -eq -1 -and [double]$b.high -ge $sl))) { $hitBar = $b } }
        $L += ("📏 Recorrido medido desde el registro ({0} velas de 4h): a favor hasta {1:N1}R · en contra hasta {2:N1}R" -f $bars.Count, $mfe, $mae)
        if ($hitBar -and $s.outcome -eq 'SL') {
            $cl = [double]$hitBar.close; $closedBeyond = ($sg -eq 1 -and $cl -lt $sl) -or ($sg -eq -1 -and $cl -gt $sl)
            $vols = @($bars | ForEach-Object { if ($_.baseVol) { [double]$_.baseVol } else { [double]$_.volume } }); $vh = if ($hitBar.baseVol) { [double]$hitBar.baseVol } else { [double]$hitBar.volume }; $va = ($vols | Measure-Object -Average).Average
            $L += $(if ($closedBeyond) { "🕯️ La vela que tocó el SL CERRÓ más allá del nivel: la ruptura del stop fue decidida, no solo una mecha." } else { "🕯️ La vela que tocó el SL volvió a cerrar del lado correcto: fue una mecha (barrido del stop) y el precio no se quedó fuera." })
            if ($va -gt 0) { $L += ("📊 Volumen de esa vela: x{0:N1} la media de las velas seguidas" -f ($vh / $va)) }
        }
        $t0 = [long]$s.lab0
        try { $bt = @(Get-GtCandles 'BTCUSDT' ($t0 + 1)); if ($bt.Count -gt 1 -and $sym -ne 'BTC') { $ch = ([double]$bt[-1].close / [double]$bt[0].open - 1) * 100; $L += ("₿ Bitcoin en ese mismo periodo: {0:+0.0;-0.0}%{1}" -f $ch, $(if ($sg * $ch -lt -1.5) { " → el mercado fue en contra de la operación, lo que ayuda a explicar el resultado" } elseif ($sg * $ch -gt 1.5) { " → el mercado acompañó" } else { " → no fue un factor determinante" })) } } catch {}
    }
    try {
        $px = [double]((Invoke-RestMethod "$($script:TrkBase)/tickers").data | Where-Object symbol -eq $s.sym).lastPrice
        $ss = @{ src = 'bitunix'; sym = $sym; name = "$sym/USDT"; currency = 'USDT'; exch = ''; price = $px; extra = @{ funding = $null } }
        $sc = Get-MomScores $ss
        if ($sc) { $me = if ($sg -eq 1) { $sc.lg } else { $sc.st }
            $L += ("🧭 Lectura actual del activo para este lado: puntuación {0} (al registrarla era favorable)" -f $me.score)
            $neg = @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 3); if ($neg.Count) { $L += "   Factores que hoy están EN CONTRA:"; $neg | ForEach-Object { $L += "   $_" } }
            $pos = @($me.fx | Where-Object { $_ -like '✅*' } | Select-Object -First 3); if ($pos.Count -and $s.outcome -ne 'SL') { $L += "   Factores que siguen a favor:"; $pos | ForEach-Object { $L += "   $_" } } }
    } catch {}
    return ($L -join "`n")
}

function Fmt-GtLevels($s) { return ("entrada {0} · SL {1} · TP parcial {2} · TP2 {3} · TP final {4}" -f (TaFp $s.entry), (TaFp $s.sl), (TaFp $s.tp1), (TaFp $s.tp2), (TaFp $s.tp3)) }

function Notify-GroupTracking {
    if (-not ($TelegramToken -and $script:MktChat)) { return }
    $sigs = Read-Signals; $dirty = $false
    foreach ($s in @($sigs | Where-Object { $_.strat -eq 'seg-grupo' })) {
        $tok = "$($s.closeNote)"; $sym = $s.sym -replace 'USDT$', ''; $dir = if ([int]$s.side -eq 1) { "LARGO" } else { "CORTO" }; $msg = $null
        if ($s.status -eq 'unfilled' -and $tok -notlike '*X*') {
            $msg = "👁️ SEGUIMIENTO · $sym $dir · SIN EJECUCIÓN`nLa orden limit (" + (TaFp $s.entry) + ") no llegó a ejecutarse: " + $s.note + ". Sin entrada, no hay resultado que contar.`nQué significa: el precio no hizo el retroceso al nivel previsto" + $(if ("$($s.note)" -like '*se fue*') { " y se fue directo hacia los objetivos (el movimiento se dio sin darnos entrada)." } elseif ("$($s.note)" -like '*invalidada*') { ", sino que perdió el nivel del stop antes de tocar la entrada (setup invalidado)." } else { " en el plazo previsto." })
            $s.closeNote = "$tok" + "X"; $dirty = $true
        }
        elseif ($s.status -in 'open', 'closed') {
            if ($tok -notlike '*F*') { $tok += "F"; $s.closeNote = $tok; $dirty = $true; Send-Tg $TelegramToken $script:MktChat ("👁️ SEGUIMIENTO · $sym $dir · ORDEN EJECUTADA`nEl precio hizo el retroceso y tocó la entrada: " + (Fmt-GtLevels $s)) $null }
            if ([int]$s.stage -ge 1 -and $tok -notlike '*1*') { $tok += "1"; $s.closeNote = $tok; $dirty = $true; Send-Tg $TelegramToken $script:MktChat ("✅ SEGUIMIENTO · $sym $dir · TP PARCIAL ALCANZADO (" + (TaFp $s.tp1) + ")`nSe asegura un tercio y el SL pasa a la entrada (" + (TaFp $s.entry) + "): desde aquí la operación ya no puede dar pérdida, salvo comisiones.") $null }
            if ([int]$s.stage -ge 2 -and $tok -notlike '*2*') { $tok += "2"; $s.closeNote = $tok; $dirty = $true; Send-Tg $TelegramToken $script:MktChat ("✅ SEGUIMIENTO · $sym $dir · TP2 ALCANZADO (" + (TaFp $s.tp2) + ")`nSegundo tercio asegurado; queda el último tercio hacia el TP final (" + (TaFp $s.tp3) + ").") $null }
            if ($s.status -eq 'closed' -and $tok -notlike '*X*') {
                $head = switch ("$($s.outcome)") { 'SL' { "❌ STOP LOSS ALCANZADO" } 'TP3' { "🏆 TP FINAL ALCANZADO" } 'TP1 + BE' { "➖ CIERRE EN LA ENTRADA tras el TP parcial" } 'TP2 + BE' { "✅ CIERRE EN BENEFICIO tras el TP2 (el resto volvió a la entrada)" } default { "⏱️ CIERRE POR TIEMPO" } }
                $res = if ($null -ne $s.R) { "Resultado: {0:+0.00;-0.00}R bruto ({1:+0.00;-0.00}R tras comisiones)" -f [double]$s.R, [double]$s.net } else { "" }
                $m = "$head · $sym $dir`n$res`n`n" + (Explain-GroupOutcome $s) + "`n`nEs un seguimiento de una oportunidad que no se operó: sirve para comprobar si la lectura funciona. No es asesoramiento."
                $s.closeNote = $tok + "X"; $dirty = $true; Send-Tg $TelegramToken $script:MktChat $m $null
            }
        }
    }
    if ($dirty) { Save-Signals $sigs }
}

# ---------- Aviso de CAMBIO SIGNIFICATIVO en señales ya enviadas ----------
# Regla fija: operación abierta o pendiente cuyo lado puntúa <= 0 en la lectura de momento Y el lado contrario puntúa >= 6 (la lectura se ha dado la vuelta).
# Cripto: se revisa tras cada cierre de vela de 4h; acciones/ETFs: una vez al día tras el cierre. Un solo aviso por señal.
# Destinos: operaciones manuales y rupturas cripto -> chat privado; rupturas 4h de cripto, seguimientos y señales de mercado -> grupo Alertas Mercados.
function Check-SignalHealth {
    if (-not $TelegramToken) { return }
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); $now = Get-MadridNow; $day = $now.ToString("yyyy-MM-dd")
    $st = Get-ReportState "salud"; $lastSlot = [long]0; $lastDay = ""; if ($st -match '^(\d+)\|(.*)$') { $lastSlot = [long]$Matches[1]; $lastDay = $Matches[2] }
    $weekday = $now.DayOfWeek -notin [DayOfWeek]::Saturday, [DayOfWeek]::Sunday
    $doCrypto = ($slot -ne $lastSlot); $doStocks = ($day -ne $lastDay -and $weekday -and $now.Hour -ge 23)
    if (-not $doCrypto -and -not $doStocks) { return }
    Set-ReportState "salud" ("{0}|{1}" -f $(if ($doCrypto) { $slot } else { $lastSlot }), $(if ($doStocks) { $day } else { $lastDay }))
    $warned = @((Get-ReportState "saludw") -split ',' | Where-Object { $_ })
    $cand = @(Read-Signals | Where-Object { $_.status -in 'open', 'pending' -and ($_.strat -in 'ruptura', 'ruptura-mercado', 'seg-grupo' -or $_.manual -eq $true) -and $_.id -notin $warned })
    if (-not $cand.Count) { return }
    $tk = $null
    foreach ($s in $cand) {
        $isStock = ($s.src -eq 'yahoo'); if ($isStock -and -not $doStocks) { continue }; if (-not $isStock -and -not $doCrypto) { continue }
        try {
            $sg = [int]$s.side; $sym = $s.sym -replace 'USDT$', ''
            if ($isStock) { $ss = Get-YahooSeries $s.sym }
            else { if (-not $tk) { $tk = @((Invoke-RestMethod "$($script:TrkBase)/tickers").data) }; $row = $tk | Where-Object symbol -eq $s.sym | Select-Object -First 1; if (-not $row) { continue }; $ss = @{ src = 'bitunix'; sym = $sym; name = "$sym/USDT"; currency = 'USDT'; exch = ''; price = [double]$row.lastPrice; extra = @{ funding = $null } } }
            if (-not $ss) { continue }
            $sc = Get-MomScores $ss; if (-not $sc) { continue }
            $own = if ($sg -eq 1) { $sc.lg } else { $sc.st }; $opp = if ($sg -eq 1) { $sc.st } else { $sc.lg }
            if (-not ($own.score -le 0 -and $opp.score -ge 6)) { continue }
            $px = [double]$ss.price; $pnl = $sg * ($px / [double]$s.entry - 1) * 100
            $neg = @($own.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 4)
            $m = ("⚠️ CAMBIO SIGNIFICATIVO · {0} {1} · valora CERRAR o proteger la operación`nLa lectura del activo se ha dado la vuelta: para esta dirección puntúa {2} y para la contraria {3}.`nPrecio actual {4} frente a entrada {5} ({6:+0.0;-0.0}% sobre la entrada) · SL {7}" -f $sym, $(if ($sg -eq 1) { 'LARGO' } else { 'CORTO' }), $own.score, $opp.score, (TaFp $px), (TaFp ([double]$s.entry)), $pnl, (TaFp ([double]$s.sl)))
            if ($neg.Count) { $m += "`nFactores en contra ahora:`n" + (($neg | ForEach-Object { "   $_" }) -join "`n") }
            $m += "`nEl bot no cierra nada: decides tú. Regla del aviso: el lado de la operación puntúa 0 o menos y el contrario 6 o más."
            $toPriv = (-not $isStock) -and ($s.strat -ne 'seg-grupo'); $toGroup = ($isStock) -or ($s.strat -eq 'seg-grupo') -or ($s.strat -eq 'ruptura' -and $s.tf -eq '4h')
            if ($s.manual -eq $true) { $toPriv = $true; $toGroup = $false }
            if ($toPriv) { Send-ToSignalChats $m }
            if ($toGroup -and $script:MktChat) { Send-Tg $TelegramToken $script:MktChat $m $null }
            $warned += $s.id
        } catch {}
        Start-Sleep -Milliseconds 150
    }
    Set-ReportState "saludw" ((@($warned | Select-Object -Last 80)) -join ',')
}
