# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`frotadiag.sh` is a single, self-contained zsh script — the entire project. It is a canonical macOS fleet-diagnostics tool (published as `Drmcoelho/FrotaDiag`) meant to be `curl`'d onto any Mac and run identically. It consolidates three older scripts (`frota-diag.sh` + `disk-triage.sh` + `zshrc-audit.sh`) into one binary with subcommands. All prose (comments, output strings, report text) is in **Brazilian Portuguese** — match that language when editing user-facing strings; keep the code idioms as-is.

## Running

```sh
./frotadiag.sh diag [--full]     # machine health (default). Read-only. --full adds softwareupdate check
./frotadiag.sh disk [scan|clean] # disk space. scan=read-only; clean=guided, prompts per category
./frotadiag.sh zshrc             # dotfile census; secrets ALWAYS redacted
./frotadiag.sh provision [--yes] # install missing tools, if-not, asking first
./frotadiag.sh fleet             # cross-host rollup: read every <host>/latest.json, print status table
./frotadiag.sh schedule <install [hour]|uninstall|status>  # nightly diag LaunchAgent
./frotadiag.sh all               # diag + disk scan + zshrc in one run
./frotadiag.sh help
```

There is no build, lint, or test suite. Validate changes with `zsh -n frotadiag.sh` (syntax) and by running the affected subcommand. To exercise `fleet`/diff without a real multi-host history, override `ICLOUD_BASE` at a temp dir seeded with fixture `latest.json` files (`ICLOUD_BASE=/tmp/x zsh frotadiag.sh fleet`) — the var is env-overridable for exactly this. The script requires `emulate -L zsh` semantics — it is zsh-only (associative arrays `typeset -A`, `${(k)...}` expansion, `read -r "var?prompt"`), not portable to bash.

**Env vars:** `ICLOUD_BASE` (override report root, mainly for tests), `FROTADIAG_NO_NOTIFY=1` (silence notifications), `FROTADIAG_NTFY_URL` (push endpoint for BAD-transition alerts, e.g. ntfy/Pushover).

## Exit codes (contract — do not break)

`diag`/`all` encode health in the exit code: `0` = all OK, `1` = at least one WARN, `2` = at least one BAD. `fleet` mirrors the same contract across the fleet (`2` if any host BAD, `1` if any WARN) so it composes into automation. `cmd_all` deliberately swallows `cmd_diag`'s non-zero exit (`|| true`) so a degraded health score doesn't abort the composite run. Unknown subcommand exits `64`.

## Core doctrine (the invariants that govern every edit)

These are the load-bearing design rules. Violating them is a regression even if the script still runs:

1. **Read never asks; mutate always asks.** Anything that only reads or emits (`diag`, `disk scan`, `zshrc`, `fleet`, `schedule status`, and the diff/notify side-effects) runs without prompting. Anything that mutates (`disk clean`, `provision`, `schedule install`/`uninstall` — which write a plist and load a launchd job) prompts first — subcommand by subcommand, category by category, via `confirm()`.
2. **`--yes` is narrow.** Only `provision` and the `SEGURO`-risk disk categories honor `--yes` (through `confirm_auto`). `REVISAR` and `DESTRUTIVO` categories *always* fall through to bare `confirm()` — `--yes` can never reach them. This asymmetry is intentional (see the header comment at `clean_category`); don't "simplify" it away.
3. **Secrets never appear in cleartext, anywhere.** `redact()` returns the literal string `REDACTED` — it does not echo length, characters, or any fingerprint. The `zshrc` census detects secrets by variable-name pattern (`SECRET_RE`) and value shape (`SECRET_VAL_RE`) and emits only the variable name + `REDACTED`. `SECRET_VAL_RE` was hardened with minimum lengths (e.g. `sk-` requires 20+ chars) specifically to avoid false positives on slugs like `backup-desk-configuration`; changing those thresholds re-opens that risk.
4. **One failing layer must not sink the others.** Every `layer_*` and `scan_zsh_file` ends in an explicit `return 0`. `run_layer` wraps each health layer so a crash becomes a single `BAD` row (`layer_<name>_error`) instead of aborting `diag`. Preserve both.

## Architecture

**Output fan-out.** A single `diag` run emits three ways at once: colored terminal (via `emit`), plus JSON and Markdown reports written by `write_diag_reports`. `emit <OK|WARN|BAD|INFO> <key> <value> <label>` is the one funnel — it prints the terminal line, appends to the `JSON_FIELDS` and `MD_LINES` arrays, bumps the `N_OK`/`N_WARN`/`N_BAD` counters, and logs. Add a metric by calling `emit`, never by hand-writing to the arrays.

**Report destination with fallback.** `resolve_out_dir` targets iCloud Drive (`$ICLOUD_BASE/<host>/`, default `~/Library/Mobile Documents/com~apple~CloudDocs/FrotaDiag/`) and silently falls back to `~/.local/state/frotadiag/reports/<host>/` if iCloud is unwritable. Each report type also gets copied to a stable `latest.*` name. A rolling log lives at `~/.local/state/frotadiag/frotadiag.log`.

**Fleet is pull; notify is push (the two halves of "away from the machines").** The shared iCloud folder — one `<host>/latest.json` per Mac, machine-readable with a versioned `schema` — is the fleet substrate. `cmd_fleet` (pull) globs `$ICLOUD_BASE/*/latest.json`, and for each host reads verdict, disk, TM status, `script_version` (version drift across the fleet is itself a signal), and **staleness by file mtime** (`stat -f %m`, not by parsing the JSON timestamp — mtime *is* when the run wrote it; >48h ≈ offline). Its own `_fleet/` output dir is excluded from the glob and each host's jq is guarded so a half-written file mid-`cp` can't sink the rollup. `notify` (push) is the complement: it fires **only on BAD transitions**, not on `N_BAD>0` — see below.

**Temporal diff + notification.** `cmd_diag` compares the *previous* `latest.json` against the just-written report via `diff_and_flag`, **before** `cp` overwrites it (first run = no-op). The comparison is by **status transition per key** (`_rank`: OK/INFO=1 < WARN=2 < BAD=3), never by parsing values like "120h atrás" — deterministic and auditable. Regressions/improvements print to terminal and append to the Markdown. Keys that *newly* became BAD (or WARN→BAD) fill the global `NEW_BAD_KEYS`, and *only that transition set* triggers `notify` (macOS banner via `osascript` + optional `FROTADIAG_NTFY_URL` push). This is deliberate: a host BAD for a week must not re-alarm nightly (alarm fatigue) — persistent BAD is what `fleet` surfaces on pull; the push exists for the transition you'd miss while away. Requires `jq` (fleet + diff both no-op with an honest message if absent).

**Scheduling.** `cmd_schedule` plants/removes a `com.coelho.frotadiag` LaunchAgent running `$SCRIPT_PATH diag` nightly (`SCRIPT_PATH` is `${0:A}`, the canonical self-path). The plist's `EnvironmentVariables > PATH` **must** include `/opt/homebrew/bin` or the scheduled run can't resolve `jq`/`smartctl`/`brew` and the diff silently breaks. Uses `launchctl bootstrap gui/$UID` + `bootout`, with `load`/`unload` fallback for older macOS.

**Health layers (`diag`).** `cmd_diag` calls `run_layer` for each `layer_*` function: identidade, memoria, disco_saude, energia_termico, timemachine, seguranca_rede, agentes, inventario, and (only under `--full`) updates. Each is independent and self-contained. To add a check, write a `layer_*` (open with `section`, close with `return 0`, report via `emit`) and register it in `cmd_diag`.

**Disk model (`disk`).** `measure_disk_categories` populates three parallel associative arrays keyed by category: `CAT_BYTES` (size, `-1` means "n/d" e.g. TM snapshots), `CAT_DESC` (label), `CAT_RISK` (`SEGURO`/`REVISAR`/`DESTRUTIVO`). `disk scan` sorts and prints; `disk clean` iterates a fixed order and routes each category through `clean_category`, whose per-category `case` block decides whether to delete directly, open Finder for manual review, or just print the manual command (destructive ops like simulator/ollama removal are never automated — they only print the command).

**Escaping.** `json_escape` and `md_escape` guard the structured outputs; `emit` already applies them. Any new value flowing into a report goes through `emit`, so escaping is automatic — don't append raw strings to `JSON_FIELDS`/`MD_LINES`/`ZMD` without escaping.

## Editing notes

- `help` is generated by `sed -n '2,28p'` of the script's own header. If you add/remove header lines (e.g. a new subcommand in the SUBCOMANDOS block), the help output truncates or leaks — update that line range in the dispatcher `case` to match the new header end.
- The `SCRIPT_VERSION` variable and the `CHANGELOG` comment block near the top are the version record. The header comments document *why* several counterintuitive choices exist (the `--yes` asymmetry, `eval` in `provision_one`, the `|| print 0` grep guards, dropping char-count from `redact`) — these encode resolved review disagreements, so read them before "fixing" the thing they describe.
