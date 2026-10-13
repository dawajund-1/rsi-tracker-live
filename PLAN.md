# Test plan — written BEFORE any result was computed

**Registered 2026-10-13.** The git history is the evidence: this file is committed before
the first results commit. If it is not, treat every result as exploratory.

This repository is a **copy** of `dawajund-1/intraday-sar-tracker` for the owner's own use:
a 1,000 SAR practice account that trades automatically, and a 500 SAR real-money record
that only logs trades the owner reports. The original tracker is not touched.

The owner asked for two things: a better stock list ("the 10 where it works best, and the
10 where it fails") and fewer large losses. Both are easy to fake with hindsight. This
plan fixes in advance how they are chosen and how they are checked.

---

## 1. Rule (inherited, frozen)

Wilder RSI(2) on daily closes. Buy when RSI closes **below 30** while flat; sell when it
closes **above 70**. Long only. Same as the live tracker. 30 / 70 / period 2 are **not**
tuned here.

## 2. Data and periods

- Yahoo Finance daily bars, split/dividend-adjusted closes, 2009-06 → today.
- **Selection period S = 2010-01-01 → 2021-12-31.** Everything is chosen here.
- **Check period T = 2022-01-01 → today.** Looked at once, after the choices are fixed.
- Candidate pool: the 150 stocks of `universe/universe.json` (chosen objectively by
  2010–2017 dollar volume in the breadth study) **plus** the live tracker's 8 names. The
  8 were picked by hand in 2026 and are flagged as hindsight picks in every result.
- **Survivorship bias:** every candidate exists today; companies that failed are absent.
  Results are therefore optimistic. Reported, not hidden.

## 3. Execution and cost

- Signal on the close of day D, filled at the **close of D** — what the live tracker and
  the pre-close alert do. Next-day fills (D+1 close) are reported as a robustness check.
- Round-trip cost **0.05%** (spread + currency conversion; Awaed charges no commission),
  and **0.10%** as a pessimistic check.

## 4. Stage A — which stocks

Per stock, every trade whose entry falls in S, each stock traded independently.

- Eligible: **at least 40 trades** in S.
- Score: **t-statistic** of net per-trade return in S (mean / standard error). This rewards
  a steady edge, not one lucky trade.
- Consistency: mean net return must be **positive in both halves** of S
  (2010–2015 and 2016–2021).
- **TOP 10** = the 10 highest scores that pass the consistency check.
- **FAIL 10** = the 10 lowest scores among eligible stocks.

**Pass rule for using TOP 10 (decided now):** on T at 0.05% cost, TOP 10's mean net
per-trade return must be (a) positive, (b) higher than the whole pool's, and
(c) significant: date-clustered bootstrap probability of "no edge" **below 0.05**, and
(d) better than chance timing: at or above the **95th percentile** of the matched
random-entry control (same stocks, same holding times, random dates).
If any of these fails, the list is **not** used and the copy keeps the live tracker's 8.

*Amendment before any real result:* condition (d) was added after a dry run on
**synthetic random-walk prices** (no real data) showed that (a)-(c) alone let a list
chosen from pure noise pass, because any long position in a rising market earns money.

## 5. Stage B — fewer large losses

Simulated exactly like the live account: **one position at a time, the whole balance**,
exit first then entry on the same close, entry priority = list order, never re-buy a
name sold on the same day. Run on the stock list chosen in stage A.

| Variant | Change |
|---|---|
| V0 | base rule |
| V1 | **market filter**: new buys only when SPY closes above its 200-day average |
| V2 | **time stop**: sell after 10 trading days if RSI has not reached 70 |
| V3 | **stop-loss**: sell at the close if the price is 8% or more below entry |
| V4 | V1 + V2 + V3 |

**Choice (decided now):** the variant with the best return-to-worst-drawdown ratio
(annual return / maximum drawdown) **in S** is chosen. It is adopted only if, on T, that
ratio is **at least as good as V0's**. Otherwise V0 is kept. All five are reported on T.

## 6. What is reported

For each group/variant: trades, trades per year, win rate, mean net per trade, worst
single trade, maximum drawdown, longest run of losses, and what **1,000 SAR** would have
become over T. Plus the matched random-entry control from the breadth study (same stock,
same holding time, random dates).

## 7. Multiple testing

This is not the project's first test. Prior tests (5m RSI, Tadawul RSI, ORB_RVOL,
VWAP_Trend, XSECT_RS, Regime, the 150-stock breadth study whose holdout **failed**) are
acknowledged. A pass here is evidence, not proof; the practice account exists to keep
gathering it.

## 8. Not allowed

No re-running with other thresholds, lists, stops or periods after seeing T. If a new
idea comes up, it is added here as a new, separately reported test.
