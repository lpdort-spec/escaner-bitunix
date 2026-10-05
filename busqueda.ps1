# Búsqueda de activos por NOMBRE o ISIN (además del símbolo): "Inditex", "Banco Santander", "Apple", "ES0148396007", "US0378331005"...
# Usa el buscador público de Yahoo Finance (acciones y ETFs de EE. UU. y Europa, índices, materias primas, divisas, bonos y cripto). Siempre dice qué activo ha entendido y qué otras coincidencias había.
# Elige la cotización PRINCIPAL: descarta mercados secundarios (Neo, Berlín, Hamburgo, Tradegate, OTC, México...) y prefiere el mercado natural según la forma jurídica (S.A. -> Madrid/París, N.V. -> Ámsterdam, AG -> Xetra/Suiza, plc -> Londres, Inc./Corp. -> EE. UU.).
$script:LegalRx = '(?i)[,\s]+(inc\.?|corp\.?|corporation|incorporated|limited|ltd\.?|plc|ag|se|s\.?a\.?|n\.?v\.?|s\.?p\.?a\.?|holdings?|group|co\.?|company|oyj|ab|asa|a/s)\b\.?'
function Get-NameCore($n) { $x = "$n"; for ($i = 0; $i -lt 3; $i++) { $x = $x -replace ($script:LegalRx + '\s*$'), '' }; return $x.Trim() }
function Select-MainListing($cands, $query) {
    $minorSym = '\.(NE|TI|HM|BE|SG|F|DU|MU|VI|MX|BA|SA|PK|OB|CN|NS|BO|TO|V|AX|KL|WA|PR|BD|IS|JK|SW2)$'
    $c = @($cands | Where-Object { $_.symbol -notmatch $minorSym -and "$($_.exchDisp)" -notmatch 'OTC|OID|Pink|PNK' }); if (-not $c.Count) { $c = @($cands) }
    # 1) mejor coincidencia de nombre: "Siemens" -> "Siemens AG" antes que "Siemens Energy AG"
    $q = "$query".Trim().ToLower()
    $best = @($c | Where-Object { (Get-NameCore $_.longname).ToLower() -eq $q -or (Get-NameCore $_.shortname).ToLower() -eq $q }); if ($best.Count) { $c = $best }
    $nm = "$($c[0].longname) $($c[0].shortname)"
    $pref = if ($nm -match 'S\.?A\.?\b|SOCIEDAD') { @('.MC', '.PA', '.LS', '.BR') } elseif ($nm -match 'N\.?V\.?\b') { @('.AS', '.PA', '.BR') } elseif ($nm -match '\bAG\b') { @('.DE', '.SW') } elseif ($nm -match '\bSE\b') { @('.DE', '.PA') } elseif ($nm -match 'S\.?p\.?A') { @('.MI') } elseif ($nm -match '(?i)\bplc\b') { @('.L') } elseif ($nm -match '(?i)\b(inc|corp|corporation|incorporated|holdings)\b') { @('') } else { @() }
    foreach ($suf in $pref) {
        foreach ($x in $c) {
            if ($suf -eq '') { if ($x.symbol -notmatch '\.') { return $x } } elseif ($x.symbol -like "*$suf") { return $x }
        }
    }
    return @{ pick = $c[0]; pref = $pref; name = "$($c[0].longname)" }
}
# Nombres habituales del IBEX 35 (el buscador no siempre devuelve la cotización de Madrid)
$script:AliasIbex = @{ 'inditex' = 'ITX.MC'; 'santander' = 'SAN.MC'; 'banco santander' = 'SAN.MC'; 'bbva' = 'BBVA.MC'; 'telefonica' = 'TEF.MC'; 'iberdrola' = 'IBE.MC'; 'repsol' = 'REP.MC'; 'caixabank' = 'CABK.MC'; 'naturgy' = 'NTGY.MC'; 'amadeus' = 'AMS.MC'; 'ferrovial' = 'FER.MC'; 'cellnex' = 'CLNX.MC'
    'acciona' = 'ANA.MC'; 'acciona energia' = 'ANE.MC'; 'aena' = 'AENA.MC'; 'endesa' = 'ELE.MC'; 'red electrica' = 'RED.MC'; 'redeia' = 'RED.MC'; 'sabadell' = 'SAB.MC'; 'banco sabadell' = 'SAB.MC'; 'bankinter' = 'BKT.MC'; 'mapfre' = 'MAP.MC'; 'grifols' = 'GRF.MC'; 'arcelormittal' = 'MTS.MC'
    'indra' = 'IDR.MC'; 'merlin' = 'MRL.MC'; 'merlin properties' = 'MRL.MC'; 'colonial' = 'COL.MC'; 'fluidra' = 'FDR.MC'; 'logista' = 'LOG.MC'; 'solaria' = 'SLR.MC'; 'rovi' = 'ROVI.MC'; 'enagas' = 'ENG.MC'; 'unicaja' = 'UNI.MC'; 'iag' = 'IAG.MC'; 'melia' = 'MEL.MC'; 'sacyr' = 'SCYR.MC'; 'pharma mar' = 'PHM.MC'; 'ibex' = '^IBEX'; 'ibex 35' = '^IBEX' }
function Remove-Accents($s) { $n = "$s".Normalize([Text.NormalizationForm]::FormD); return (($n.ToCharArray() | Where-Object { [Globalization.CharUnicodeInfo]::GetUnicodeCategory($_) -ne 'NonSpacingMark' }) -join '') }
function Resolve-SymbolText($text, [switch]$Force) {
    $t = "$text".Trim(); $res = @{ sym = $t.ToUpper(); note = $null }
    if (-not $t) { return $res }
    $al = (Remove-Accents $t).ToLower().Trim(); if ($script:AliasIbex.ContainsKey($al)) { $res.sym = $script:AliasIbex[$al]; $res.note = "🔎 He interpretado «$t» como $($res.sym) (cotización en la Bolsa de Madrid)."; return $res }
    $isIsin = ($t.ToUpper() -match '^[A-Z]{2}[A-Z0-9]{9}[0-9]$')
    $plain = ($t -match '^[A-Za-z0-9.\-\^=]{1,12}$') -and -not $isIsin
    $nameLike = $plain -and ($t -cmatch '[a-z]') -and ($t -match '^[A-Za-z]{4,}$')        # una sola palabra con minúsculas ("Apple", "tesla"): puede ser un nombre
    if ($plain -and -not $nameLike -and -not $Force) { return $res }
    $hdr = @{ 'User-Agent' = 'Mozilla/5.0' }; $types = 'EQUITY', 'ETF', 'INDEX', 'MUTUALFUND', 'CRYPTOCURRENCY', 'CURRENCY', 'FUTURE'
    try {
        $j = Invoke-RestMethod ("https://query2.finance.yahoo.com/v1/finance/search?q=" + [uri]::EscapeDataString($t) + "&quotesCount=12&newsCount=0&listsCount=0") -Headers $hdr -TimeoutSec 20
        $c = @($j.quotes | Where-Object { $_.symbol -and $_.quoteType -in $types })
        if (-not $c.Count) { return $res }
        if ($nameLike -and -not $Force) {
            if (@($c | Where-Object { $_.symbol -eq $t.ToUpper() }).Count) { return $res }
            $c = @($c | Where-Object { ("$($_.longname)" -match "^(?i)$([regex]::Escape($t))") -or ("$($_.shortname)" -match "^(?i)$([regex]::Escape($t))") }); if (-not $c.Count) { return $res }
        }
        $pick = $null
        if ($Force) { $ex = @($c | Where-Object { $_.symbol -eq $t.ToUpper() -or $_.symbol -eq ($t.ToUpper() + '-USD') }); if ($ex.Count) { $pick = $ex[0] } }
        if (-not $pick) {
            $sel = Select-MainListing $c $t
            if ($sel -is [hashtable]) {
                $pick = $sel.pick
                if ($sel.pref.Count -and $sel.name) {      # el mercado natural no salía en la primera búsqueda: se busca por el nombre completo
                    try { $j2 = Invoke-RestMethod ("https://query2.finance.yahoo.com/v1/finance/search?q=" + [uri]::EscapeDataString($sel.name) + "&quotesCount=12&newsCount=0&listsCount=0") -Headers $hdr -TimeoutSec 20
                          $c2 = @($j2.quotes | Where-Object { $_.symbol -and $_.quoteType -in $types -and "$($_.longname)" -eq $sel.name }); if ($c2.Count) { $sel2 = Select-MainListing $c2 $sel.name; $pick = if ($sel2 -is [hashtable]) { $sel2.pick } else { $sel2 }; $c = @($c + $c2 | Sort-Object symbol -Unique) } } catch {}
                }
            } else { $pick = $sel }
        }
        $nm = if ($pick.longname) { $pick.longname } elseif ($pick.shortname) { $pick.shortname } else { $pick.symbol }
        $others = @($c | Where-Object { $_.symbol -ne $pick.symbol } | Select-Object -First 3 | ForEach-Object { "$($_.symbol)" }) -join ", "
        $res.sym = "$($pick.symbol)".ToUpper()
        $res.note = "🔎 He interpretado «$t» como $nm ($($pick.symbol), $($pick.exchDisp), $($pick.typeDisp))." + $(if ($others) { " Otras coincidencias: $others (pídelas con su símbolo si buscabas otra)." } else { "" })
    } catch {}
    return $res
}
function Get-QueryWords($words, [string[]]$keywords) {      # separa el texto del activo de las palabras clave finales (accion, cripto, largo, corto...)
    $w = @($words); $kw = @()
    while ($w.Count -gt 1 -and $w[-1].ToLower() -in $keywords) { $kw = @($w[-1].ToLower()) + $kw; $w = @($w[0..($w.Count - 2)]) }
    return @{ text = ($w -join ' '); kw = $kw }
}
