# RSI Live Tracker (copy)

A copy of [`intraday-sar-tracker`](https://github.com/dawajund-1/intraday-sar-tracker)
for the owner's own trading. **The original is not touched by anything in this repo.**

**Never logs into Awaed and never places an order.** It reads public US prices, applies
the RSI(2) rule, keeps two accounts and sends alerts to the owner's phone (ntfy).

Dashboard: https://dawajund-1.github.io/rsi-tracker-live/

## Two accounts

| | Practice | Your real account |
|---|---|---|
| Start | 1,000 SAR | 500 SAR |
| Trades | by itself, on the real close | only what **you** confirm |
| Alerts | none (shown in the daily summary) | yes |
| Files | `data/state.json`, `data/paper_trades.csv` | `data/real_state.json`, `data/real_trades.csv` |

## When messages arrive (Riyadh time)

| Message | Summer | Winter (from 2 Nov) | Market |
|---|---|---|---|
| **BUY / SELL** for your account, with share count | ~22:30 | ~23:30 | open |
| Correction, if the 22:30 signal did not hold at the close | ~23:15 | ~00:15 | closed |
| Daily summary: your account + practice | ~23:20 | ~00:20 | closed |

## Confirming what you did

Type a reply in the ntfy app, in the same channel the alerts arrive on:

| You type | Meaning |
|---|---|
| `done` (or `تم`) | I did what the alert said, at the alert price |
| `done 226.10` | I did it at 226.10 |
| `bought 226.10` / `sold 742.50` | when a SELL and a BUY are both open |
| `skip` (or `تخطي`) | I did nothing |

You get a confirmation with your new balance. A price more than 20% away from the alert
price is refused as a likely typo. Alerts with no reply for 3 days are dropped. Replies
are read every 2 hours and on every run.

## The rule and the stock list

Same as the original: Wilder RSI(2) on daily closes, buy below 30, sell above 70, one
position at a time, the 8 names in `config.json`.

Before copying, `PLAN.md` registered a fair test of a "best 10 stocks" list and of three
loss limits (market filter, 10-day time stop, 8% stop-loss). Results are in
`results/study.json`:

- the best-10 list **failed** on 2022-2026 (it did no better than the worst 10), so the
  original 8 are kept;
- no loss limit beat the base rule, so the rule is unchanged;
- realistic picture 2022-2026 for this rule: 1,000 SAR -> about 1,426 SAR (about +8% a
  year), 61% winning trades, worst single trade -23.5%, and at its worst the account
  was **47% below its peak**. Survivorship bias makes even this optimistic.

## Files

| Path | Purpose |
|---|---|
| `scripts/Get-Signals.ps1` | nightly run: replies, pre-close alert, practice trade, close check |
| `scripts/RealAccountLib.ps1` | your real account and reply reading |
| `scripts/PreCloseLib.ps1` | the 22:30 preview |
| `scripts/Get-DailySummary.ps1` | the summary |
| `scripts/Get-Replies.ps1` | reads replies every 2 hours |
| `scripts/Test-Idempotency.ps1` | tests, run before every signal job |
| `research/` | the PLAN.md study |
