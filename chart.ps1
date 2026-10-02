# Dibuja un gráfico de velas con zonas de entrada, stop y objetivos (estilo del canal) y lo guarda como PNG.
# Solo Windows PowerShell 5.1 (System.Drawing). En otros entornos devuelve $null y se envía solo texto.
function New-SignalChart($candles, $side, $entry, $sl, $tp1, $tp2, $tp3, $title, $path, $sweepLevel = $null) {
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { return $null }
    try {
        $W = 900; $H = 520; $padL = 12; $padR = 110; $padT = 38; $padB = 24
        $bmp = New-Object System.Drawing.Bitmap $W, $H
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
        $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#0f141c'))
        $n = $candles.Count
        $hi = ($candles | % { $_.h } | Measure-Object -Maximum).Maximum; $lo = ($candles | % { $_.l } | Measure-Object -Minimum).Minimum
        $hi = [Math]::Max($hi, [Math]::Max($tp3, $entry)); $lo = [Math]::Min($lo, [Math]::Min($sl, $entry))
        if ($side -eq 'SHORT') { $hi = [Math]::Max($hi, $sl); $lo = [Math]::Min($lo, $tp3) }
        $span = ($hi - $lo) * 1.06; $hi += ($hi - $lo) * 0.03; $lo = $hi - $span
        $plotW = $W - $padL - $padR - 150; $plotH = $H - $padT - $padB      # 150 px libres a la derecha para las zonas
        $cw = $plotW / $n
        function Y([double]$p) { return $padT + ($hi - $p) / ($hi - $lo) * $plotH }
        $green = [System.Drawing.ColorTranslator]::FromHtml('#26a69a'); $red = [System.Drawing.ColorTranslator]::FromHtml('#ef5350')
        $grid = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(40, 255, 255, 255))
        $font = New-Object System.Drawing.Font 'Segoe UI', 9; $fontB = New-Object System.Drawing.Font 'Segoe UI', 11, ([System.Drawing.FontStyle]::Bold)
        $white = [System.Drawing.Brushes]::White; $gray = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(170, 200, 200, 200))
        for ($k = 0; $k -le 5; $k++) { $p = $lo + ($hi - $lo) * $k / 5; $y = Y $p; $g.DrawLine($grid, $padL, $y, $W - $padR, $y); $g.DrawString(('{0:G6}' -f $p), $font, $gray, $W - $padR + 6, $y - 8) }
        # zonas (a la derecha de las velas)
        $x0 = $padL + $plotW - 6; $zw = $W - $padR - $x0
        $zTP = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 38, 166, 154)); $zSL = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(70, 239, 83, 80))
        $g.FillRectangle($zTP, $x0, [Math]::Min((Y $entry), (Y $tp3)), $zw, [Math]::Abs((Y $entry) - (Y $tp3)))
        $g.FillRectangle($zSL, $x0, [Math]::Min((Y $entry), (Y $sl)), $zw, [Math]::Abs((Y $entry) - (Y $sl)))
        # velas
        for ($i = 0; $i -lt $n; $i++) {
            $c = $candles[$i]; $x = $padL + $i * $cw + $cw / 2; $up = $c.c -ge $c.o
            $col = if ($up) { $green } else { $red }; $pen = New-Object System.Drawing.Pen $col, 1
            $g.DrawLine($pen, $x, (Y $c.h), $x, (Y $c.l))
            $yT = Y ([Math]::Max($c.o, $c.c)); $yB = Y ([Math]::Min($c.o, $c.c)); $bh = [Math]::Max(1.5, $yB - $yT)
            $g.FillRectangle((New-Object System.Drawing.SolidBrush $col), $x - $cw * 0.35, $yT, [Math]::Max(1.5, $cw * 0.7), $bh)
        }
        # niveles
        function Line($p, $color, $label, [bool]$dash) {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($color)), 1.2
            if ($dash) { $pen.DashStyle = 'Dash' }
            $y = Y $p; $g.DrawLine($pen, $padL, $y, $W - $padR, $y)
            $br = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($color))
            $g.FillRectangle($br, $W - $padR + 2, $y - 9, 104, 18)
            $g.DrawString(("{0} {1:G6}" -f $label, $p), $font, [System.Drawing.Brushes]::Black, $W - $padR + 4, $y - 8)
        }
        if ($sweepLevel) { Line $sweepLevel '#b39ddb' 'Liquidez' $true }
        Line $tp3 '#26a69a' 'TP3' $true; Line $tp2 '#4db6ac' 'TP2' $true; Line $tp1 '#80cbc4' 'TP1' $true
        Line $entry '#90caf9' 'Entrada' $false; Line $sl '#ef5350' 'SL' $false
        # flecha de recorrido esperado
        $ap = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml('#4f8cff')), 3
        $ap.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap 5, 6
        $g.DrawLine($ap, ($padL + $plotW - 14), (Y $entry), ($x0 + $zw * 0.65), (Y $tp3))
        $icon = if ($side -eq 'LONG') { '#26a69a' } else { '#ef5350' }
        $g.DrawString($title, $fontB, $white, 12, 8)
        $g.Dispose(); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        return $path
    } catch { return $null }
}

function Send-TelegramPhoto($token, $chatId, $photoPath, $caption) {
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction Stop
        $client = New-Object System.Net.Http.HttpClient
        $mp = New-Object System.Net.Http.MultipartFormDataContent
        $mp.Add((New-Object System.Net.Http.StringContent([string]$chatId)), 'chat_id')
        $mp.Add((New-Object System.Net.Http.StringContent($caption, [System.Text.Encoding]::UTF8)), 'caption')
        $bytes = [IO.File]::ReadAllBytes($photoPath)
        $img = New-Object System.Net.Http.ByteArrayContent (, $bytes); $img.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('image/png')
        $mp.Add($img, 'photo', 'senal.png')
        $r = $client.PostAsync("https://api.telegram.org/bot$token/sendPhoto", $mp).Result
        $ok = $r.IsSuccessStatusCode; $client.Dispose(); return $ok
    } catch { return $false }
}
