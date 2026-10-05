# Seguimiento de oportunidades NO operadas, comunicado SOLO al grupo Alertas Mercados: se registra la oportunidad con su entrada, SL, TP parcial y TP final,
# se sigue con las velas reales (mismo seguimiento que las señales: tercios en 1R/2R/3R, SL a la entrada tras el TP parcial) y se avisa de cada hecho con un análisis de por qué.
# Registro: seguimiento-grupo.json (se importa una sola vez por id). Los registros usan strat 'seg-grupo' y NO entran en las estadísticas privadas.

function Import-GroupTracking($file) {
    if (-not (Test-Path $file)) { return }
    $items = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json; $have = @(Read-Signals | ForEach-Object { $_.id })
    foreach ($i in $items) {
        if ($i.id -in $have) {
            if ($i.replace -eq $true) {
                $all = Read-Signals; $r0 = $all | Where-Object { $_.id -eq $i.id } | Select-Object -First 1
                if ($r0 -and $r0.status -in 'open', 'pending' -and ([double]$r0.sl -ne [double]$i.sl -or [double]$r0.tp1 -ne [double]$i.tp1 -or [double]$r0.tp3 -ne [double]$i.tp3)) {
                    $r0.sl = [double]$i.sl; $r0.tp1 = [double]$i.tp1; $r0.tp2 = [double]$i.tp2; $r0.tp3 = [double]$i.tp3; $r0.riskAbs = [Math]::Abs([double]$r0.entry - [double]$i.sl); $r0.slPct = $r0.riskAbs / [double]$r0.entry * 100
                    Save-Signals $all
                }
            }
            continue
        }
        $lastLabel = [long]0
        try { $k = @((Invoke-RestMethod "$($script:TrkBase)/kline?symbol=$($i.sym)USDT&interval=4h&limit=5" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $lastLabel = [long]$k[$k.Count - 2].time } catch { continue }
        $sg = [int]$i.side; $en = [double]$i.entry; $sl = [double]$i.sl; $risk = [Math]::Abs($en - $sl)
        Add-SignalRecord ([ordered]@{
            id = $i.id; time = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); sym = "$($i.sym)USDT"; tf = "4h"; strat = $(if ($i.dest -eq "privado") { "seg-priv" } else { "seg-grupo" }); side = $sg
            entryType = $(if ($i.dest -eq "privado") { "market" } else { "limit" }); entry = $en; sl = $sl; tp1 = [double]$i.tp1; tp2 = [double]$i.tp2; tp3 = [double]$i.tp3; riskAbs = $risk; slPct = ($risk / $en * 100)
            ratio = $null; trend = $null; aligned = $null; btcAligned = $null; pool = ""; risk = "SEGUIMIENTO"
            status = $(if ($i.dest -eq "privado") { "open" } else { "pending" }); stage = 0; realized = 0.0; age = 0; lastLabel = $lastLabel; lab0 = $lastLabel; expiry = $(if ($i.expiry) { [int]$i.expiry } else { 12 })
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

function Send-GtMsg($priv, $text) {
    if ($priv) { $text = $text.Replace('SEGUIMIENTO', 'TU OPERACIÓN').Replace('Es un seguimiento de una oportunidad que no se operó: sirve para comprobar si la lectura funciona. No es asesoramiento.', 'Seguimiento de tu operación con el plan propuesto (SL, TP parcial y final). No es asesoramiento.'); Send-ToSignalChats $text }
    elseif ($script:MktChat) { Send-Tg $TelegramToken $script:MktChat $text $null }
}
function Notify-GroupTracking {
    if (-not $TelegramToken) { return }
    $sigs = Read-Signals; $dirty = $false
    foreach ($s in @($sigs | Where-Object { $_.strat -in 'seg-grupo', 'seg-priv' })) {
        $priv = ($s.strat -eq 'seg-priv'); $tok = "$($s.closeNote)"; $sym = $s.sym -replace 'USDT$', ''; $dir = if ([int]$s.side -eq 1) { "LARGO" } else { "CORTO" }; $msg = $null
        if ($s.status -eq 'unfilled' -and $tok -notlike '*X*') {
            $msg = "👁️ SEGUIMIENTO · $sym $dir · SIN EJECUCIÓN`nLa orden limit (" + (TaFp $s.entry) + ") no llegó a ejecutarse: " + $s.note + ". Sin entrada, no hay resultado que contar.`nQué significa: el precio no hizo el retroceso al nivel previsto" + $(if ("$($s.note)" -like '*se fue*') { " y se fue directo hacia los objetivos (el movimiento se dio sin darnos entrada)." } elseif ("$($s.note)" -like '*invalidada*') { ", sino que perdió el nivel del stop antes de tocar la entrada (setup invalidado)." } else { " en el plazo previsto." })
            $s.closeNote = "$tok" + "X"; $dirty = $true; Send-GtMsg $priv $msg
        }
        elseif ($s.status -in 'open', 'closed') {
            if ($tok -notlike '*F*') { $tok += "F"; $s.closeNote = $tok; $dirty = $true; if (-not $priv) { Send-GtMsg $priv ("👁️ SEGUIMIENTO · $sym $dir · ORDEN EJECUTADA`nEl precio hizo el retroceso y tocó la entrada: " + (Fmt-GtLevels $s)) } }
            if ([int]$s.stage -ge 1 -and $tok -notlike '*1*') { $tok += "1"; $s.closeNote = $tok; $dirty = $true; Send-GtMsg $priv ("✅ SEGUIMIENTO · $sym $dir · TP PARCIAL ALCANZADO (" + (TaFp $s.tp1) + ")`nSe asegura un tercio y el SL pasa a la entrada (" + (TaFp $s.entry) + "): desde aquí la operación ya no puede dar pérdida, salvo comisiones.") }
            if ([int]$s.stage -ge 2 -and $tok -notlike '*2*') { $tok += "2"; $s.closeNote = $tok; $dirty = $true; Send-GtMsg $priv ("✅ SEGUIMIENTO · $sym $dir · TP2 ALCANZADO (" + (TaFp $s.tp2) + ")`nSegundo tercio asegurado; queda el último tercio hacia el TP final (" + (TaFp $s.tp3) + ").") }
            if ($s.status -eq 'closed' -and $tok -notlike '*X*') {
                $head = switch ("$($s.outcome)") { 'SL' { "❌ STOP LOSS ALCANZADO" } 'TP3' { "🏆 TP FINAL ALCANZADO" } 'TP1 + BE' { "➖ CIERRE EN LA ENTRADA tras el TP parcial" } 'TP2 + BE' { "✅ CIERRE EN BENEFICIO tras el TP2 (el resto volvió a la entrada)" } default { "⏱️ CIERRE POR TIEMPO" } }
                $res = if ($null -ne $s.R) { "Resultado: {0:+0.00;-0.00}R bruto ({1:+0.00;-0.00}R tras comisiones)" -f [double]$s.R, [double]$s.net } else { "" }
                $m = "$head · $sym $dir`n$res`n`n" + (Explain-GroupOutcome $s) + "`n`nEs un seguimiento de una oportunidad que no se operó: sirve para comprobar si la lectura funciona. No es asesoramiento."
                $s.closeNote = $tok + "X"; $dirty = $true; Send-GtMsg $priv $m
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
    $cand = @(Read-Signals | Where-Object { $_.status -in 'open', 'pending' -and ($_.strat -in 'ruptura', 'ruptura-mercado', 'seg-grupo', 'seg-priv' -or $_.manual -eq $true) -and $_.id -notin $warned })
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

# ---------- Revisión de gestión de TUS operaciones abiertas (strat seg-priv): SOLO al chat privado ----------
# Cada vela de 4h se mira si hay un soporte/resistencia nuevo que justifique SUBIR el SL (largos) o BAJARLO (cortos), o una resistencia/soporte antes del TP final que aconseje tomar beneficios antes.
# Un aviso por cambio de nivel. El bot no modifica ninguna orden: lo haces tú en Bitunix.
$script:RpSlot = 0
function Review-OpenPositions {
    if (-not $TelegramToken) { return }
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); if ($slot -eq $script:RpSlot) { return }; $script:RpSlot = $slot
    $mem = @{}; foreach ($kv in ((Get-ReportState "ajustes") -split ',' | Where-Object { $_ -match '=' })) { $p = $kv -split '=', 2; $mem[$p[0]] = $p[1] }
    $tk = $null; $chg = $false
    foreach ($s in @(Read-Signals | Where-Object { $_.strat -eq 'seg-priv' -and $_.status -eq 'open' })) {
        try {
            $sym = $s.sym -replace 'USDT$', ''; $sg = [int]$s.side
            if (-not $tk) { $tk = @((Invoke-RestMethod "$($script:TrkBase)/tickers").data) }; $row = $tk | Where-Object symbol -eq $s.sym | Select-Object -First 1; if (-not $row) { continue }; $px = [double]$row.lastPrice
            $cd = Get-MomentoCd @{ src = 'bitunix'; sym = $sym } '4h'; if (-not $cd) { continue }; $a = Analyze-TF $cd '4h' 100; $atr = [double]$a.atr; if ($atr -le 0) { continue }
            $en = [double]$s.entry; $slEff = if ([int]$s.stage -ge 1) { $en } else { [double]$s.sl }; $tpF = [double]$s.tp3; $msgs = @()
            $lvls = if ($sg -eq 1) { @($a.sup | ForEach-Object { [double]$_.p } | Where-Object { $_ -lt $px - 0.5 * $atr }) } else { @($a.res | ForEach-Object { [double]$_.p } | Where-Object { $_ -gt $px + 0.5 * $atr }) }
            if ($lvls.Count) {
                $near = if ($sg -eq 1) { ($lvls | Measure-Object -Maximum).Maximum } else { ($lvls | Measure-Object -Minimum).Minimum }; $newSl = $near - $sg * 0.3 * $atr
                $better = if ($sg -eq 1) { $newSl -gt $slEff + 0.5 * $atr } else { $newSl -lt $slEff - 0.5 * $atr }; $last = if ($mem.ContainsKey("$($s.id)|sl")) { [double]$mem["$($s.id)|sl"] } else { $null }
                $newer = ($null -eq $last) -or ($sg -eq 1 -and $newSl -gt $last + 0.5 * $atr) -or ($sg -eq -1 -and $newSl -lt $last - 0.5 * $atr)
                if ($better -and $newer) { $msgs += ("🔧 Ajuste de SL: hay un nuevo {0} en {1}. Podrías {2} el SL de {3} a {4} (un poco {5} del nivel), asegurando más y sin quedar pegado al ruido." -f $(if ($sg -eq 1) { "soporte" } else { "resistencia" }), (TaFp $near), $(if ($sg -eq 1) { "subir" } else { "bajar" }), (TaFp $slEff), (TaFp $newSl), $(if ($sg -eq 1) { "por debajo" } else { "por encima" })); $mem["$($s.id)|sl"] = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $newSl); $chg = $true }
            }
            $obs = if ($sg -eq 1) { @($a.res | ForEach-Object { [double]$_.p } | Where-Object { $_ -gt $px -and $_ -lt $tpF - 0.5 * $atr }) } else { @($a.sup | ForEach-Object { [double]$_.p } | Where-Object { $_ -lt $px -and $_ -gt $tpF + 0.5 * $atr }) }
            if ($obs.Count) {
                $ob = if ($sg -eq 1) { ($obs | Measure-Object -Minimum).Minimum } else { ($obs | Measure-Object -Maximum).Maximum }; $lastO = if ($mem.ContainsKey("$($s.id)|tp")) { [double]$mem["$($s.id)|tp"] } else { $null }
                if ($null -eq $lastO -or [Math]::Abs($ob - $lastO) -gt 0.5 * $atr) { $msgs += ("🎯 Ajuste de TP: hay {0} en {1}, antes de tu TP final ({2}). Valora tomar beneficios allí o bajar el TP un poco antes del nivel." -f $(if ($sg -eq 1) { "una resistencia" } else { "un soporte" }), (TaFp $ob), (TaFp $tpF)); $mem["$($s.id)|tp"] = [string]::Format([Globalization.CultureInfo]::InvariantCulture, "{0}", $ob); $chg = $true }
            }
            # noticias de riesgo recientes sobre el activo (legal, regulación, riesgo): se tienen en cuenta SIN reenviar la noticia; se propone proteger la operación
            $nr = @(); try { foreach ($nw in @(Get-AssetNews $sym $null $true 12)) { $nr += @(Get-NewsFlags $nw.title | Where-Object { $_ -match 'legal|regulación|riesgo' }) } } catch {}
            $nr = @($nr | Select-Object -Unique)
            if ($nr.Count) {
                $kn = "$($s.id)|news|$((Get-Date).ToString('yyyyMMdd'))"
                if (-not $mem.ContainsKey($kn)) {
                    $prot = if ($sg * ($px - $en) -gt 0.5 * $atr) { $en + $sg * 0.1 * $atr } elseif ($lvls.Count) { $near - $sg * 0.3 * $atr } else { $slEff }
                    $improve = if ($sg -eq 1) { $prot -gt $slEff } else { $prot -lt $slEff }
                    $msgs += ("📰 Tengo en cuenta noticias recientes de riesgo sobre {0} ({1}; no te las reenvío). Por prudencia: {2} TP final sin cambios ({3}) y, si ya estás en beneficio, valora tomar parcial ahora." -f $sym, ($nr -join ' · '), $(if ($improve) { "SL propuesto " + (TaFp $prot) + " (antes " + (TaFp $slEff) + ");" } else { "mantén el SL (" + (TaFp $slEff) + ") sin aflojarlo y no añadas posición;" }), (TaFp $tpF))
                    $mem[$kn] = "1"; $chg = $true
                }
            }
            if ($msgs.Count) { Send-ToSignalChats (("📌 GESTIÓN DE TU OPERACIÓN · {0} {1} · precio {2} (entrada {3})`n" -f $sym, $(if ($sg -eq 1) { "LARGO" } else { "CORTO" }), (TaFp $px), (TaFp $en)) + ($msgs -join "`n") + "`nEl bot no modifica ninguna orden: decides tú. Son sugerencias de estructura de 4h, no garantías.") }
        } catch {}
    }
    if ($chg) { Set-ReportState "ajustes" ((@($mem.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) | Select-Object -Last 40) -join ',') }
}