# ⚡ CLAUDE-STATBAR

**The statusline that finally tells the truth about your OpenRouter spend.**

Running Claude Code through OpenRouter? The built-in status bar lies to you — it
uses Anthropic's private price table, invents a fake ~200k context window for
models that really have 1M, and shows `$0` for models it doesn't recognize.

**CLAUDE-STATBAR** plugs straight into the OpenRouter API and shows you the **real**
numbers — today's actual price with the provider's discount, your live key
balance, daily spend, real context limit, and a full token/cache breakdown.
One glance at the bottom of your terminal and you know exactly what you're
spending, in real dollars.

![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform: Windows / macOS / Linux](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)
![OpenRouter ready](https://img.shields.io/badge/OpenRouter-ready-orange)
![Tests: 16/16 passing](https://img.shields.io/badge/tests-16%2F16%20passing-brightgreen)
![Language: Bash + Python](https://img.shields.io/badge/language-Bash%20%2F%20Python-3776AB)

---

## 🚀 Why you'll love it

| The built-in statusline does this | CLAUDE-STATBAR does this |
|---|---|
| Shows `$0` / garbage for non-Anthropic models | Shows the **real price per 1M tokens**, including the provider's live discount |
| Invents a ~200k context window | Shows the **true model limit** (e.g. 1,048,576 for DeepSeek V4 Flash) with an honest usage % |
| No balance, no spend | Live **key balance** + **daily spend** |
| One dull line | A **color-coded, scannable** statusline that works in any terminal |

## ⚡ What it looks like

```
V4-flash-0731 | b $29.81 | d $4.15 | P $0.0786 • $0.1572 | in 156.6k / out 291 | c +0 ~15.5k $0.0002 | ctx 156.6k/1M (15%)
```

| Segment | Meaning |
|---|---|
| `V4-flash-0731` | model (version slug) |
| `b $29.81` | OpenRouter **key balance** — muted green |
| `d $4.15` | **daily spend** — muted amber |
| `P $0.0786 • $0.1572` | model price per 1M tokens — **input • output**, discounted — muted cyan |
| `in 156.6k / out 291` | session **tokens** in/out — muted blue |
| `c +0 ~15.5k $0.0002` | cache write (`+`) / cache read (`~`) + its real cost — muted purple |
| `ctx 156.6k/1M (15%)` | context used vs the **real** limit + honest % — teal |

Every segment appears **only when the data is real** — it never shows a fake `0`.

## ✨ Features

- 🔵 **True pricing** — pulls today's effective per-1M price (list price minus the
  provider's promo) straight from the OpenRouter endpoints API.
- 💰 **Live balance & spend** — your key balance and daily usage at a glance.
- 🧠 **Real context** — shows the model's actual available context, not Claude Code's
  bogus fallback, with a **correct** usage percentage.
- 🧾 **Token & cache audit** — input/output tokens plus cache read/write *and* what
  the cache reads actually cost you.
- 🎨 **Subtle colors** — a quiet, muted palette so the line is readable, not loud.
- ⚡ **No API spam** — everything is cached (prices 6h, balance/spend 5min), so it
  never hammers OpenRouter on redraws.
- 🧪 **Fully tested** — an offline, deterministic test suite (16 checks).

## 🛠️ Install in 3 steps

> Takes about 60 seconds. No build, no dependencies beyond `bash`, `python3`, `curl`.

**1 — Copy the script**

```bash
cp statusline-command.sh ~/.claude/statusline-command.sh
```

**2 — Point it at your key**

Open `~/.claude/settings.json` and set your OpenRouter key as an environment
variable (or `export` it in your shell):

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://openrouter.ai/api",
    "ANTHROPIC_AUTH_TOKEN": "sk-or-v1-ТВОЙ_КЛЮЧ"
  }
}
```

**3 — Wire up the statusline**

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh"
  }
}
```

Restart Claude Code, send any message, and watch your terminal come alive. 🎉

## ▶️ Try it on any machine (no Claude Code needed)

Pipe a sample payload straight through the script:

```bash
cat example-payload.json | ANTHROPIC_AUTH_TOKEN="sk-or-v1-ТВОЙ_КЛЮЧ" bash statusline-command.sh
```

## 🧪 Tests

`test-statusline.sh` runs the script against synthetic payloads and asserts every
segment — including the tricky ones (the honest context %, the discounted price,
the `M`/`k` formatting). It seeds a throwaway HOME, so it's **offline and
deterministic**:

```bash
bash test-statusline.sh
# === 16 passed, 0 failed ===
```

## 🔍 How it works

- **List prices + real context** → `GET /api/v1/models` (cached 6h).
- **Effective price** (your actual cost) → `GET /api/v1/models/{id}/endpoints`
  — the same discounted number the OpenRouter website shows.
- **Balance** → `GET /api/v1/credits` (cached 5min).
- **Daily spend** → `GET /api/v1/key` (cached 5min).
- Cached under `~/.claude/cache/` so the API is never hit on every redraw.

## 🔒 Security

- **No keys in the repo** — only placeholders. Real keys live in your local
  `settings.json`, which `.gitignore` keeps out of version control.
- A **post-write guard** and a **git pre-commit hook** scan every file you write
  for a real `sk-or-v1-` / `sk-ant-` key and block it before it can be committed.
- If a key is ever exposed anywhere — rotate it at
  [OpenRouter → Keys](https://openrouter.ai/settings/keys).

## 📦 Dependencies

`bash`, `python3`, `curl` — every OS ships them or installs in seconds.

## 📄 License

[MIT](LICENSE). Free to use, fork, and build on.
