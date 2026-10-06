# Traducción al castellano de titulares y eventos macro que llegan en inglés. Sin IA ni claves: traductor web gratuito (Google; respaldo MyMemory) + VERIFICACIÓN antes de publicar:
# todas las cifras y las siglas/tickers del original deben aparecer en la traducción; si algo no cuadra o el traductor falla, se publica el original en inglés marcado, nunca una traducción dudosa.
# Los titulares traducidos llevan el original al lado para que se pueda comprobar. Los eventos macro usan un diccionario fijo (traducción exacta, sin traducción automática).
$script:TrCache = @{}
$script:MacroEs = [ordered]@{
    'Federal Funds Rate' = 'Tipos de interés de la Fed (decisión)'; 'FOMC Statement' = 'Comunicado del FOMC (Fed)'; 'FOMC Press Conference' = 'Rueda de prensa del FOMC (Fed)'; 'FOMC Meeting Minutes' = 'Actas de la reunión del FOMC (Fed)'
    'Non-Farm Employment Change' = 'Empleo no agrícola (NFP)'; 'ADP Non-Farm Employment Change' = 'Empleo no agrícola ADP'; 'Unemployment Rate' = 'Tasa de paro'; 'Unemployment Claims' = 'Solicitudes semanales de subsidio por desempleo'
    'Core CPI m/m' = 'IPC subyacente (mensual)'; 'CPI m/m' = 'IPC (mensual)'; 'CPI y/y' = 'IPC (interanual)'; 'Core PCE Price Index m/m' = 'Índice de precios PCE subyacente (mensual)'; 'PPI m/m' = 'IPP (mensual)'; 'Core PPI m/m' = 'IPP subyacente (mensual)'
    'Advance GDP q/q' = 'PIB avance (trimestral)'; 'Prelim GDP q/q' = 'PIB preliminar (trimestral)'; 'Final GDP q/q' = 'PIB final (trimestral)'; 'Retail Sales m/m' = 'Ventas minoristas (mensual)'; 'Core Retail Sales m/m' = 'Ventas minoristas subyacentes (mensual)'
    'ISM Manufacturing PMI' = 'PMI manufacturero ISM'; 'ISM Services PMI' = 'PMI de servicios ISM'; 'JOLTS Job Openings' = 'Ofertas de empleo JOLTS'; 'Crude Oil Inventories' = 'Inventarios de crudo'
    'Prelim UoM Consumer Sentiment' = 'Confianza del consumidor Universidad de Michigan (preliminar)'; 'Fed Chair Powell Speaks' = 'Intervención del presidente de la Fed, Powell'; 'Treasury Currency Report' = 'Informe de divisas del Tesoro de EE. UU.'
}
function Test-LooksSpanish([string]$t) { return (($t -match '[áéíóúñ¿¡]') -or (($t -match '(?i)\b(el|la|los|las|del|que|para|con|por|una|y)\b') -and ($t -notmatch '(?i)\b(the|of|and|to|in|for|on|with|is|are|as|at|by)\b'))) }
function Test-TranslationFaithful([string]$src, [string]$dst) {
    $srcN = $src -replace '(?<![A-Za-z0-9])Q[1-4](?![A-Za-z0-9])', ' '      # "Q3" se comprueba aparte (puede salir como "tercer trimestre")
    foreach ($n in [regex]::Matches($srcN, '\d+(?:[.,]\d+)?')) { $d = ($n.Value -replace '[.,]', ''); if (($dst -replace '[.,]', '') -notmatch ('(?<!\d)' + [regex]::Escape($d) + '(?!\d)')) { return $false } }
    foreach ($w in [regex]::Matches($src, '(?<![A-Za-z0-9])\$?[A-Z][A-Z0-9]{1,9}(?![A-Za-z0-9])')) { $v = $w.Value.TrimStart('$'); if ($v -match '^Q([1-4])$') { if ($dst -match ('(?i)trimestre|(?<![A-Za-z0-9])T' + $Matches[1] + '(?![A-Za-z0-9])|(?<![A-Za-z0-9])Q' + $Matches[1] + '(?![A-Za-z0-9])')) { continue } else { return $false } }; if ($dst -cnotmatch ('(?<![A-Za-z0-9])' + [regex]::Escape($v) + '(?![A-Za-z0-9])')) { return $false } }
    return $true
}
function Invoke-GoogleTr([string]$t) {
    try {
        $u = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=es&dt=t&q=" + [uri]::EscapeDataString($t)
        $r = Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 15; $raw = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
        $lang = [regex]::Match($raw, ',"([a-z\-]{2,7})",(?:null|\d)').Groups[1].Value; $out = ""
        $cut = $raw.IndexOf(']],null,'); $segs = if ($cut -gt 0) { $raw.Substring(0, $cut) } else { $raw }      # solo la lista de frases traducidas (lo que viene después son metadatos, p. ej. un código hash)
        foreach ($m in [regex]::Matches($segs, '\["((?:[^"\\]|\\.)*)","((?:[^"\\]|\\.)*)",(?:null|\d)')) { $out += ("""" + $m.Groups[1].Value + """" | ConvertFrom-Json) }
        if (-not $out) { return $null }; return @{ text = $out; lang = $lang }
    } catch { return $null }
}
function Invoke-MyMemoryTr([string]$t) {
    try { $j = Invoke-RestMethod ("https://api.mymemory.translated.net/get?langpair=en|es&q=" + [uri]::EscapeDataString($t)) -TimeoutSec 15; $x = "$($j.responseData.translatedText)"; if ($x -and $j.responseStatus -eq 200 -and $x -notmatch 'MYMEMORY WARNING') { return @{ text = $x; lang = 'en' } } } catch {}
    return $null
}
# Vocabulario financiero (castellano de España): correcciones de errores habituales del traductor automático y casos en los que NO se publica la traducción porque suele ser incorrecta.
$script:TrFix = @(
    @('(?i)\bminutas de la (Fed|FOMC|Reserva Federal)\b', 'actas de la $1'), @('(?i)\bminutas del (FOMC|BCE|Banco Central)\b', 'actas del $1'), @('(?i)\brendimientos de los bonos\b', 'rentabilidades de los bonos'), @('(?i)\brendimiento de los bonos\b', 'rentabilidad de los bonos'), @('(?i)\bminutos de la (Fed|FOMC|Reserva Federal)\b', 'actas de la $1'), @('(?i)\bminutos del (FOMC|BCE|Banco Central)\b', 'actas del $1')
    @('(?i)\brecortes? de tasas?\b', 'recortes de tipos'), @('(?i)\bsubidas? de tasas?\b', 'subida de tipos'), @('(?i)\btasas de interés\b', 'tipos de interés'), @('(?i)\btasa de interés\b', 'tipo de interés')
    @('(?i)\bla Reserva Federal de EE\. UU\.\b', 'la Reserva Federal'), @('\bacciones de la empresa\b', 'acciones de la compañía')
)
$script:TrRisky = @(      # @(regex en el original, regex que NO debe aparecer en la traducción, o $null si basta con que aparezca el español esperado, regex del español esperado)
    @('(?i)\bbid\b', '(?i)\boferta\b', $null), @('(?i)\bsuit\b', $null, '(?i)demanda|pleito|litigio|juicio'), @('(?i)\bsettles?\b', $null, '(?i)acuerd|llega|pacta|zanja|resuelve|concilia'), @('(?i)\bshort squeeze\b', $null, '(?i)squeeze|cobertura|liquidaci')
    @('(?i)\beasing\b', $null, '(?i)flexibiliz|relajaci|recorte|bajada|rebaja|est[ií]mulo'), @('(?i)\btightening\b', $null, '(?i)endurec|restricci|subida|ajuste'), @('(?i)\bpare\b', $null, '(?i)reduc|recort|rebaj|moder'), @('(?i)\bslide[sd]?\b', $null, '(?i)ca[ey]|desliz|baj|retroced|descien|pierd|desplom|hund')
    @('(?i)\bcrackdown\b', $null, '(?i)represi|ofensiva|mano dura|endurec|actuaci|medidas'), @('(?i)\bhalts?\b', $null, '(?i)suspend|paraliz|detien|interrump|frena|detiene|paraliza')
)
function Test-RiskyTerms([string]$src, [string]$dst) {      # $true si la traducción es aceptable respecto a los términos que suelen traducirse mal
    foreach ($r in $script:TrRisky) { if ($src -match $r[0]) { if ($r[1] -and $dst -match $r[1]) { return $false }; if ($r[2] -and $dst -notmatch $r[2]) { return $false } } }
    return $true
}
function Translate-Es([string]$t) {      # devuelve el texto en castellano verificado, o $null si no se pudo traducir con garantías
    $t = "$t".Trim(); if (-not $t) { return $null }; if ($script:TrCache.ContainsKey($t)) { return $script:TrCache[$t] }
    $res = $null
    if (Test-LooksSpanish $t) { $res = $t }
    else { foreach ($fn in 'Invoke-GoogleTr', 'Invoke-MyMemoryTr') { $r = & $fn $t; if ($r -and $r.text) { if ($r.lang -eq 'es') { $res = $t; break }
        $x = $r.text.Trim(); foreach ($f in $script:TrFix) { $x = [regex]::Replace($x, $f[0], $f[1]) }
        if ((Test-TranslationFaithful $t $x) -and (Test-RiskyTerms $t $x)) { $res = $x; break } } } }
    $script:TrCache[$t] = $res; return $res
}
function Format-NwTitle([string]$t, [switch]$Block) {      # titular para publicar: traducción verificada + original; si no se puede garantizar, el original marcado como "en inglés"
    $es = Translate-Es $t
    if ($null -eq $es) { return ("{0} (en inglés: no he podido traducirlo con garantías)" -f $t) }
    if ($es -eq $t) { return $t }
    if ($Block) { return ("{0}`n(traducción automática; original: {1})" -f $es, $t) } else { return ("{0} (traducción automática; orig.: {1})" -f $es, $t) }
}
function Format-MacroTitle([string]$t) {      # eventos macro de EE. UU.: diccionario fijo; lo que no esté, traducción verificada o el original
    $k = "$t".Trim(); foreach ($e in $script:MacroEs.GetEnumerator()) { if ($k -ieq $e.Key) { return ("{0} ({1})" -f $e.Value, $k) } }
    $es = Translate-Es $k; if ($es -and $es -ne $k) { return ("{0} (traducción automática; orig.: {1})" -f $es, $k) }; return $k
}
