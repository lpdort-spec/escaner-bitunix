# /opinion [LARGO|CORTO] SIMBOLO [PRECIO]  (chat privado y grupo Alertas Mercados; en el chat privado también como frase libre: «operación largo BTC 85.500», «corto TSLA 250»)
# Es una OPINIÓN sobre una idea ("¿qué te parece un largo en BTC a 85.500?"), NO una alerta ni una orden: no hace falta SL, TP ni apalancamiento. Valora el lado y el precio con las mismas reglas del bot
# (estructura, ADX, MACD, RSI, Bollinger, volumen, EMAs/soportes cerca de ese precio, posicionamiento de los mejores traders, noticias). Cripto de Bitunix y acciones/ETFs.
function Resolve-OpinionPrice([string]$tok, [double]$px) {      # "85.500" puede ser 85,5 o 85500: se elige la lectura más cercana al precio actual
    $cands = @(); $t = ($tok -replace '[^0-9.,]', ''); if (-not $t) { return $null }
    if ($t -match '^\d{1,3}(\.\d{3})+$') { $cands += [double]($t -replace '\.', '') }
    if ($t -match '^\d{1,3}(,\d{3})+$') { $cands += [double]($t -replace ',', '') }
    $n = ConvertTo-Num $t; if ($null -ne $n) { $cands += $n }
    if (-not $cands.Count) { return $null }; if ($px -le 0) { return $cands[0] }
    return ($cands | Sort-Object { [Math]::Abs([Math]::Log([Math]::Max($_, 1e-12) / $px)) } | Select-Object -First 1)
}
function Get-OpinionLevels($s, [double]$px) {      # niveles de EMAs y soportes/resistencias cercanos (cripto de Bitunix: 1h/4h/1d; acciones: diario)
    $lv = @()
    try { if ($s.src -eq 'bitunix' -and (Get-Command Get-StructLevels -ErrorAction SilentlyContinue)) { $lv += @(Get-StructLevels $s.sym $px) }
          elseif ($s.src -eq 'yahoo' -and (Get-Command Get-MktBars -ErrorAction SilentlyContinue)) { $b = Get-MktBars $s.sym; if ($b) { $cl = @($b.c) + @($px); foreach ($n in 20, 50, 100, 200) { if ($cl.Count -ge $n) { $lv += [pscustomobject]@{ p = (Get-EmaValue $cl $n); tag = "EMA$n diaria" } } } } } } catch {}
    return $lv
}
function Handle-Opinion($ra) {
    $words = @($ra | ForEach-Object { "$_" }); $side = 0; $sym = $null; $tokPx = $null
    $stop = 'operacion', 'operación', 'opinion', 'opinión', 'como', 'cómo', 'ves', 'que', 'qué', 'te', 'parece', 'un', 'una', 'en', 'a', 'de', 'la', 'el', 'sobre', 'para', 'por', 'idea', 'y', 'con', 'precio', 'entrada', 'abrir', 'entrar', 'posicion', 'posición', 'usd', 'usdt', 'dolares', 'dólares', 'cripto', 'accion', 'acción'
    foreach ($w in $words) { $lw = $w.ToLower().Trim(',', '.', '?', '¿', '!', '¡')
        if ($lw -in 'largo', 'long', 'compra', 'comprar', 'alcista') { $side = 1; continue }; if ($lw -in 'corto', 'short', 'venta', 'vender', 'bajista') { $side = -1; continue }
        if ($lw -in $stop) { continue }
        if ($w -match '^[0-9][0-9.,]*$') { if (-not $tokPx) { $tokPx = $w }; continue }
        if (-not $sym -and $w -match '^[A-Za-z0-9.\-]{1,12}$') { $sym = ($w.ToUpper() -replace 'USDT$', '') } }
    if (-not $sym -or $side -eq 0) { return "Uso: /opinion LARGO|CORTO SIMBOLO [PRECIO]`nEjemplos: /opinion largo BTC 85500 · /opinion corto TSLA 250 · /opinion largo ETH`nTambién puedes escribirlo como frase: «operación largo BTC 85.500». Es una OPINIÓN, no una alerta: no hace falta SL, TP ni apalancamiento." }
    $rs = Resolve-SymbolText $sym; $q = $rs.sym; $s = Resolve-SeriesM $q ''
    if (-not $s) { return "No he podido obtener datos fiables de $sym. Prueba con el símbolo exacto (BTC, SOL, TSLA, AAPL...). No voy a inventar datos." }
    $px = [double]$s.price; $idea = if ($tokPx) { Resolve-OpinionPrice $tokPx $px } else { $px }; if (-not $idea -or $idea -le 0) { $idea = $px }
    $sc = Get-MomScores $s; if (-not $sc) { return "No tengo velas suficientes de $($s.name) para dar una opinión fiable." }
    $me = if ($side -eq 1) { $sc.lg } else { $sc.st }; $opp = if ($side -eq 1) { $sc.st } else { $sc.lg }; $score = [int]$me.score
    $cd = Get-MomentoCd $s '4h'; $cd1 = Get-MomentoCd $s '1d'; $a4 = if ($cd) { Analyze-TF $cd '4h' 100 } else { $null }; $a1 = if ($cd1) { Analyze-TF $cd1 '1d' 90 } else { $null }
    $atr = if ($s.src -eq 'bitunix' -and $a4) { [double]$a4.atr } elseif ($a1) { [double]$a1.atr } else { $px * 0.03 }; $dPct = ($idea / $px - 1) * 100; $distAtr = [Math]::Abs($idea - $px) / [Math]::Max($atr, 1e-12)
    $dir = if ($side -eq 1) { "LARGO" } else { "CORTO" }; $L = @()
    $L += ("🧭 OPINIÓN · {0} {1}{2} (precio ahora {3})" -f $dir, $s.name, $(if ($tokPx) { " a " + (TaFp $idea) } else { "" }), (TaFp $px))
    $L += "Es una opinión sobre la idea, no una alerta ni una orden."; $L += ""
    # 1) relación entre el precio de la idea y el actual
    if ($tokPx) { $tipo = if ($distAtr -le 0.4) { "prácticamente a mercado" } elseif ($side * ($px - $idea) -gt 0) { "una orden limit de {0}" -f $(if ($side -eq 1) { "retroceso (más abajo)" } else { "rebote (más arriba)" }) } else { "ir a por el precio (orden de {0})" -f $(if ($side -eq 1) { "ruptura al alza" } else { "ruptura a la baja" }) }
        $L += ("📍 Tu precio está a {0:+0.0;-0.0}% del actual ({1:N1} ATR): es {2}." -f $dPct, $distAtr, $tipo)
        if ($distAtr -gt 4) { $L += "   ⚠️ Está muy lejos para el corto plazo: es una idea de medio plazo y habría que reevaluarla si el precio se acerca." } }
    # 2) niveles cerca de ese precio
    $lv = @(Get-OpinionLevels $s $px); foreach ($a in $a4, $a1) { if ($a) { foreach ($x in @($a.sup)) { $lv += [pscustomobject]@{ p = [double]$x.p; tag = "soporte" } }; foreach ($x in @($a.res)) { $lv += [pscustomobject]@{ p = [double]$x.p; tag = "resistencia" } } } }
    $near = @($lv | Where-Object { [Math]::Abs($_.p - $idea) -le 1.2 * $atr } | Sort-Object { [Math]::Abs($_.p - $idea) } | Select-Object -First 5)
    if ($near.Count) { $L += ("🧱 Cerca de {0}: {1}" -f (TaFp $idea), (($near | ForEach-Object { "{0} {1}" -f $_.tag, (TaFp $_.p) }) -join " · ")) } else { $L += ("🧱 No veo EMAs ni soportes/resistencias relevantes a ±1,2 ATR de {0}." -f (TaFp $idea)) }
    $inval = if ($side -eq 1) { @($lv | Where-Object { $_.p -lt $idea - 0.2 * $atr } | Sort-Object p -Descending | Select-Object -First 1) } else { @($lv | Where-Object { $_.p -gt $idea + 0.2 * $atr } | Sort-Object p | Select-Object -First 1) }
    if ($inval.Count) { $L += ("   La idea se debilita si el precio {0} {1} ({2})." -f $(if ($side -eq 1) { "pierde" } else { "supera" }), (TaFp $inval[0].p), $inval[0].tag) }
    # 3) lectura del bot para ese lado
    $L += ""; $L += ("📊 Lectura del bot para un {0}: puntuación {1} (el lado contrario {2}){3}" -f $dir.ToLower(), $score, [int]$opp.score, $(if ($null -ne $me.timing -and [int]$me.timing -ne 0) { "; timing 1h {0:+0;-0}" -f [int]$me.timing } else { "" }))
    @($me.fx | Where-Object { $_ -like '✅*' } | Select-Object -First 3) | ForEach-Object { $L += "   $_" }; @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 3) | ForEach-Object { $L += "   $_" }
    if ($s.src -eq 'bitunix') { try { if (Get-Command Get-MultiTfLine -ErrorAction SilentlyContinue) { $mt = Get-MultiTfLine $side ($s.sym -replace 'USDT$', '') $px; if ($mt) { $L += ""; $L += $mt } } } catch {} }      # 15m, 1h, 4h, 1D, 1S y 1M frente a la idea
    # 4) posicionamiento de los mejores traders (si hay datos)
    try { if (Get-Command Get-SmartMoneyLines -ErrorAction SilentlyContinue) { $sm = @(Get-SmartMoneyLines ($s.sym -replace '\.MC$', '')); $sm = @($sm | Where-Object { $_ -notlike '*Datos oficiales*' -and $_ -notlike '*Interés abierto*' -and $_ -notlike '*Volumen agresivo*' } | Select-Object -First 4); if ($sm.Count) { $L += ""; $L += $sm } } } catch {}
    # 5) noticias
    try { if (Get-Command Get-AssetNews -ErrorAction SilentlyContinue) { $nw = @(Get-AssetNews $s.sym $s.name ($s.src -ne 'yahoo') 48 | Select-Object -First 2); if ($nw.Count) { $L += ""; $L += "📰 Titulares recientes:"; foreach ($n in $nw) { $L += ("   • {0} — {1}" -f (Format-NwTitle $n.title), $n.src) } } } } catch {}
    # 6) conclusión con reglas fijas
    $L += ""; $far = ($tokPx -and $distAtr -gt 4)
    $conc = if ($score -ge 7 -and -not $far) { "✅ Veo la idea razonable: la lectura respalda el $($dir.ToLower())." } elseif ($score -ge 4 -and -not $far) { "🟡 La veo posible pero sin ventaja clara: la lectura respalda el $($dir.ToLower()) solo a medias; mejor esperar confirmación o un nivel mejor." } elseif ($far) { "🟠 Como idea de corto plazo no la veo: el precio está demasiado lejos; mientras tanto la lectura del $($dir.ToLower()) es de $score." } else { "⛔ No me convence ahora: la lectura NO respalda un $($dir.ToLower()) (puntuación $score" + $(if ([int]$opp.score -ge $score + 3) { ", y el lado contrario puntúa $([int]$opp.score))." } else { ")." }) }
    $L += "➡️ $conc"
    $L += "ℹ️ Opinión con reglas fijas y datos públicos; no es asesoramiento ni una señal validada. Opera siempre en aislado y con SL."
    return ($L -join "`n")
}
