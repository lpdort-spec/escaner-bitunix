# AVISO DE BALLENAS: posición NUEVA de >= 10.000.000 USD (largo o corto) en Hyperliquid (futuros descentralizados donde TODAS las posiciones son públicas por cartera). Fuente oficial y pública, sin claves.
# En los exchanges centralizados (Binance, Bybit, OKX, Bitunix...) las posiciones individuales NO son públicas, por eso solo se puede vigilar Hyperliquid. Se revisan las mayores carteras cada ~10 min; la primera pasada solo guarda el estado (sin avisos).
# Destino: chat privado y grupo Alertas Mercados. Es información de contexto: el bot no sabe si la ballena acierta (muchas tienen pérdidas no realizadas). Umbral configurable en chats.json: "ballenaMinUsd".
$script:BallWallets = @(); $script:BallWalletsAt = [datetime]::MinValue; $script:BallAt = [datetime]::MinValue
function Get-BallMinUsd { try { $c = Get-Content (Join-Path $PSScriptRoot "chats.json") -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $c.ballenaMinUsd -and [double]$c.ballenaMinUsd -gt 0) { return [double]$c.ballenaMinUsd } } catch {}; return 10000000.0 }
function Get-BallWallets {      # carteras con mas de 1 M USD de valor, ordenadas por valor (se refresca cada 6 h: el ranking pesa varios MB)
    if ($script:BallWallets.Count -and ((Get-Date) - $script:BallWalletsAt).TotalHours -lt 6) { return $script:BallWallets }
    try { $lb = Invoke-RestMethod 'https://stats-data.hyperliquid.xyz/Mainnet/leaderboard' -TimeoutSec 60 -Headers @{ 'User-Agent' = 'Mozilla/5.0' }
        $script:BallWallets = @(@($lb.leaderboardRows) | Where-Object { [double]$_.accountValue -ge 1000000 } | Sort-Object { [double]$_.accountValue } -Descending | Select-Object -First 150 | ForEach-Object { $_.ethAddress }); $script:BallWalletsAt = Get-Date } catch {}
    return $script:BallWallets
}
function Get-BallPositions([double]$minUsd) {      # @{ clave = detalle } de las posiciones >= umbral
    $out = @{}; $h = @{ 'User-Agent' = 'Mozilla/5.0'; 'Content-Type' = 'application/json' }
    foreach ($a in (Get-BallWallets)) {
        try { $b = @{ type = 'clearinghouseState'; user = $a } | ConvertTo-Json -Compress; $st = Invoke-RestMethod 'https://api.hyperliquid.xyz/info' -Method Post -Headers $h -Body $b -TimeoutSec 20
            foreach ($p in @($st.assetPositions)) { $pos = $p.position; $nv = [Math]::Abs([double]$pos.positionValue); if ($nv -ge $minUsd) {
                $side = if ([double]$pos.szi -gt 0) { 'L' } else { 'S' }; $k = "{0}|{1}|{2}" -f $a.Substring(2, 8), $pos.coin, $side
                $out[$k] = [pscustomobject]@{ addr = $a; coin = "$($pos.coin)"; side = $side; usd = $nv; lev = $pos.leverage.value; entry = [double]$pos.entryPx; liq = $(if ($pos.liquidationPx) { [double]$pos.liquidationPx } else { $null }); upl = [double]$pos.unrealizedPnl; acct = [double]$st.marginSummary.accountValue } } } } catch {}
        Start-Sleep -Milliseconds 100
    }
    return $out
}
function Handle-Ballenas($ra) {      # /ballenas [MONEDA]: foto de las posiciones >= 2 M USD de las mayores carteras de Hyperliquid
    $coin = @($ra | ForEach-Object { "$_" } | Where-Object { $_ -match '^[A-Za-z0-9]{2,12}$' } | Select-Object -First 1)[0]
    $pos = @((Get-BallPositions 2000000).Values); if (-not $pos.Count) { return "Hyperliquid no ha devuelto datos ahora. Prueba en unos minutos." }
    $hora = (Get-Date).ToString('dd/MM HH:mm'); $L = @()
    if ($coin) {
        $c = ("$coin".ToUpper() -replace 'USDT$', ''); $hl = if ($c -like '1000*') { 'k' + $c.Substring(4) } else { $c }
        $x = @($pos | Where-Object { $_.coin -ieq $hl -or $_.coin -ieq $c })
        if (-not $x.Count) { return "Ninguna de las mayores carteras de Hyperliquid tiene ahora una posición de 2 M USD o más en $c (o la moneda no cotiza allí)." }
        $lg = @($x | Where-Object { $_.side -eq 'L' }); $st = @($x | Where-Object { $_.side -eq 'S' }); $sl = ($lg | Measure-Object usd -Sum).Sum; $ss = ($st | Measure-Object usd -Sum).Sum; if (-not $sl) { $sl = 0 }; if (-not $ss) { $ss = 0 }
        $L += ("🐋 BALLENAS en {0} · Hyperliquid · {1} (hora de España)" -f $c, $hora)
        $L += ("Posiciones de 2 M USD o más en las mayores carteras: {0:N1} M USD en LARGO ({1} carteras) frente a {2:N1} M USD en CORTO ({3} carteras) → {4}" -f ($sl / 1e6), $lg.Count, ($ss / 1e6), $st.Count, $(if ($sl + $ss -le 0) { "sin datos" } elseif ($sl -ge 1.5 * $ss) { "sesgo LARGO ($([int](100 * $sl / ($sl + $ss)))%)" } elseif ($ss -ge 1.5 * $sl) { "sesgo CORTO ($([int](100 * $ss / ($sl + $ss)))%)" } else { "equilibrado" }))
        foreach ($p in ($x | Sort-Object usd -Descending | Select-Object -First 8)) { $L += ("   {0} {1:N1} M · x{2} · entrada {3}{4} · PnL no real. {5:+0.0;-0.0} M" -f $(if ($p.side -eq 'L') { "🟢 LARGO" } else { "🔴 CORTO" }), ($p.usd / 1e6), $p.lev, (TaFp $p.entry), $(if ($p.liq) { " · liq. " + (TaFp $p.liq) } else { "" }), ($p.upl / 1e6)) }
    } else {
        $L += ("🐋 BALLENAS · mayores posiciones abiertas en Hyperliquid · {0} (hora de España)" -f $hora)
        foreach ($g in ($pos | Group-Object coin | Sort-Object { ($_.Group | Measure-Object usd -Sum).Sum } -Descending | Select-Object -First 8)) { $sl = (@($g.Group | Where-Object { $_.side -eq 'L' }) | Measure-Object usd -Sum).Sum; $ss = (@($g.Group | Where-Object { $_.side -eq 'S' }) | Measure-Object usd -Sum).Sum; if (-not $sl) { $sl = 0 }; if (-not $ss) { $ss = 0 }
            $L += ("   {0}: {1:N0} M largo · {2:N0} M corto → {3}" -f $g.Name, ($sl / 1e6), ($ss / 1e6), $(if ($sl -ge 1.5 * $ss) { "🟢 sesgo largo" } elseif ($ss -ge 1.5 * $sl) { "🔴 sesgo corto" } else { "⚪ equilibrado" })) }
        $L += ""; $L += "Mayores posiciones individuales:"
        foreach ($p in ($pos | Sort-Object usd -Descending | Select-Object -First 6)) { $L += ("   {0} {1} {2:N0} M · x{3} · PnL no real. {4:+0;-0} M" -f $(if ($p.side -eq 'L') { "🟢" } else { "🔴" }), $p.coin, ($p.usd / 1e6), $p.lev, ($p.upl / 1e6)) }
        $L += "Para una moneda concreta: /ballenas BTC"
    }
    $L += ""; $L += "ℹ️ Solo se ven las mayores carteras de Hyperliquid (exchange descentralizado, posiciones públicas on-chain). En Binance, Bybit, OKX o Bitunix no hay posiciones individuales públicas. Dato informativo, no una señal."
    return ($L -join "`n")
}
function Format-BallAlert($p, $inBitunix) {
    $dir = if ($p.side -eq 'L') { "LARGO" } else { "CORTO" }; $em = if ($p.side -eq 'L') { "🟢" } else { "🔴" }
    $L = @(); $L += ("🐋 BALLENA · posición {0} nueva de ≈ {1:N1} M USD en {2}" -f $dir, ($p.usd / 1e6), $p.coin)
    $L += ("{0} {1} x{2} en Hyperliquid · entrada {3}{4} · cartera {5:N0} M USD · PnL no realizado {6:+0.0;-0.0} M USD" -f $em, $dir, $p.lev, (TaFp $p.entry), $(if ($p.liq) { " · liquidación " + (TaFp $p.liq) } else { "" }), ($p.acct / 1e6), ($p.upl / 1e6))
    $L += ("Cartera {0}…{1} (pública on-chain). {2}" -f $p.addr.Substring(0, 8), $p.addr.Substring($p.addr.Length - 4), $(if ($inBitunix) { "$($p.coin) también está en Bitunix: consulta /informe o /momento." } else { "" }))
    $L += "ℹ️ Dato informativo, no una señal: el bot no sabe si esta ballena acierta (muchas tienen pérdidas no realizadas) ni si seguirá abierta. Solo se ven posiciones de Hyperliquid; en Binance, Bybit, OKX o Bitunix no hay posiciones individuales públicas."
    return ($L -join "`n")
}
function Send-BallenasIfDue {
    if (-not $TelegramToken) { return }
    if (((Get-Date) - $script:BallAt).TotalMinutes -lt 4) { return }; $script:BallAt = Get-Date      # cada ~4 min (cada pasada tarda ~20 s)
    $min = Get-BallMinUsd; $cur = Get-BallPositions ($min * 0.7); if (-not $cur.Count -and -not (Get-BallWallets).Count) { return }      # se recuerdan las posiciones desde el 70% del umbral: una que oscile junto a 10 M no avisa dos veces
    $prevRaw = Get-ReportState "ball"; $first = ($null -eq $prevRaw -or "$prevRaw" -eq ''); $prev = @("$prevRaw" -split ',' | Where-Object { $_ })
    $new = @($cur.Keys | Where-Object { $_ -notin $prev -and $cur[$_].usd -ge $min } | Sort-Object { $cur[$_].usd } -Descending)
    Set-ReportState "ball" ((@($cur.Keys) | Select-Object -First 400) -join ',')
    if ($first) { Write-Host ("  [ballenas] primera pasada: {0} posiciones >= {1:N0} USD registradas, sin avisos" -f $cur.Count, $min) -ForegroundColor DarkGray; return }
    if (-not $new.Count) { return }
    $bx = @{}; try { foreach ($t in (Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data) { $bx[($t.symbol -replace 'USDT$', '')] = 1 } } catch {}
    if (Get-Command Run-MesaObs -ErrorAction SilentlyContinue) { try { Run-MesaObs @($new | ForEach-Object { $cur[$_] }) } catch {} }      # observación silenciosa de la mesa de ballenas
    $sent = 0
    foreach ($k in $new) { if ($sent -ge 5) { break }
        $m = Format-BallAlert $cur[$k] ($bx.ContainsKey($cur[$k].coin)); try { Send-ToSignalChats $m } catch {}; if ($script:MktChat) { try { Send-Tg $TelegramToken $script:MktChat $m $null } catch {} }; $sent++ }
    if ($new.Count -gt $sent) { $r = "🐋 Además se han abierto {0} posiciones más de >= {1:N0} M USD en Hyperliquid (mostradas las {2} mayores)." -f ($new.Count - $sent), ($min / 1e6), $sent; try { Send-ToSignalChats $r } catch {}; if ($script:MktChat) { try { Send-Tg $TelegramToken $script:MktChat $r $null } catch {} } }
}
