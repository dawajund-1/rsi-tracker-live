# Dashboard refresh during market hours: live prices and RSI, plus the owner's
# ntfy replies. Makes NO trading decision and sends no BUY/SELL alert - those
# come only from Get-Signals.ps1 (22:30 preview, close). Places no trades.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")
. (Join-Path $PSScriptRoot "OutboxLib.ps1")
. (Join-Path $PSScriptRoot "RealAccountLib.ps1")
. (Join-Path $PSScriptRoot "PreCloseLib.ps1")

# Only while the US market is open (9:30-16:05 New York, weekdays). A late
# run after the close would overwrite the closing snapshot and race the
# after-close commit - which is what failed once at 03:00 Riyadh.
$ny = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), [TimeZoneInfo]::FindSystemTimeZoneById("America/New_York"))
$mins = $ny.Hour * 60 + $ny.Minute
if ($ny.DayOfWeek -in 'Saturday', 'Sunday' -or $mins -lt 570 -or $mins -gt 965) {
    Write-Host "refresh: US market closed ($($ny.ToString('ddd HH:mm')) New York) - nothing to do."
    exit 0
}

$cfg   = Read-Config
$state = Read-State
Invoke-OutboxDrain -Cfg $cfg

$real = Read-RealState -Cfg $cfg
Remove-StalePending -State $real -NowUtc (Get-Date).ToUniversalTime()
Invoke-RealReplies -Cfg $cfg -RealState $real -Replies (Get-NtfyReplies -Topic $env:NTFY_TOPIC_US) | Out-Null
Save-RealState $real

$m = Get-LiveMarket -Cfg $cfg
if ($m.Px.Count -gt 0) { Write-LiveSnapshot -Cfg $cfg -State $state -Rsi $m.Rsi -Px $m.Px }

# A refresh is cosmetic: if another run committed first, skip rather than fail.
if (Publish-DataCommit "Live refresh $((Get-Date).ToUniversalTime().ToString('s'))Z") { Invoke-OutboxDrain -Cfg $cfg }
else { Write-Warning "refresh: could not save this refresh (another run saved first); the next one will." }
exit 0
