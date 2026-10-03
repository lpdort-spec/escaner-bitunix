# Secciones adicionales del informe: objetivos de analistas y escenarios, insiders (SEC), opciones (put/call), zonas de volumen y órdenes grandes.
# Regla: solo datos de fuentes citadas; si una fuente falla o no existe, se dice "no disponible". Nada se estima sin avisarlo.
$script:XUA = @{ 'User-Agent' = 'AlertasBitunix-bot/1.0 (uso personal)' }
$script:BrowserUA = @{ 'User-Agent' = 'Mozilla/5.0' }
$script:SecTickers = $null; $script:SecTickersAt = [datetime]::MinValue
$script:YSess = $null; $script:YCrumb = $null; $script:YCrumbAt = [datetime]::MinValue

function Fm($x) {                                   # millones con 1-2 decimales
    if ($null -eq $x) { return "n/d" }
    if ([Math]::Abs($x) -ge 1e9) { return ("{0:N2} mil M" -f ($x / 1e9)) }
    if ([Math]::Abs($x) -ge 1e6) { return ("{0:N2} M" -f ($x / 1e6)) }
    return ("{0:N0}" -f $x)
}

# ---------- Yahoo: sesión con "crumb" (necesaria para opciones y objetivos de analistas) ----------
function Get-YahooSession {
    if ($script:YCrumb -and ((Get-Date) - $script:YCrumbAt).TotalMinutes -lt 25) { return $true }
    try {
        $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
        try { Invoke-WebRequest "https://fc.yahoo.com" -UseBasicParsing -WebSession $sess -Headers $script:BrowserUA -TimeoutSec 15 | Out-Null } catch {}
        $crumb = Invoke-RestMethod "https://query1.finance.yahoo.com/v1/test/getcrumb" -WebSession $sess -Headers $script:BrowserUA -TimeoutSec 15
        if ($crumb -and "$crumb".Length -lt 40 -and "$crumb" -notmatch '<') { $script:YSess = $sess; $script:YCrumb = "$crumb"; $script:YCrumbAt = Get-Date; return $true }
    } catch {}
    return $false
}
function Get-YahooTargets($tkr) {                   # consenso de analistas a 12 meses
    if (-not (Get-YahooSession)) { return $null }
    try {
        $u = "https://query2.finance.yahoo.com/v10/finance/quoteSummary/" + [uri]::EscapeDataString($tkr) + "?modules=financialData&crumb=" + [uri]::EscapeDataString($script:YCrumb)
        $f = (Invoke-RestMethod $u -WebSession $script:YSess -Headers $script:BrowserUA -TimeoutSec 20).quoteSummary.result[0].financialData
        if (-not $f -or -not $f.targetMeanPrice.raw) { return $null }
        return @{ mean = [double]$f.targetMeanPrice.raw; high = [double]$f.targetHighPrice.raw; low = [double]$f.targetLowPrice.raw; n = [int]$f.numberOfAnalystOpinions.raw; rec = $f.recommendationKey }
    } catch { return $null }
}
function Get-YahooOptions($tkr) {                   # ratio put/call por volumen y por interés abierto (próximos vencimientos)
    if (-not (Get-YahooSession)) { return $null }
    try {
        $cr = [uri]::EscapeDataString($script:YCrumb); $base = "https://query2.finance.yahoo.com/v7/finance/options/" + [uri]::EscapeDataString($tkr)
        $first = (Invoke-RestMethod "${base}?crumb=$cr" -WebSession $script:YSess -Headers $script:BrowserUA -TimeoutSec 20).optionChain.result[0]
        if (-not $first) { return $null }
        $dates = @($first.expirationDates | Select-Object -First 4)
        $cv = 0.0; $pv = 0.0; $co = 0.0; $po = 0.0
        foreach ($dt in $dates) {
            $res = if ($dt -eq $dates[0]) { $first } else { (Invoke-RestMethod "${base}?date=$dt&crumb=$cr" -WebSession $script:YSess -Headers $script:BrowserUA -TimeoutSec 20).optionChain.result[0] }
            $o = $res.options[0]
            foreach ($x in $o.calls) { $cv += [double]$x.volume; $co += [double]$x.openInterest }
            foreach ($x in $o.puts) { $pv += [double]$x.volume; $po += [double]$x.openInterest }
        }
        if (($co + $cv) -le 0) { return $null }
        return @{ callVol = $cv; putVol = $pv; callOI = $co; putOI = $po; exps = $dates.Count }
    } catch { return $null }
}

# ---------- SEC EDGAR: operaciones de insiders (formulario 4, fuente oficial) ----------
function Get-SecInsiders($tkr, [double]$minUsd = 500000, [int]$days = 365) {
    try {
        if (-not $script:SecTickers -or ((Get-Date) - $script:SecTickersAt).TotalHours -gt 12) { $script:SecTickers = (Invoke-RestMethod "https://www.sec.gov/files/company_tickers.json" -Headers $script:XUA -TimeoutSec 30).PSObject.Properties.Value; $script:SecTickersAt = Get-Date }
        $co = $script:SecTickers | Where-Object { $_.ticker -eq $tkr.ToUpper() } | Select-Object -First 1
        if (-not $co) { return @{ error = "no consta en la SEC (no es una empresa con cotización en EE. UU.)" } }
        $cik10 = "{0:D10}" -f [int]$co.cik_str; $cik = [int]$co.cik_str
        $sub = Invoke-RestMethod "https://data.sec.gov/submissions/CIK$cik10.json" -Headers $script:XUA -TimeoutSec 30
        $rec = $sub.filings.recent; $cut = (Get-Date).AddDays(-$days).ToString("yyyy-MM-dd")
        $idx = @(0..($rec.form.Count - 1) | Where-Object { $rec.form[$_] -eq '4' -and $rec.filingDate[$_] -ge $cut } | Select-Object -First 60)
        $tx = @()
        foreach ($i in $idx) {
            Start-Sleep -Milliseconds 130
            $acc = ($rec.accessionNumber[$i] -replace '-', ''); $doc = ($rec.primaryDocument[$i] -replace '^xsl[^/]+/', '')
            try { $raw = Invoke-WebRequest "https://www.sec.gov/Archives/edgar/data/$cik/$acc/$doc" -UseBasicParsing -Headers $script:XUA -TimeoutSec 25; [xml]$x = $raw.Content } catch { continue }
            $od = $x.ownershipDocument; if (-not $od) { continue }
            $own = @($od.reportingOwner)[0]; $name = $own.reportingOwnerId.rptOwnerName
            $rel = $own.reportingOwnerRelationship; $role = if ($rel.officerTitle) { $rel.officerTitle } elseif ($rel.isDirector -eq '1' -or $rel.isDirector -eq 'true') { "Director" } elseif ($rel.isTenPercentOwner -eq '1' -or $rel.isTenPercentOwner -eq 'true') { "Titular >10%" } else { "Insider" }
            foreach ($t in @($od.nonDerivativeTable.nonDerivativeTransaction)) {
                if (-not $t) { continue }
                $code = $t.transactionCoding.transactionCode; if ($code -notin 'P', 'S') { continue }       # compras y ventas en mercado (excluye concesiones, ejercicios y retenciones)
                $sh = [double]$t.transactionAmounts.transactionShares.value; $pr = [double]$t.transactionAmounts.transactionPricePerShare.value
                $tx += [pscustomobject]@{ date = $t.transactionDate.value; name = $name; role = $role; side = $(if ($code -eq 'P') { "COMPRA" } else { "VENTA" }); shares = $sh; price = $pr; usd = $sh * $pr }
            }
        }
        # agrupar por persona, día y sentido
        $grp = @($tx | Group-Object { "$($_.name)|$($_.date)|$($_.side)" } | ForEach-Object { $g = $_.Group; [pscustomobject]@{ date = $g[0].date; name = $g[0].name; role = $g[0].role; side = $g[0].side; usd = ($g | Measure-Object usd -Sum).Sum; shares = ($g | Measure-Object shares -Sum).Sum } })
        $big = @($grp | Where-Object { $_.usd -ge $minUsd } | Sort-Object date -Descending)
        return @{ total = $grp.Count; filings = $idx.Count; big = $big; buyUsd = [double](($grp | Where-Object side -eq "COMPRA" | Measure-Object usd -Sum).Sum); sellUsd = [double](($grp | Where-Object side -eq "VENTA" | Measure-Object usd -Sum).Sum); days = $days; minUsd = $minUsd }
    } catch { return @{ error = "la SEC no respondió ($($_.Exception.Message))" } }
}

# ---------- Deribit: opciones de BTC y ETH ----------
function Get-DeribitPcr($cur) {
    try {
        $d = (Invoke-RestMethod "https://www.deribit.com/api/v2/public/get_book_summary_by_currency?currency=$cur&kind=option" -TimeoutSec 30).result
        $co = 0.0; $po = 0.0; $cv = 0.0; $pv = 0.0
        foreach ($i in $d) { $t = ($i.instrument_name -split '-')[-1]; if ($t -eq 'C') { $co += [double]$i.open_interest; $cv += [double]$i.volume } elseif ($t -eq 'P') { $po += [double]$i.open_interest; $pv += [double]$i.volume } }
        if ($co -le 0) { return $null }
        return @{ callOI = $co; putOI = $po; callVol = $cv; putVol = $pv; n = $d.Count }
    } catch { return $null }
}

# ---------- Zonas con más volumen (perfil de volumen) ----------
function Get-VolumeZones($o, $h, $l, $c, $v, [int]$bins = 30) {
    $n = $c.Count; if ($n -lt 30) { return $null }
    $mn = ($l | Measure-Object -Minimum).Minimum; $mx = ($h | Measure-Object -Maximum).Maximum; if ($mx -le $mn) { return $null }
    $step = ($mx - $mn) / $bins; $buy = New-Object 'double[]' $bins; $sell = New-Object 'double[]' $bins
    for ($i = 0; $i -lt $n; $i++) {
        $tp = ($h[$i] + $l[$i] + $c[$i]) / 3; $b = [Math]::Min($bins - 1, [int][Math]::Floor(($tp - $mn) / $step))
        if ($c[$i] -ge $o[$i]) { $buy[$b] += $v[$i] } else { $sell[$b] += $v[$i] }
    }
    $zones = for ($b = 0; $b -lt $bins; $b++) { [pscustomobject]@{ lo = $mn + $b * $step; hi = $mn + ($b + 1) * $step; tot = $buy[$b] + $sell[$b]; buyPct = $(if (($buy[$b] + $sell[$b]) -gt 0) { 100.0 * $buy[$b] / ($buy[$b] + $sell[$b]) } else { 0 }) } }
    return @($zones | Sort-Object tot -Descending | Select-Object -First 3)
}
function Get-YahooIntraday($tkr) {
    try {
        $res = (Invoke-RestMethod ("https://query1.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($tkr) + "?range=3mo&interval=60m") -Headers $script:BrowserUA -TimeoutSec 25).chart.result[0]
        $q = $res.indicators.quote[0]; $o = @(); $h = @(); $l = @(); $c = @(); $v = @()
        for ($i = 0; $i -lt $res.timestamp.Count; $i++) { if ($null -ne $q.close[$i] -and $null -ne $q.open[$i]) { $o += [double]$q.open[$i]; $h += [double]$q.high[$i]; $l += [double]$q.low[$i]; $c += [double]$q.close[$i]; $v += [double]$q.volume[$i] } }
        return @{ o = $o; h = $h; l = $l; c = $c; v = $v; desc = "velas de 1 hora de los últimos 3 meses (Yahoo Finance)" }
    } catch { return $null }
}
function Get-BitunixIntraday($sym) {
    try {
        $all = @{}; $end = $null
        for ($p = 0; $p -lt 4; $p++) {
            $u = "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=1h&limit=200"; if ($end) { $u += "&endTime=$end" }
            $dd = (Invoke-RestMethod $u -TimeoutSec 20).data; if (-not $dd) { break }
            $mn = [long]::MaxValue; foreach ($k in $dd) { $all[[string]$k.time] = $k; if ([long]$k.time -lt $mn) { $mn = [long]$k.time } }; $end = $mn - 1
        }
        $s = @($all.Values | Sort-Object { [long]$_.time }); $s = @($s[0..($s.Count - 2)])
        return @{ o = @($s | % { [double]$_.open }); h = @($s | % { [double]$_.high }); l = @($s | % { [double]$_.low }); c = @($s | % { [double]$_.close }); v = @($s | % { [double]$_.quoteVol }); desc = "velas de 1 hora de las últimas ~$([int]($s.Count / 24)) jornadas (Bitunix)" }
    } catch { return $null }
}
function Get-BookWalls($sym) {                      # órdenes grandes visibles en el libro de Bitunix
    try {
        $d = (Invoke-RestMethod "$($script:CmdBase)/depth?symbol=${sym}USDT&limit=max" -TimeoutSec 20).data
        $mid = ([double]$d.bids[0][0] + [double]$d.asks[0][0]) / 2; $step = $mid * 0.002
        $agg = { param($side) $h = @{}; foreach ($x in $side) { $p = [double]$x[0]; if ([Math]::Abs($p / $mid - 1) -gt 0.10) { continue }; $b = [Math]::Floor($p / $step); $h[$b] += [double]$p * [double]$x[1] }; return @($h.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { [pscustomobject]@{ price = ($_.Key + 0.5) * $step; usd = $_.Value } }) }
        return @{ bids = (& $agg $d.bids); asks = (& $agg $d.asks); mid = $mid }
    } catch { return $null }
}

# ---------- Escenarios a 1, 3 y 5 años ----------
function Get-Cagr($tkr) {                           # rentabilidad anual compuesta con datos mensuales de Yahoo (hasta 10 años)
    try {
        $res = (Invoke-RestMethod ("https://query1.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($tkr) + "?range=10y&interval=1mo") -Headers $script:BrowserUA -TimeoutSec 25).chart.result[0]
        $cl = @($res.indicators.quote[0].close | Where-Object { $null -ne $_ }); if ($cl.Count -lt 24) { return $null }
        $yrs = ($cl.Count - 1) / 12.0
        return @{ cagr = [Math]::Pow($cl[-1] / $cl[0], 1.0 / $yrs) - 1; years = $yrs }
    } catch { return $null }
}

function Build-Extra($s) {
    $script:PlatOK = @(); $script:PlatFail = @()      # lista de plataformas consultadas: se reinicia al empezar cada informe (así TradingView también consta)
    $px = $s.price; $cur = $s.currency; $sym = $s.sym; $L = @()
    $L += "━━━━━━━━━━━━━━━━━━"
    $L += "🧭 DATOS PARA DECIDIR · $($s.name)"
    # 0) análisis técnico avanzado (charting, Fibonacci, Bollinger...) y TradingView
    if (Get-Command Get-AdvancedTechSection -ErrorAction SilentlyContinue) { $L += ""; try { $L += @(Get-AdvancedTechSection $s) } catch { $L += "🧮 Análisis técnico avanzado: no disponible ahora." } }
    # 1) objetivos
    $L += ""; $L += "🎯 OBJETIVOS DE PRECIO"
    $tg = $null; if ($s.src -eq 'yahoo' -and $s.kind -in 'acción', 'ETF') { $tg = Get-YahooTargets $sym }
    if ($tg) { $L += ("• A 1 año (consenso de {0} analistas, Yahoo Finance): medio {1} {2} ({3}) · mínimo {4} · máximo {5} · recomendación media: {6}" -f $tg.n, (Fnum $tg.mean), $cur, (Fpct (($tg.mean / $px - 1) * 100)), (Fnum $tg.low), (Fnum $tg.high), $tg.rec) }
    elseif ($s.kind -like '*cripto*' -or $s.kind -like '*futuro*') { $L += "• A 1 año: no existen objetivos de analistas fiables para criptomonedas. Más abajo van escenarios matemáticos." }
    else { $L += "• A 1 año: no he podido obtener el consenso de analistas de una fuente fiable ahora mismo (Yahoo no respondió). No lo invento." }
    $cg = $null; $cgSym = $null
    if ($s.src -eq 'yahoo') { $cgSym = $sym } elseif ($s.src -eq 'bitunix' -and $sym -in 'BTC', 'ETH', 'SOL', 'XRP', 'DOGE', 'ADA', 'LTC', 'LINK', 'AVAX', 'BNB') { $cgSym = "$sym-USD" }
    if ($cgSym) { $cg = Get-Cagr $cgSym }
    $mk = Get-Cagr "^GSPC"
    if ($cg -or $mk) {
        $L += "• A 1, 3 y 5 años (ESCENARIOS MATEMÁTICOS, NO pronósticos de nadie; ninguna fuente fiable publica objetivos a 3-5 años):"
        $rows = @(); if ($cg) { $rows += @{ n = ("repite su rentabilidad anual histórica ({0:N1}%/año, {1:N1} años de datos)" -f ($cg.cagr * 100), $cg.years); g = $cg.cagr } }
        if ($mk) { $rows += @{ n = ("rinde como el S&P 500 ({0:N1}%/año de media en 10 años)" -f ($mk.cagr * 100)); g = $mk.cagr } }
        $rows += @{ n = "no se revaloriza (0%/año)"; g = 0.0 }
        foreach ($r in $rows) { $L += ("   - Si {0}: 1a {1} · 3a {2} · 5a {3} {4}" -f $r.n, (Fnum ($px * [Math]::Pow(1 + $r.g, 1))), (Fnum ($px * [Math]::Pow(1 + $r.g, 3))), (Fnum ($px * [Math]::Pow(1 + $r.g, 5))), $cur) }
    } else { $L += "• A 3 y 5 años: sin historial suficiente para ni siquiera un escenario matemático. No hay objetivos fiables." }
    # 2) insiders
    $L += ""; $L += "🧑‍💼 INSIDERS (SEC, formulario 4; compras y ventas en mercado de más de 500.000 USD, últimos 12 meses)"
    if ($s.src -eq 'yahoo' -and $s.kind -in 'acción', 'ETF' -and $sym -notmatch '[.\-=^]') {
        $ins = Get-SecInsiders $sym
        if ($ins.error) { $L += "• No disponible: $($ins.error)." }
        elseif ($ins.big.Count -eq 0) { $L += ("• Ninguna operación de más de 500.000 USD en {0} formularios revisados. Total de insiders (todas las cuantías): compras {1}, ventas {2} USD." -f $ins.filings, (Fm $ins.buyUsd), (Fm $ins.sellUsd)) }
        else {
            foreach ($b in ($ins.big | Select-Object -First 8)) { $L += ("• {0} · {1} ({2}) · {3} de {4} USD ({5:N0} acciones)" -f $b.date, $b.name, $b.role, $b.side, (Fm $b.usd), $b.shares) }
            $L += ("• Balance de todos los insiders en el periodo: compras {0} USD · ventas {1} USD (neto {2})." -f (Fm $ins.buyUsd), (Fm $ins.sellUsd), $(if ($ins.sellUsd -gt $ins.buyUsd) { "vendedor" } else { "comprador" }))
        }
    } else { $L += "• No aplica: solo hay formulario 4 para empresas que cotizan en EE. UU." }
    # 3) opciones
    $L += ""; $L += "📊 POSICIONAMIENTO EN OPCIONES (ratio put/call)"
    $op = $null; $opSrc = ""
    if ($s.src -eq 'bitunix' -and $sym -in 'BTC', 'ETH') { $op = Get-DeribitPcr $sym; $opSrc = "Deribit, todos los vencimientos" }
    elseif ($s.src -eq 'yahoo' -and $s.kind -in 'acción', 'ETF') { $op = Get-YahooOptions $sym; $opSrc = "Yahoo Finance, próximos 4 vencimientos" }
    if ($op) {
        $pcrOI = $op.putOI / [Math]::Max(1, $op.callOI); $pcrV = $op.putVol / [Math]::Max(1, $op.callVol)
        $lec = if ($pcrOI -gt 1.0) { "más puts que calls: posicionamiento defensivo o de cobertura" } elseif ($pcrOI -lt 0.7) { "más calls que puts: posicionamiento optimista" } else { "equilibrado" }
        $L += ("• Por interés abierto: put/call {0:N2} ({1}). Por volumen del día: {2:N2}. Fuente: {3}." -f $pcrOI, $lec, $pcrV, $opSrc)
    } else { $L += "• No disponible para este activo o la fuente no respondió (solo cubro opciones de BTC, ETH y acciones/ETF de EE. UU.)." }
    # 4) zonas de volumen
    $L += ""; $L += "📍 PRECIOS CON MÁS VOLUMEN (perfil de volumen)"
    $iv = $null; if ($s.src -eq 'bitunix') { $iv = Get-BitunixIntraday $sym } elseif ($s.src -eq 'yahoo') { $iv = Get-YahooIntraday $sym }
    if ($iv) {
        $zn = Get-VolumeZones $iv.o $iv.h $iv.l $iv.c $iv.v
        if ($zn) { $L += "• Zonas donde más se ha negociado ($($iv.desc)); el reparto compra/venta es una aproximación según el color de cada vela:"; foreach ($z in $zn) { $L += ("   - {0} - {1} {2}: {3:N0}% de las velas cerraron al alza (compra) / {4:N0}% a la baja (venta)" -f (Fnum $z.lo), (Fnum $z.hi), $cur, $z.buyPct, (100 - $z.buyPct)) } }
        else { $L += "• Historial insuficiente para calcularlo." }
    } else { $L += "• No disponible: la fuente no devolvió velas horarias." }
    if ($s.src -eq 'bitunix') {
        $bw = Get-BookWalls $sym
        if ($bw) {
            $L += "• Órdenes límite más grandes visibles AHORA en el libro de Bitunix (pueden retirarse en cualquier momento):"
            $L += "   Compra: " + (($bw.bids | % { "{0} ({1} USDT)" -f (Fnum $_.price), (Fm $_.usd) }) -join " · ")
            $L += "   Venta:  " + (($bw.asks | % { "{0} ({1} USDT)" -f (Fnum $_.price), (Fm $_.usd) }) -join " · ")
            $big = @($bw.bids + $bw.asks | Where-Object { $_.usd -ge 1e6 }).Count
            $L += $(if ($big -gt 0) { "   $big nivel(es) superan 1 M USDT: posible actividad de grandes participantes." } else { "   Ningún nivel supera 1 M USDT." })
        }
    }
    # 5) ballenas, derivados, fundamentales, instituciones (varias plataformas)
    $L += ""
    $pl = $null; try { $pl = @(Build-Plataformas $s) } catch { $pl = $null }
    if ($pl -and $pl.Count) { $L += $pl }
    else { $L += "🐋 BALLENAS: no se han podido consultar las plataformas ahora mismo; no lo invento." }
    $L += ""; $L += "Fuentes: SEC EDGAR, Yahoo Finance, Deribit, Binance, Bybit, OKX, Coinbase, Bitunix, CoinGecko y blockchain.com, según el activo. Todo son datos públicos; no es asesoramiento ni garantía."
    return ($L -join "`n")
}

if (Test-Path (Join-Path $PSScriptRoot "informes-plataformas.ps1")) { . (Join-Path $PSScriptRoot "informes-plataformas.ps1") }
