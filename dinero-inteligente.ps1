# "Qué hacen los mejores traders": datos AGREGADOS y oficiales de Binance Futures (API pública, sin claves): posiciones de los mejores traders (largo/corto), todos los traders, volumen comprador vs vendedor agresivo,
# interés abierto y funding. No son operaciones individuales ni copy trading: es una lectura de posicionamiento (FOMO/FUD) para dar contexto. Si Binance no responde (p. ej. bloqueo regional), la sección se omite sin error.
# Es una lectura de CONTEXTO: no está validada en backtest todavía (Binance solo conserva ~30 días de este histórico).
function Get-FlatArr($a) { foreach ($i in @($a)) { if ($i -is [System.Array]) { Get-FlatArr $i } elseif ($null -ne $i) { $i } } }      # PowerShell 5.1 devuelve el array JSON como UN objeto: se aplana
function Get-BinanceFut($path) { try { return @(Get-FlatArr (Invoke-RestMethod ("https://fapi.binance.com" + $path) -TimeoutSec 15)) } catch { return @() } }
function ConvertTo-LongPct($ratio) { $r = [double]$ratio; if ($r -le 0) { return $null }; return ($r / (1 + $r) * 100) }
function Get-MultiExchangeData($base) {      # % en largo de los mejores traders y de la masa en OKX, Bybit y Gate.io (APIs públicas oficiales); lo que no responda se omite
    $res = @{ top = [ordered]@{}; crowd = [ordered]@{} }
    try { $r = Invoke-RestMethod "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-position-ratio-contract-top-trader?instId=$base-USDT-SWAP&period=1H" -TimeoutSec 15; if ($r.code -eq '0' -and $r.data.Count) { $v = ConvertTo-LongPct $r.data[0][1]; if ($null -ne $v) { $res.top['OKX'] = $v } } } catch {}
    try { $r = Invoke-RestMethod "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-account-ratio?ccy=$base&period=1H" -TimeoutSec 15; if ($r.code -eq '0' -and $r.data.Count) { $v = ConvertTo-LongPct $r.data[0][1]; if ($null -ne $v) { $res.crowd['OKX'] = $v } } } catch {}
    try { $r = Invoke-RestMethod "https://api.bybit.com/v5/market/account-ratio?category=linear&symbol=${base}USDT&period=1h&limit=1" -TimeoutSec 15; if ($r.retCode -eq 0 -and @($r.result.list).Count) { $res.crowd['Bybit'] = [double]@($r.result.list)[0].buyRatio * 100 } } catch {}
    try { $r = @(Get-FlatArr (Invoke-RestMethod "https://api.gateio.ws/api/v4/futures/usdt/contract_stats?contract=${base}_USDT&interval=1h&limit=3" -TimeoutSec 15)); if ($r.Count) { $g = ($r | Sort-Object { [long]$_.time } | Select-Object -Last 1)
        if ($g.top_lsr_size) { $v = ConvertTo-LongPct $g.top_lsr_size; if ($null -ne $v) { $res.top['Gate.io'] = $v } }; if ($g.lsr_account) { $v = ConvertTo-LongPct $g.lsr_account; if ($null -ne $v) { $res.crowd['Gate.io'] = $v } } } } catch {}
    return $res
}
function Get-SmartMoneyLines($sym) {
    $s = ("$sym" -replace 'USDT$', '') + "USDT"; $L = @()
    $bs = ("$sym" -replace 'USDT$', ''); $md = $null; try { $md = Get-MultiExchangeData $bs } catch {}
    $extra = @(); if ($md) {
        $tops = @($md.top.GetEnumerator()); $crw = @($md.crowd.GetEnumerator())
        if ($tops.Count) { $extra += ("   Otros exchanges · mejores traders (largo): " + (($tops | ForEach-Object { "{0} {1:N0}%" -f $_.Key, $_.Value }) -join ' · ')) }
        if ($crw.Count) { $extra += ("   Otros exchanges · masa de traders (largo): " + (($crw | ForEach-Object { "{0} {1:N0}%" -f $_.Key, $_.Value }) -join ' · ')) } }
    $script:SmartExtra = $extra; $script:SmartTops = $(if ($md) { @($md.top.Values) } else { @() })
    $top = @(Get-BinanceFut "/futures/data/topLongShortPositionRatio?symbol=$s&period=1h&limit=12"); $all = @(Get-BinanceFut "/futures/data/globalLongShortAccountRatio?symbol=$s&period=1h&limit=12")
    $tk = @(Get-BinanceFut "/futures/data/takerlongshortRatio?symbol=$s&period=1h&limit=6"); $oi = @(Get-BinanceFut "/futures/data/openInterestHist?symbol=$s&period=1h&limit=12")
    if (-not $top.Count -or -not $all.Count) {
        if ($extra.Count) { return @("🐋 Qué hacen los mejores traders (datos agregados; esta moneda no está en Binance Futures):") + $extra + @("   (Datos oficiales de OKX, Bybit y Gate.io; es contexto, no una señal validada.)") }
        return @() }
    $t0 = [double]$top[-1].longAccount * 100; $t1 = [double]$top[0].longAccount * 100; $a0 = [double]$all[-1].longAccount * 100
    $L += ("🐋 Qué hacen los mejores traders (Binance, datos agregados): {0:N0}% de sus posiciones en LARGO ({1:+0;-0} pts en 12 h) frente a {2:N0}% de la masa de traders" -f $t0, ($t0 - $t1), $a0)
    $dv = $t0 - $a0
    if ($dv -ge 8) { $L += "   → Los mejores traders están claramente más largos que la masa: sesgo alcista de los que más saben." } elseif ($dv -le -8) { $L += "   → Los mejores traders están claramente más cortos que la masa: sesgo bajista de los que más saben." } else { $L += "   → Mejores traders y masa van alineados: sin señal de divergencia." }
    if ($a0 -ge 62) { $L += "   ⚠️ FOMO: la masa está muy larga ($([int]$a0)%); históricamente un exceso así deja el mercado expuesto a barridos de largos." } elseif ($a0 -le 38) { $L += "   ⚠️ FUD: la masa está muy corta ($([int]$a0)% largos); suele dar pie a rebotes bruscos (short squeeze)." }
    if ($tk.Count) { $tr = ($tk | Select-Object -Last 6 | ForEach-Object { [double]$_.buySellRatio } | Measure-Object -Average).Average; $L += ("   Volumen agresivo últimas 6 h: compradores/vendedores = {0:N2} ({1})" -f $tr, $(if ($tr -ge 1.1) { "predominan compradores" } elseif ($tr -le 0.9) { "predominan vendedores" } else { "equilibrado" })) }
    if ($oi.Count -ge 2) { $o0 = [double]$oi[-1].sumOpenInterestValue; $o1 = [double]$oi[0].sumOpenInterestValue; if ($o1 -gt 0) { $L += ("   Interés abierto 12 h: {0:+0.0;-0.0}% ({1})" -f (($o0 / $o1 - 1) * 100), $(if ($o0 -gt $o1 * 1.03) { "entra dinero nuevo" } elseif ($o0 -lt $o1 * 0.97) { "se cierran posiciones" } else { "estable" })) } }
    $L += $extra
    $allTops = @([double]$t0) + @($script:SmartTops); if ($allTops.Count -ge 2) { $avg = ($allTops | Measure-Object -Average).Average; $nL = @($allTops | Where-Object { $_ -ge 55 }).Count; $nS = @($allTops | Where-Object { $_ -le 45 }).Count
        $L += ("   ➜ Consenso de los mejores traders ({0} exchanges): {1:N0}% en largo de media · {2} apuntan al largo, {3} al corto, {4} neutros" -f $allTops.Count, $avg, $nL, $nS, ($allTops.Count - $nL - $nS)) }
    $L += "   (Datos oficiales y públicos de Binance, OKX, Bybit y Gate.io; es contexto, no una señal validada.)"
    return $L
}
