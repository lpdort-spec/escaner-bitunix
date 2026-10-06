# "Qué hacen los mejores traders": datos AGREGADOS y oficiales de Binance Futures (API pública, sin claves): posiciones de los mejores traders (largo/corto), todos los traders, volumen comprador vs vendedor agresivo,
# interés abierto y funding. No son operaciones individuales ni copy trading: es una lectura de posicionamiento (FOMO/FUD) para dar contexto. Si Binance no responde (p. ej. bloqueo regional), la sección se omite sin error.
# Es una lectura de CONTEXTO: no está validada en backtest todavía (Binance solo conserva ~30 días de este histórico).
function Get-FlatArr($a) { foreach ($i in @($a)) { if ($i -is [System.Array]) { Get-FlatArr $i } elseif ($null -ne $i) { $i } } }      # PowerShell 5.1 devuelve el array JSON como UN objeto: se aplana
function Get-BinanceFut($path) { try { return @(Get-FlatArr (Invoke-RestMethod ("https://fapi.binance.com" + $path) -TimeoutSec 15)) } catch { return @() } }
function Get-SmartMoneyLines($sym) {
    $s = ("$sym" -replace 'USDT$', '') + "USDT"; $L = @()
    $top = @(Get-BinanceFut "/futures/data/topLongShortPositionRatio?symbol=$s&period=1h&limit=12"); $all = @(Get-BinanceFut "/futures/data/globalLongShortAccountRatio?symbol=$s&period=1h&limit=12")
    $tk = @(Get-BinanceFut "/futures/data/takerlongshortRatio?symbol=$s&period=1h&limit=6"); $oi = @(Get-BinanceFut "/futures/data/openInterestHist?symbol=$s&period=1h&limit=12")
    if (-not $top.Count -or -not $all.Count) { return @() }
    $t0 = [double]$top[-1].longAccount * 100; $t1 = [double]$top[0].longAccount * 100; $a0 = [double]$all[-1].longAccount * 100
    $L += ("🐋 Qué hacen los mejores traders (Binance, datos agregados): {0:N0}% de sus posiciones en LARGO ({1:+0;-0} pts en 12 h) frente a {2:N0}% de la masa de traders" -f $t0, ($t0 - $t1), $a0)
    $dv = $t0 - $a0
    if ($dv -ge 8) { $L += "   → Los mejores traders están claramente más largos que la masa: sesgo alcista de los que más saben." } elseif ($dv -le -8) { $L += "   → Los mejores traders están claramente más cortos que la masa: sesgo bajista de los que más saben." } else { $L += "   → Mejores traders y masa van alineados: sin señal de divergencia." }
    if ($a0 -ge 62) { $L += "   ⚠️ FOMO: la masa está muy larga ($([int]$a0)%); históricamente un exceso así deja el mercado expuesto a barridos de largos." } elseif ($a0 -le 38) { $L += "   ⚠️ FUD: la masa está muy corta ($([int]$a0)% largos); suele dar pie a rebotes bruscos (short squeeze)." }
    if ($tk.Count) { $tr = ($tk | Select-Object -Last 6 | ForEach-Object { [double]$_.buySellRatio } | Measure-Object -Average).Average; $L += ("   Volumen agresivo últimas 6 h: compradores/vendedores = {0:N2} ({1})" -f $tr, $(if ($tr -ge 1.1) { "predominan compradores" } elseif ($tr -le 0.9) { "predominan vendedores" } else { "equilibrado" })) }
    if ($oi.Count -ge 2) { $o0 = [double]$oi[-1].sumOpenInterestValue; $o1 = [double]$oi[0].sumOpenInterestValue; if ($o1 -gt 0) { $L += ("   Interés abierto 12 h: {0:+0.0;-0.0}% ({1})" -f (($o0 / $o1 - 1) * 100), $(if ($o0 -gt $o1 * 1.03) { "entra dinero nuevo" } elseif ($o0 -lt $o1 * 0.97) { "se cierran posiciones" } else { "estable" })) } }
    $L += "   (Datos oficiales de Binance Futures sobre ESTA moneda en Binance; es contexto, no una señal validada.)"
    return $L
}
