# Noticias y calendario macro para los análisis y avisos (acciones, ETFs y cripto).
# Fuentes públicas gratuitas (RSS y calendarios): Yahoo Finance (por activo), Google News (agrega Reuters, Bloomberg, WSJ, CNBC, etc. por tema y por activo), CoinDesk, Cointelegraph,
# Decrypt, The Block, Bitcoin Magazine, BeInCrypto, CNBC, MarketWatch, Investing.com, notas de prensa de la Reserva Federal y de la SEC, calendario económico (Forex Factory) y calendario FOMC de la Fed.
# LÍMITE HONESTO: el bot detecta titulares y los clasifica por palabras clave (legal, regulación, macro, riesgo, catalizador); NO entiende si una noticia es buena o mala para el precio.
# Los titulares se muestran en su idioma original (inglés) y hay que confirmarlos en la fuente. Las fuentes de pago (Bloomberg Terminal, Reuters Eikon) no están disponibles.

$script:NwUA = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' }
$script:NwPool = $null; $script:NwPoolAt = [datetime]::MinValue; $script:NwEv = $null; $script:NwEvAt = [datetime]::MinValue; $script:NwFomc = $null; $script:NwFomcAt = [datetime]::MinValue
$script:NwFeeds = @(
    @{ n = 'Cointelegraph'; u = 'https://cointelegraph.com/rss'; k = 'cripto' }, @{ n = 'Decrypt'; u = 'https://decrypt.co/feed'; k = 'cripto' }, @{ n = 'The Block'; u = 'https://www.theblock.co/rss.xml'; k = 'cripto' },
    @{ n = 'CoinDesk'; u = 'https://www.coindesk.com/arc/outboundfeeds/rss'; k = 'cripto' }, @{ n = 'Bitcoin Magazine'; u = 'https://bitcoinmagazine.com/.rss/full/'; k = 'cripto' }, @{ n = 'BeInCrypto'; u = 'https://beincrypto.com/feed/'; k = 'cripto' },
    @{ n = 'CNBC'; u = 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=10000664'; k = 'bolsa' }, @{ n = 'CNBC'; u = 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114'; k = 'bolsa' },
    @{ n = 'MarketWatch'; u = 'https://feeds.content.dowjones.io/public/rss/mw_topstories'; k = 'bolsa' }, @{ n = 'Investing.com'; u = 'https://www.investing.com/rss/news.rss'; k = 'bolsa' },
    @{ n = 'Benzinga'; u = 'https://www.benzinga.com/feed'; k = 'bolsa' }, @{ n = 'MarketWatch'; u = 'https://feeds.content.dowjones.io/public/rss/mw_realtimeheadlines'; k = 'bolsa' }, @{ n = 'Yahoo Finance'; u = 'https://finance.yahoo.com/news/rssindex'; k = 'bolsa' },
    @{ n = 'Investing.com'; u = 'https://www.investing.com/rss/news_301.rss'; k = 'cripto' }, @{ n = 'Cinco Días'; u = 'https://feeds.elpais.com/mrss-s/pages/ep/site/cincodias.elpais.com/portada'; k = 'bolsa' },
    @{ n = 'Reserva Federal'; u = 'https://www.federalreserve.gov/feeds/press_all.xml'; k = 'macro' }, @{ n = 'SEC'; u = 'https://www.sec.gov/news/pressreleases.rss'; k = 'legal' }
)
$script:NwTopics = @(
    @{ q = 'Federal Reserve FOMC interest rates'; k = 'macro' }, @{ q = 'SEC crypto lawsuit OR ruling OR approval'; k = 'legal' }, @{ q = 'crypto bill Senate OR Congress OR regulation'; k = 'cripto' },
    @{ q = 'stablecoin law OR MiCA OR crypto regulation Europe OR Asia'; k = 'cripto' }, @{ q = 'Bitcoin ETF approval OR rejected OR delayed'; k = 'cripto' }, @{ q = 'tariffs OR trade war OR inflation stocks'; k = 'macro' },
    @{ q = 'site:reuters.com markets OR stocks OR crypto'; k = 'bolsa' }, @{ q = 'site:bloomberg.com markets OR stocks OR crypto'; k = 'bolsa' }, @{ q = 'site:wsj.com markets OR stocks'; k = 'bolsa' }, @{ q = 'site:ft.com markets OR crypto'; k = 'bolsa' },
    @{ q = 'lawsuit OR indictment OR trial OR SEC charges company stock'; k = 'legal' }, @{ q = 'exchange hack OR bankruptcy OR delisting crypto'; k = 'cripto' }
)

function Get-NwTz { foreach ($id in 'Romance Standard Time', 'Europe/Madrid') { try { return [TimeZoneInfo]::FindSystemTimeZoneById($id) } catch {} }; return [TimeZoneInfo]::Utc }
function Get-RssItems($url, $name, $kind) {
    $out = @()
    try {
        $r = Invoke-WebRequest $url -UseBasicParsing -Headers $script:NwUA -TimeoutSec 20 -MaximumRedirection 5
        $x = New-Object System.Xml.XmlDocument; $x.LoadXml($r.Content.TrimStart([char]0xFEFF))
        $nodes = @($x.SelectNodes('//*[local-name()="item"]')); if (-not $nodes.Count) { $nodes = @($x.SelectNodes('//*[local-name()="entry"]')) }
        foreach ($n in $nodes) {
            $t = $n.SelectSingleNode('*[local-name()="title"]'); if (-not $t) { continue }; $title = ("$($t.InnerText)" -replace '\s+', ' ').Trim(); if (-not $title) { continue }
            $l = $n.SelectSingleNode('*[local-name()="link"]'); $link = if ($l) { if ($l.InnerText) { $l.InnerText.Trim() } else { "$($l.GetAttribute('href'))" } } else { "" }
            $d = $n.SelectSingleNode('*[local-name()="pubDate"]'); if (-not $d) { $d = $n.SelectSingleNode('*[local-name()="published"]') }; if (-not $d) { $d = $n.SelectSingleNode('*[local-name()="updated"]') }
            $when = [DateTimeOffset]::UtcNow; if ($d) { try { $when = [DateTimeOffset]::Parse($d.InnerText, [Globalization.CultureInfo]::InvariantCulture) } catch {} }
            $src = $name; if ($name -eq 'Google News' -and $title -match '^(.*) - ([^-]{2,40})$') { $title = $Matches[1].Trim(); $src = $Matches[2].Trim() }
            $out += [pscustomobject]@{ title = $title; link = $link; when = $when; src = $src; kind = $kind }
        }
    } catch {}
    return $out
}
function Get-NewsPool {
    if ($script:NwPool -and ((Get-Date) - $script:NwPoolAt).TotalMinutes -lt 30) { return $script:NwPool }
    $all = @(); foreach ($f in $script:NwFeeds) { $all += @(Get-RssItems $f.u $f.n $f.k) }
    foreach ($t in $script:NwTopics) { $all += @(Get-RssItems ("https://news.google.com/rss/search?q=" + [uri]::EscapeDataString("$($t.q) when:2d") + "&hl=en-US&gl=US&ceid=US:en") 'Google News' $t.k) }
    $cut = [DateTimeOffset]::UtcNow.AddHours(-72); $seen = @{}; $keep = @()
    foreach ($i in ($all | Sort-Object { $_.when } -Descending)) { $k = $i.title.ToLower(); if ($seen.ContainsKey($k) -or $i.when -lt $cut) { continue }; $seen[$k] = 1; $keep += $i }
    $script:NwPool = $keep; $script:NwPoolAt = Get-Date; return $keep
}

function Get-NewsFlags($title) {
    $t = $title.ToLower(); $f = @()
    if ($t -match 'lawsuit|sues|sued|\bsue\b|trial|court|judge|ruling|indict|charged|charges|settle|probe|investigat|subpoena|fraud|class action|antitrust|\bdoj\b|justice department|fine[sd]?\b|penalt') { $f += '⚖️ legal' }
    if ($t -match '\bbill\b|\blaw\b|legislat|regulat|\bban(s|ned)?\b|senate|congress|\bmica\b|stablecoin|framework|\bsec\b|\bcftc\b|tax rule|crackdown|clarity act|genius act') { $f += '🏛️ regulación' }
    if ($t -match 'approv' -and $t -match '\bsec\b|\betf|\bfda\b|regulator|commission|congress|senate|\bbill\b|exchange|license') { $f += '🏛️ regulación' }
    if ($t -match '\bfed\b|fomc|federal reserve|rate cut|rate hike|interest rate|inflation|\bcpi\b|jobs report|payroll|powell|tariff|treasury yield|recession') { $f += '🏦 macro' }
    if ($t -match 'hack|exploit|breach|bankrupt|insolven|delist|halt(ed)?\b|default|liquidat|outage|collapse|rug pull|stolen|theft|depeg') { $f += '🔒 riesgo' }
    if ($t -match 'earnings|guidance|upgrade|downgrade|partnership|acquisition|acquire|merger|offering|dilution|buyback|etf|listing|launch|deal\b|contract') { $f += '📈 catalizador' }
    return @($f | Select-Object -Unique)
}
function Test-NwMatch($title, $tokens) { foreach ($k in $tokens) { if ($k.Length -lt 2) { continue }; if ($title -cmatch ('(?<![A-Za-z0-9])' + [regex]::Escape($k) + '(?![A-Za-z0-9])')) { return $true } }; return $false }
function Get-AgeText($when) { $h = ([DateTimeOffset]::UtcNow - $when).TotalHours; if ($h -lt 1) { return "hace <1 h" } elseif ($h -lt 48) { return ("hace {0:N0} h" -f $h) } else { return ("hace {0:N0} d" -f ($h / 24)) } }

$script:NwNames = @{ BTC = 'Bitcoin'; ETH = 'Ethereum'; SOL = 'Solana'; XRP = 'XRP'; DOGE = 'Dogecoin'; BNB = 'Binance'; ADA = 'Cardano'; AVAX = 'Avalanche'; LINK = 'Chainlink'; LTC = 'Litecoin'; LDO = 'Lido'; HYPE = 'Hyperliquid'; SUI = 'Sui'; TON = 'Toncoin' }
# Noticias de UN activo: Yahoo Finance (por ticker), Google News (por nombre/ticker) y el fondo de noticias generales filtrado por nombre/ticker
function Get-AssetNews($sym, $name, [bool]$isCrypto, [int]$hours = 72) {
    $sym = "$sym".ToUpper() -replace 'USDT$', ''; $core = ""
    if ($isCrypto -and $script:NwNames.ContainsKey($sym)) { $core = $script:NwNames[$sym] }
    elseif (-not $isCrypto -and $name) { $core = (("$name" -replace '\(.*$', '' -replace '(?i)\b(inc|corp|corporation|limited|ltd|plc|holdings|group|co|company|sa|s\.a\.|ag|nv)\b\.?', '').Trim()); if ($core.Length -lt 3) { $core = "" } }
    $tok = @($sym); if ($core) { $tok += $core }
    $items = @()
    if (-not $isCrypto) {
        $items += @(Get-RssItems ("https://feeds.finance.yahoo.com/rss/2.0/headline?s=" + [uri]::EscapeDataString($sym) + "&region=US&lang=en-US") 'Yahoo Finance' 'activo')
        if ($sym -notmatch '[.\-=^]') { $items += @(Get-RssItems ("https://www.nasdaq.com/feed/rssoutbound?symbol=" + [uri]::EscapeDataString($sym)) 'Nasdaq' 'activo'); $items += @(Get-RssItems ("https://seekingalpha.com/api/sa/combined/" + [uri]::EscapeDataString($sym) + ".xml") 'Seeking Alpha' 'activo') }
    } else {
        $items += @(Get-RssItems ("https://feeds.finance.yahoo.com/rss/2.0/headline?s=" + [uri]::EscapeDataString($sym) + "-USD&region=US&lang=en-US") 'Yahoo Finance' 'activo')
        if ($core) { $items += @(Get-RssItems ("https://cointelegraph.com/rss/tag/" + ($core.ToLower() -replace '[^a-z0-9]', '-')) 'Cointelegraph' 'activo') }
    }
    $q = if ($isCrypto) { "$sym $(if ($core) { $core } else { 'crypto token' })" } else { "`"$(if ($core) { $core } else { $sym })`" stock" }
    $items += @(Get-RssItems ("https://news.google.com/rss/search?q=" + [uri]::EscapeDataString("$q when:3d") + "&hl=en-US&gl=US&ceid=US:en") 'Google News' 'activo')
    foreach ($p in (Get-NewsPool)) { if (Test-NwMatch $p.title $tok) { $items += $p } }
    $cut = [DateTimeOffset]::UtcNow.AddHours(-$hours); $seen = @{}; $keep = @()
    foreach ($i in ($items | Sort-Object { $_.when } -Descending)) {
        $k = $i.title.ToLower(); if ($seen.ContainsKey($k) -or $i.when -lt $cut) { continue }
        # los resultados de Google News/Yahoo por activo deben mencionar el ticker o el nombre para ser relevantes
        if ($i.kind -eq 'activo' -and -not (Test-NwMatch $i.title $tok) -and -not ($core -and $i.title -match [regex]::Escape($core))) { continue }
        $seen[$k] = 1; $keep += $i
    }
    return $keep
}

# ---------- Calendario macro ----------
function Get-MacroEvents([int]$days = 8) {
    if ($script:NwEv -and ((Get-Date) - $script:NwEvAt).TotalMinutes -lt 60) { $ev = $script:NwEv } else {
        $ev = @()
        foreach ($u in 'https://nfs.faireconomy.media/ff_calendar_thisweek.json', 'https://nfs.faireconomy.media/ff_calendar_nextweek.json') {
            try { $j = Invoke-RestMethod $u -Headers $script:NwUA -TimeoutSec 20; foreach ($e in @($j)) { if ($e.impact -eq 'High' -and $e.country -in 'USD', 'All') { $ev += [pscustomobject]@{ when = [DateTimeOffset]::Parse($e.date, [Globalization.CultureInfo]::InvariantCulture); title = "$($e.title)"; country = "$($e.country)" } } } } catch {}
        }
        $script:NwEv = $ev; $script:NwEvAt = Get-Date
    }
    $now = [DateTimeOffset]::UtcNow
    return @($ev | Where-Object { $_.when -gt $now.AddHours(-2) -and $_.when -lt $now.AddDays($days) } | Sort-Object { $_.when })
}
function Get-NextFomc {                      # próxima reunión FOMC (calendario oficial de la Fed): @{ text; days } o $null
    if ($script:NwFomc -and ((Get-Date) - $script:NwFomcAt).TotalHours -lt 12) { return $script:NwFomc }
    try {
        $h = (Invoke-WebRequest 'https://www.federalreserve.gov/monetarypolicy/fomccalendars.htm' -UseBasicParsing -Headers $script:NwUA -TimeoutSec 25).Content
        $months = @{ January = 1; February = 2; March = 3; April = 4; May = 5; June = 6; July = 7; August = 8; September = 9; October = 10; November = 11; December = 12 }
        $best = $null; $today = (Get-Date).Date; $esMes = @{ January = "enero"; February = "febrero"; March = "marzo"; April = "abril"; May = "mayo"; June = "junio"; July = "julio"; August = "agosto"; September = "septiembre"; October = "octubre"; November = "noviembre"; December = "diciembre" }
        foreach ($yy in [regex]::Matches($h, '(\d{4}) FOMC Meetings')) {
            $year = [int]$yy.Groups[1].Value; $seg = $h.Substring($yy.Index, [Math]::Min(12000, $h.Length - $yy.Index)); $nx = [regex]::Match($seg.Substring(20), '\d{4} FOMC Meetings'); if ($nx.Success) { $seg = $seg.Substring(0, $nx.Index + 20) }
            foreach ($m in [regex]::Matches($seg, 'fomc-meeting__month[^>]*><strong>(\w+)</strong>.*?fomc-meeting__date[^>]*>\s*([\d\-/\*]+)\s*<', 'Singleline')) {
                if (-not $months.ContainsKey($m.Groups[1].Value)) { continue }; $mo = $months[$m.Groups[1].Value]; $days = $m.Groups[2].Value -replace '[^\d\-]', ''; $last = [int](($days -split '-')[-1])
                try { $dt = Get-Date -Year $year -Month $mo -Day $last -Hour 0 -Minute 0 -Second 0 } catch { continue }
                if ($dt.Date -ge $today -and (-not $best -or $dt -lt $best.dt)) { $best = @{ dt = $dt.Date; label = ("{0} de {1}" -f $days, $esMes[$m.Groups[1].Value]) } }
            }
        }
        if ($best) { $script:NwFomc = @{ text = "reunión del FOMC (decisión de tipos): {0} de {1} ({2})" -f $best.label, $best.dt.Year, $(if (($best.dt - $today).Days -eq 0) { "HOY" } else { "en $(($best.dt - $today).Days) días" }); days = ($best.dt - $today).Days }; $script:NwFomcAt = Get-Date; return $script:NwFomc }
    } catch {}
    return $null
}

# ---------- Sección de texto para informes y /momento ----------
function Get-NewsSection($sym, $name, [bool]$isCrypto, [switch]$Short) {
    $tz = Get-NwTz; $L = @(); $L += "📰 NOTICIAS Y CALENDARIO"
    try {
        $fo = Get-NextFomc; $ev = @(Get-MacroEvents 8)
        if ($fo) { $L += "🗓️ Próxima $($fo.text)" }
        foreach ($e in ($ev | Select-Object -First 4)) { $loc = [TimeZoneInfo]::ConvertTime($e.when, $tz); $dh = ($e.when - [DateTimeOffset]::UtcNow).TotalHours
            $L += ("🗓️ {0:dd/MM HH:mm} (hora de España) · {1} (EE. UU., impacto alto){2}" -f $loc.DateTime, $e.title, $(if ($dh -gt 0 -and $dh -lt 24) { " ⚠️ en menos de 24 h: suele dar volatilidad" } else { "" })) }
        if (-not $fo -and -not $ev.Count) { $L += "🗓️ No he podido leer el calendario macro ahora." }
    } catch { $L += "🗓️ No he podido leer el calendario macro ahora." }
    if ($Short -and -not $isCrypto) { try { $ne = Get-NextEarnings $sym; if ($ne) { $L += ("🗓️ Resultados trimestrales de {0}: {1:dd/MM/yyyy} ({2}){3}" -f $sym, $ne.date, $(if ($ne.days -ge 0) { "en $($ne.days) días" } else { "ya publicados" }), $(if ($ne.days -ge 0 -and $ne.days -le 7) { " ⚠️ cercanos: riesgo de salto de precio" } else { "" })) } } catch {} }
    $max = if ($Short) { 3 } else { 5 }
    try {
        $as = @(Get-AssetNews $sym $name $isCrypto 72)
        $fl = @($as | ForEach-Object { [pscustomobject]@{ i = $_; f = @(Get-NewsFlags $_.title) } })
        $top = @($fl | Sort-Object { $_.f.Count }, { $_.i.when } -Descending | Select-Object -First $max); $top = @($top | Sort-Object { $_.i.when } -Descending)
        if ($top.Count) { $L += "Titulares recientes de $sym (72 h):"; foreach ($t in $top) { $L += ("   • {0}{1} — {2}, {3}" -f $(if ($t.f.Count) { "[" + ($t.f -join ' · ') + "] " } else { "" }), $t.i.title, $t.i.src, (Get-AgeText $t.i.when)) } }
        else { $L += "Sin titulares recientes de $sym en las fuentes consultadas (puede ser que no haya noticias o que las fuentes no las recojan)." }
    } catch { $L += "No he podido leer titulares del activo ahora." }
    try {
        $kinds = if ($isCrypto) { 'cripto', 'legal', 'macro' } else { 'macro', 'legal' }
        $gen = @(Get-NewsPool | Where-Object { $_.kind -in $kinds -and $_.when -gt [DateTimeOffset]::UtcNow.AddHours(-36) } | ForEach-Object { [pscustomobject]@{ i = $_; f = @(Get-NewsFlags $_.title) } } | Where-Object { $_.f -match 'legal|regulación|macro' } | Select-Object -First 3)
        if ($gen.Count) { $L += "Contexto de mercado (regulación, leyes, juicios, Reserva Federal; 36 h):"; foreach ($t in $gen) { $L += ("   • [{0}] {1} — {2}, {3}" -f ($t.f -join ' · '), $t.i.title, $t.i.src, (Get-AgeText $t.i.when)) } }
    } catch {}
    $L += "   (Titulares en inglés clasificados por palabras clave: el bot NO sabe si una noticia es buena o mala para el precio. Confírmalas en la fuente. Fuentes: Yahoo Finance, Google News, CNBC, MarketWatch, medios cripto, Fed, SEC y calendario económico.)"
    return ($L -join "`n")
}

# ---------- Avisos automáticos ----------
function Send-NwMsg([bool]$toPriv, [bool]$toGroup, $text) {
    if ($toPriv) { Send-ToSignalChats $text }
    if ($toGroup -and $script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $text $null }
}
$script:NwRemAt = [datetime]::MinValue
function Send-MacroRemindersIfDue {          # aviso previo (< 26 h) de eventos macro de impacto alto de EE. UU. (FOMC, IPC, empleo...) a ambos chats; una vez por evento
    if (((Get-Date) - $script:NwRemAt).TotalMinutes -lt 30 -or -not $TelegramToken) { return }
    $script:NwRemAt = Get-Date
    $sent = @((Get-ReportState "macrord") -split ',' | Where-Object { $_ }); $tz = Get-NwTz; $new = @()
    foreach ($e in (Get-MacroEvents 2)) {
        $dh = ($e.when - [DateTimeOffset]::UtcNow).TotalHours; if ($dh -lt 0 -or $dh -gt 26) { continue }
        $key = ($e.when.ToString("yyyyMMddHH") + "-" + (($e.title -replace '[^A-Za-z0-9]', '').ToLower())); if ($key -in $sent) { continue }
        $loc = [TimeZoneInfo]::ConvertTime($e.when, $tz)
        $m = ("📅 AVISO MACRO · en ≈{0:N0} h ({1:dd/MM HH:mm}, hora de España): {2} (EE. UU., impacto alto)`nEstos eventos suelen mover bolsa y cripto con fuerza en pocos minutos. Si tienes operaciones abiertas, revisa el SL y evita abrir justo antes del dato.`nNo es una señal de operación." -f $dh, $loc.DateTime, $e.title)
        Send-NwMsg $true $true $m; $new += $key
    }
    if ($new.Count) { Set-ReportState "macrord" ((@($sent + $new) | Select-Object -Last 40) -join ',') }
}
$script:NwPosAt = 0
function Check-NewsOnPositions {             # titulares de riesgo (legal, regulación, riesgo) sobre activos con operación abierta o seguimiento, tras cada vela de 4h; una vez por titular
    if (-not $TelegramToken) { return }
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); if ($slot -eq $script:NwPosAt) { return }; $script:NwPosAt = $slot
    $done = @((Get-ReportState "noticiasw") -split ',' | Where-Object { $_ }); $add = @()
    foreach ($s in @(Read-Signals | Where-Object { $_.status -in 'open', 'pending' -and $_.strat -in 'seg-grupo', 'ruptura-mercado' })) {
        $isStock = ($s.src -eq 'yahoo'); $sym = $s.sym -replace 'USDT$', ''
        $toPriv = $false; $toGroup = ($s.strat -in 'seg-grupo', 'ruptura-mercado')
        try {
            foreach ($n in @(Get-AssetNews $sym $null (-not $isStock) 12)) {
                $fl = @(Get-NewsFlags $n.title | Where-Object { $_ -match 'legal|regulación|riesgo' }); if (-not $fl.Count) { continue }
                $h = [Math]::Abs(($sym + $n.title).GetHashCode()).ToString(); if ($h -in $done -or $h -in $add) { continue }
                $m = ("📰 NOTICIA A TENER EN CUENTA · {0} {1}`n[{2}] {3}`n{4}, {5}{6}`nEl bot no sabe si es buena o mala para el precio: revísala en la fuente y valora tu SL. Tienes una operación o seguimiento abierto en este activo." -f $sym, $(if ([int]$s.side -eq 1) { "LARGO" } else { "CORTO" }), ($fl -join ' · '), $n.title, $n.src, (Get-AgeText $n.when), $(if ($n.link) { "`n" + $n.link } else { "" }))
                Send-NwMsg $toPriv $toGroup $m; $add += $h
            }
        } catch {}
    }
    if ($add.Count) { Set-ReportState "noticiasw" ((@($done + $add) | Select-Object -Last 120) -join ',') }
}

# Barrido de titulares de riesgo (legal, regulación, riesgo) sobre CUALQUIER activo del universo: cripto de Bitunix (top por volumen) y acciones/ETFs del universo de mercado.
# Se compara el fondo general de noticias (todos los portales) con los tickers (>= 3 letras, en mayúsculas o con $) y nombres de las principales criptos. Una vez por titular; máximo 6 por barrido.
$script:NwUniAt = 0
function Scan-UniverseNews {
    if (-not $TelegramToken) { return }
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); if ($slot -eq $script:NwUniAt) { return }; $script:NwUniAt = $slot
    $done = @((Get-ReportState "noticiasu") -split ',' | Where-Object { $_ }); $add = @(); $sent = 0
    $crypto = @{}; try { foreach ($t in @((Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 150)) { $b = $t.symbol -replace 'USDT$', ''; if ($b.Length -ge 3 -and $b -cmatch '^[A-Z0-9]+$') { $crypto[$b] = 1 } } } catch {}
    $stocks = @{}; if ($script:UniTodos) { foreach ($u in $script:UniTodos) { if ($u.Length -ge 3 -and $u -cmatch '^[A-Z]+$') { $stocks[$u] = 1 } } }
    $cut = [DateTimeOffset]::UtcNow.AddHours(-8); $seenDK = @()
    foreach ($p in (Get-NewsPool)) {
        if ($sent -ge 6) { break }; if ($p.when -lt $cut) { continue }
        $fl = @(Get-NewsFlags $p.title | Where-Object { $_ -match 'legal|regulación|riesgo' }); if (-not $fl.Count) { continue }
        $hit = $null; $isC = $false
        foreach ($w in ([regex]::Matches($p.title, '(?<![A-Za-z0-9])\$?([A-Z][A-Z0-9]{2,9})(?![A-Za-z0-9])') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique)) {
            if ($crypto.ContainsKey($w) -and ($p.kind -eq 'cripto' -or $p.title -match '(?i)crypto|token|coin|blockchain|exchange')) { $hit = $w; $isC = $true; break }
            if ($stocks.ContainsKey($w) -and $p.kind -ne 'cripto') { $hit = $w; break }
        }
        if (-not $hit) { foreach ($k in $script:NwNames.Keys) { if (($crypto.ContainsKey($k) -or $k -in 'BTC', 'ETH') -and $p.title -match ('(?i)\b' + [regex]::Escape($script:NwNames[$k]) + '\b')) { $hit = $k; $isC = $true; break } } }
        if (-not $hit) { continue }
        $dk = "$hit|$($fl[0])"; if ($dk -in $seenDK) { continue }      # misma historia en varios portales: un solo aviso por activo y tipo
        $h = [Math]::Abs(($hit + $p.title).GetHashCode()).ToString(); if ($h -in $done -or $h -in $add) { continue }
        $seenDK += $dk
        $m = ("📰 NOTICIA RELEVANTE · {0}`n[{1}] {2}`n{3}, {4}{5}`nEl bot no sabe si es buena o mala para el precio: revísala en la fuente. Si hay operación abierta en este activo, valora el SL." -f $hit, ($fl -join ' · '), $p.title, $p.src, (Get-AgeText $p.when), $(if ($p.link) { "`n" + $p.link } else { "" }))
        Send-NwMsg $false $true $m; $add += $h; $sent++
    }
    if ($add.Count) { Set-ReportState "noticiasu" ((@($done + $add) | Select-Object -Last 150) -join ',') }
}