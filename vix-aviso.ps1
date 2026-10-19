# Aviso automático SOLO para el grupo Alertas Mercados: el VIX (índice de volatilidad del S&P 500, Yahoo ^VIX) SOBREPASA o PIERDE el nivel 19.
# Se mira cada 5 minutos; el estado (encima/debajo del 19) se guarda en last-report.txt (clave 'vix'); la primera vez solo se guarda sin avisar. Entre dos avisos pasan al menos 30 minutos para no repetirse si el VIX oscila justo en 19.
$script:VixLevel = 19.0; $script:VixChk = $null
function Get-VixQuote {
    try {
        $ua = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36' }
        $r = (Invoke-RestMethod "https://query1.finance.yahoo.com/v8/finance/chart/%5EVIX?range=5d&interval=5m" -Headers $ua -TimeoutSec 25).chart.result[0]; $m = $r.meta
        $px = [double]$m.regularMarketPrice; $prev = [double]$m.chartPreviousClose; if ($px -le 0) { return $null }
        $q = $r.indicators.quote[0]; $hi = $null; $lo = $null; $day = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.regularMarketTime).UtcDateTime.Date
        $hs = @(); $ls = @(); $pc = 0.0      # chartPreviousClose es el cierre ANTERIOR al rango de 5 días: el cierre previo se toma de la última vela del día anterior
        for ($i = 0; $i -lt $r.timestamp.Count; $i++) { $d0 = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.timestamp[$i]).UtcDateTime.Date
            if ($d0 -eq $day -and $null -ne $q.high[$i] -and $null -ne $q.low[$i]) { $hs += [double]$q.high[$i]; $ls += [double]$q.low[$i] } elseif ($d0 -lt $day -and $null -ne $q.close[$i]) { $pc = [double]$q.close[$i] } }
        if ($pc -gt 0) { $prev = $pc }
        if ($hs.Count) { $hi = ($hs | Measure-Object -Maximum).Maximum; $lo = ($ls | Measure-Object -Minimum).Minimum }
        return @{ px = $px; prev = $prev; chg = $(if ($prev -gt 0) { ($px / $prev - 1) * 100 } else { 0.0 }); hi = $hi; lo = $lo }
    } catch { return $null }
}
function Build-VixMessage([string]$kind, $q, [bool]$example = $false) {      # kind: 'up' (sobrepasa) o 'down' (pierde)
    $lv = $script:VixLevel; $L = @()
    if ($example) { $L += "🧪 EJEMPLO DE AVISO (no es un aviso real: así se verá cuando ocurra)"; $L += "" }
    if ($kind -eq 'up') { $L += ("🔺 EL VIX SOBREPASA LOS {0:N0} · {1:N2} ({2:+0.0;-0.0}% hoy)" -f $lv, $q.px, $q.chg) } else { $L += ("🔻 EL VIX PIERDE LOS {0:N0} · {1:N2} ({2:+0.0;-0.0}% hoy)" -f $lv, $q.px, $q.chg) }
    $L += ("Cierre anterior {0:N2}{1}" -f $q.prev, $(if ($null -ne $q.hi) { " · rango de hoy {0:N2} - {1:N2}" -f $q.lo, $q.hi } else { "" }))
    if ($kind -eq 'up') { $L += "El índice de volatilidad del S&P 500 (el 'índice del miedo') pasa a la zona de volatilidad más alta: el mercado descuenta movimientos más bruscos en las próximas semanas. Suele acompañar a caídas o incertidumbre en la bolsa de EE. UU., y las señales de acciones y cripto pueden fallar más o moverse más rápido: conviene vigilar el tamaño de las posiciones y los SL." }
    else { $L += "El índice de volatilidad del S&P 500 vuelve a la zona de menor volatilidad: el mercado se calma y descuenta movimientos más suaves. Una vuelta por debajo de este nivel no garantiza que la tensión haya terminado: puede volver a cruzarlo." }
    $L += "Referencia habitual: por debajo de ~15 se considera calma; entre 15 y 20, normal; por encima de 20-25, tensión; por encima de 30, miedo fuerte."
    $L += ""; $L += "ℹ️ Aviso informativo de contexto del mercado, no es una señal de compra o venta ni asesoramiento financiero. Fuente: Yahoo Finance (^VIX), puede llevar algún minuto de retraso."
    return ($L -join "`n")
}
function Run-VixAlertIfDue {
    if (-not ($script:MktChat -and $TelegramToken)) { return }
    if ($script:VixChk -and ((Get-Date) - $script:VixChk).TotalSeconds -lt 300) { return }; $script:VixChk = Get-Date
    $q = Get-VixQuote; if (-not $q) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $cur = if ($q.px -gt $script:VixLevel) { 'above' } else { 'below' }
    $st = Get-ReportState 'vix'; $prev = $null; $last = 0L; if ($st -match '^(above|below)\|(\d+)$') { $prev = $Matches[1]; $last = [long]$Matches[2] }
    if (-not $prev) { Set-ReportState 'vix' ("{0}|{1}" -f $cur, 0); return }      # primera vez: solo se guarda el estado
    if ($cur -eq $prev) { return }
    if (($now - $last) -lt 1800) { return }      # al menos 30 min entre avisos (el estado no cambia hasta avisar)
    Send-Tg $TelegramToken $script:MktChat (Build-VixMessage $(if ($cur -eq 'above') { 'up' } else { 'down' }) $q) $null
    Set-ReportState 'vix' ("{0}|{1}" -f $cur, $now)
}
