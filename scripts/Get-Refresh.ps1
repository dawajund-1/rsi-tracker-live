# Dashboard refresh during market hours: live prices and RSI, plus the owner's
# ntfy replies. Makes NO trading decision and sends no BUY/SELL alert - those
# come only from Get-Signals.ps1 (22:30 preview, close). Places no trades.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")
. (Join-Path $PSScriptRoot "OutboxLib.ps1")
. (Join-Path $PSScriptRoot "RealAccountLib.ps1")
. (Join-Path $PSScriptRoot "PreCloseLib.ps1")

$cfg   = Read-Config
$state = Read-State
Invoke-OutboxDrain -Cfg $cfg

$real = Read-RealState -Cfg $cfg
Remove-StalePending -State $real -NowUtc (Get-Date).ToUniversalTime()
Invoke-RealReplies -Cfg $cfg -RealState $real -Replies (Get-NtfyReplies -Topic $env:NTFY_TOPIC_US) | Out-Null
Save-RealState $real

$m = Get-LiveMarket -Cfg $cfg
if ($m.Px.Count -gt 0) { Write-LiveSnapshot -Cfg $cfg -State $state -Rsi $m.Rsi -Px $m.Px }

if (Publish-DataCommit "Live refresh $((Get-Date).ToUniversalTime().ToString('s'))Z") { Invoke-OutboxDrain -Cfg $cfg }
