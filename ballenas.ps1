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
                $out[$k] = @{ addr = $a; coin = "$($pos.coin)"; side = $side; usd = $nv; lev = $pos.leverage.value; entry = [double]$pos.entryPx; liq = $(if ($pos.liquidationPx) { [double]$pos.liquidationPx } else { $null }); upl = [double]$pos.unrealizedPnl; acct = [double]$st.marginSummary.accountValue } } } } catch {}
        Start-Sleep -Milliseconds 100
    }
    return $out
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
    if (((Get-Date) - $script:BallAt).TotalMinutes -lt 10) { return }; $script:BallAt = Get-Date
    $min = Get-BallMinUsd; $cur = Get-BallPositions ($min * 0.7); if (-not $cur.Count -and -not (Get-BallWallets).Count) { return }      # se recuerdan las posiciones desde el 70% del umbral: una que oscile junto a 10 M no avisa dos veces
    $prevRaw = Get-ReportState "ball"; $first = ($null -eq $prevRaw -or "$prevRaw" -eq ''); $prev = @("$prevRaw" -split ',' | Where-Object { $_ })
    $new = @($cur.Keys | Where-Object { $_ -notin $prev -and $cur[$_].usd -ge $min } | Sort-Object { $cur[$_].usd } -Descending)
    Set-ReportState "ball" ((@($cur.Keys) | Select-Object -First 400) -join ',')
    if ($first) { Write-Host ("  [ballenas] primera pasada: {0} posiciones >= {1:N0} USD registradas, sin avisos" -f $cur.Count, $min) -ForegroundColor DarkGray; return }
    if (-not $new.Count) { return }
    $bx = @{}; try { foreach ($t in (Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data) { $bx[($t.symbol -replace 'USDT$', '')] = 1 } } catch {}
    $sent = 0
    foreach ($k in $new) { if ($sent -ge 5) { break }
        $m = Format-BallAlert $cur[$k] ($bx.ContainsKey($cur[$k].coin)); try { Send-ToSignalChats $m } catch {}; if ($script:MktChat) { try { Send-Tg $TelegramToken $script:MktChat $m $null } catch {} }; $sent++ }
    if ($new.Count -gt $sent) { $r = "🐋 Además se han abierto {0} posiciones más de >= {1:N0} M USD en Hyperliquid (mostradas las {2} mayores)." -f ($new.Count - $sent), ($min / 1e6), $sent; try { Send-ToSignalChats $r } catch {}; if ($script:MktChat) { try { Send-Tg $TelegramToken $script:MktChat $r $null } catch {} } }
}
