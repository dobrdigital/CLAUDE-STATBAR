#!/usr/bin/env bash
# Claude Code status line: model name, real OpenRouter cost, and a per-session
# token breakdown (input / output / cache write / cache read / context window %).
# Cost is computed from OpenRouter API pricing (pricing.prompt / pricing.completion),
# cached in ~/.claude/cache/openrouter-prices.json (refreshed every 6 hours).
# Every token/cache/context segment is only printed when Claude Code actually
# supplies that field on stdin (context_window.*), so nothing shows as 0 or
# wrong when the payload doesn't include it (e.g. before the first API call).

input=$(cat)

python - "$input" <<'PYEOF'
import sys, json, os, time, subprocess

# force UTF-8 on stdout: Windows Python defaults to cp1252, which mangles
# non-ASCII separators (•) into garbage in the UTF-8 terminal
try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

raw = sys.argv[1]
try:
    d = json.loads(raw)
except Exception:
    sys.exit(0)

model_obj = d.get("model") or {}
mid = model_obj.get("id") if isinstance(model_obj, dict) else model_obj
if not mid:
    mid = model_obj.get("display_name", "") if isinstance(model_obj, dict) else str(model_obj or "")
mname = model_obj.get("display_name") if isinstance(model_obj, dict) else ""
if not mname:
    mname = mid

cw = d.get("context_window") or {}
in_tok = int(cw.get("total_input_tokens") or 0)
out_tok = int(cw.get("total_output_tokens") or 0)
pct = cw.get("used_percentage")
cw_size = cw.get("context_window_size")
current_usage = cw.get("current_usage")
if not isinstance(current_usage, dict):
    current_usage = {}
cache_write = current_usage.get("cache_creation_input_tokens")
cache_read = current_usage.get("cache_read_input_tokens")

DIM = "\033[2m"
RESET = "\033[0m"

# Muted 256-color palette (mid-tones, dimmed) so the line is readable but quiet.
C_GREEN  = 71   # key balance
C_AMBER  = 178  # daily spend
C_CYAN   = 74   # model price
C_BLUE   = 68   # tokens
C_PURPLE = 134  # cache
C_TEAL   = 66   # context usage

def seg(code, text):
    return f"{DIM}\033[38;5;{code}m{text}{RESET}"

def fmt_tok(n):
    if n >= 1000000:
        m = f"{n/1000000:.1f}M"
        return m.replace(".0M", "M")
    if n >= 1000:
        return f"{n/1000:.1f}k"
    return str(n)

CACHE = os.path.expanduser("~/.claude/cache/openrouter-prices.json")
TTL = 6 * 3600

def fetch_effective(model_id, key, enc):
    # Real billed price = the cheapest endpoint's price (list price minus the
    # provider's promo, e.g. StreamLake 44% off). /api/v1/models only returns
    # list prices; this endpoint returns what you actually pay per provider.
    try:
        url = "https://openrouter.ai/api/v1/models/" + model_id + "/endpoints"
        if key:
            out = subprocess.run(
                ["curl", "-s", "--max-time", "8", url, "-H", f"Authorization: Bearer {key}"],
                capture_output=True, text=True, timeout=12, **enc)
        else:
            out = subprocess.run(["curl", "-s", "--max-time", "8", url],
                                 capture_output=True, text=True, timeout=12, **enc)
        eps = json.loads(out.stdout).get("data", {}).get("endpoints", []) or []
        best = None
        for e in eps:
            p = e.get("pricing") or {}
            try:
                ppr = float(p.get("prompt", 0) or 0)
            except (TypeError, ValueError):
                continue
            if ppr <= 0:
                continue
            if best is None or ppr < best["prompt"]:
                best = {"prompt": ppr,
                        "completion": float(p.get("completion", 0) or 0),
                        "cache_read": float(p.get("input_cache_read", 0) or 0),
                        "provider": e.get("provider_name")}
        return best
    except Exception:
        return None

def get_price(model_id):
    data, fetched = {}, 0
    try:
        with open(CACHE, "r", encoding="utf-8") as f:
            data = json.load(f)
        fetched = data.get("_fetched", 0)
    except Exception:
        pass
    entry = data.get("models", {}).get(model_id) if isinstance(data, dict) else None
    # stale if too old OR missing a field (cache written before a schema bump)
    if entry and time.time() - fetched < TTL and "context" in entry and "eff_prompt" in entry:
        return entry
    # cache miss / stale -> refresh from OpenRouter
    try:
        key = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
        url = "https://openrouter.ai/api/v1/models"
        enc = {"encoding": "utf-8", "errors": "replace"}
        if key:
            out = subprocess.run(
                ["curl", "-s", "--max-time", "8", url, "-H", f"Authorization: Bearer {key}"],
                capture_output=True, text=True, timeout=12, **enc)
        else:
            out = subprocess.run(["curl", "-s", "--max-time", "8", url],
                                 capture_output=True, text=True, timeout=12, **enc)
        ms = json.loads(out.stdout).get("data", [])
        models = {}
        for m in ms:
            p = m.get("pricing") or {}
            try:
                tp = m.get("top_provider") or {}
                # "realistically available" context = what the top provider actually
                # exposes, not the model's theoretical max
                context = tp.get("context_length") if tp else m.get("context_length")
                models[m["id"]] = {"prompt": float(p.get("prompt", 0) or 0),
                                   "completion": float(p.get("completion", 0) or 0),
                                   "cache_read": float(p.get("input_cache_read", 0) or 0),
                                   "context": context}
            except (TypeError, ValueError):
                continue
        # overlay effective prices of the CURRENT model (cheapest live endpoint)
        eff = fetch_effective(model_id, key, enc)
        cur = models.get(model_id)
        if cur is not None:
            cur["eff_prompt"] = eff["prompt"] if eff else None
            cur["eff_completion"] = eff["completion"] if eff else None
            cur["eff_cache_read"] = eff["cache_read"] if eff else None
            cur["eff_provider"] = eff["provider"] if eff else None
        with open(CACHE, "w", encoding="utf-8") as f:
            json.dump({"_fetched": time.time(), "models": models}, f)
        return models.get(model_id)
    except Exception:
        return entry

price = get_price(mid)

# Daily / monthly spend from /api/v1/key (usage_daily / usage_monthly).
# Same 5-min cache trick so we don't hit the API on every redraw.
KEY_CACHE = os.path.expanduser("~/.claude/cache/openrouter-key.json")

def get_spend():
    data = {}
    try:
        with open(KEY_CACHE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if time.time() - data.get("_fetched", 0) < BAL_TTL and "daily" in data:
            return data["daily"], data["monthly"]
    except Exception:
        pass
    try:
        key = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
        url = "https://openrouter.ai/api/v1/key"
        out = subprocess.run(
            ["curl", "-s", "--max-time", "8", url, "-H", f"Authorization: Bearer {key}"],
            capture_output=True, text=True, timeout=12, encoding="utf-8", errors="replace")
        j = json.loads(out.stdout).get("data") or {}
        if "usage_daily" in j and "usage_monthly" in j:
            daily = float(j["usage_daily"]); monthly = float(j["usage_monthly"])
            with open(KEY_CACHE, "w", encoding="utf-8") as f:
                json.dump({"_fetched": time.time(), "daily": daily, "monthly": monthly}, f)
            return daily, monthly
    except Exception:
        pass
    return None, None

# OpenRouter key balance (credits): limit - usage from /api/v1/auth/key.
# Cached ~5 min so it doesn't hit the API on every statusline redraw.
BAL_CACHE = os.path.expanduser("~/.claude/cache/openrouter-balance.json")
BAL_TTL = 5 * 60

def get_balance():
    data = {}
    try:
        with open(BAL_CACHE, "r", encoding="utf-8") as f:
            data = json.load(f)
        if time.time() - data.get("_fetched", 0) < BAL_TTL and "balance" in data:
            return data["balance"]
    except Exception:
        pass
    try:
        key = os.environ.get("ANTHROPIC_AUTH_TOKEN", "")
        url = "https://openrouter.ai/api/v1/credits"
        out = subprocess.run(
            ["curl", "-s", "--max-time", "8", url, "-H", f"Authorization: Bearer {key}"],
            capture_output=True, text=True, timeout=12, encoding="utf-8", errors="replace")
        j = json.loads(out.stdout).get("data") or {}
        # total_credits = credited, total_usage = spent -> balance = difference
        if "total_credits" in j and "total_usage" in j:
            bal = float(j["total_credits"]) - float(j["total_usage"])
            with open(BAL_CACHE, "w", encoding="utf-8") as f:
                json.dump({"_fetched": time.time(), "balance": bal}, f)
            return bal
    except Exception:
        pass
    return None

# Short model label from the slug: "deepseek/deepseek-v4-flash-0731" -> "V4-flash-0731"
def short_name(mid):
    if mid and "/" in mid:
        prov, slug = mid.split("/", 1)
        if slug.startswith(prov + "-"):
            slug = slug[len(prov) + 1:]
    else:
        slug = mid or mname
    if slug:
        slug = slug[:1].upper() + slug[1:]
    return slug or mname

parts = [f"{DIM}{short_name(mid)}{RESET}"]

bal = get_balance()
if bal is not None:
    parts.append(seg(C_GREEN, f"b ${bal:.2f}"))

daily, monthly = get_spend()
if daily is not None and monthly is not None:
    parts.append(seg(C_AMBER, f"d ${daily:.2f}"))

if price and price.get("prompt") is not None and price.get("completion") is not None:
    # model price per 1M tokens (effective = list minus the provider promo),
    # the same numbers the OpenRouter website shows for IN and OUT
    ip = price.get("eff_prompt"); op = price.get("eff_completion")
    ip = ip if ip is not None else price["prompt"]
    op = op if op is not None else price["completion"]
    parts.append(seg(C_CYAN, f"P ${ip*1e6:.4f} • ${op*1e6:.4f}"))
else:
    fallback = d.get("cost") or {}
    if fallback.get("total_cost_usd"):
        parts.append(seg(C_CYAN, f"${float(fallback['total_cost_usd']):.4f}"))

if in_tok or out_tok:
    parts.append(seg(C_BLUE, f"in {fmt_tok(in_tok)} / out {fmt_tok(out_tok)}"))

if cache_write is not None or cache_read is not None:
    bits = []
    if cache_write is not None:
        bits.append(f"+{fmt_tok(int(cache_write))}")
    if cache_read is not None:
        bits.append(f"~{fmt_tok(int(cache_read))}")
    # honest cache-read cost: tokens * input_cache_read price (from OpenRouter),
    # preferring the effective (discounted) price
    cr_price = (price or {}).get("eff_cache_read")
    if cr_price is None:
        cr_price = (price or {}).get("cache_read") if isinstance(price, dict) else None
    if cache_read is not None and cr_price is not None and cr_price > 0:
        bits.append(f"${int(cache_read) * cr_price:.4f}")
    parts.append(seg(C_PURPLE, f"c {' '.join(bits)}"))

# Prefer the REAL context limit from OpenRouter (price cache), not the
# context_window_size Claude Code sends (its fallback for non-Anthropic models
# can be meaningless, e.g. ~200k for DeepSeek's real 1.3M).
real_limit = (price or {}).get("context") if isinstance(price, dict) else None
limit = real_limit or cw_size
if limit:
    if isinstance(limit, (int, float)) and limit > 0:
        ctx_str = f"ctx {fmt_tok(in_tok)}/{fmt_tok(int(limit))}"
        # recompute % from the REAL limit; the used_percentage Claude Code sends
        # is based on its own (wrong for OpenRouter) context_window_size
        if real_limit and in_tok > 0:
            ctx_str += f" ({100.0 * in_tok / int(limit):.0f}%)"
        elif pct is not None:
            ctx_str += f" ({float(pct):.0f}%)"
    else:
        ctx_str = f"ctx {float(pct):.0f}%"
    parts.append(seg(C_TEAL, ctx_str))

print(" | ".join(parts))
PYEOF
