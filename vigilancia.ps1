# Seguimiento especial semanal de IREN (domingos) y vigilancia de cambios importantes -> SOLO al grupo "Alertas Mercados" (nunca al chat privado de resultados).
# Regla: solo cifras calculadas con datos reales; lo que no se puede calcular, se dice. Las alertas son avisos de cambio de condiciones, NO recomendaciones de compra o venta.

function Get-WatchList {                       # lista de activos vigilados: chats.json -> "vigilar"; por defecto IREN y los dos grandes referentes de cripto
    $l = @('IREN', 'BTC', 'ETH')
    try { $c = Get-Content (Join-Path $PSScriptRoot "chats.json") -Raw -Encoding UTF8 | ConvertFrom-Json; if ($c.vigilar) { $l = @($c.vigilar | ForEach-Object { "$_".ToUpper() }) } } catch {}
    return $l
}
function Get-WatchYahooSymbol($s) { if ($s -in 'BTC', 'ETH', 'SOL', 'XRP', 'BNB', 'DOGE', 'ADA', 'AVAX', 'LINK') { return "$s-USD" } else { return $s } }

function Get-VigiaState { $j = Get-ReportState "vigia"; if (-not $j) { return @{} }; try { $o = $j | ConvertFrom-Json; $h = @{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = $p.Value }; return $h } catch { return @{} } }
function Set-VigiaState($h) { Set-ReportState "vigia" (($h | ConvertTo-Json -Compress -Depth 4)) }

function Get-TvDailyLabel($sym) {              # lectura agregada diaria de TradingView (o $null)
    try {
        $isC = $sym -in 'BTC', 'ETH', 'SOL', 'XRP', 'BNB', 'DOGE', 'ADA', 'AVAX', 'LINK'
        $t = if ($isC) { Resolve-TvTarget 'bitunix' $sym '' } else { Resolve-TvTarget 'yahoo' $sym '' }
        if (-not $t.rating) { return $null }
        $d = $t.rating | Where-Object { $_.tf -eq '1d' } | Select-Object -First 1
        if ($d -and $null -ne $d.all) { return (Get-TvLabel $d.all) }
    } catch {}
    return $null
}

# Devuelve la lista de cambios importantes de UN activo en su última vela diaria cerrada (y actualiza su estado)
function Get-WatchEvents($sym, $st) {
    $b = Get-MktBars (Get-WatchYahooSymbol $sym); if (-not $b) { return @{ ev = @(); st = $st; err = "sin datos" } }
    $n = $b.n; $c = $b.c; $d = ([DateTimeOffset]::FromUnixTimeMilliseconds($b.t[$n - 1])).UtcDateTime.ToString("yyyy-MM-dd")
    $prev = $st; if ($null -eq $prev) { $prev = @{} }
    $ev = @(); $first = -not $prev.ContainsKey('bar')
    $e21 = @(); $e50 = @(); $k21 = 2.0 / 22; $k50 = 2.0 / 51; $a = $c[0]; $bb = $c[0]
    for ($i = 0; $i -lt $n; $i++) { $a = $c[$i] * $k21 + $a * (1 - $k21); $bb = $c[$i] * $k50 + $bb * (1 - $k50); $e21 += $a; $e50 += $bb }
    $px = $c[$n - 1]; $pp = $c[$n - 2]
    $rsi = Mkt-Rsi $c; $r = $rsi[$n - 1]; $rp = $rsi[$n - 2]
    $avgV = (($b.v[($n - 21)..($n - 2)]) | Measure-Object -Average).Average
    $vr = if ($avgV -gt 0) { $b.v[$n - 1] / $avgV } else { 0 }
    $atr = 0.0; for ($i = $n - 14; $i -lt $n; $i++) { $atr += [Math]::Max($b.h[$i] - $b.l[$i], [Math]::Max([Math]::Abs($b.h[$i] - $c[$i - 1]), [Math]::Abs($b.l[$i] - $c[$i - 1]))) }; $atr /= 14
    $ret = ($px / $pp - 1) * 100
    $hi20 = ($b.h[($n - 21)..($n - 2)] | Measure-Object -Maximum).Maximum; $lo20 = ($b.l[($n - 21)..($n - 2)] | Measure-Object -Minimum).Minimum
    $w = [Math]::Min($n - 1, 251); $hi52 = ($b.h[($n - 1 - $w)..($n - 2)] | Measure-Object -Maximum).Maximum; $lo52 = ($b.l[($n - 1 - $w)..($n - 2)] | Measure-Object -Minimum).Minimum
    $newBar = ($prev['bar'] -ne $d)
    if ($newBar -and -not $first) {
        if ($vr -ge 2.5) { $ev += ("📊 VOLUMEN: x{0:N1} la media de 20 sesiones en la última sesión cerrada (movimiento del precio {1:+0.0;-0.0}%)." -f $vr, $ret) }
        if ($b.h[$n - 1] -gt $hi52) { $ev += ("🏔️ NUEVO MÁXIMO DE 52 SEMANAS (máximo {0:N2}, cierre {1:N2})." -f $b.h[$n - 1], $px) }
        elseif ($px -gt $hi20 -and $pp -le $hi20) { $ev += ("🔼 ESTRUCTURA: cierre por encima del máximo de las 20 sesiones previas ({0:N2}): ruptura alcista del rango." -f $hi20) }
        if ($b.l[$n - 1] -lt $lo52) { $ev += ("🕳️ NUEVO MÍNIMO DE 52 SEMANAS (mínimo {0:N2}, cierre {1:N2})." -f $b.l[$n - 1], $px) }
        elseif ($px -lt $lo20 -and $pp -ge $lo20) { $ev += ("🔽 ESTRUCTURA: cierre por debajo del mínimo de las 20 sesiones previas ({0:N2}): ruptura bajista del rango." -f $lo20) }
        if ($pp -le $e21[$n - 2] -and $px -gt $e21[$n - 1]) { $ev += "📈 TENDENCIA: el precio recupera la EMA21 diaria (cierre por encima)." }
        if ($pp -ge $e21[$n - 2] -and $px -lt $e21[$n - 1]) { $ev += "📉 TENDENCIA: el precio pierde la EMA21 diaria (cierre por debajo)." }
        if ($pp -le $e50[$n - 2] -and $px -gt $e50[$n - 1]) { $ev += "📈 TENDENCIA: el precio recupera la EMA50 diaria (cierre por encima)." }
        if ($pp -ge $e50[$n - 2] -and $px -lt $e50[$n - 1]) { $ev += "📉 TENDENCIA: el precio pierde la EMA50 diaria (cierre por debajo)." }
        if ($rp -lt 70 -and $r -ge 70) { $ev += ("🌡️ RSI(14) diario entra en sobrecompra ({0:N0})." -f $r) }
        if ($rp -ge 30 -and $r -le 30) { $ev += ("🌡️ RSI(14) diario entra en sobreventa ({0:N0})." -f $r) }
        if ($atr -gt 0 -and [Math]::Abs($px - $pp) -ge 2.5 * $atr) { $ev += ("⚡ MOVIMIENTO BRUSCO: {0:+0.0;-0.0}% en una sesión (≈ {1:N1} veces el rango medio diario)." -f $ret, ([Math]::Abs($px - $pp) / $atr)) }
    }
    # cambio de lectura agregada diaria de TradingView (se compara con la última guardada)
    $tv = Get-TvDailyLabel $sym; $tvOld = $prev['tv']
    if ($tv -and $tvOld -and $tv -ne $tvOld -and $newBar) { $ev += "📺 TRADINGVIEW (diario): la lectura técnica agregada cambia de «$tvOld» a «$tv»." }
    $new = @{ bar = $d; tv = $(if ($tv) { $tv } else { $tvOld }); px = [Math]::Round($px, 4) }
    return @{ ev = $ev; st = $new; px = $px; ret = $ret; vr = $vr; rsi = $r }
}

function Send-WatchAlertsIfDue {               # una vez al día a partir de las 22:45 (hora de España), tras el cierre de EE. UU. y el escaneo de mercado
    $now = Get-MadridNow; $today = $now.ToString("yyyy-MM-dd")
    if ($now.Hour -lt 22 -or ($now.Hour -eq 22 -and $now.Minute -lt 45)) { return }
    if ((Get-ReportState "vigiahoy") -eq $today) { return }
    Set-ReportState "vigiahoy" $today
    $all = Get-VigiaState; $out = @()
    foreach ($s in (Get-WatchList)) {
        try {
            $old = $null; if ($all.ContainsKey($s)) { $o = $all[$s]; $old = @{}; foreach ($p in $o.PSObject.Properties) { $old[$p.Name] = $p.Value } }
            $r = Get-WatchEvents $s $old
            if ($r.st) { $all[$s] = $r.st }
            if ($r.ev.Count) { $out += ("🔔 {0} · {1:N2} ({2:+0.0;-0.0}% en la sesión)`n" -f $s, $r.px, $r.ret) + (($r.ev | ForEach-Object { "   $_" }) -join "`n") }
        } catch {}
    }
    Set-VigiaState $all
    if ($out.Count -and $script:MktChat -and $TelegramToken) {
        $msg = "🔔 ALERTA DE CAMBIOS · vigilancia diaria (velas diarias cerradas)`n`n" + ($out -join "`n`n") + "`n`nSon avisos de que han cambiado las condiciones del activo, no recomendaciones de compra o venta. Para el análisis completo: /informe SIMBOLO o /momento SIMBOLO."
        Send-Tg $TelegramToken $script:MktChat $msg $null
    }
}

# ---------- Seguimiento semanal completo de IREN ----------
function Build-IrenWeekly([switch]$Test, [switch]$NoSave) {
    $sym = 'IREN'; $L = @()
    if ($Test) { $L += "🧪 PRUEBA · Este es un ENVÍO DE PRUEBA del seguimiento semanal de IREN que se publicará cada domingo. Los datos son reales; el formato puede ajustarse."; $L += "" }
    $L += "📌 SEGUIMIENTO SEMANAL ESPECIAL · IREN (cada domingo)"
    $b = Get-MktBars $sym
    $snap = $null
    if ($b) {
        $n = $b.n; $c = $b.c; $px = $c[$n - 1]; $d = ([DateTimeOffset]::FromUnixTimeMilliseconds($b.t[$n - 1])).UtcDateTime.ToString("yyyy-MM-dd")
        $wk = $c[[Math]::Max(0, $n - 6)]; $wkRet = ($px / $wk - 1) * 100
        $hiW = ($b.h[($n - 5)..($n - 1)] | Measure-Object -Maximum).Maximum; $loW = ($b.l[($n - 5)..($n - 1)] | Measure-Object -Minimum).Minimum
        $vW = (($b.v[($n - 5)..($n - 1)]) | Measure-Object -Average).Average; $vP = (($b.v[($n - 25)..($n - 6)]) | Measure-Object -Average).Average
        $rsi = (Mkt-Rsi $c)[$n - 1]
        $L += ""
        $L += "🗓️ RESUMEN DE LA SEMANA (5 sesiones hasta $d)"
        $L += ("Cierre {0:N2} USD · variación semanal {1:+0.0;-0.0}% · rango semanal {2:N2} - {3:N2}" -f $px, $wkRet, $loW, $hiW)
        if ($vP -gt 0) { $L += ("Volumen medio de la semana: x{0:N1} respecto a las 4 semanas anteriores" -f ($vW / $vP)) }
        $tvl = Get-TvDailyLabel $sym
        $snap = @{ date = $d; px = [Math]::Round($px, 4); rsi = [Math]::Round($rsi, 1); tv = $tvl }
        $old = $null; try { $j = Get-ReportState "irensnap"; if ($j) { $old = $j | ConvertFrom-Json } } catch {}
        if ($old) {
            $L += ""
            $L += "↔️ QUÉ HA CAMBIADO DESDE EL DOMINGO ANTERIOR ($($old.date))"
            $L += ("Precio: {0:N2} → {1:N2} ({2:+0.0;-0.0}%) · RSI diario: {3:N0} → {4:N0}" -f [double]$old.px, $px, (($px / [double]$old.px - 1) * 100), [double]$old.rsi, $rsi)
            if ($old.tv -and $tvl) { $L += "Lectura TradingView (diario): " + $(if ($old.tv -eq $tvl) { "sin cambios ($tvl)" } else { "«$($old.tv)» → «$tvl»" }) }
        } else { $L += ""; $L += "↔️ Primera edición del seguimiento: a partir del próximo domingo se mostrará qué ha cambiado respecto a esta semana." }
    } else { $L += "(No he podido leer las velas diarias de IREN para el resumen semanal; no invento cifras.)" }
    $L += ""
    $L += "══════ INFORME COMPLETO ══════"
    $L += (Resolve-Report 'IREN' 'accion')
    $L += ""
    $L += "══════ ¿BUEN MOMENTO? (/momento) ══════"
    try { $L += (Get-MomentoReport 'IREN' 'accion' '') } catch { $L += "(El análisis de momento no se ha podido generar ahora.)" }
    if (-not $NoSave -and $snap) { try { Set-ReportState "irensnap" (($snap | ConvertTo-Json -Compress)) } catch {} }
    return ($L -join "`n")
}
function Send-IrenWeeklyIfDue {                // domingos a partir de las 18:00 (hora de España), una vez por semana
    $now = Get-MadridNow
    if ($now.DayOfWeek -ne [DayOfWeek]::Sunday -or $now.Hour -lt 18) { return }
    $week = $now.ToString("yyyy-MM-dd"); if ((Get-ReportState "iren") -eq $week) { return }
    Set-ReportState "iren" $week
    $rep = Build-IrenWeekly
    if ($script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $rep $null }
}
