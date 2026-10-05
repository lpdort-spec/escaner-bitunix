# Resultados, fundamentales y comunicados oficiales de cualquier activo. Todo se obtiene automáticamente de fuentes públicas:
#  - Acciones/ETFs: Yahoo Finance (resultados trimestrales, sorpresas de beneficios, valoración, deuda/caja, próximos resultados), SEC EDGAR (comunicados oficiales: 8-K, 10-K, 10-Q, emisiones, participaciones),
#    notas de prensa de la propia empresa (Business Wire, GlobeNewswire, PR Newswire, Access Newswire) y, para valores españoles, hechos relevantes de la CNMV (vía Google News).
#  - Cripto: CoinGecko (capitalización, valoración totalmente diluida, oferta circulante y máxima, distancia al máximo histórico).
# Regla: solo cifras de la fuente; si una no existe para ese activo (p. ej. un ETF no tiene resultados trimestrales), se dice.

function Fmt-Big($x) { if ($null -eq $x) { return "n/d" }; $a = [Math]::Abs([double]$x); $s = if ([double]$x -lt 0) { "-" } else { "" }
    if ($a -ge 1e12) { return ("{0}{1:N2} B" -f $s, ($a / 1e12)) } elseif ($a -ge 1e9) { return ("{0}{1:N2} mil M" -f $s, ($a / 1e9)) } elseif ($a -ge 1e6) { return ("{0}{1:N1} M" -f $s, ($a / 1e6)) } else { return ("{0}{1:N0}" -f $s, $a) } }
function Rw($o) { if ($null -ne $o -and $null -ne $o.raw) { return [double]$o.raw } else { return $null } }

function Get-YahooFundamentals($tkr) {
    try {
        if (-not (Get-YahooSession)) { return $null }
        $u = "https://query2.finance.yahoo.com/v10/finance/quoteSummary/" + [uri]::EscapeDataString($tkr) + "?modules=defaultKeyStatistics,financialData,summaryDetail,earningsHistory,calendarEvents,incomeStatementHistoryQuarterly&crumb=" + [uri]::EscapeDataString($script:YCrumb)
        return (Invoke-RestMethod $u -WebSession $script:YSess -Headers $script:BrowserUA -TimeoutSec 25).quoteSummary.result[0]
    } catch { return $null }
}
function Get-NextEarnings($tkr) {               # @{ date; days } o $null
    try { $r = Get-YahooFundamentals $tkr; $d = @($r.calendarEvents.earnings.earningsDate)[0]; if ($d -and $d.raw) { $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$d.raw).UtcDateTime.Date; return @{ date = $dt; days = [int]($dt - (Get-Date).Date).TotalDays } } } catch {}
    return $null
}

$script:SecItems = @{ '1.01' = 'acuerdo material'; '1.02' = 'terminación de un acuerdo material'; '1.03' = 'QUIEBRA/concurso'; '2.01' = 'compra o venta de activos'; '2.02' = 'RESULTADOS trimestrales'; '2.03' = 'nueva deuda'; '2.04' = 'aceleración de deuda'; '2.05' = 'reestructuración'; '2.06' = 'deterioro de activos'
    '3.01' = 'aviso de exclusión de cotización'; '3.02' = 'venta de acciones no registrada'; '3.03' = 'cambio en derechos de accionistas'; '4.01' = 'cambio de auditor'; '4.02' = 'estados financieros NO fiables'; '5.01' = 'cambio de control'; '5.02' = 'cambios en la directiva'; '5.03' = 'cambio de estatutos'; '5.07' = 'votación de accionistas'; '7.01' = 'comunicación a inversores (Reg FD)'; '8.01' = 'otros eventos' }
function Get-SecFilings($tkr, [int]$max = 6) {
    try {
        if (-not $script:SecTickers -or ((Get-Date) - $script:SecTickersAt).TotalHours -gt 12) { $script:SecTickers = (Invoke-RestMethod "https://www.sec.gov/files/company_tickers.json" -Headers $script:XUA -TimeoutSec 30).PSObject.Properties.Value; $script:SecTickersAt = Get-Date }
        $c = $script:SecTickers | Where-Object { $_.ticker -eq $tkr.ToUpper() } | Select-Object -First 1; if (-not $c) { return $null }
        $sub = Invoke-RestMethod ("https://data.sec.gov/submissions/CIK{0:D10}.json" -f [int]$c.cik_str) -Headers $script:XUA -TimeoutSec 30; $rf = $sub.filings.recent; $out = @()
        for ($i = 0; $i -lt $rf.form.Count -and $out.Count -lt $max; $i++) {
            $f = "$($rf.form[$i])"; if ($f -notmatch '^(8-K|10-K|10-Q|S-1|S-3|F-1|424B|SC 13|SCHEDULE 13|6-K|20-F|40-F|DEF 14A|NT 10)') { continue }
            $items = (("$($rf.items[$i])" -split ',') | Where-Object { $_ -and $_ -ne '9.01' } | ForEach-Object { if ($script:SecItems.ContainsKey($_)) { $script:SecItems[$_] } else { "punto $_" } }) -join "; "
            $kind = switch -Regex ($f) { '^10-K' { 'informe anual' } '^10-Q' { 'informe trimestral' } '^424B' { 'emisión de valores (folleto)' } '^S-[13]' { 'registro de emisión' } 'SC(HEDULE)? 13' { 'participación significativa de un inversor' } '^NT 10' { 'AVISO de retraso en presentar cuentas' } '^DEF 14A' { 'junta de accionistas' } default { '' } }
            if ([datetime]::Parse("$($rf.filingDate[$i])") -lt (Get-Date).AddDays(-400)) { continue }; $out += [pscustomobject]@{ date = "$($rf.filingDate[$i])"; form = $f; text = $(if ($items) { $items } else { $kind }) }
        }
        return $out
    } catch { return $null }
}
function Get-CompanyWire($name, $sym, [bool]$spanish) {
    $core = (("$name" -replace '\(.*$', '' -replace '(?i)\b(inc|corp|corporation|limited|ltd|plc|holdings|group|co|company|sa|s\.a\.|ag|nv)\b\.?', '').Trim()); if ($core.Length -lt 3) { $core = $sym }
    $q = if ($spanish) { "`"$core`" (site:cnmv.es OR `"hecho relevante`" OR `"resultados`")" } else { "`"$core`" (site:businesswire.com OR site:globenewswire.com OR site:prnewswire.com OR site:accessnewswire.com)" }
    $items = @(Get-RssItems ("https://news.google.com/rss/search?q=" + [uri]::EscapeDataString("$q when:45d") + "&hl=" + $(if ($spanish) { "es&gl=ES&ceid=ES:es" } else { "en-US&gl=US&ceid=US:en" })) 'Google News' 'oficial')
    return @($items | Where-Object { $_.title -match [regex]::Escape($core) -or $_.title -match [regex]::Escape($sym) } | Select-Object -First 4)
}

function Get-StockFundamentalsSection($s) {
    $tkr = $s.sym; $L = @(); $L += "📑 RESULTADOS Y FUNDAMENTALES (Yahoo Finance, SEC EDGAR y comunicados de la empresa)"
    $r = Get-YahooFundamentals $tkr
    if ($r) {
        $q = @($r.incomeStatementHistoryQuarterly.incomeStatementHistory)
        if ($q.Count -and $q[0]) { $L += "Últimos trimestres (ingresos · beneficio neto):"; foreach ($x in ($q | Select-Object -First 4)) { $L += ("   • {0}: {1} · {2}" -f $x.endDate.fmt, (Fmt-Big (Rw $x.totalRevenue)), (Fmt-Big (Rw $x.netIncome))) } }
        $eh = @($r.earningsHistory.history | Where-Object { $_ })
        if ($eh.Count) {
            $beat = @($eh | Where-Object { $null -ne (Rw $_.epsActual) -and $null -ne (Rw $_.epsEstimate) -and (Rw $_.epsActual) -ge (Rw $_.epsEstimate) }).Count
            $L += ("Beneficio por acción real vs estimado: " + (($eh | ForEach-Object { "{0}: {1} vs {2} {3}" -f $_.quarter.fmt, $_.epsActual.fmt, $_.epsEstimate.fmt, $(if ((Rw $_.epsActual) -ge (Rw $_.epsEstimate)) { "✅" } else { "❌" }) }) -join " · ") + " → superó la previsión en $beat de $($eh.Count)")
        }
        $ce = @($r.calendarEvents.earnings.earningsDate)[0]; if ($ce -and $ce.fmt) { $dd = [int]([DateTimeOffset]::FromUnixTimeSeconds([long]$ce.raw).UtcDateTime.Date - (Get-Date).Date).TotalDays; $L += ("Próximos resultados trimestrales: {0} ({1}){2}" -f $ce.fmt, $(if ($dd -ge 0) { "en $dd días" } else { "ya publicados" }), $(if ($dd -ge 0 -and $dd -le 7) { " ⚠️ cercanos: suelen provocar saltos de precio" } else { "" })) }
        $fd = $r.financialData; $sd = $r.summaryDetail; $ks = $r.defaultKeyStatistics
        $v = @(); if (Rw $sd.trailingPE) { $v += ("PER {0:N1}" -f (Rw $sd.trailingPE)) }; if (Rw $sd.forwardPE) { $v += ("PER estimado {0:N1}" -f (Rw $sd.forwardPE)) }; if (Rw $sd.priceToSalesTrailing12Months) { $v += ("precio/ventas {0:N1}" -f (Rw $sd.priceToSalesTrailing12Months)) }; if (Rw $ks.priceToBook) { $v += ("precio/valor contable {0:N1}" -f (Rw $ks.priceToBook)) }; if (Rw $ks.enterpriseToEbitda) { $v += ("EV/EBITDA {0:N1}" -f (Rw $ks.enterpriseToEbitda)) }; if (Rw $sd.marketCap) { $v += "capitalización $(Fmt-Big (Rw $sd.marketCap))" }; if ((Rw $sd.dividendYield) -gt 0) { $v += ("dividendo {0:N2}%" -f ((Rw $sd.dividendYield) * 100)) }
        if ($v.Count) { $L += "Valoración: " + ($v -join " · ") + $(if (-not (Rw $sd.trailingPE) -and (Rw $fd.profitMargins) -lt 0) { " (sin PER: la empresa tiene pérdidas)" } else { "" }) }
        $h = @(); if (Rw $fd.totalRevenue) { $h += "ingresos 12m $(Fmt-Big (Rw $fd.totalRevenue))" }; if ($null -ne (Rw $fd.revenueGrowth)) { $h += ("crecimiento de ingresos {0:+0.0;-0.0}%" -f ((Rw $fd.revenueGrowth) * 100)) }; if ($null -ne (Rw $fd.profitMargins)) { $h += ("margen neto {0:N1}%" -f ((Rw $fd.profitMargins) * 100)) }; if ($null -ne (Rw $fd.returnOnEquity)) { $h += ("ROE {0:N1}%" -f ((Rw $fd.returnOnEquity) * 100)) }
        if ($h.Count) { $L += "Negocio: " + ($h -join " · ") }
        $cash = Rw $fd.totalCash; $debt = Rw $fd.totalDebt; $fcf = Rw $fd.freeCashflow
        if ($null -ne $cash -or $null -ne $debt) { $L += ("Balance: caja {0} · deuda {1}{2}{3}" -f (Fmt-Big $cash), (Fmt-Big $debt), $(if ($null -ne $fcf) { " · flujo de caja libre " + (Fmt-Big $fcf) } else { "" }), $(if ($cash -and $debt -and $debt -gt 2 * $cash) { " ⚠️ deuda superior al doble de la caja" } elseif ($null -ne $fcf -and $fcf -lt 0) { " ⚠️ consume caja" } else { "" })) }
        if (-not $q.Count -and -not $eh.Count -and -not $fd.totalRevenue) { $L += "Este valor (por ejemplo un ETF o un fondo) no publica resultados trimestrales propios; sus datos son los de las empresas que lo componen." }
    } else { $L += "No he podido leer los resultados de Yahoo Finance ahora." }
    $sf = Get-SecFilings $tkr 6
    if ($sf -and @($sf).Count) { $L += "Comunicados oficiales a la SEC (más recientes):"; foreach ($f in $sf) { $L += ("   • {0} · {1}{2}" -f $f.date, $f.form, $(if ($f.text) { " — " + $f.text } else { "" })) } }
    elseif ($tkr -notmatch '\.') { $L += "SEC EDGAR: sin comunicados recientes localizados para este símbolo (puede no ser una empresa de EE. UU.)." }
    $spanish = ($tkr -like '*.MC'); $w = @(Get-CompanyWire $s.name $tkr $spanish)
    if ($w.Count) { $L += $(if ($spanish) { "Comunicados de la empresa y hechos relevantes (CNMV, 45 días):" } else { "Notas de prensa de la propia empresa (45 días):" }); foreach ($x in $w) { $L += ("   • {0} — {1}, {2}" -f $x.title, $x.src, (Get-AgeText $x.when)) } }
    $L += "   (Cifras tal como las publica la fuente; confirma en la web de relaciones con inversores de la empresa.)"
    return ($L -join "`n")
}
function Get-CryptoFundamentalsSection($s) {
    $sym = "$($s.sym)".ToUpper() -replace 'USDT$', ''; $L = @(); $L += "📑 FUNDAMENTALES DEL PROYECTO (CoinGecko)"
    try {
        $g = Invoke-RestMethod "https://api.coingecko.com/api/v3/search?query=$([uri]::EscapeDataString($sym))" -Headers $script:UA -TimeoutSec 20
        $hit = @($g.coins | Where-Object { $_.symbol -eq $sym } | Sort-Object { if ($_.market_cap_rank) { [int]$_.market_cap_rank } else { 999999 } })[0]
        if (-not $hit) { $L += "No he localizado este símbolo en CoinGecko."; return ($L -join "`n") }
        $d = @(Invoke-RestMethod "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=$($hit.id)&price_change_percentage=30d" -Headers $script:UA -TimeoutSec 25)[0]
        if (-not $d -or -not $d.name) { $L += "CoinGecko no devolvió datos de mercado ahora."; return ($L -join "`n") }
        $L += ("{0}: capitalización {1} USD (puesto #{2}) · valoración totalmente diluida {3} USD · volumen 24h {4} USD" -f $d.name, (Fmt-Big $d.market_cap), $(if ($d.market_cap_rank) { $d.market_cap_rank } else { "n/d" }), (Fmt-Big $d.fully_diluted_valuation), (Fmt-Big $d.total_volume))
        if ($d.circulating_supply) { $pc = if ($d.max_supply) { " ({0:N0}% de la oferta máxima)" -f ($d.circulating_supply / $d.max_supply * 100) } elseif ($d.total_supply) { " ({0:N0}% de la oferta total)" -f ($d.circulating_supply / $d.total_supply * 100) } else { "" }; $L += ("Oferta circulante: {0:N0}{1}{2}" -f $d.circulating_supply, $pc, $(if ($d.total_supply -and $d.circulating_supply / $d.total_supply -lt 0.5) { " ⚠️ menos de la mitad en circulación: pueden venir desbloqueos (presión vendedora)" } else { "" })) }
        $L += ("Distancia al máximo histórico: {0:N0}% (el {1}) · cambio 30 días {2:+0.0;-0.0}%" -f $d.ath_change_percentage, ("$($d.ath_date)" -replace 'T.*', ''), $d.price_change_percentage_30d_in_currency)
    } catch { $L += "No he podido leer CoinGecko ahora." }
    $L += "   (Una cripto no tiene resultados trimestrales; los desbloqueos de tokens, auditorías y alianzas se siguen con las noticias.)"
    return ($L -join "`n")
}
function Get-FundamentalsSection($s) { if ($s.src -eq 'yahoo') { return (Get-StockFundamentalsSection $s) } else { return (Get-CryptoFundamentalsSection $s) } }
