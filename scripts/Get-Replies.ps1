# Reads the owner's replies in the ntfy app ("done", "sold 742.5", "skip" ...)
# and updates his REAL account. Runs every few hours so no reply is lost:
# ntfy.sh keeps messages for 12 hours only. Places no trades.

. (Join-Path $PSScriptRoot "TrackerLib.ps1")
. (Join-Path $PSScriptRoot "OutboxLib.ps1")
. (Join-Path $PSScriptRoot "RealAccountLib.ps1")

$cfg  = Read-Config
Invoke-OutboxDrain -Cfg $cfg

$real = Read-RealState -Cfg $cfg
Remove-StalePending -State $real -NowUtc (Get-Date).ToUniversalTime()
$changed = Invoke-RealReplies -Cfg $cfg -RealState $real -Replies (Get-NtfyReplies -Topic $env:NTFY_TOPIC_US)
if (-not $changed) { Write-Host "replies: nothing new."; exit 0 }
Save-RealState $real

if (Publish-DataCommit "Real account: replies $((Get-Date).ToUniversalTime().ToString('s'))Z") { Invoke-OutboxDrain -Cfg $cfg }
else { Write-Warning "replies: data commit did not land; confirmation left undelivered on purpose." }
