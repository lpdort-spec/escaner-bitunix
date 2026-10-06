# /señal tomada [SIMBOLO] PRECIO [xAPALANCAMIENTO]  ·  /señal cerrada [SIMBOLO] [PRECIO]   (chat privado de Luis y grupo Alertas Mercados)
# Cuando el bot emite una señal (cripto o acciones/ETF) y la tomas, se lo dices con este comando: el bot valora tu entrada con los datos de ese momento (precio, SL y TP de la señal, relación R:B desde TU entrada,
# lectura del mercado) y a partir de ahí la vigila EN VIVO (cada ~40 s con el precio actual): te avisa si debes cerrar, subir el SL, cerrar parcial en TP1/TP2, o si la lectura se da la vuelta.
# No opera por ti: solo te asesora. Con símbolo se elige la señal; sin símbolo se usa la última enviada (hasta 36 h cripto, 72 h acciones).
# Registros: strat 'tomada' (no entran en estadísticas; el seguimiento por velas no los toca; los avisos los emite Watch-TakenOrders). dest = 'priv' (chat privado) o 'group' (Alertas Mercados).
$script:tomAt = [datetime]::MinValue

function ConvertTo-Num($s) {
    $x = ("$s" -replace '\s', '' -replace '[^0-9,\.\-]', ''); if (-not $x) { return $null }
    if ($x -match ',' -and $x -match '\.') { if ($x.LastIndexOf(',') -gt $x.LastIndexOf('.')) { $x = ($x -replace '\.', '') -replace ',', '.' } else { $x = $x -replace ',', '' } } elseif ($x -match ',') { $x = $x -replace ',', '.' }
    $d = 0.0; if ([double]::TryParse($x, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d } else { return $null }
}
function Get-LiveOrderPrice($s) {      # precio en vivo: Bitunix (cripto) o Yahoo (acciones/ETF)
    try {
        if ($s.src -eq 'yahoo') { $y = Get-YahooSeries $s.sym; if ($y) { return [double]$y.price } else { return 0.0 } }
        return [double]((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data | Where-Object symbol -eq $s.sym | Select-Object -First 1).lastPrice
    } catch { return 0.0 }
}
function Get-LiveScores($s, [double]$px) {
    try {
        $sym = $s.sym -replace 'USDT$', ''
        $ss = if ($s.src -eq 'yahoo') { Get-YahooSeries $s.sym } else { @{ src = 'bitunix'; sym = $sym; name = "$sym/USDT"; currency = 'USDT'; exch = ''; price = $px; extra = @{ funding = $null } } }
        if (-not $ss) { return $null }; return (Get-MomScores $ss)
    } catch { return $null }
}
function Send-TomadaMsg($s, $text) {
    if ($s.dest -eq 'group') { if ($script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $text $null } }
    else { Send-ToSignalChats $text }
}
function Close-TomadaRecord($s, [double]$exitPx, $outcome, [double]$rr) {
    $s.status = 'closed'; $s.exit = $exitPx; $s.outcome = $outcome; $s.R = [Math]::Round($rr, 2); $s.closedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $s.net = [Math]::Round($rr - 0.0015 / ([double]$s.slPct / 100), 2)
}

function Handle-SenalTomada($ra, $chat = $null, $who = "") {
    $uso = "Uso: /señal tomada [SIMBOLO] PRECIO [xAPALANCAMIENTO]  (ej.: /señal tomada API3 0,3817 x6)`n     /señal cerrada [SIMBOLO] [PRECIO]`nSin símbolo, se usa la última señal que se envió. Vale para cripto y para acciones/ETFs."
    $isPriv = (-not $script:PrivateChats) -or ($chat -in $script:PrivateChats); $dest = if ($isPriv) { 'priv' } else { 'group' }
    $words = @($ra | ForEach-Object { "$_" }); if (-not $words.Count) { return $uso }
    $kw = 'orden', 'orde', 'tomada', 'tomado', 'tomar', 'cogida', 'cogido', 'entrada', 'entre', 'entré', 'en', 'a', 'al', 'precio', 'valor', 'señal', 'senal', 'cerrada', 'cerrado', 'cierre', 'cerrar', 'de', 'la', 'el', 'mi', 'x'
    $closing = [bool](@($words | Where-Object { $_.ToLower() -in 'cerrada', 'cerrado', 'cierre', 'cerrar' }).Count)
    $sym = $null; $nums = @(); $lev = $null
    foreach ($w in $words) {
        $lw = $w.ToLower()
        if ($lw -in $kw) { continue }
        if ($lw -match '^x(\d+)$' -or $lw -match '^(\d+)x$') { $lev = [double]$Matches[1]; continue }
        if ($w -match '^[\d\.,]+$') { $n = ConvertTo-Num $w; if ($null -ne $n) { $nums += $n; continue } }
        if ($w -match '^[A-Za-z0-9\.\-\^=]{1,15}$') { $sym = ($w.ToUpper() -replace 'USDT$', '') }
    }
    $all = @(Read-Signals); $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($closing) {
        $open = @($all | Where-Object { $_.strat -eq 'tomada' -and $_.status -eq 'open' -and $_.dest -eq $dest -and ((-not $sym) -or $_.sym -eq "${sym}USDT" -or $_.sym -eq $sym) } | Sort-Object { [long]$_.time } -Descending)
        if (-not $open.Count) { return "No tengo ninguna operación tomada abierta" + $(if ($sym) { " de $sym" } else { "" }) + ".`n$uso" }
        $o = $open[0]; $sg = [int]$o.side; $s0 = $o.sym -replace 'USDT$', ''
        $px = if ($nums.Count) { $nums[0] } else { Get-LiveOrderPrice $o }
        if ($px -le 0) { return "No he podido leer el precio de $s0; indícalo: /señal cerrada $s0 PRECIO" }
        $mm = $sg * ($px - [double]$o.entry) / [double]$o.riskAbs; $rr = [double]$o.realized + $mm * $(switch ([int]$o.stage) { 0 { 1.0 } 1 { 2.0 / 3 } default { 1.0 / 3 } })
        $all2 = @(Read-Signals); foreach ($r in $all2) { if ($r.id -eq $o.id) { Close-TomadaRecord $r $px 'cierre manual' $rr } }; Save-Signals $all2
        return ("✅ Cerrada la operación tomada {0} {1}: entrada {2} → salida {3} · {4:+0.00;-0.00}R aprox. (incluye lo ya asegurado en parciales). Dejo de vigilarla." -f $s0, $(if ($sg -eq 1) { "LARGO" } else { "CORTO" }), (TaFp ([double]$o.entry)), (TaFp $px), $rr)
    }
    if (-not $nums.Count) { return "Dime el precio al que tomaste la orden.`n$uso" }
    $entry = $nums[0]
    $cand = @($all | Where-Object { $_.strat -in 'ruptura', 'ruptura-mercado', 'aviso-momento', 'seg-grupo', 'seg-priv' -and ((-not $sym) -or $_.sym -eq "${sym}USDT" -or $_.sym -eq $sym) -and ($now - [long]$_.time) -le $(if ($_.src -eq 'yahoo') { 259200 } else { 129600 }) -and $_.sl -and $_.tp1 } | Sort-Object { [long]$_.time } -Descending)
    if (-not $cand.Count) { return "No encuentro una señal reciente" + $(if ($sym) { " de $sym" } else { "" }) + " en mi registro (cripto 36 h, acciones 72 h).`nSi la operación es tuya y no salió de una señal mía, regístrala con /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO." }
    $sig = $cand[0]; $sg = [int]$sig.side; $s0 = $sig.sym -replace 'USDT$', ''; $dirTxt = if ($sg -eq 1) { "LARGO" } else { "CORTO" }; $isStock = ($sig.src -eq 'yahoo')
    $sl = [double]$sig.sl; $t1 = [double]$sig.tp1; $t2 = [double]$sig.tp2; $t3 = [double]$sig.tp3
    $px = Get-LiveOrderPrice $sig
    if ($px -gt 0 -and [Math]::Abs($entry / $px - 1) -gt 0.5 -and [Math]::Abs($entry * 1000 / $px - 1) -lt 0.5) { $entry = $entry * 1000 }       # "85.200" leído como 85,2
    if ($sg * ($entry - $sl) -le 0) { return "Con tu entrada ($(TaFp $entry)) el SL de la señal ($(TaFp $sl)) queda al otro lado del precio: revisa el valor o la señal elegida ($s0 $dirTxt)." }
    $R = [Math]::Abs($entry - $sl); $slPct = $R / $entry * 100
    if (-not $lev) { $lev = if ($sig.lev) { [double]$sig.lev } else { 1 } }
    $L = @(); $L += ("📌 ORDEN TOMADA registrada · {0} {1} · tu entrada {2} (la señal decía {3}{4})" -f $s0, $dirTxt, (TaFp $entry), (TaFp ([double]$sig.entry)), $(if ($sig.entryType -eq 'limit') { ", orden limit" } else { ", a mercado" }))
    $dif = $sg * ([double]$sig.entry - $entry) / [double]$sig.entry * 100
    $L += ("   Entraste {0:N2}% {1} que el precio de la señal." -f [Math]::Abs($dif), $(if ($dif -ge 0) { "mejor" } else { "peor" }))
    $L += ("   Plan: SL {0} (a {1:N2}% de tu entrada) · TP1 {2} · TP2 {3} · TP final {4}" -f (TaFp $sl), $slPct, (TaFp $t1), (TaFp $t2), (TaFp $t3))
    $rb1 = $sg * ($t1 - $entry) / $R; $rb3 = $sg * ($t3 - $entry) / $R
    $L += ("   Desde TU entrada: TP1 = {0:N1}R · TP final = {1:N1}R {2}" -f $rb1, $rb3, $(if ($rb3 -lt 1.5) { "⚠️ relación R:B pobre: valora tomar el TP1 como objetivo principal" } else { "✔" }))
    if ($px -gt 0) {
        $unr = $sg * ($px / $entry - 1) * 100; $L += ("   Ahora: {0} · latente {1:+0.00;-0.00}% del precio (≈ {2:+0.0;-0.0}% del margen con x{3:N0})" -f (TaFp $px), $unr, ($unr * $lev), $lev)
        if ($sg * ($px - $t1) -ge 0) { $L += "   ⚠️ El precio YA ha pasado el TP1 de la señal: desde aquí el recorrido que queda es corto; entrar tarde es perseguir el precio." }
        elseif ($sg * ($px - $sl) -le 0) { $L += "   ⛔ El precio YA está más allá del SL de la señal: la operación está invalidada." }
    }
    # lectura del activo en este momento
    $ctx = $null; $sc = Get-LiveScores $sig $px
    if ($sc) {
        $me = if ($sg -eq 1) { $sc.lg } else { $sc.st }; $opp = if ($sg -eq 1) { $sc.st } else { $sc.lg }; $ctx = [int]$me.score
        $L += ""; $L += ("🧭 Lectura ahora: puntuación {0} para tu dirección (contraria {1}) · {2}" -f $me.score, $opp.score, $(if ($me.score -le 0 -and $opp.score -ge 6) { "⛔ se ha dado la vuelta: no la abriría / valora cerrar" } elseif ($me.score -ge 6) { "✔ sigue vigente" } else { "⚠️ lectura floja" }))
        @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 3) | ForEach-Object { $L += "   $_" }
        @($me.fx | Where-Object { $_ -like '✅*' } | Select-Object -First 2) | ForEach-Object { $L += "   $_" }
    }
    if ($isPriv -and -not $isStock) {      # reglas personales de Luis (margen, SL <= 20% del margen, reentradas...)
        $mgEst = if ($sig.margin) { [double]$sig.margin } else { 200 }
        try { $L += ""; $L += (Get-RiskCheck $s0 $sg $entry $sl $t3 $mgEst $lev) } catch {}
    } else { $L += ("   Con x{0:N0}, tocar el SL costaría ≈ {1:N0}% del margen." -f $lev, ($slPct * $lev)) }
    $last = 0L; $dup = @($all | Where-Object { $_.strat -eq 'tomada' -and $_.sym -eq $sig.sym -and $_.status -eq 'open' -and $_.dest -eq $dest })
    if ($dup.Count) { $L += "`n(Ya tenías una operación tomada abierta de $s0; añado esta al seguimiento. Cierra la anterior con /señal cerrada $s0 si ya no existe.)" }
    Add-SignalRecord ([ordered]@{
        id = "tomada-$s0-$now"; time = $now; sym = $sig.sym; src = $sig.src; tf = $(if ($isStock) { '1d' } else { '4h' }); strat = 'tomada'; dest = $dest; by = "$who"; chat = "$chat"; side = $sg; entryType = 'market'
        entry = $entry; sl = $sl; sl0 = $sl; tp1 = $t1; tp2 = $t2; tp3 = $t3; riskAbs = $R; slPct = $slPct; lev = $lev; status = 'open'; stage = 0; realized = 0.0; age = 0; lastLabel = 0; lab0 = 0
        cost = $(if ($isStock) { 0.0010 } else { 0.0015 }); outcome = $null; R = $null; net = $null; ctxScore = $ctx; chkAt = $now; closeNote = ""; origen = $sig.id
        note = "Operación tomada tras la señal $($sig.id)"
    })
    $L += ""; $L += "👁️ Desde ahora la vigilo EN VIVO (cada ~40 s): te aviso al momento si debes CERRAR, SUBIR el SL o CERRAR PARCIAL (TP1/TP2), si me acerco al SL, o si la lectura se da la vuelta. Cuando la cierres, dímelo con /señal cerrada $s0 PRECIO. No opero por ti: decides tú."
    return ($L -join "`n")
}

# Alta directa de una operación abierta (desde /operacion o una captura): se vigila en vivo con parciales en tercios del recorrido hasta el TP indicado.
function Add-LiveOrder($sym, [int]$sg, [double]$en, [double]$sl, [double]$tp, [double]$mg, [double]$lv, [string]$origen, [string]$who) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $all2 = @(Read-Signals); $dirty = $false
    foreach ($r in $all2) { if ($r.strat -eq 'tomada' -and $r.status -eq 'open' -and $r.sym -eq "${sym}USDT" -and $r.dest -eq 'priv') { $r.status = 'closed'; $r.outcome = 'sustituida por un registro nuevo'; $r.closedAt = $now; $dirty = $true } }
    if ($dirty) { Save-Signals $all2 }
    $R = [Math]::Abs($en - $sl); if ($R -le 0) { return }
    Add-SignalRecord ([ordered]@{
        id = "tomada-$sym-$now"; time = $now; sym = "${sym}USDT"; src = $null; tf = '4h'; strat = 'tomada'; dest = 'priv'; by = "$who"; chat = ""; side = $sg; entryType = 'market'
        entry = $en; sl = $sl; sl0 = $sl; tp1 = ($en + $sg * [Math]::Abs($tp - $en) / 3); tp2 = ($en + $sg * 2 * [Math]::Abs($tp - $en) / 3); tp3 = $tp; riskAbs = $R; slPct = ($R / $en * 100); lev = $lv; margin = $mg; status = 'open'; stage = 0; realized = 0.0; age = 0; lastLabel = 0; lab0 = 0
        cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = $null; chkAt = $now; closeNote = ""; origen = $origen; note = "Operación registrada con /$origen"
    })
}
# Vigilancia en vivo de las órdenes tomadas (se llama desde el bucle principal cada ~40 s). Idempotente: cada evento se anota en closeNote.
function Watch-TakenOrders {
    if (-not $TelegramToken) { return }
    if (((Get-Date) - $script:tomAt).TotalSeconds -lt 40) { return }; $script:tomAt = Get-Date
    $sigs = @(Read-Signals); $open = @($sigs | Where-Object { $_.strat -eq 'tomada' -and $_.status -eq 'open' }); if (-not $open.Count) { return }
    $dirty = $false; $tk = $null; $nowS = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    foreach ($s in $open) {
        try {
            $sg = [int]$s.side; $sym = $s.sym -replace 'USDT$', ''; $dir = if ($sg -eq 1) { "LARGO" } else { "CORTO" }; $en = [double]$s.entry; $R = [double]$s.riskAbs; $tok = "$($s.closeNote)"
            if ($s.src -eq 'yahoo') { $px = Get-LiveOrderPrice $s } else { if (-not $tk) { $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data) }; $row = $tk | Where-Object symbol -eq $s.sym | Select-Object -First 1; $px = if ($row) { [double]$row.lastPrice } else { 0.0 } }
            if ($px -le 0) { continue }
            $who = if ($s.by) { " (de $($s.by))" } else { "" }; $head = "{0} {1}{2}" -f $sym, $dir, $who
            $pct = $sg * ($px / $en - 1) * 100; $stage = [int]$s.stage; $slEff = if ($stage -ge 1) { $en } else { [double]$s.sl }
            $msgs = @(); $closeOut = $null; $closeR = 0.0
            # 1) stop
            if ($sg * ($px - $slEff) -le 0) {
                if ($stage -eq 0) { $msgs += ("❌ STOP LOSS · {0}`nEl precio ({1}) ha tocado el SL ({2}). Si tu stop no se ha ejecutado ya, cierra: la operación está invalidada. Pérdida ≈ -1R (≈ {3:N0}% del margen con x{4:N0})." -f $head, (TaFp $px), (TaFp $slEff), ([double]$s.slPct * [double]$s.lev), [double]$s.lev); $closeOut = 'SL'; $closeR = -1.0 }
                else { $msgs += ("➖ CIERRE EN LA ENTRADA · {0}`nEl precio ({1}) ha vuelto a tu entrada ({2}) tras el parcial: cierra el resto; el beneficio ya asegurado en los parciales se mantiene." -f $head, (TaFp $px), (TaFp $en)); $closeOut = $(if ($stage -eq 1) { 'TP1 + BE' } else { 'TP2 + BE' }); $closeR = [double]$s.realized }
            } else {
                # 2) objetivos, en orden
                if ($stage -eq 0 -and $sg * ($px - [double]$s.tp1) -ge 0) { $stage = 1; $s.stage = 1; $s.realized = 1.0 / 3; $msgs += ("✅ TP1 ALCANZADO · {0} ({1})`nCierra un TERCIO (parcial) y MUEVE el SL a tu entrada ({2}): desde aquí no puede dar pérdida, salvo comisiones." -f $head, (TaFp $s.tp1), (TaFp $en)) }
                if ($stage -eq 1 -and $sg * ($px - [double]$s.tp2) -ge 0) { $stage = 2; $s.stage = 2; $s.realized = 1.0 / 3 + (2.0 / 3); $msgs += ("✅ TP2 ALCANZADO · {0} ({1})`nCierra otro tercio y SUBE el SL a la zona del TP1 ({2}) para asegurar beneficio. Queda el último tercio hacia el TP final ({3})." -f $head, (TaFp $s.tp2), (TaFp $s.tp1), (TaFp $s.tp3)) }
                if ($stage -eq 2 -and $sg * ($px - [double]$s.tp3) -ge 0) { $msgs += ("🏆 TP FINAL ALCANZADO · {0} ({1})`nCierra el último tercio. Operación completada." -f $head, (TaFp $s.tp3)); $closeOut = 'TP3'; $closeR = [double]$s.realized + 3.0 / 3 }
                if (-not $closeOut) {
                    # 3) cerca del SL (una vez)
                    $dSl = $sg * ($px - $slEff) / $R
                    if ($stage -eq 0 -and $dSl -lt 0.3 -and $tok -notlike '*N*') { $tok += "N"; $msgs += ("⚠️ CERCA DEL STOP · {0}`nEl precio ({1}) está a solo {2:N2}R de tu SL ({3}). Si el motivo de entrada ya no se cumple, valora cerrar antes y limitar la pérdida." -f $head, (TaFp $px), $dSl, (TaFp $slEff)) }
                    # 4) relectura del activo cada 30 min
                    if (($nowS - [long]$s.chkAt) -ge 1800) {
                        $s.chkAt = $nowS; $sc = Get-LiveScores $s $px
                        if ($sc) {
                            $me = if ($sg -eq 1) { $sc.lg } else { $sc.st }; $opp = if ($sg -eq 1) { $sc.st } else { $sc.lg }; $neg = @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 3)
                            if ($me.score -le 0 -and $opp.score -ge 6 -and $tok -notlike '*C*') { $tok += "C"; $msgs += ("⛔ VALORA CERRAR · {0}`nLa lectura del activo se ha dado la vuelta: para tu dirección puntúa {1} y para la contraria {2}. Precio {3} ({4:+0.0;-0.0}% sobre tu entrada), SL {5}.`n{6}`nEl bot no cierra nada: decides tú." -f $head, $me.score, $opp.score, (TaFp $px), $pct, (TaFp $slEff), (($neg | ForEach-Object { "   $_" }) -join "`n")) }
                            elseif ($null -ne $s.ctxScore -and ([int]$s.ctxScore - [int]$me.score) -ge 4 -and $pct -gt 0 -and $tok -notlike '*D*') { $tok += "D"; $msgs += ("🔔 SE DEBILITA · {0}`nLa puntuación ha bajado de {1} a {2} y vas en beneficio ({3:+0.0;-0.0}%): valora tomar un parcial y subir el SL a {4}.`n{5}" -f $head, $s.ctxScore, $me.score, $pct, (TaFp $(if ($stage -ge 1) { $en } else { $en + $sg * 0.1 * $R })), (($neg | ForEach-Object { "   $_" }) -join "`n")) }
                        }
                    }
                }
            }
            if ($closeOut) { Close-TomadaRecord $s $px $closeOut $closeR; $msgs += ("   Resultado aproximado: {0:+0.00;-0.00}R · registrada como cerrada; dejo de vigilarla." -f $closeR) }
            $s.closeNote = $tok; $dirty = $true
            foreach ($m in $msgs) { Send-TomadaMsg $s $m }
        } catch {}
        Start-Sleep -Milliseconds 120
    }
    if ($dirty) { $cur = @(Read-Signals); foreach ($c in $cur) { $m = $open | Where-Object { $_.id -eq $c.id } | Select-Object -First 1; if ($m) { foreach ($p in 'stage', 'realized', 'status', 'exit', 'outcome', 'R', 'net', 'closedAt', 'closeNote', 'chkAt') { $c.$p = $m.$p } } }; Save-Signals $cur }
}
