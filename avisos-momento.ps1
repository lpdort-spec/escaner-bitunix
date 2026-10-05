# Avisos automáticos de "BUEN MOMENTO" para abrir un LARGO o un CORTO (misma puntuación de reglas fijas que el comando /momento).
#  - Cripto de Bitunix (las de mayor volumen): se revisa tras cada cierre de vela de 4h -> chat privado de señales y grupo Alertas Mercados.
#  - Acciones, ETFs y demás valores del universo de mercado: se revisa cada día tras el cierre -> solo grupo Alertas Mercados.
# Es una lectura de CONTEXTO con reglas fijas: NO está validada en backtest como la táctica de rupturas con retesteo. Se avisa solo al CRUZAR el umbral (puntuación >= 7)
# y no se repite hasta que el activo baje de (umbral - 3), para no inundar los chats. Ajustable en chats.json: "umbralMomento", "momentoCripto" (nº de criptos por volumen).

function Get-MomCfg($k, $def) { try { $c = Get-Content (Join-Path $PSScriptRoot "chats.json") -Raw -Encoding UTF8 | ConvertFrom-Json; if ($null -ne $c.$k -and "$($c.$k)" -ne '') { return $c.$k } } catch {}; return $def }
function Get-MomAct { $v = Get-ReportState "momact"; if (-not $v) { return @() }; return @($v -split ',' | Where-Object { $_ }) }
function Set-MomAct($a) { Set-ReportState "momact" ((@($a) | Select-Object -Unique) -join ',') }

# Puntúa largo y corto de un activo ya resuelto ($s como las series de /informe). $null si faltan velas 4h o 1d.
function Get-MomScores($s) {
    $cd4 = Get-MomentoCd $s '4h'; $cd1 = Get-MomentoCd $s '1d'
    if (-not $cd4 -or -not $cd1) { return $null }
    $a4 = Analyze-TF $cd4 '4h' 100; $a1 = Analyze-TF $cd1 '1d' 90
    $tv = $null; try { $tv = Resolve-TvTarget $s.src $s.sym $s.exch } catch {}
    $sentVal = $null; try { $t = Get-MarketSentiment ($s.src -ne 'yahoo'); if ($t -match '(\d+)/100') { $sentVal = [double]$Matches[1] } } catch {}
    $fund = if ($s.extra -and $null -ne $s.extra.funding) { [double]$s.extra.funding } else { $null }
    $tvr = if ($tv) { $tv.rating } else { $null }; $px = [double]$s.price
    return @{ lg = (Score-Momento 1 $a4 $a1 $tvr $px $sentVal $fund); st = (Score-Momento -1 $a4 $a1 $tvr $px $sentVal $fund) }
}

function Build-MomAlert($kind, $sym, $side, $score) {
    $mode = if ($kind -eq 'cripto') { 'cripto' } else { 'accion' }
    $rep = Get-MomentoReport $sym $mode $(if ($side -eq 'L') { 'largo' } else { 'corto' })
    if ($rep -like 'No he podido*' -or $rep -like 'Tengo el precio*') { return $null }
    $dirU = if ($side -eq 'L') { "LARGO" } else { "CORTO" }
    $h = "🔔 AVISO DE BUEN MOMENTO · $dirU · $sym`n(Revisión automática con las velas cerradas · puntuación $score; umbral de aviso $(Get-MomCfg 'umbralMomento' 7))"
    if ($kind -ne 'cripto') { $h += "`nEn opciones: LARGO ≈ call y CORTO ≈ put. Este análisis no valora la prima, el vencimiento ni la volatilidad implícita de la opción: solo la dirección del subyacente." }
    return $h + "`n`n" + $rep
}

# Procesa una lista de elementos; devuelve nº de avisos enviados. -Dry: solo muestra puntuaciones, no envía ni guarda estado.
function Invoke-MomItems($kind, $items, [switch]$Dry) {
    $thr = [int](Get-MomCfg 'umbralMomento' 7); $act = @(Get-MomAct); $sent = 0; $cap = 8
    foreach ($it in $items) {
        if (($script:cmdTick++ % 10) -eq 0) { try { Poll-Commands } catch {} }
        try {
            if ($kind -eq 'cripto') { $s = @{ src = 'bitunix'; sym = $it.sym; name = "$($it.sym)/USDT"; currency = 'USDT'; exch = ''; price = $it.px; extra = @{ funding = $it.fund } } }
            else { $s = Get-YahooSeries $it }
            if (-not $s) { continue }
            $sc = Get-MomScores $s; if (-not $sc) { continue }
            $sym = $s.sym -replace '\.MC$', '.MC'
            if ($Dry) { Write-Host ("  {0,-8} largo {1,3} · corto {2,3}" -f $sym, $sc.lg.score, $sc.st.score); continue }
            foreach ($side in 'L', 'S') {
                $score = if ($side -eq 'L') { $sc.lg.score } else { $sc.st.score }; $key = "${sym}:$side"
                if ($score -ge $thr -and $key -notin $act) {
                    if ($script:MomSent -ge $cap) { continue }
                    $msg = Build-MomAlert $kind $sym $side $score; if (-not $msg) { continue }
                    if ($kind -eq 'cripto') { Send-ToSignalChats $msg }
                    if ($script:MktChat -and $TelegramToken) { Send-Tg $TelegramToken $script:MktChat $msg $null }
                    $act += $key; $sent++; $script:MomSent++
                } elseif ($score -lt ($thr - 3) -and $key -in $act) { $act = @($act | Where-Object { $_ -ne $key }) }
            }
        } catch {}
        Start-Sleep -Milliseconds 150
    }
    if (-not $Dry) { Set-MomAct $act }
    return $sent
}

$script:MomSent = 0
function Run-MomentoCryptoIfDue {                  # tras cada cierre de vela de 4h, por tandas de 20 para seguir atendiendo comandos
    if (-not $TelegramToken) { return }
    $slot = [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 14400); $idx = 0
    $st = Get-ReportState "momc"; if ($st -match '^(\d+):(\d+)$' -and [long]$Matches[1] -eq $slot) { $idx = [int]$Matches[2] }
    $n = [int](Get-MomCfg 'momentoCripto' 100)
    $tk = @((Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object { $_.symbol -like "*USDT" } | Sort-Object { [double]$_.quoteVol } -Descending | Select-Object -First $n)
    if ($idx -ge $tk.Count) { return }
    if ($idx -eq 0) { $script:MomSent = 0 }
    $fm = @{}; try { foreach ($f in (Invoke-RestMethod "$($script:CmdBase)/funding_rate/batch").data) { $fm[$f.symbol] = [double]$f.fundingRate } } catch {}
    $end = [Math]::Min($idx + 20, $tk.Count)
    $items = @($tk[$idx..($end - 1)] | ForEach-Object { @{ sym = ($_.symbol -replace 'USDT$', ''); px = [double]$_.lastPrice; fund = $(if ($fm.ContainsKey($_.symbol)) { $fm[$_.symbol] } else { $null }) } })
    Set-ReportState "momc" "${slot}:$end"
    $k = Invoke-MomItems 'cripto' $items
    Write-Host ("  [momento cripto] tanda {0}-{1} de {2} · avisos: {3}" -f $idx, $end, $tk.Count, $k) -ForegroundColor DarkGray
}
function Run-MomentoStocksIfDue {                  # laborables tras el cierre (desde las 22:50 hora de España), por tandas de 25
    if (-not $TelegramToken -or -not $script:MktChat) { return }
    $now = Get-MadridNow; $ref = $now.AddHours(-4)
    if ($ref.DayOfWeek -in [DayOfWeek]::Saturday, [DayOfWeek]::Sunday) { return }
    if (-not ($now.Hour -ge 23 -or $now.Hour -lt 4 -or ($now.Hour -eq 22 -and $now.Minute -ge 50))) { return }
    $day = $ref.ToString("yyyy-MM-dd"); $idx = 0
    $st = Get-ReportState "momm"; if ($st -match '^(\d{4}-\d{2}-\d{2}):(\d+)$' -and $Matches[1] -eq $day) { $idx = [int]$Matches[2] }
    $uni = @($script:UniTodos); if ($idx -ge $uni.Count) { return }
    if ($idx -eq 0) { $script:MomSent = 0 }
    $end = [Math]::Min($idx + 25, $uni.Count)
    Set-ReportState "momm" "${day}:$end"
    $k = Invoke-MomItems 'accion' @($uni[$idx..($end - 1)])
    Write-Host ("  [momento mercado] tanda {0}-{1} de {2} · avisos: {3}" -f $idx, $end, $uni.Count, $k) -ForegroundColor DarkGray
}
