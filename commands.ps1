# Comandos del bot de Telegram: informes técnicos bajo demanda de cualquier cripto o acción.
# Regla de oro: solo cifras calculadas a partir de datos de mercado reales y citando la fuente. Lo que no se puede obtener, se dice.
# Fuentes: Bitunix (futuros cripto, API pública), Yahoo Finance (cotizaciones de bolsa), CoinGecko (otras criptos).
$script:CmdBase = "https://fapi.bitunix.com/api/v1/futures/market"
$script:LastCmd = @{}
$script:UA = @{ 'User-Agent' = 'Mozilla/5.0 (compatible; AlertasBitunix/1.0)' }

function Fnum($x) {
    if ($null -eq $x) { return "n/d" }
    $a = [Math]::Abs($x)
    if ($a -ge 1000) { return ("{0:N0}" -f $x) } elseif ($a -ge 1) { return ("{0:N2}" -f $x) } elseif ($a -ge 0.01) { return ("{0:N4}" -f $x) } else { return $x.ToString("0.00000000").TrimEnd('0') }
}
function Fpct($x) { if ($null -eq $x) { return "n/d" } else { return ("{0:+0.0;-0.0;0.0}%" -f $x) } }
function Ema-Of($v, $n) { $k = 2.0 / ($n + 1); $e = $v[0]; for ($i = 1; $i -lt $v.Count; $i++) { $e = $v[$i] * $k + $e * (1 - $k) }; return $e }
function Rsi-Of($c, $n = 14) {
    if ($c.Count -le $n + 1) { return $null }
    $g = 0.0; $l = 0.0
    for ($i = 1; $i -le $n; $i++) { $d = $c[$i] - $c[$i-1]; if ($d -gt 0) { $g += $d } else { $l -= $d } }
    $g /= $n; $l /= $n
    for ($i = $n + 1; $i -lt $c.Count; $i++) { $d = $c[$i] - $c[$i-1]; $g = ($g * ($n - 1) + [Math]::Max($d, 0)) / $n; $l = ($l * ($n - 1) + [Math]::Max(-$d, 0)) / $n }
    if ($l -eq 0) { return 100 }; return 100 - 100 / (1 + $g / $l)
}

# ---------- Fuentes de datos ----------
function Get-BitunixSeries($sym) {
    $tk = (Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq "${sym}USDT"
    if (-not $tk) { return $null }
    $all = @{}; $end = $null
    for ($p = 0; $p -lt 3; $p++) {
        $u = "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=1d&limit=200"; if ($end) { $u += "&endTime=$end" }
        $d = (Invoke-RestMethod $u).data; if (-not $d) { break }
        $mn = [long]::MaxValue; foreach ($c in $d) { $all[[string]$c.time] = $c; if ([long]$c.time -lt $mn) { $mn = [long]$c.time } }; $end = $mn - 1
    }
    $s = @($all.Values | Sort-Object { [long]$_.time }); $s = @($s[0..($s.Count - 2)])        # sin la vela en curso
    if ($s.Count -lt 30) { return $null }
    $fund = ((Invoke-RestMethod "$($script:CmdBase)/funding_rate/batch").data | Where-Object symbol -eq "${sym}USDT").fundingRate
    $bk = (Invoke-RestMethod "$($script:CmdBase)/depth?symbol=${sym}USDT&limit=50").data
    $bv = ($bk.bids | ForEach-Object { [double]$_[0] * [double]$_[1] } | Measure-Object -Sum).Sum; $av = ($bk.asks | ForEach-Object { [double]$_[0] * [double]$_[1] } | Measure-Object -Sum).Sum
    return @{
        kind = "futuro perpetuo de Bitunix (cripto o activo tokenizado)"; name = "${sym}/USDT"; source = "Bitunix (API pública de futuros)"; currency = "USDT"
        price = [double]$tk.lastPrice; priceNote = "precio en vivo"
        c = @($s | ForEach-Object { [double]$_.close }); h = @($s | ForEach-Object { [double]$_.high }); l = @($s | ForEach-Object { [double]$_.low }); v = @($s | ForEach-Object { [double]$_.quoteVol })
        lastDate = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s[-1].time).UtcDateTime.AddDays(1).ToString("yyyy-MM-dd")
        extra = @{ vol24 = [double]$tk.quoteVol; funding = [double]$fund; bookBuy = if (($av + $bv) -gt 0) { 100 * $bv / ($av + $bv) } else { $null } }
    }
}
function Get-YahooSeries($tkr) {
    try { $r = Invoke-RestMethod -Uri ("https://query1.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($tkr) + "?range=2y&interval=1d") -Headers $script:UA -TimeoutSec 25 } catch { return $null }
    $res = $r.chart.result; if (-not $res) { return $null }
    $res = $res[0]; $m = $res.meta; $q = $res.indicators.quote[0]; $ts = $res.timestamp
    if (-not $ts -or $ts.Count -lt 30) { return $null }
    $rows = for ($i = 0; $i -lt $ts.Count; $i++) { if ($null -ne $q.close[$i]) { [pscustomobject]@{ t = $ts[$i]; c = [double]$q.close[$i]; h = [double]$q.high[$i]; l = [double]$q.low[$i]; v = $(if ($null -ne $q.volume[$i]) { [double]$q.volume[$i] } else { 0.0 }) } } }
    $rows = @($rows); if ($rows.Count -lt 30) { return $null }
    $kind = switch ($m.instrumentType) { "EQUITY" { "acción" } "ETF" { "ETF" } "CRYPTOCURRENCY" { "cripto" } "INDEX" { "índice" } default { "valor ($($m.instrumentType))" } }
    $name = if ($m.longName) { "$($m.longName) ($($m.symbol))" } elseif ($m.shortName) { "$($m.shortName) ($($m.symbol))" } else { $m.symbol }
    return @{
        kind = $kind; name = $name; source = "Yahoo Finance ($($m.fullExchangeName); puede llevar retraso)"; currency = $m.currency
        price = [double]$m.regularMarketPrice; priceNote = "último precio de mercado"
        c = @($rows | % { $_.c }); h = @($rows | % { $_.h }); l = @($rows | % { $_.l }); v = @($rows | % { $_.v })
        lastDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.regularMarketTime).UtcDateTime.ToString("yyyy-MM-dd HH:mm") + " UTC"
        extra = @{ hi52 = $m.fiftyTwoWeekHigh; lo52 = $m.fiftyTwoWeekLow }
    }
}
function Get-GeckoSeries($q) {
    try { $s = Invoke-RestMethod "https://api.coingecko.com/api/v3/search?query=$([uri]::EscapeDataString($q))" -Headers $script:UA -TimeoutSec 25 } catch { return $null }
    $cand = @($s.coins | Where-Object { $_.symbol -eq $q.ToUpper() } | Sort-Object { if ($_.market_cap_rank) { [int]$_.market_cap_rank } else { 999999 } })
    if ($cand.Count -eq 0) { return $null }
    $coin = $cand[0]
    try { $d = Invoke-RestMethod "https://api.coingecko.com/api/v3/coins/$($coin.id)/market_chart?vs_currency=usd&days=365&interval=daily" -Headers $script:UA -TimeoutSec 25 } catch { return $null }
    $pr = @($d.prices | ForEach-Object { [double]$_[1] }); $vo = @($d.total_volumes | ForEach-Object { [double]$_[1] })
    if ($pr.Count -lt 30) { return $null }
    $pr = @($pr[0..($pr.Count - 2)]) ; $vo = @($vo[0..($vo.Count - 2)])                       # el último punto es del día en curso
    return @{
        kind = "cripto (sin par directo en Bitunix con este símbolo)"; name = "$($coin.name) ($($coin.symbol))"; source = "CoinGecko (precios diarios agregados)"; currency = "USD"
        price = $pr[-1]; priceNote = "último cierre diario"; c = $pr; h = $null; l = $null; v = $vo
        lastDate = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$d.prices[-2][0]).UtcDateTime.ToString("yyyy-MM-dd"); extra = @{ rank = $coin.market_cap_rank }
    }
}

# ---------- Informe ----------
function Build-Report($s) {
    $c = $s.c; $n = $c.Count; $px = $s.price
    $ret = { param($d) if ($n -gt $d) { ($px / $c[$n - 1 - $d] - 1) * 100 } else { $null } }
    $r1 = & $ret 1; $r7 = & $ret 7; $r30 = & $ret 30; $r90 = & $ret 90; $r365 = & $ret 364
    $win = [Math]::Min($n, 252); $seg = $c[($n - $win)..($n - 1)]
    $hi52 = if ($s.extra.hi52) { [double]$s.extra.hi52 } else { ($seg | Measure-Object -Maximum).Maximum }
    $lo52 = if ($s.extra.lo52) { [double]$s.extra.lo52 } else { ($seg | Measure-Object -Minimum).Minimum }
    $e21 = Ema-Of $c 21; $e50 = Ema-Of $c 50; $e200 = if ($n -ge 200) { Ema-Of $c 200 } else { $null }
    $rsi = Rsi-Of $c
    $tr = if ($px -gt $e21 -and $e21 -gt $e50) { "alcista" } elseif ($px -lt $e21 -and $e21 -lt $e50) { "bajista" } else { "mixta/lateral" }
    $rets = for ($i = [Math]::Max(1, $n - 30); $i -lt $n; $i++) { [Math]::Log($c[$i] / $c[$i-1]) }
    $mean = ($rets | Measure-Object -Average).Average; $sd = [Math]::Sqrt((($rets | % { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum) / ([Math]::Max(1, $rets.Count - 1)))
    $annual = $sd * [Math]::Sqrt(365) * 100
    $atr = $null; if ($s.h) { $sum = 0.0; for ($i = $n - 14; $i -lt $n; $i++) { $sum += [Math]::Max($s.h[$i] - $s.l[$i], [Math]::Max([Math]::Abs($s.h[$i] - $c[$i-1]), [Math]::Abs($s.l[$i] - $c[$i-1]))) }; $atr = $sum / 14 / $c[-1] * 100 }
    # pivotes (máximos/mínimos locales de 5 velas a cada lado)
    $hs = if ($s.h) { $s.h } else { $c }; $ls = if ($s.l) { $s.l } else { $c }; $res = @(); $sup = @()
    for ($i = $n - 200; $i -lt $n - 5; $i++) { if ($i -lt 5) { continue }; $isH = $true; $isL = $true; for ($j = $i - 5; $j -le $i + 5; $j++) { if ($hs[$j] -gt $hs[$i]) { $isH = $false }; if ($ls[$j] -lt $ls[$i]) { $isL = $false } }; if ($isH -and $hs[$i] -gt $px) { $res += $hs[$i] }; if ($isL -and $ls[$i] -lt $px) { $sup += $ls[$i] } }
    $res = @($res | Sort-Object | Select-Object -First 3); $sup = @($sup | Sort-Object -Descending | Select-Object -First 3)
    $vtxt = ""
    if ($s.v -and ($s.v | Measure-Object -Sum).Sum -gt 0 -and $n -ge 22) { $vr = $s.v[-1] / (($s.v[($n-21)..($n-2)] | Measure-Object -Average).Average); $vtxt = "Volumen de la última sesión: x{0:N1} la media de 20 sesiones." -f $vr }
    $L = @()
    $L += "📊 INFORME · $($s.name)"
    $L += "Tipo: $($s.kind) | Fuente: $($s.source)"
    $L += "Datos hasta: $($s.lastDate) ($($s.priceNote))"
    $L += ""
    $L += ("💵 Precio: {0} {1}" -f (Fnum $px), $s.currency)
    $L += ("Rentabilidad: 1d {0} · 7d {1} · 30d {2} · 90d {3} · 1 año {4}" -f (Fpct $r1), (Fpct $r7), (Fpct $r30), (Fpct $r90), (Fpct $r365))
    $rl = if ($n -ge 252 -or $s.extra.hi52) { "Rango de 52 semanas" } else { "Rango del historial disponible ($n días; el activo tiene menos de 1 año de datos)" }
    $L += ("{0}: {1} - {2} (a {3:N0}% del máximo; {4} sobre el mínimo)" -f $rl, (Fnum $lo52), (Fnum $hi52), ($px / $hi52 * 100), (Fpct (($px / $lo52 - 1) * 100)))
    $L += ""
    $L += "📈 TENDENCIA (diaria): $tr"
    $m = "Medias: EMA21 {0} · EMA50 {1}" -f (Fnum $e21), (Fnum $e50); if ($e200) { $m += " · EMA200 {0} (precio {1} la EMA200)" -f (Fnum $e200), $(if ($px -gt $e200) { "SOBRE" } else { "BAJO" }) } else { $m += " · EMA200 no calculable (historial corto)" }
    $L += $m
    if ($rsi) { $rt = if ($rsi -ge 70) { "sobrecompra" } elseif ($rsi -ge 65) { "cerca de sobrecompra" } elseif ($rsi -le 30) { "sobreventa" } elseif ($rsi -le 35) { "cerca de sobreventa" } else { "zona neutra" }; $L += ("RSI(14) diario: {0:N0} ({1})" -f $rsi, $rt) }
    $v = ("Volatilidad: desviación anualizada {0:N0}% (30 sesiones)" -f $annual); if ($atr) { $v += (" · ATR diario {0:N1}%" -f $atr) }; $L += $v
    if ($res.Count) { $L += "Resistencias cercanas (máximos locales): " + (($res | % { Fnum $_ }) -join " · ") }
    if ($sup.Count) { $L += "Soportes cercanos (mínimos locales): " + (($sup | % { Fnum $_ }) -join " · ") }
    if ($vtxt) { $L += $vtxt }
    if ($s.extra.funding -ne $null) { $vv = if ($s.extra.vol24 -ge 1e6) { "{0:N1} M USDT" -f ($s.extra.vol24 / 1e6) } else { "{0:N0} USDT" -f $s.extra.vol24 }
    $L += ("⚖️ Derivados Bitunix: funding {0:N4}% por 8h · volumen 24h {1} · libro de órdenes {2:N0}% compradores" -f $s.extra.funding, $vv, $s.extra.bookBuy) }
    if ($s.extra.rank) { $L += "Ranking por capitalización (CoinGecko): #$($s.extra.rank)" }
    $L += ""
    $L += "❗ NO incluido (el bot no tiene una fuente gratuita y fiable para automatizarlo, así que no se inventa): noticias, resultados de empresa, objetivos de analistas, compras/ventas de instituciones o ballenas, ETF, proyecciones. Para eso consulta fuentes oficiales (SEC/CNMV, web de la empresa, exchange) o pídeselo a Luis."
    $L += "Es información técnica calculada con datos públicos; no es asesoramiento ni garantía."
    return ($L -join "`n")
}

function Resolve-Report($raw, $mode) {
    $q = ($raw -replace '[^A-Za-z0-9.\-\^=]', '').ToUpper()
    if (-not $q -or $q.Length -gt 15) { return "No he entendido el símbolo. Ejemplos: /informe BTC · /informe ETH · /informe AAPL · /informe IREN · /informe SAN.MC" }
    $s = $null; $note = ""; $base = $q -replace 'USDT$', ''
    # ¿es una cripto conocida? (CoinGecko: coincidencia exacta de símbolo y capitalización entre las 300 primeras)
    $isCrypto = $false
    if ($mode -eq "cripto" -or $q -like '*USDT') { $isCrypto = $true }
    elseif ($mode -ne "accion") {
        try { $g = Invoke-RestMethod "https://api.coingecko.com/api/v3/search?query=$([uri]::EscapeDataString($base))" -Headers $script:UA -TimeoutSec 20
              $hit = @($g.coins | Where-Object { $_.symbol -eq $base -and $_.market_cap_rank -and [int]$_.market_cap_rank -le 300 }); if ($hit.Count) { $isCrypto = $true } } catch {}
    }
    if ($isCrypto) {
        try { $s = Get-BitunixSeries $base } catch {}
        if (-not $s) { try { $s = Get-GeckoSeries $base } catch {} }
        if (-not $s -and $mode -ne "cripto") { try { $s = Get-YahooSeries $q } catch {} }
    } else {
        try { $s = Get-YahooSeries $q } catch {}
        if ($s) { try { $bx = (Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq "${base}USDT"; if ($bx) { $note = "ℹ️ Además, en Bitunix existe el futuro perpetuo ${base}/USDT (precio {0} USDT, en vivo)." -f (Fnum ([double]$bx.lastPrice)) } } catch {} }
        if (-not $s -and $mode -ne "accion") { try { $s = Get-BitunixSeries $base } catch {} }
        if (-not $s -and $mode -ne "accion") { try { $s = Get-GeckoSeries $base } catch {} }
    }
    if (-not $s) { return "No he podido obtener datos fiables de '$q'. Prueba con el símbolo bursátil exacto (AAPL, MSFT, IREN, SAN.MC para España) o el ticker de la cripto (BTC, SOL). Si el símbolo es correcto, puede que la fuente esté caída: inténtalo más tarde. No voy a inventar datos." }
    try { $rep = Build-Report $s; if ($note) { $rep += "`n" + $note }; return $rep } catch { return "Tengo datos de '$q' pero ha fallado el cálculo del informe. No envío cifras dudosas." }
}

# ---------- Telegram ----------
function Send-Tg($token, $chat, $text, $replyTo = $null) {
    foreach ($part in ([regex]::Matches($text, '(?s).{1,3800}(?:\n|$)') | ForEach-Object { $_.Value })) {
        $b = @{ chat_id = $chat; text = $part; disable_web_page_preview = $true }; if ($replyTo) { $b.reply_to_message_id = $replyTo; $b.allow_sending_without_reply = $true }
        try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes(($b | ConvertTo-Json -Compress))) | Out-Null } catch {}
    }
}
$script:HelpText = @"
🤖 Bot de Alertas Bitunix · comandos
/informe SIMBOLO · informe técnico de una cripto o una acción
   Ejemplos: /informe BTC · /informe SOL · /informe AAPL · /informe IREN · /informe SAN.MC
   Si hay confusión: /informe COIN accion  o  /informe ARB cripto
/precio SIMBOLO · precio rápido
/resultados · aciertos reales de las señales del bot
/ayuda · esta ayuda
/id · muestra el identificador del chat

En el grupo escribe / y elige el comando del menú del bot (así Telegram añade el nombre del bot solo).
Qué datos usa: Bitunix (cripto en futuros), Yahoo Finance (bolsa) y CoinGecko (otras criptos). Cada informe cita su fuente y la fecha del dato.
Qué NO hace: noticias, analistas, ballenas/instituciones, proyecciones ni recomendaciones de compra o venta. Si no hay dato fiable, lo dice.
"@

function Handle-Commands($token, $allowedChats, $offsetFile) {
    $off = 0; if (Test-Path $offsetFile) { try { $off = [long](Get-Content $offsetFile -Raw).Trim() } catch {} }
    try { $u = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/getUpdates?offset=$off&timeout=0&allowed_updates=%5B%22message%22%5D" -TimeoutSec 25 } catch { return }
    foreach ($up in $u.result) {
        Set-Content $offsetFile ([string]($up.update_id + 1))
        $m = $up.message; if (-not $m -or -not $m.text) { continue }
        $chat = "$($m.chat.id)"
        if ($m.text.Trim().ToLower() -match '^/id(@\w+)?$') { Send-Tg $token $chat ("🆔 Identificador de este chat: {0} (tipo: {1}). Si quieres que el bot envíe aquí las señales, díselo a Luis." -f $chat, $m.chat.type) $m.message_id; continue }
        if ($chat -notin $allowedChats) { continue }
        $t = $m.text.Trim(); if (-not $t.StartsWith("/")) { continue }
        $parts = $t -split '\s+'; $cmd = ($parts[0] -replace '@.*$', '').ToLower(); $args1 = @($parts | Select-Object -Skip 1)
        $key = "$chat"; if ($script:LastCmd[$key] -and ((Get-Date) - $script:LastCmd[$key]).TotalSeconds -lt 12) { Send-Tg $token $chat "Un momento, voy con una petición cada pocos segundos. Repite en unos segundos." $m.message_id; continue }
        $script:LastCmd[$key] = Get-Date
        switch ($cmd) {
            { $_ -in "/ayuda", "/start", "/help" } { Send-Tg $token $chat $script:HelpText $m.message_id }
            "/resultados" { $rep = try { Get-Report } catch { "Aún no hay resultados registrados." }; Send-Tg $token $chat $rep $m.message_id }
            "/precio" {
                if (-not $args1) { Send-Tg $token $chat "Uso: /precio SIMBOLO (ej. /precio BTC o /precio AAPL)" $m.message_id; break }
                $q = ($args1[0] -replace '[^A-Za-z0-9.\-\^=]', '').ToUpper(); $out = $null
                try { $tk = (Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq "$($q -replace 'USDT$','')USDT"; if ($tk) { $out = "{0}/USDT: {1} USDT ({2:+0.00;-0.00}% en 24h). Fuente: Bitunix, en vivo." -f ($q -replace 'USDT$',''), (Fnum ([double]$tk.lastPrice)), ((([double]$tk.lastPrice - [double]$tk.open) / [double]$tk.open) * 100) } } catch {}
                if (-not $out) { $y = Get-YahooSeries $q; if ($y) { $out = "{0}: {1} {2}. Fuente: Yahoo Finance ({3}); puede llevar retraso." -f $y.name, (Fnum $y.price), $y.currency, $y.lastDate } }
                if (-not $out) { $out = "No he podido obtener un precio fiable de '$q'. No voy a inventarlo." }
                Send-Tg $token $chat $out $m.message_id
            }
            "/informe" {
                if (-not $args1) { Send-Tg $token $chat "Uso: /informe SIMBOLO (ej. /informe BTC, /informe AAPL, /informe IREN)" $m.message_id; break }
                $mode = ""; if ($args1.Count -gt 1) { $w = $args1[1].ToLower(); if ($w -in "accion", "acción", "bolsa", "stock") { $mode = "accion" } elseif ($w -in "cripto", "crypto") { $mode = "cripto" } }
                Send-Tg $token $chat "⏳ Preparando el informe de $($args1[0].ToUpper())..." $m.message_id
                Send-Tg $token $chat (Resolve-Report $args1[0] $mode) $null
            }
            default { }
        }
    }
}
