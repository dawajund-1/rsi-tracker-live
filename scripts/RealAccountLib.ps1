# The owner's REAL account (starts at real_account.starting_sar, default 500 SAR).
#
# Nothing here places an order. The owner trades himself in Awaed and tells the
# system what he did by typing a short reply in the ntfy app, on the same topic
# the alerts arrive on:
#
#   done            -> every pending alert was carried out at the alert price
#   done 226.10     -> the single pending alert was carried out at 226.10
#   bought 226.10   -> the pending BUY was carried out (price optional)
#   sold 742.50     -> the pending SELL was carried out (price optional)
#   skip            -> nothing was done; pending alerts are dropped
#   (Arabic: "تم" = done, "تخطي" = skip)
#
# Only what he confirms enters the ledger. Alerts are about the REAL account:
# the 1,000 SAR practice account trades by itself and needs no alerts.
#
# Dot-sourced after TrackerLib.ps1 and OutboxLib.ps1 ($DataDir must be set).

$RealStatePath  = Join-Path $DataDir "real_state.json"
$RealTradesPath = Join-Path $DataDir "real_trades.csv"

function New-RealState {
    param($Cfg)
    $start = if ($Cfg.real_account -and $Cfg.real_account.starting_sar) { [double]$Cfg.real_account.starting_sar } else { 500.0 }
    return [pscustomobject]@{
        start_sar       = $start
        cash_usd        = [math]::Round($start / [double]$Cfg.sar_per_usd, 4)
        position        = $null
        realized_pl_usd = 0.0
        purified_usd    = 0.0
        pending         = @()
        processed_ids   = @()
    }
}

function Read-RealState {
    param($Cfg)
    if (Test-Path $RealStatePath) {
        $s = Get-Content $RealStatePath -Raw | ConvertFrom-Json
        if ($null -eq $s.pending) { $s | Add-Member pending @() -Force }
        if ($null -eq $s.processed_ids) { $s | Add-Member processed_ids @() -Force }
        return $s
    }
    return New-RealState -Cfg $Cfg
}

function Save-RealState {
    param($State)
    # Keep the processed-id list short; ntfy only caches 12 hours of messages.
    $State.processed_ids = @($State.processed_ids | Select-Object -Last 200)
    $State | ConvertTo-Json -Depth 8 | Set-Content $RealStatePath -Encoding utf8
}

function Add-RealPending {
    # Remember an alert the owner may act on. Same action+ticker+bar is stored once.
    param($State, [string]$Action, [string]$Ticker, [double]$Price, [string]$BarId)
    $key = "${Action}:${Ticker}:${BarId}"
    if (@($State.pending | Where-Object { $_.key -eq $key }).Count) { return }
    $State.pending = @($State.pending) + [pscustomobject]@{
        key = $key; action = $Action; ticker = $Ticker; price = [math]::Round($Price, 4)
        bar = $BarId; created_utc = (Get-Date).ToUniversalTime().ToString("s") + "Z"
    }
}

function Remove-RealPending {
    param($State, [string]$Key)
    $State.pending = @($State.pending | Where-Object { $_.key -ne $Key })
}

function Remove-StalePending {
    # An alert nobody answered within 3 days is dropped: prices have moved on.
    param($State, [datetime]$NowUtc)
    $State.pending = @($State.pending | Where-Object {
        ($NowUtc - [datetime]::Parse($_.created_utc).ToUniversalTime()).TotalDays -lt 3 })
}

function Get-RealValueUsd {
    param($State, [hashtable]$Prices)
    $v = [double]$State.cash_usd
    if ($State.position) {
        $p = if ($Prices -and $Prices.ContainsKey($State.position.ticker)) { $Prices[$State.position.ticker] } else { [double]$State.position.entry_price }
        $v += [double]$State.position.shares * $p
    }
    return [math]::Round($v, 4)
}

function Invoke-RealSell {
    param($State, [double]$Price, $Cfg, [string]$WhenUtc)
    $pos = $State.position
    if (-not $pos) { return $null }
    $pl  = [math]::Round(($Price - [double]$pos.entry_price) * [double]$pos.shares, 4)
    $pur = if ($pl -gt 0) { [math]::Round($pl * [double]$Cfg.purification_pct, 4) } else { 0.0 }
    $State.cash_usd = [math]::Round([double]$State.cash_usd + [double]$pos.shares * $Price - $pur, 4)
    $State.realized_pl_usd = [math]::Round([double]$State.realized_pl_usd + $pl, 4)
    $State.purified_usd = [math]::Round([double]$State.purified_usd + $pur, 4)
    $row = [pscustomobject]@{
        timestamp_utc = $WhenUtc; action = "SELL"; ticker = $pos.ticker; price = [math]::Round($Price, 4)
        shares = $pos.shares; entry_price = $pos.entry_price; pl_usd = $pl; purification_usd = $pur
        cash_after_usd = $State.cash_usd
    }
    $State.position = $null
    return $row
}

function Invoke-RealBuy {
    # Whole cash balance, fractional shares (Awaed allows them).
    param($State, [string]$Ticker, [double]$Price, [string]$WhenUtc)
    if ($State.position -or [double]$State.cash_usd -le 0) { return $null }
    $shares = [math]::Round([double]$State.cash_usd / $Price, 6)
    $State.position = [pscustomobject]@{ ticker = $Ticker; shares = $shares; entry_price = [math]::Round($Price, 4); entry_time = $WhenUtc }
    $row = [pscustomobject]@{
        timestamp_utc = $WhenUtc; action = "BUY"; ticker = $Ticker; price = [math]::Round($Price, 4)
        shares = $shares; entry_price = [math]::Round($Price, 4); pl_usd = ""; purification_usd = ""
        cash_after_usd = 0.0
    }
    $State.cash_usd = 0.0
    return $row
}

function ConvertFrom-Reply {
    # Pure. Turns one reply into a plan against the pending alerts.
    # Returns @{ Kind = "apply"|"skip"|"unclear"; Items = @(@{key;action;ticker;price}); Note = "..." }
    param([string]$Text, $Pending)
    $t = ($Text -replace '\s+', ' ').Trim().ToLowerInvariant()
    $t = $t -replace '^تم', 'done' -replace '^تخطي', 'skip' -replace '٫', '.'
    $digits = '٠١٢٣٤٥٦٧٨٩'
    for ($i = 0; $i -lt 10; $i++) { $t = $t.Replace($digits[$i], [string]$i) }
    $pend = @($Pending)
    $num = if ($t -match '(\d+(?:[.,]\d+)?)') { [double]($Matches[1] -replace ',', '.') } else { $null }

    if ($t -match '^(skip|no|cancel)\b') { return @{ Kind = "skip"; Items = @(); Note = "" } }
    if ($pend.Count -eq 0) { return @{ Kind = "unclear"; Items = @(); Note = "There is no open alert to confirm." } }

    $pick = $null
    if ($t -match '^(bought|buy)\b')      { $pick = @($pend | Where-Object { $_.action -eq "BUY" }) }
    elseif ($t -match '^(sold|sell)\b')   { $pick = @($pend | Where-Object { $_.action -eq "SELL" }) }
    elseif ($t -match '^(done|ok|yes)\b') {
        if ($null -ne $num -and $pend.Count -gt 1) {
            return @{ Kind = "unclear"; Items = @(); Note = "Two alerts are open. Reply 'sold <price>' and 'bought <price>' separately, or just 'done'." }
        }
        $pick = $pend
    } else {
        return @{ Kind = "unclear"; Items = @(); Note = "Reply 'done', 'done <price>', 'bought <price>', 'sold <price>' or 'skip'." }
    }
    if (-not $pick -or $pick.Count -eq 0) { return @{ Kind = "unclear"; Items = @(); Note = "No matching open alert." } }
    # A typed price far from the alert price is almost always a typo; refuse it
    # rather than let one slip distort the balance.
    if ($null -ne $num -and $pick.Count -eq 1) {
        $ref = [double]$pick[0].price
        if ($ref -gt 0 -and [math]::Abs($num / $ref - 1) -gt 0.20) {
            return @{ Kind = "unclear"; Items = @()
                      Note = "The price $num is far from the alert price $ref - please check it and reply again." }
        }
    }

    $items = @($pick | Sort-Object { if ($_.action -eq "SELL") { 0 } else { 1 } } | ForEach-Object {
        @{ key = $_.key; action = $_.action; ticker = $_.ticker
           price = if ($null -ne $num -and $pick.Count -eq 1) { $num } else { [double]$_.price } }
    })
    return @{ Kind = "apply"; Items = $items; Note = "" }
}

function Get-NtfyReplies {
    # Messages the owner typed in the app: no title (every bot message has one).
    param([string]$Topic)
    if (-not $Topic) { return @() }
    try {
        $raw = Invoke-WebRequest -Uri "https://ntfy.sh/$Topic/json?poll=1&since=12h" -TimeoutSec 20 -UseBasicParsing
    } catch {
        Write-Warning "replies: could not read ntfy - $($_.Exception.Message)"
        return @()
    }
    $out = @()
    foreach ($line in ($raw.Content -split "`n")) {
        if (-not $line.Trim()) { continue }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ($m.event -eq "message" -and -not $m.title -and $m.message) { $out += $m }
    }
    return @($out | Sort-Object time)
}

function Invoke-RealReplies {
    # Applies every new reply. Returns $true if anything changed (caller commits).
    param($Cfg, $RealState, $Replies)
    $changed = $false
    foreach ($m in @($Replies | Where-Object { $_ -and $_.id })) {
        if (@($RealState.processed_ids) -contains $m.id) { continue }
        $RealState.processed_ids = @($RealState.processed_ids) + $m.id
        $changed = $true
        $when = ([DateTimeOffset]::FromUnixTimeSeconds([int64]$m.time)).UtcDateTime.ToString("s") + "Z"
        $plan = ConvertFrom-Reply -Text $m.message -Pending $RealState.pending
        $lines = @()
        if ($plan.Kind -eq "skip") {
            $n = @($RealState.pending).Count
            $RealState.pending = @()
            $lines += "Noted: nothing done ($n open alert(s) dropped)."
        } elseif ($plan.Kind -eq "unclear") {
            $lines += "Not recorded. $($plan.Note)"
        } else {
            foreach ($it in $plan.Items) {
                if ($it.action -eq "SELL") {
                    if (-not $RealState.position -or $RealState.position.ticker -ne $it.ticker) {
                        $lines += "Skipped SELL $($it.ticker): your record does not hold it."
                    } else {
                        $row = Invoke-RealSell -State $RealState -Price $it.price -Cfg $Cfg -WhenUtc $when
                        Append-Csv -Path $RealTradesPath -Row $row
                        $lines += "Recorded SELL $($row.ticker) $($row.shares) sh @ `$$($row.price) | P/L `$$($row.pl_usd) | purified `$$($row.purification_usd)"
                    }
                } else {
                    $row = Invoke-RealBuy -State $RealState -Ticker $it.ticker -Price $it.price -WhenUtc $when
                    if ($row) {
                        Append-Csv -Path $RealTradesPath -Row $row
                        $lines += "Recorded BUY $($row.ticker) $($row.shares) sh @ `$$($row.price)"
                    } else {
                        $lines += "Skipped BUY $($it.ticker): your record already holds $($RealState.position.ticker)."
                    }
                }
                Remove-RealPending -State $RealState -Key $it.key
            }
        }
        $value = Get-RealValueUsd -State $RealState -Prices @{}
        $sar = [math]::Round($value * [double]$Cfg.sar_per_usd, 2)
        $hold = if ($RealState.position) { "holding $($RealState.position.ticker)" } else { "all cash" }
        Add-OutboxEvent -Id "REPLY:$($m.id)" -Title "Your account" `
            -Message (($lines -join " | ") + " | Balance about SAR $sar ($hold)") | Out-Null
    }
    return $changed
}
