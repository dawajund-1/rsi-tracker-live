"""Implements PLAN.md exactly. Writes results/study.json and prints a summary.

Stage A: rank stocks on the selection period S, check the chosen list once on T.
Stage B: simulate the live account (one position, whole balance) with five pre-declared
         loss-control variants; choose on S, check on T.

Nothing here is tuned after seeing T. See PLAN.md sections 4-5 for every threshold.
"""
import json
import math
import os
import sys
from collections import defaultdict
from datetime import datetime, timezone

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CACHE = os.path.join(ROOT, "data_cache")

RSI_PERIOD, BUY_BELOW, SELL_ABOVE = 2, 30.0, 70.0
S = ("2010-01-01", "2021-12-31")
S1 = ("2010-01-01", "2015-12-31")
S2 = ("2016-01-01", "2021-12-31")
T = ("2022-01-01", "2099-12-31")
COST, COST_HI = 0.0005, 0.0010
MIN_TRADES = 40
LIVE8 = ["AAPL", "MSFT", "NVDA", "TSLA", "AMZN", "GOOGL", "META", "AMD"]
START_SAR = 1000.0
TIME_STOP_DAYS, STOP_LOSS, SMA_DAYS = 10, 0.08, 200


# ---------------------------------------------------------------- data / RSI

def wilder_rsi(c):
    """Identical maths to the live tracker's Get-RsiLast and the breadth engine."""
    n = len(c)
    out = np.full(n, np.nan)
    if n < RSI_PERIOD + 1:
        return out
    d = np.diff(c)
    g, l = np.where(d > 0, d, 0.0), np.where(d < 0, -d, 0.0)
    ag, al = g[:RSI_PERIOD].mean(), l[:RSI_PERIOD].mean()
    out[RSI_PERIOD] = 100.0 if al == 0 else 100.0 - 100.0 / (1 + ag / al)
    for i in range(RSI_PERIOD, n - 1):
        ag = (ag * (RSI_PERIOD - 1) + g[i]) / RSI_PERIOD
        al = (al * (RSI_PERIOD - 1) + l[i]) / RSI_PERIOD
        out[i + 1] = 100.0 if al == 0 else 100.0 - 100.0 / (1 + ag / al)
    return out


def load():
    tickers = []
    for line in open(os.path.join(ROOT, "universe", "candidates.txt")):
        if line.strip() and not line.startswith("#"):
            tickers += line.split()
    data = {}
    for t in dict.fromkeys(tickers):
        p = os.path.join(CACHE, f"{t}.json")
        if not os.path.exists(p):
            continue
        rows = json.load(open(p))
        dates = [r[0] for r in rows]
        closes = np.array([r[1] for r in rows], dtype=float)
        data[t] = {"dates": dates, "close": closes, "rsi": wilder_rsi(closes),
                   "idx": {d: i for i, d in enumerate(dates)}}
    return data


def inside(d, period):
    return period[0] <= d <= period[1]


# ---------------------------------------------------------------- stage A

def stock_trades(t, s, lag=0):
    """Independent trades for one stock. lag=0: fill at signal close; lag=1: next close."""
    c, r, dates = s["close"], s["rsi"], s["dates"]
    out, pos = [], None
    for i in range(len(c) - lag):
        if np.isnan(r[i]):
            continue
        if pos is None and r[i] < BUY_BELOW:
            pos = i + lag
        elif pos is not None and r[i] > SELL_ABOVE and i + lag > pos:
            x = i + lag
            out.append({"ticker": t, "entry": dates[pos], "exit": dates[x],
                        "hold": x - pos, "gross": c[x] / c[pos] - 1.0})
            pos = None
    return out


def summarize(trades, cost=COST, years=None):
    if not trades:
        return {"trades": 0}
    n = np.array([t["gross"] - cost for t in trades])
    out = {"trades": len(n), "win_rate": float((n > 0).mean()),
           "mean_net": float(n.mean()), "worst": float(n.min()),
           "median_hold": float(np.median([t["hold"] for t in trades]))}
    if years:
        out["per_year"] = len(n) / years
    if len(n) > 1:
        out["t_stat"] = float(n.mean() / (n.std(ddof=1) / math.sqrt(len(n)))) if n.std(ddof=1) > 0 else 0.0
    return out


def bootstrap_p(trades, cost=COST, reps=2000, seed=7):
    """Date-clustered: resample whole entry dates. Returns (CI lo, CI hi, P(mean<=0))."""
    g = defaultdict(list)
    for t in trades:
        g[t["entry"]].append(t["gross"] - cost)
    arrs = [np.array(v) for v in g.values()]
    if not arrs:
        return None, None, None
    rng = np.random.default_rng(seed)
    k = len(arrs)
    means = np.array([np.concatenate([arrs[i] for i in rng.integers(0, k, k)]).mean()
                      for _ in range(reps)])
    return float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5)), float((means <= 0).mean())


def random_control(trades, data, period, cost=COST, reps=1000, seed=11):
    """Same stock, same holding time, random entry date in the same period; one shared
    draw per real entry date so the null is as correlated as the strategy."""
    if not trades:
        return None
    rng = np.random.default_rng(seed)
    real = float(np.mean([t["gross"] - cost for t in trades]))
    by_date = defaultdict(list)
    for t in trades:
        by_date[t["entry"]].append(t)
    ok = {t: [i for i, d in enumerate(data[t]["dates"]) if inside(d, period)]
          for t in {x["ticker"] for x in trades}}
    null = np.empty(reps)
    for b in range(reps):
        vals = []
        for grp in by_date.values():
            u = rng.random()
            for t in grp:
                idx = ok[t["ticker"]]
                span = len(idx) - t["hold"] - 1
                if span <= 0:
                    continue
                i = idx[int(u * span)]
                c = data[t["ticker"]]["close"]
                if i + t["hold"] < len(c):
                    vals.append(c[i + t["hold"]] / c[i] - 1.0 - cost)
        null[b] = np.mean(vals) if vals else 0.0
    return {"real": real, "null_mean": float(null.mean()),
            "percentile": float((null < real).mean() * 100), "p": float((null >= real).mean())}


def years_of(period, data):
    last = max(s["dates"][-1] for s in data.values())
    a = datetime.fromisoformat(period[0])
    b = datetime.fromisoformat(min(period[1], last))
    return (b - a).days / 365.25


def stage_a(data):
    pool = [t for t in data if t != "SPY"]
    per = {}
    for t in pool:
        tr = stock_trades(t, data[t])
        sel = [x for x in tr if inside(x["entry"], S)]
        h1 = [x for x in tr if inside(x["entry"], S1)]
        h2 = [x for x in tr if inside(x["entry"], S2)]
        tst = [x for x in tr if inside(x["entry"], T)]
        per[t] = {"S": summarize(sel), "S1": summarize(h1), "S2": summarize(h2),
                  "T": summarize(tst), "hindsight_pick": t in LIVE8, "_all": tr}

    eligible = [t for t in pool if per[t]["S"].get("trades", 0) >= MIN_TRADES]
    ranked = sorted(eligible, key=lambda t: per[t]["S"]["t_stat"], reverse=True)
    consistent = [t for t in ranked
                  if per[t]["S1"].get("mean_net", -1) > 0 and per[t]["S2"].get("mean_net", -1) > 0]
    top10 = consistent[:10]
    fail10 = sorted(eligible, key=lambda t: per[t]["S"]["t_stat"])[:10]

    yT = years_of(T, data)

    def group(names, period, cost=COST, lag=0):
        tr = []
        for t in names:
            src = per[t]["_all"] if lag == 0 else stock_trades(t, data[t], lag=1)
            tr += [x for x in src if inside(x["entry"], period)]
        return tr

    groups = {"TOP10": top10, "FAIL10": fail10, "LIVE8": LIVE8, "ALL": eligible}
    check = {}
    for name, names in groups.items():
        tr = group(names, T)
        lo, hi, p = bootstrap_p(tr)
        check[name] = {
            "names": names if name != "ALL" else f"{len(names)} stocks",
            "T": summarize(tr, years=yT), "T_cost_0.10%": summarize(tr, cost=COST_HI),
            "T_next_day_fill": summarize(group(names, T, lag=1)),
            "S": summarize(group(names, S), years=years_of(S, data)),
            "boot_ci": [lo, hi], "p_no_edge": p,
            "random_control": random_control(tr, data, T),
        }

    top, allp = check["TOP10"], check["ALL"]
    passed = (top["T"].get("mean_net", -1) > 0
              and top["T"].get("mean_net", -1) > allp["T"].get("mean_net", 9)
              and top["p_no_edge"] is not None and top["p_no_edge"] < 0.05
              and top["random_control"] is not None and top["random_control"]["percentile"] >= 95.0)
    table = {t: {k: per[t][k] for k in ("S", "S1", "S2", "T", "hindsight_pick")} for t in pool}
    return {"top10": top10, "fail10": fail10, "eligible": len(eligible),
            "groups": check, "top10_passes": bool(passed),
            "chosen_list": top10 if passed else LIVE8, "per_stock": table}


# ---------------------------------------------------------------- stage B

def simulate(data, names, period, variant, cost=COST):
    """The live account: one position, whole balance, exit then entry on the same close,
    entry priority = list order, never re-buy a name sold that day."""
    spy = data["SPY"]
    spy_sma = np.convolve(spy["close"], np.ones(SMA_DAYS) / SMA_DAYS, mode="full")[:len(spy["close"])]
    spy_sma[:SMA_DAYS - 1] = np.nan
    days = sorted({d for t in names for d in data[t]["dates"] if inside(d, period)})
    use_filter = variant in ("V1", "V4")
    use_time = variant in ("V2", "V4")
    use_stop = variant in ("V3", "V4")

    eq, pos, trades, curve = 1.0, None, [], []
    for d in days:
        # exit
        if pos:
            s = data[pos["t"]]
            i = s["idx"].get(d)
            if i is not None:
                held = i - pos["i"]
                px = s["close"][i]
                why = None
                if s["rsi"][i] > SELL_ABOVE:
                    why = "rsi"
                elif use_stop and px <= pos["px"] * (1 - STOP_LOSS):
                    why = "stop"
                elif use_time and held >= TIME_STOP_DAYS:
                    why = "time"
                if why:
                    r = px / pos["px"] - 1.0 - cost
                    eq *= 1 + r
                    trades.append({"ticker": pos["t"], "entry": pos["d"], "exit": d,
                                   "hold": held, "net": r, "why": why})
                    sold, pos = pos["t"], None
                else:
                    sold = None
            else:
                sold = None
        else:
            sold = None
        # entry
        if pos is None:
            ok = True
            if use_filter:
                j = spy["idx"].get(d)
                ok = j is not None and not np.isnan(spy_sma[j]) and spy["close"][j] > spy_sma[j]
            if ok:
                for t in names:
                    if t == sold:
                        continue
                    s = data[t]
                    i = s["idx"].get(d)
                    if i is not None and not np.isnan(s["rsi"][i]) and s["rsi"][i] < BUY_BELOW:
                        pos = {"t": t, "i": i, "d": d, "px": s["close"][i]}
                        break
        # mark to market
        m = eq
        if pos:
            s = data[pos["t"]]
            i = s["idx"].get(d)
            if i is not None:
                m = eq * s["close"][i] / pos["px"]
        curve.append(m)

    curve = np.array(curve) if curve else np.array([1.0])
    peak = np.maximum.accumulate(curve)
    mdd = float(((curve - peak) / peak).min())
    yrs = max(len(days) / 252.0, 1e-9)
    cagr = float(curve[-1] ** (1 / yrs) - 1) if curve[-1] > 0 else -1.0
    nets = np.array([t["net"] for t in trades]) if trades else np.array([0.0])
    streak = run = 0
    for x in nets:
        run = run + 1 if x <= 0 else 0
        streak = max(streak, run)
    return {"trades": len(trades), "per_year": len(trades) / yrs,
            "win_rate": float((nets > 0).mean()) if trades else None,
            "mean_net": float(nets.mean()) if trades else None,
            "worst_trade": float(nets.min()) if trades else None,
            "max_drawdown": mdd, "annual_return": cagr,
            "ratio": cagr / abs(mdd) if mdd < 0 else None,
            "longest_losing_run": streak,
            "sar_1000_becomes": round(START_SAR * float(curve[-1]), 2),
            "exits": {k: sum(1 for t in trades if t["why"] == k) for k in ("rsi", "stop", "time")},
            "last_trades": trades[-5:]}


def stage_b(data, names):
    variants = ["V0", "V1", "V2", "V3", "V4"]
    resS = {v: simulate(data, names, S, v) for v in variants}
    best = max(variants, key=lambda v: resS[v]["ratio"] if resS[v]["ratio"] is not None else -9)
    resT = {v: simulate(data, names, T, v) for v in variants}
    resT_hi = {v: simulate(data, names, T, v, cost=COST_HI) for v in variants}
    rb, r0 = resT[best]["ratio"], resT["V0"]["ratio"]
    adopted = best if (best == "V0" or (rb is not None and r0 is not None and rb >= r0)
                       or (rb is not None and r0 is None)) else "V0"
    live8T = {v: simulate(data, LIVE8, T, v) for v in ("V0", best)}
    return {"chosen_on_S": best, "adopted": adopted, "S": resS, "T": resT,
            "T_cost_0.10%": resT_hi, "LIVE8_T_for_comparison": live8T}


def main():
    data = load()
    if "SPY" not in data:
        print("SPY missing - cannot run stage B")
        return 1
    last = max(s["dates"][-1] for s in data.values())
    a = stage_a(data)
    b = stage_b(data, a["chosen_list"])
    out = {"generated_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
           "data_through": last, "stocks_loaded": len(data) - 1, "plan": "PLAN.md",
           "selection_period": S, "check_period": [T[0], last],
           "stage_a": a, "stage_b": b}
    os.makedirs(os.path.join(ROOT, "results"), exist_ok=True)
    with open(os.path.join(ROOT, "results", "study.json"), "w") as fh:
        json.dump(out, fh, indent=1, default=float)

    g = a["groups"]
    print(f"data through {last}; {len(data)-1} stocks; eligible {a['eligible']}")
    print("TOP10 :", a["top10"])
    print("FAIL10:", a["fail10"])
    for k in ("TOP10", "ALL", "LIVE8", "FAIL10"):
        tt = g[k]["T"]
        print(f"  {k:6s} T: trades {tt.get('trades')}, win {tt.get('win_rate',0):.1%}, "
              f"mean {tt.get('mean_net',0):+.3%}, p_no_edge {g[k]['p_no_edge']}, "
              f"rand pct {g[k]['random_control'] and round(g[k]['random_control']['percentile'],1)}")
    print("TOP10 passes:", a["top10_passes"], "-> list used:", a["chosen_list"])
    for v, r in b["T"].items():
        print(f"  {v} T: 1000 SAR -> {r['sar_1000_becomes']}, maxDD {r['max_drawdown']:.1%}, "
              f"worst {r['worst_trade'] or 0:+.1%}, win {r['win_rate'] or 0:.1%}, trades {r['trades']}")
    print("variant chosen on S:", b["chosen_on_S"], "adopted:", b["adopted"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
