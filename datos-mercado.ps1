# RECOLECTOR HORARIO de datos de posicionamiento (solo para MEDIR a futuro; no envía nada ni cambia ninguna señal). Los exchanges solo conservan ~30 días de interés abierto y ratios largo/corto: para poder hacer backtest en 2-3 meses hay que ir guardándolos.
# Cada hora UTC guarda, para las 60 monedas con más volumen de Bitunix: precio marcado, funding, interés abierto, ratio largo/corto de cuentas, ratio largo/corto de posiciones de los mejores traders y ratio taker compra/venta.
# Fuente principal Binance Futures (API pública); si no responde (p. ej. bloqueo regional en el servidor) se usa Gate.io (open interest, ratio de cuentas y de mejores traders). Fichero: datos/posicionamiento-AAAAMM.csv (una fila por moneda y hora; el flujo de trabajo guarda la carpeta datos/).
# Se procesa por tandas de 15 monedas en cada vuelta del bucle principal para no retrasar los comandos de Telegram.
$script:DmSlot = 0; $script:DmIdx = 0; $script:DmCoins = @(); $script:DmPrem = @{}; $script:DmBinOk = $true
function Get-DmFlat($a) { foreach ($i in @($a)) { if ($i -is [System.Array]) { Get-DmFlat $i } elseif ($null -ne $i) { $i } } }
function Get-DmJson($url) { try { $r = @(Get-DmFlat (Invoke-RestMethod $url -TimeoutSec 15)); return ,$r } catch { return $null } }      # la coma conserva el array (un solo objeto se devolvería desenrollado y sin .Count)
function Run-DatosMercadoIfDue {
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 3600)
    $dir = Join-Path $PSScriptRoot 'datos'; $file = Join-Path $dir ("posicionamiento-" + [DateTime]::UtcNow.ToString('yyyyMM') + ".csv")
    if ($script:DmSlot -ne $slot) {
        $script:DmSlot = $slot; $script:DmIdx = 0; $script:DmPrem = @{}; $script:DmBinOk = $true
        try { $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 25).data | Where-Object { $_.symbol -like '*USDT' } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First 60); $script:DmCoins = @($tk | ForEach-Object { $_.symbol }) } catch { $script:DmCoins = @() }
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        if (-not (Test-Path $file)) { Set-Content -Path $file -Value "slot,utc,sym,src,mark,funding,oi,lsr_cuentas,lsr_top_posiciones,taker_buysell" -Encoding UTF8 }
        else { $tail = @(Get-Content $file -Tail 120 -Encoding UTF8); if (@($tail | Where-Object { $_ -like "$slot,*" }).Count -ge 20) { $script:DmIdx = $script:DmCoins.Count } }      # esta hora ya está guardada (reinicio del turno)
        $pi = Get-DmJson "https://fapi.binance.com/fapi/v1/premiumIndex"; if ($null -eq $pi -or -not $pi.Count) { $script:DmBinOk = $false } else { foreach ($r in $pi) { $script:DmPrem[$r.symbol] = $r } }
        if (-not $script:DmBinOk) { Write-Host "  [datos-mercado] Binance no responde: se usa Gate.io" -ForegroundColor DarkGray }
    }
    if ($script:DmIdx -ge $script:DmCoins.Count) { return }
    $end = [Math]::Min($script:DmIdx + 15, $script:DmCoins.Count); $rows = @(); $utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:00:00Z')
    foreach ($sym in @($script:DmCoins[$script:DmIdx..($end - 1)])) {
        $mark = ''; $fund = ''; $oi = ''; $gl = ''; $tp = ''; $tk2 = ''; $src = ''
        if ($script:DmBinOk) {
            $p = $script:DmPrem[$sym]
            if ($p) { $mark = $p.markPrice; $fund = $p.lastFundingRate; $src = 'binance' }
            $o = Get-DmJson "https://fapi.binance.com/fapi/v1/openInterest?symbol=$sym"; if ($o -and $o.Count) { $oi = $o[0].openInterest }
            $g = Get-DmJson "https://fapi.binance.com/futures/data/globalLongShortAccountRatio?symbol=$sym&period=1h&limit=1"; if ($g -and $g.Count) { $gl = $g[0].longShortRatio }
            $t = Get-DmJson "https://fapi.binance.com/futures/data/topLongShortPositionRatio?symbol=$sym&period=1h&limit=1"; if ($t -and $t.Count) { $tp = $t[0].longShortRatio }
            $k = Get-DmJson "https://fapi.binance.com/futures/data/takerlongshortRatio?symbol=$sym&period=1h&limit=1"; if ($k -and $k.Count) { $tk2 = $k[0].buySellRatio }
        }
        if (-not $src) {      # respaldo: Gate.io
            $base = ($sym -replace 'USDT$', ''); $gs = Get-DmJson "https://api.gateio.ws/api/v4/futures/usdt/contract_stats?contract=${base}_USDT&interval=1h&limit=2"
            if ($gs -and $gs.Count) { $x = @($gs | Sort-Object { [long]$_.time })[-1]; $src = 'gate'; $oi = $x.open_interest; $gl = $x.lsr_account; $tp = $x.top_lsr_size; $mark = $x.mark_price }
            $gc = Get-DmJson "https://api.gateio.ws/api/v4/futures/usdt/contracts/${base}_USDT"; if ($gc -and $gc.Count) { $fund = $gc[0].funding_rate; if (-not $mark) { $mark = $gc[0].mark_price } }
        }
        if ($src) { $rows += ("{0},{1},{2},{3},{4},{5},{6},{7},{8},{9}" -f $script:DmSlot, $utc, $sym, $src, $mark, $fund, $oi, $gl, $tp, $tk2) }
        Start-Sleep -Milliseconds 80
    }
    $script:DmIdx = $end
    if ($rows.Count) { try { Add-Content -Path $file -Value $rows -Encoding UTF8 } catch {} }
    if ($script:DmIdx -ge $script:DmCoins.Count) { Write-Host ("  [datos-mercado] hora {0}: {1} monedas guardadas ({2})" -f $utc, $script:DmCoins.Count, $(if ($script:DmBinOk) { 'Binance' } else { 'Gate.io' })) -ForegroundColor DarkGray }
}
