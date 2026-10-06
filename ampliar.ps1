# /ampliar PAR [MARGEN_TOTAL=200] [PRECIO]  (solo chat privado de Luis): ¿puedo aumentar la posición abierta hasta X USDT de margen y bajar el precio medio de entrada?
# Calcula con tu posición registrada (/operacion, captura o /señal tomada) el precio medio nuevo, el SL y la pérdida resultante sobre el margen TOTAL, la liquidación y el beneficio con el TP,
# para el precio actual y dos órdenes limit más bajas (largos) / más altas (cortos); y da un veredicto con reglas fijas: lectura del activo + timing 1h + tu límite del 35% del margen. Siempre AISLADO.
function Get-OpenPosition($sym) {
    $sigs = @(Read-Signals | Where-Object { $_.status -eq 'open' -and $_.sym -eq "${sym}USDT" -and ($_.strat -eq 'tomada' -or $_.manual -eq $true) } | Sort-Object { [long]$_.time } -Descending)
    if (-not $sigs.Count) { return $null }
    $s = $sigs[0]; $mg = if ($s.margin) { [double]$s.margin } else { $null }; $lv = if ($s.lev) { [double]$s.lev } else { $null }
    return @{ sg = [int]$s.side; entry = [double]$s.entry; sl = [double]$s.sl0; tp = $(if ($s.tp3) { [double]$s.tp3 } else { [double]$s.tp1 }); margin = $mg; lev = $lv; src = $s.strat; id = $s.id; slCur = [double]$s.sl }
}
function Get-AmpliarScenario($pos, [double]$addMargin, [double]$p) {
    $q0 = $pos.margin * $pos.lev / $pos.entry; $q1 = $addMargin * $pos.lev / $p; $q = $q0 + $q1; $avg = ($q0 * $pos.entry + $q1 * $p) / $q; $M = $pos.margin + $addMargin; $sg = $pos.sg
    $lossSl = $q * $sg * ($avg - $pos.sl) * 1.0; $lossSl = [Math]::Max($lossSl, 0); $gainTp = $q * $sg * ($pos.tp - $avg); $liqPct = 100.0 / $pos.lev - 1.4; $liq = $avg * (1 - $sg * $liqPct / 100)
    return @{ price = $p; avg = $avg; qty = $q; margin = $M; lossSl = $lossSl; lossPct = ($lossSl / $M * 100); gainTp = $gainTp; liq = $liq; rr = $(if ($lossSl -gt 0) { $gainTp / $lossSl } else { 0 }) }
}
function Get-AmpliarReport($sym, [double]$target, [double]$limitPx) {
    $pos = Get-OpenPosition $sym
    if (-not $pos -or -not $pos.margin -or -not $pos.lev) { return "No tengo registrada una posición abierta de $sym con margen y apalancamiento.`nRegístrala primero con /operacion $sym LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO (o envíame la captura de la posición) y vuelve a preguntar." }
    $sg = $pos.sg; $dir = if ($sg -eq 1) { "LARGO" } else { "CORTO" }; $add = $target - $pos.margin
    if ($add -le 1) { return ("Tu margen en {0} ya es {1:N0} USDT (objetivo {2:N0}): no hay margen que añadir." -f $sym, $pos.margin, $target) }
    $px = [double]((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data | Where-Object symbol -eq "${sym}USDT" | Select-Object -First 1).lastPrice
    $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=1h&limit=60" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $closed = @($k[0..($k.Count - 2)])
    $tr = @(); for ($i = $closed.Count - 14; $i -lt $closed.Count; $i++) { $h = [double]$closed[$i].high; $l = [double]$closed[$i].low; $pc = [double]$closed[$i - 1].close; $tr += [Math]::Max($h - $l, [Math]::Max([Math]::Abs($h - $pc), [Math]::Abs($l - $pc))) }; $atr = ($tr | Measure-Object -Average).Average
    $last12 = @($closed | Select-Object -Last 12); $swing = if ($sg -eq 1) { ($last12 | ForEach-Object { [double]$_.low } | Measure-Object -Minimum).Minimum } else { ($last12 | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum }
    $pnlPct = $sg * ($px / $pos.entry - 1) * 100
    $c1 = $px; $c2 = $px - $sg * 0.5 * $atr; $c3 = if ($sg * ($px - $swing) -gt 0.3 * $atr) { $swing } else { $px - $sg * 1.0 * $atr }
    $cands = @(@("a mercado (ahora)", $c1), @("limit a 0,5 ATR de 1h ($(TaFp $c2))", $c2), @("limit en el último soporte/resistencia 1h ($(TaFp $c3))", $c3)); if ($limitPx -gt 0) { $cands = @(@("tu precio ($(TaFp $limitPx))", $limitPx)) + $cands }
    $L = @(); $L += ("🧮 AMPLIAR {0} {1} x{2:N0} · tienes {3:N0} USDT de margen, entrada {4}, SL {5}, TP {6} · precio ahora {7} ({8:+0.0;-0.0}% sobre tu entrada)" -f $sym, $dir, $pos.lev, $pos.margin, (TaFp $pos.entry), (TaFp $pos.sl), (TaFp $pos.tp), (TaFp $px), $pnlPct)
    $L += ("   Añadir {0:N0} USDT de margen para llegar a {1:N0} (misma palanca y mismo SL)" -f $add, $target); $L += ""
    $base = Get-AmpliarScenario $pos 0.0001 $px; $L += ("   Hoy: pierdes ≈ {0:N0} USDT ({1:N0}% del margen) si salta el SL y ganas ≈ {2:N0} USDT con el TP" -f $base.lossSl, ($base.lossSl / $pos.margin * 100), $base.gainTp); $L += ""
    $ok35 = @()
    foreach ($c in $cands) { $sc = Get-AmpliarScenario $pos $add ([double]$c[1]); $ok = $sc.lossPct -le 35
        $L += ("• {0}: precio medio nuevo {1} (antes {2}) · si salta el SL pierdes ≈ {3:N0} USDT ({4:N0}% del margen total){5} · con el TP ganas ≈ {6:N0} USDT (R:B {7:N1}) · liquidación ≈ {8}" -f $c[0], (TaFp $sc.avg), (TaFp $pos.entry), $sc.lossSl, $sc.lossPct, $(if ($ok) { " ✔" } else { " ⚠️ pasa de tu 35%" }), $sc.gainTp, $sc.rr, (TaFp $sc.liq)); if ($ok) { $ok35 += $c } }
    # lectura del activo + timing
    $own = $null; $opp = $null; $neg = @(); $tmg = 0
    try { $s = @{ src = 'bitunix'; sym = $sym; name = "$sym/USDT"; currency = 'USDT'; exch = ''; price = $px; extra = @{ funding = $null } }; $r = Get-MomScores $s
        if ($r) { $me = if ($sg -eq 1) { $r.lg } else { $r.st }; $op = if ($sg -eq 1) { $r.st } else { $r.lg }; $own = [int]$me.score; $opp = [int]$op.score; $tmg = if ($null -ne $me.timing) { [int]$me.timing } else { 0 }; $neg = @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 3) } } catch {}
    $L += ""; if ($null -ne $own) { $L += ("🧭 Lectura actual para tu dirección: puntuación {0} (contraria {1}){2}" -f $own, $opp, $(if ($tmg -ne 0) { "; timing 1h {0:+0;-0}" -f $tmg } else { "" })); $neg | ForEach-Object { $L += "   $_" } }
    # veredicto con reglas fijas
    $verd = ""; $why = @()
    if ($sg * ($px - $pos.entry) -lt 0) {      # promediando a la baja (largo) / al alza (corto)
        if ($null -eq $own -or $own -lt 7 -or $tmg -le -3) { $verd = "⛔ NO AÑADIRÍA"; $why += "estarías promediando una posición que va en contra con una lectura que no es claramente favorable (puntuación $own); es el patrón que más te ha costado (MOVR, API3)" }
        elseif (-not $ok35.Count) { $verd = "⛔ NO AÑADIRÍA"; $why += "con el mismo SL el riesgo total superaría tu 35% del margen" }
        else { $verd = "🟡 SOLO CON LIMIT, NO A MERCADO"; $why += "la lectura sigue a favor (puntuación $own), pero solo añade con una orden limit más baja de las de arriba que cumplen tu 35%, sin mover el SL y sin volver a añadir después" }
    } else {
        if ($null -ne $own -and $own -ge 6 -and $tmg -gt -3 -and $ok35.Count) { $verd = "✅ SE PUEDE AÑADIR (en beneficio)"; $why += "la lectura sigue a favor; sube el SL a la entrada tras añadir para que el conjunto no pueda perder más de lo previsto" }
        else { $verd = "🟡 MEJOR ESPERAR"; $why += "en beneficio añadir tiene sentido solo con lectura clara a favor y sin estiramiento (ahora: puntuación $own, timing $tmg)" }
    }
    $L += ""; $L += ("{0} · {1}" -f $verd, ($why -join "; ")); $L += "🔒 Mantén AISLADO. Si añades, el SL no se mueve en contra y el margen total no debe pasar de $($target.ToString('N0')) USDT. Promediar baja el precio medio pero sube el riesgo en la misma proporción."
    return ($L -join "`n")
}
function Handle-Ampliar($ra) {
    $sym = $null; $nums = @()
    foreach ($w in @($ra | ForEach-Object { "$_" })) { $lw = $w.ToLower(); if ($lw -in 'hasta', 'usdt', 'margen', 'a', 'de', 'la', 'el', 'posicion', 'posición', 'en', 'con', 'puedo', 'precio') { continue }
        if ($w -match '^[0-9][0-9.,]*$') { $n = ConvertTo-Num $w; if ($null -ne $n) { $nums += $n }; continue }
        if (-not $sym -and $w -match '^[A-Za-z0-9]{2,12}$') { $sym = ($w.ToUpper() -replace 'USDT$', '') } }
    if (-not $sym) { return "Uso: /ampliar PAR [MARGEN_TOTAL] [PRECIO_LIMIT]`nEjemplos: /ampliar FET (hasta 200 USDT de margen) · /ampliar FET 200 0,2420`nTe calculo el precio medio nuevo, el riesgo total y si te conviene añadir." }
    $target = 200.0; $limit = 0.0; $live = 0.0; try { $live = [double]((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data | Where-Object symbol -eq "${sym}USDT" | Select-Object -First 1).lastPrice } catch {}
    if ($live -le 0) { return "No encuentro ${sym}USDT en Bitunix. Escribe el símbolo exacto (FET, API3, SOL...)." }
    foreach ($n in $nums) { if ([Math]::Abs($n / $live - 1) -le 0.25) { $limit = $n } else { $target = $n } }      # un número cerca del precio actual es el precio limit; el otro, el margen total
    return (Get-AmpliarReport $sym $target $limit)
}
# Traductor sencillo de frases libres del chat privado a los comandos del bot (el bot NO es una IA: solo reconoce estas intenciones por palabras clave)
function Handle-FreeText($text) {
    $t = "$text".Trim(); if (-not $t -or $t.StartsWith('/')) { return $null }; $lt = $t.ToLower()
    $stop = 'puedo', 'hasta', 'usdt', 'margen', 'como', 'cómo', 'ves', 'que', 'qué', 'la', 'el', 'una', 'un', 'de', 'en', 'con', 'mi', 'mis', 'esta', 'esto', 'abrir', 'abro', 'entrar', 'entro', 'largo', 'corto', 'long', 'short', 'posicion', 'posición', 'operacion', 'operación', 'ampliar', 'aumentar', 'subir', 'añadir', 'anadir', 'precio', 'entrada', 'bajar', 'consulta', 'consultar', 'hola', 'por', 'favor', 'quiero', 'me', 'si', 'y', 'o', 'a', 'al', 'para', 'seria', 'sería', 'bien', 'cripto', 'moneda'
    $tick = $null; try { $tick = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data | ForEach-Object { $_.symbol -replace 'USDT$', '' }) } catch {}
    $sym = $null; foreach ($w in ($t -split '[\s,;:¿?¡!]+')) { $u = $w.ToUpper(); if ($w -match '^[A-Za-z0-9]{2,12}$' -and $w.ToLower() -notin $stop -and $tick -and $u -in $tick) { $sym = $u; break } }
    $nums = @([regex]::Matches($t, '\d+(?:[.,]\d+)?') | ForEach-Object { $_.Value })
    $side = if ($lt -match '\b(corto|short)\b') { 'corto' } elseif ($lt -match '\b(largo|long)\b') { 'largo' } else { '' }
    if ($sym -and $lt -match 'ampli|aument|añad|anad|promedi|bajar.*(precio|entrada)|subir.*(posici|margen)|hasta.*\d+') { return (Handle-Ampliar (@($sym) + $nums)) }
    if ($sym -and $lt -match 'c[oó]mo (la )?ves|consult|abrir|abro|entrar|entro|momento|qu[eé] opinas|merece|compro|vendo|largo|corto|long|short') { return (Get-ConsultaReport $sym $side) }
    if ($sym) { return (Get-ConsultaReport $sym $side) }
    return "No te he entendido: yo soy un bot de reglas fijas, no una IA que conversa. Puedes escribirme cosas como:`n• «cómo ves SOL» o «puedo abrir un largo en API3» → análisis y plan (/consulta)`n• «puedo ampliar FET hasta 200» → precio medio y riesgo al añadir (/ampliar)`n• o usar /operacion, /señal, /cerrar, /resultados, /ayuda"
}
