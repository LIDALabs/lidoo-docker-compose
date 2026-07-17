# BCV Exchange Rate Resilience — Design Spec

**Date:** 2026-07-17
**Target:** `l10n_ve_currency_rate_live` + `l10n_ve/tools/binaural_bcv_query.py` (repo `LIDALabs/odoo-venezuela`, submodule `l10n_ve`)
**Versions:** Odoo 17 (branch `17.0-lida`) and Odoo 18, delivered together.

## 1. Problem

The BCV rate feature has three recurring failures:

1. **BCV website down** → the daily Enterprise cron advances `currency_next_execution_date` *before* querying (`currency_rate_live/models/res_config_settings.py:1171`), so one failed attempt loses the whole day. The wizard offers only the stale last-known rate.
2. **Non-working days** → validation is `isoweekday() <= 5` only; Venezuelan bank holidays are invisible. The `can_update_habil_days` flag has inverted semantics (True = do NOT update on weekends, label says the opposite).
3. **Server powered off at cron time** → the day's rate is never captured; multi-day gaps are never backfilled.

## 2. Constraints and decisions (user-approved)

| # | Decision |
|---|----------|
| D1 | **Official BCV sources only.** No third-party mirror APIs (pydolarve, dolarapi, etc.). |
| D2 | **Keep and improve `binaural_bcv_query.py` in place** (do not replace). Its consumers (`l10n_ve_currency_rate_live`) must keep working without import changes. |
| D3 | **Store rates under their real Fecha Valor, including future dates.** BCV pre-publishes the next business day's rate each afternoon; capturing it means "today's rate is already in the DB since yesterday". Safe because every consumer resolves rates with `name <= date` (`l10n_ve_rate.compute_rate:44`, Odoo core `_get_rates`). |
| D4 | **Own idempotent hourly cron** in `l10n_ve_currency_rate_live`; the Enterprise `_parse_bcv_data` hook remains as a thin adapter so the Settings "Update now" button keeps working. |
| D5 | **Fallback never writes rate rows.** When BCV is unreachable, the last stored rate already governs via `name <= date`; writing the old value under today's date only falsifies history. |
| D6 | **Fecha Valor is the banking calendar.** No holiday table: if BCV published no rate dated D, then D is not a banking day. Weekend/holiday flags (`can_update_habil_days`) are removed. |
| D7 | Deliver on **both 17 and 18** branches of the submodule from the start. |
| D8 | **USD is the only currency surfaced in the module UI** (wizard + log). The multi-currency fetch is retained; non-USD rates are stored ONLY for currencies already active in the DB (standard Odoo `search`), never shown in the BCV wizard. Do not add non-USD fields to the wizard/log. |

## 3. Current-state defects (verified in code)

| ID | Defect | Location |
|----|--------|----------|
| B1 | Wizard "Actualizar Precios" always writes the rate under **today**, ignoring Fecha Valor — on pre-publication afternoons it applies tomorrow's rate to today's documents. | `wizard/bcv_rate_wizard.py:198-219` |
| B2 | Multi-company loop uses `return` instead of `continue`; first company hitting weekend/error aborts every remaining company. Helper also uses `self.env.company` instead of the loop company. | `models/res_company.py:17-33` |
| B3 | Missing currency blocks parse as `"0.0"` → `veb_per_usd/rate` raises `ZeroDivisionError`, killing the whole run. | `tools/binaural_bcv_query.py:76-97` + `models/res_company.py:76` |
| B4 | `default_get` performs HTTP query + log/rate writes on wizard open, wrapped in `except Exception: pass`. | `wizard/bcv_rate_wizard.py:16-83` |
| B5 | "Active rate" resolved by `write_date desc` — manually editing an old rate row makes it the wizard's "current" rate. | `wizard/bcv_rate_wizard.py:31-34` |
| B6 | On query error with no fallback available, the wizard writes nothing and shows nothing (silent dead end). | `wizard/bcv_rate_wizard.py:91-110` |
| B7 | Single HTTP attempt, 5s timeout, no retries, no browser User-Agent. | `tools/binaural_bcv_query.py:28` |
| B8 | Numeric parse breaks on thousands separators ("1.234,56") — relevant given Venezuelan redenomination history. | `tools/binaural_bcv_query.py:71-97` |
| B9 | Missing Fecha Valor silently falls back to today — under D3 that could store tomorrow's rate as today's. | `tools/binaural_bcv_query.py:55-58` |
| B10 | `_update_product_prices` does `compute_rate(...)['foreign_rate']` → `KeyError` on a DB with no rates. | `lida_reference_prices/models/product_pricelist.py:147` |
| B11 | `fields.Date.context_today` under the cron user's TZ (often UTC): at 20:00 Caracas it is already "tomorrow" in UTC, shifting date comparisons. | helper/company/wizard, all date logic |
| B12 | Rate writes happen through three independent paths (helper `_update_currency_rate`, Enterprise `_generate_currency_rates`, wizard `action_update_prices`). | module-wide |
| B13 | Inverted flag `can_update_habil_days` (see §1.2). | `models/res_company.py:13,23` |
| B14 | Fallback re-announces months-old rates without any staleness warning; log rows are created even on wizard open (spam). | `models/bcv_rate_helper.py:75-90` |
| B15 | `verify=False` + import-time `disable_warnings(InsecureRequestWarning)`: TLS verification disabled (MITM can inject a fake rate into accounting) and warnings silenced process-wide for all of Odoo. | `tools/binaural_bcv_query.py:1-2,23,28` |
| B16 | Early `return`s in `_parse_bcv_data` (weekend/error) return `None`; Enterprise then calls `_generate_currency_rates(None)` → `AttributeError`, surfaced as a misleading "Unable to connect" UserError from the Settings button on weekends. | `models/res_company.py:24-52` + `currency_rate_live/models/res_config_settings.py:225-226` |

## 4. Target architecture

All changes live in the existing module and tool; no new module.

### 4.1 `tools/binaural_bcv_query.py` (improved in place)

- `get_bcv_rate_of_the_day(self)` keeps its exact signature and return contract (`{rates, date, error}`) — existing consumers untouched.
- Internals upgraded: `requests.Session` + `urllib3 Retry` (3 attempts, backoff, timeout ≥15s), browser-like `User-Agent`, robust number normalizer (thousands dots + decimal comma), missing currency blocks **omitted** from `rates` instead of `"0.0"`; USD missing = `ParsingError`.
- **TLS fixed, not disabled**: BCV's server sends an incomplete certificate chain, which is why the current code uses `verify=False`. Replace with a bundled CA chain (`tools/certs/bcv_chain.pem`, BCV's intermediates + root) passed as `verify=<bundle>`. Verification stays ON — a MITM on this endpoint means poisoned accounting rates. Remove the process-global `disable_warnings(InsecureRequestWarning)` (it silences TLS warnings for ALL of Odoo's urllib3 usage, not just this call). Verification failure is treated as a normal fetch error (logged, retried later); the documented remedy is refreshing the bundle.
- Missing Fecha Valor no longer defaults to today: it returns `error {type: 'NoFechaValor'}` so the caller can decide (B9).
- New function `get_bcv_rate_history(self, date_from, date_to)`: parses the official BCV statistics source ("Tipo de Cambio de Referencia SMC", same `bcv.org.ve` domain, XLS files) for backfill. Uses `xlrd`/`openpyxl` already shipped with Odoo. *(Verification task: confirm exact URL pattern and workbook layout during implementation.)*

### 4.2 `bcv.rate.service` (new AbstractModel in `l10n_ve_currency_rate_live`)

Single orchestration + **single write path** for rate rows:

- `sync(companies=None)` — idempotent: for each company determines `needed = {today's governing rate, next published Fecha Valor}`; if satisfied, does nothing. Otherwise: manual-rate check → homepage query → (on parse failure) SMC history query → store under real Fecha Valor → log with source used.
- `backfill(companies=None)` — detects gaps between last stored Fecha Valor and today; fills real banking days from SMC history. Skipped dates absent from SMC = non-banking days (D6).
- `_store_rate(company, date, rates)` — the only place that writes `res.currency.rate` (upsert by currency+date+company, writes `inverse_company_rate` for USD, cross rates for EUR/CNY/RUB/TRY when present).
- All "today" computations use `America/Caracas` explicitly (B11).
- Anomaly guard: a fetched USD rate deviating more than `SUSPECT_THRESHOLD_PERCENT` (module constant, 20%) from the last governing rate is logged as `suspect` and **not** stored automatically (manual-rate flow is the override); prevents a parsing glitch from poisoning rates.

### 4.3 Cron + Enterprise adapter

- New `ir.cron` (module data): hourly, calls `bcv.rate.service.sync()` then `backfill()`. Idempotency makes hourly cheap: at most one HTTP round-trip per hour, none once satisfied. Odoo runs overdue crons at startup → powered-off servers self-heal on boot.
- Enterprise integration via an override of `res.company.update_currency_rates`: companies with provider `bcv` are routed to `service.sync()` (per-company isolation, fixes B2/B16); other providers fall through to `super()`. `_parse_bcv_data` is removed — routing at `update_currency_rates` level avoids ever handing `None`/partial dicts to `_generate_currency_rates`, and keeps the single write path (D5/B12). Settings "Update now" and the Enterprise daily cron both pass through this override unchanged (C23). *(Port verification: method exists with same signature in 18.)*
- `post_init_hook` kept: sets provider `bcv` + triggers first `sync()`.

### 4.4 Wizard (validation pass)

- `default_get`: read-only — shows governing rate (ordered by `name desc`, fixes B5), next published rate if any, source and capture time, staleness warning when governing rate is older than the last banking day. **No network, no writes** (B4).
- "Consultar BCV" button: calls `sync()`, then reloads state; on total failure shows explicit error block (fixes B6) with the manual-rate escape hatch (existing `group_bcv_manual_rate` flow unchanged).
- "Actualizar Precios": writes nothing to `res.currency.rate` directly (D5/B1); it only triggers `_update_product_prices()` using the governing rate, and refuses with a clear message when no governing rate exists (suspect values never reach storage, so the governing rate is always a confirmed one). `compute_rate` empty-dict case handled with a `UserError` (B10).
- "Usar última tasa conocida" button removed: under D5 the last known rate **already governs** — the wizard states this instead of pretending to load it.
- `date` field semantics fixed: shows Fecha Valor (Date), plus separate capture timestamp.

### 4.5 Log (`bcv.rate.log`)

- Reuse existing fields: `rate_source` selection gains `smc` (official history source); the existing `date` field IS the Fecha Valor (the tree view already labels it that). New `suspect` boolean; model gains `mail.activity.mixin`.
- Wizard opens no longer create rows (B14); a row is created only when something happens — a rate stored/changed, an error, or a suspect value. Idempotent no-op fetches log nothing (avoids hourly spam during the afternoon publication window).
- After N consecutive failed days (default 2), schedule an activity for the accounting group so a human notices layout changes / prolonged outages.

### 4.6 Settings

- Remove `can_update_habil_days` (B13/D6) from company, settings and view; migration drops the column.
- Keep Enterprise provider selection UI working (D4).

## 5. Full case matrix

"Current" = behavior today; "Target" = behavior after this design. FV = Fecha Valor.

| ID | Scenario | Current | Target |
|----|----------|---------|--------|
| C1 | Business day, morning, BCV up (FV == today) | Cron writes today's rate once daily | `sync()` satisfied on first hourly run; idempotent re-runs no-op |
| C2 | Business day, afternoon (BCV shows FV == next business day) | `rate_day > today` → discarded entirely | Stored under its future FV; next day starts covered |
| C3 | Weekend | Skip if flag set — via `return`, aborting other companies (B2) | Saturday fetch stores Monday's rate under Monday; no flag; wizard explains "non-banking day, Friday's rate governs" |
| C4 | Bank holiday midweek | `isoweekday<=5` misses it; cron discards future FV; wizard could write tomorrow's rate as today (B1) | FV-driven storage handles it naturally; wizard informs |
| C5 | BCV down at cron hour, up later | Enterprise cron already advanced next-execution → lost day | Hourly retries all day; usually moot because C2 pre-captured today |
| C6 | BCV down since yesterday afternoon (no pre-capture) | Stale rate used silently; wizard shows fallback warning | Same governing-rate behavior, but hourly retries + explicit wizard state + activity after N days + manual escape. Honest limit of official-only sources |
| C7 | Server off at cron time, boots later same day | Overdue cron runs at boot, fetches today only | Same + `backfill()` fills any missed banking days |
| C8 | Server off for N days | Gap days never filled; USD reports for those dates use stale rate | `backfill()` reconstructs real FV rows from SMC history |
| C9 | Manual rate exists for today | Manual short-circuits BCV (root-only group) | Kept; surfaced explicitly in wizard + log source `manual` |
| C10 | Fresh DB, no rates at all | Wizard open fires HTTP in `default_get`; `_update_product_prices` → KeyError (B10) | No network on open; guided first sync; UserError with instructions if still empty |
| C11 | BCV drops a currency block (e.g. EUR) | `"0.0"` → ZeroDivisionError kills run (B3) | Currency omitted; USD required, others optional |
| C12 | BCV homepage layout change | ParsingError → silent stale fallback forever | SMC parser as second official source; activity raised after N failed days |
| C13 | Thousands-separator format ("1.234,56") | `float()` ValueError (B8) | Robust normalizer |
| C14 | Multi-company | First company's skip/error aborts rest; wrong company context (B2) | Per-company `continue`, explicit company arg everywhere |
| C15 | Rate already exists for FV | Three write paths, duplicate risk (B12) | Single `_store_rate` upsert |
| C16 | Old rate row edited by hand | Becomes wizard's "active" rate via `write_date` (B5) | Governing rate = max `name <= today` |
| C17 | FV missing from homepage HTML | Silent "today" assumption (B9) | Error → try SMC → else explicit parse failure, nothing stored |
| C18 | Query fails, no fallback exists | Wizard silently unchanged (B6) | Explicit error state + manual escape |
| C19 | Cron runs 20:00–23:59 Caracas time | UTC `context_today` shifts to tomorrow (B11) | All banking-day math pinned to `America/Caracas` |
| C20 | "Actualizar Precios" while fallback/stale governs | Stale value re-written under today (B1) | No rate writes from wizard; stale state warned before price update |
| C21 | Anomalous value fetched (deviation > threshold) | Stored blindly | Marked `suspect`, withheld, wizard asks for confirmation |
| C22 | DB whose only rate is future-dated (first capture = tomorrow) | — (cannot happen today) | `compute_rate` falls back to oldest row → tomorrow's rate governs today; accepted edge, documented (better than no rate) |
| C23 | Settings "Update now" button | Full Enterprise path, UserError on failure | Same UX, delegates to `sync()` |
| C24 | BCV rotates its TLS certificate chain | Invisible (verification is off — MITM also invisible, B15) | Verification against bundled chain fails → normal fetch error + activity after N days; remedy = refresh `bcv_chain.pem` |

## 6. Error handling & observability

- One `bcv.rate.log` row per event (rate stored/changed, error, suspect) with status, source, error type/message, FV; silent no-op fetches log nothing.
- Consecutive-failure activity (§4.5). Log tree view gets `source`/`suspect` columns.
- No exception may escape the cron; per-company isolation.

## 7. Testing strategy

- **Tool unit tests** (HTML/XLS fixtures, mocked HTTP): happy path, missing FV, missing currency block, thousands format, timeout/connection/HTTP-error, UA header, SMC history parse.
- **Service tests**: idempotency (double `sync()` = one write), future-FV storage, backfill gap fill, manual-rate precedence, suspect threshold, multi-company isolation, Caracas TZ boundary (20:00/00:00 cases), fallback-writes-nothing (D5).
- **Wizard tests**: no network on `default_get`, governing-rate ordering, error state, price-update guards.
- Fixtures live in the module; tests tagged to run in both 17 and 18.

## 8. Delivery on 17 and 18

- Implement + test on submodule branch `17.0-lida`.
- Port branch (18): view syntax `tree` → `list` (log views, `view_mode`), re-verify `_parse_bcv_data` hook signature and `currency_provider` selection in 18's `currency_rate_live`, re-verify `inverse_company_rate` field, run the same test suite. *(Verification tasks at port start; the service/tool layer is version-agnostic by design.)*
- Migration script: drop `can_update_habil_days`, add new log columns.

## 9. Risks / open verifications

| Risk | Mitigation |
|------|------------|
| SMC statistics URL/XLS layout differs from assumption | Verification task before coding `get_bcv_rate_history`; feature degrades to homepage-only if SMC unavailable |
| BCV blocks scrapers harder (UA/rate-limiting) | Hourly idempotent design keeps request volume minimal (≤1 fetch/hour/DB) |
| Odoo 18 Enterprise hook changes | Explicit verification task at port phase; adapter is 10 lines |
| BCV rotates TLS chain → bundled CA verification fails | Treated as fetch outage (C24); bundle refresh documented as ops procedure |
| Existing DBs with wrong historical rows (from B1) | Out of scope; log-based audit query documented in plan |
