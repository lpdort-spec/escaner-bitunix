# CALENDARIO MACRO (solo gestión de riesgo, NO es una señal): decisiones de la Fed (FOMC) de 2026 verificadas en federalreserve.gov (13/10/2026). Alrededor de esos anuncios son habituales picos de volatilidad y barridos de stops;
# no hay una ventaja medida, solo se avisa en el control de riesgo y en /consulta para no abrir posiciones nuevas muy apalancadas justo antes. Hora de la decisión: 14:00 hora de Nueva York (18:00 UTC con horario de verano de EE. UU., hasta el 1/11; 19:00 UTC con horario de invierno).
# Fechas del IPC (CPI) y empleo NO incluidas: la web del BLS bloquea el acceso automático y no se han podido verificar; se añaden en $script:MacroEvents cuando se confirmen. Revisar cada diciembre la lista del año siguiente.
$script:MacroEvents = @(
    @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-01-28T19:00:00Z' }, @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-03-18T18:00:00Z' },
    @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-04-29T18:00:00Z' }, @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-06-17T18:00:00Z' },
    @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-07-29T18:00:00Z' }, @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-09-16T18:00:00Z' },
    @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-10-28T18:00:00Z' }, @{ name = 'decisión de tipos de la Fed (FOMC)'; utc = '2026-12-09T19:00:00Z' }
)
function Get-MacroNear([int]$hoursBefore = 24, [int]$hoursAfter = 4) {      # devuelve el evento más próximo dentro de la ventana [-hoursBefore, +hoursAfter] o $null
    $now = [DateTime]::UtcNow
    foreach ($e in $script:MacroEvents) { $t = [DateTime]::Parse($e.utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal); $h = ($t - $now).TotalHours
        if ($h -le $hoursBefore -and $h -ge -$hoursAfter) { return @{ name = $e.name; utc = $t; hours = $h } } }
    return $null
}
function Get-MacroLine {
    try { $m = Get-MacroNear 24 4; if (-not $m) { return $null }
        $when = if ($m.hours -ge 0) { "en {0:N0} h" -f $m.hours } else { "hace {0:N0} h" -f [Math]::Abs($m.hours) }
        return ("📅 Evento macro cercano: {0} ({1:dd/MM HH:mm} UTC, {2}). Es habitual ver picos de volatilidad y barridos de stops: no abras posiciones nuevas muy apalancadas justo antes y revisa tus SL." -f $m.name, $m.utc, $when) } catch { return $null }
}
