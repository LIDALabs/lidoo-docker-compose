# BCV Rate Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Spec:** `docs/superpowers/specs/2026-07-17-bcv-rate-resilience-design.md` (read it first — it holds the case matrix C1–C24 and defect list B1–B16 referenced below).

**Goal:** Make the BCV exchange-rate feature survive BCV outages, non-banking days and powered-off servers, by capturing rates under their real Fecha Valor with an idempotent hourly sync + official-history backfill, while fixing all wizard/cron validation defects.

**Architecture:** `tools/binaural_bcv_query.py` is improved in place (same public contract) and gains an official SMC-history fetcher. A new `bcv.rate.service` AbstractModel becomes the single orchestrator and the ONLY writer of `res.currency.rate` rows. An hourly `ir.cron` calls it; the Enterprise path is routed through an `update_currency_rates` override. The wizard becomes a read-only view over the service state plus explicit actions.

**Tech Stack:** Odoo 17/18 (Python), requests + urllib3 Retry, BeautifulSoup, xlrd (SMC .xls), pytz, Odoo test framework (`TransactionCase`, tagged `bcv_rate`).

## Global Constraints

- Official BCV sources ONLY (`www.bcv.org.ve` homepage + SMC statistics). No third-party APIs (spec D1).
- `get_bcv_rate_of_the_day(self)` keeps its exact signature and `{rates, date, error}` return contract (spec D2).
- Rates are stored under their real Fecha Valor, future dates included (spec D3).
- `bcv.rate.service._store_rate` is the only code path that writes `res.currency.rate` (spec D5/B12). Fallback NEVER writes rows.
- No holiday tables; absence of a BCV publication for a date = non-banking day (spec D6).
- All "today"/hour math uses `America/Caracas` (spec B11/C19).
- TLS verification stays ON, against the bundled `tools/certs/bcv_chain.pem`. Never `verify=False`, never `disable_warnings` (spec B15/C24).
- Code, comments, commit messages in English; user-visible strings in the module stay Spanish like the existing ones. Conventional commits, no AI attribution.
- All l10n_ve work happens INSIDE the submodule repo `/home/moi/Documentos/odoo-docker-dev/l10n_ve` (branch `feature/bcv-rate-resilience` off `17.0-lida`). Parent repo is NOT committed by this plan.
- Tests run with: `docker compose run --rm odoo17 odoo -d test_bcv -i l10n_ve_currency_rate_live -u l10n_ve_currency_rate_live --test-tags bcv_rate --stop-after-init` (from `/home/moi/Documentos/odoo-docker-dev`; the `odoo17` service already carries DB env config). Expected pass output ends with `0 failed, 0 error(s)`.

---

### Task 0: Feature branch in the submodule

**Files:** none (git only)

- [ ] **Step 1: Create the branch**

```bash
cd /home/moi/Documentos/odoo-docker-dev/l10n_ve
git status --short          # review; do NOT carry unrelated dirty files into feature commits
git checkout 17.0-lida && git pull
git checkout -b feature/bcv-rate-resilience
```

Expected: `Switched to a new branch 'feature/bcv-rate-resilience'`.

---

### Task 1: Number normalizer in the BCV tool

**Files:**
- Modify: `l10n_ve/tools/binaural_bcv_query.py`
- Test: `l10n_ve/l10n_ve_currency_rate_live/tests/__init__.py`, `l10n_ve/l10n_ve_currency_rate_live/tests/test_bcv_query_tool.py`

**Interfaces:**
- Produces: `binaural_bcv_query.parse_bcv_number(raw: str) -> float` (raises `ValueError` on junk). Used by Tasks 3–4.

- [ ] **Step 1: Write the failing tests**

Create `l10n_ve/l10n_ve_currency_rate_live/tests/__init__.py`:

```python
from . import test_bcv_query_tool
```

Create `l10n_ve/l10n_ve_currency_rate_live/tests/test_bcv_query_tool.py`:

```python
from odoo.tests import TransactionCase, tagged

from odoo.addons.l10n_ve.tools import binaural_bcv_query


@tagged("post_install", "-at_install", "bcv_rate")
class TestParseBcvNumber(TransactionCase):
    def test_decimal_comma(self):
        self.assertEqual(binaural_bcv_query.parse_bcv_number("621,53"), 621.53)

    def test_thousands_dot_with_decimal_comma(self):
        self.assertEqual(binaural_bcv_query.parse_bcv_number("1.234,56"), 1234.56)

    def test_surrounding_noise(self):
        self.assertEqual(binaural_bcv_query.parse_bcv_number("\nUSD  621,53000000 "), 621.53)

    def test_junk_raises(self):
        with self.assertRaises(ValueError):
            binaural_bcv_query.parse_bcv_number("N/A")

    def test_empty_raises(self):
        with self.assertRaises(ValueError):
            binaural_bcv_query.parse_bcv_number("")
```

Note: the tools package import path is `odoo.addons.l10n_ve.tools` only when the repo root is an addon path member named `l10n_ve`. Check how `bcv_rate_helper.py` imports it today (`from ...tools import binaural_bcv_query`) — if the relative style is the working one, import in tests via `from odoo.addons.l10n_ve_currency_rate_live.models import bcv_rate_helper` and reference `bcv_rate_helper.binaural_bcv_query`. Resolve at implementation time by running the test; use whichever import the running server accepts.

- [ ] **Step 2: Run tests to verify they fail**

Run the Global Constraints test command. Expected: FAIL/ERROR with `AttributeError: ... has no attribute 'parse_bcv_number'`.

- [ ] **Step 3: Implement the normalizer**

Add to `l10n_ve/tools/binaural_bcv_query.py` (top-level, after imports):

```python
import re


def parse_bcv_number(raw):
    """Parse a BCV-formatted number ('621,53', '1.234,56') into a float.

    BCV uses comma as decimal separator and dot as thousands separator.
    Raises ValueError when no numeric content is present.
    """
    cleaned = re.sub(r"[^\d,.]", "", raw or "")
    if not cleaned or not re.search(r"\d", cleaned):
        raise ValueError("no numeric content in %r" % (raw,))
    if "," in cleaned:
        cleaned = cleaned.replace(".", "").replace(",", ".")
    return float(cleaned)
```

- [ ] **Step 4: Run tests to verify they pass** (same command, expected `0 failed`)

- [ ] **Step 5: Commit**

```bash
cd /home/moi/Documentos/odoo-docker-dev/l10n_ve
git add tools/binaural_bcv_query.py l10n_ve_currency_rate_live/tests/
git commit -m "feat(bcv): add robust BCV number normalizer"
```

---

### Task 2: HTTP layer — session, retries, UA, TLS bundle

**Files:**
- Create: `l10n_ve/tools/certs/bcv_chain.pem`
- Modify: `l10n_ve/tools/binaural_bcv_query.py`
- Test: `l10n_ve/l10n_ve_currency_rate_live/tests/test_bcv_query_tool.py`

**Interfaces:**
- Produces: `binaural_bcv_query._http_get(url: str) -> requests.Response` (raises `requests` exceptions; retries 3x with backoff; browser UA; verifies TLS against the bundle). Tasks 3–4 call ONLY this to touch the network — tests patch this single symbol.
- Produces: constants `BCV_BASE_URL`, `TIMEOUT = 15`, `BCV_CA_BUNDLE`.

- [ ] **Step 1: Build the CA bundle**

```bash
cd /home/moi/Documentos/odoo-docker-dev/l10n_ve/tools && mkdir -p certs
openssl s_client -showcerts -connect www.bcv.org.ve:443 -servername www.bcv.org.ve </dev/null 2>/dev/null \
  | awk '/BEGIN CERTIFICATE/,/END CERTIFICATE/' > certs/bcv_chain_leafs.pem
```

Then identify the ISSUER chain (BCV's server omits intermediates — that is the whole reason `verify=False` existed): inspect `openssl x509 -in certs/bcv_chain_leafs.pem -noout -issuer`, download the issuer's intermediate + root certs from the CA's official site (Sectigo/DigiCert/whichever the current issuer is), and concatenate intermediates+root into `certs/bcv_chain.pem`. Validate:

```bash
python3 -c "import requests; print(requests.get('https://www.bcv.org.ve/', verify='certs/bcv_chain.pem', timeout=20).status_code)"
```

Expected: `200`. If BCV is down today, validate later — the code path must still land with the bundle in place. Delete the scratch `bcv_chain_leafs.pem` afterwards.

- [ ] **Step 2: Write the failing tests**

Append to `test_bcv_query_tool.py`:

```python
import os
from unittest.mock import patch


@tagged("post_install", "-at_install", "bcv_rate")
class TestHttpLayer(TransactionCase):
    def test_session_has_browser_user_agent(self):
        session = binaural_bcv_query._build_session()
        self.assertIn("Mozilla", session.headers.get("User-Agent", ""))

    def test_verify_uses_bundle_when_present(self):
        self.assertTrue(str(binaural_bcv_query._verify_arg()).endswith("bcv_chain.pem"))

    def test_no_global_warning_disable(self):
        source = open(binaural_bcv_query.__file__).read()
        self.assertNotIn("disable_warnings", source)
        self.assertNotIn("verify=False", source)
```

- [ ] **Step 3: Run tests — expected FAIL** (`_build_session` missing)

- [ ] **Step 4: Implement**

In `binaural_bcv_query.py`: DELETE the `urllib3.exceptions`/`disable_warnings` imports and the `disable_warnings(...)` call; add:

```python
import os

from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BCV_BASE_URL = "https://www.bcv.org.ve/"
TIMEOUT = 15
BCV_CA_BUNDLE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "certs", "bcv_chain.pem")
_USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"
)


def _verify_arg():
    """CA bundle shipped with the repo; BCV's server omits its intermediates."""
    return BCV_CA_BUNDLE if os.path.exists(BCV_CA_BUNDLE) else True


def _build_session():
    session = requests.Session()
    retry = Retry(total=3, backoff_factor=1.0, status_forcelist=[500, 502, 503, 504],
                  allowed_methods=["GET"])
    session.mount("https://", HTTPAdapter(max_retries=retry))
    session.headers.update({"User-Agent": _USER_AGENT})
    return session


def _http_get(url):
    return _build_session().get(url, timeout=TIMEOUT, verify=_verify_arg())
```

- [ ] **Step 5: Run tests — expected PASS**

- [ ] **Step 6: Commit**

```bash
git add tools/ l10n_ve_currency_rate_live/tests/
git commit -m "feat(bcv): verified TLS with bundled CA chain, retries and browser UA"
```

---

### Task 3: Rework `get_bcv_rate_of_the_day` (same contract)

**Files:**
- Modify: `l10n_ve/tools/binaural_bcv_query.py`
- Create: `l10n_ve/l10n_ve_currency_rate_live/tests/fixtures/bcv_home.html`, `bcv_home_no_fv.html`, `bcv_home_no_eur.html`, `bcv_home_no_usd.html`
- Test: `test_bcv_query_tool.py`

**Interfaces:**
- Keeps: `get_bcv_rate_of_the_day(self) -> {'rates': dict|None, 'date': date|False, 'error': None|{'type': str, 'message': str}}`.
- New behavior: missing FV → `error.type == 'NoFechaValor'` (nothing guessed); missing non-USD currency → key omitted from `rates`; missing USD → `ParsingError`; `requests.exceptions.SSLError` → `error.type == 'SSLError'`.

- [ ] **Step 1: Create fixtures**

`fixtures/bcv_home.html` (replicates the real ids/classes the parser targets):

```html
<html><body>
  <span class="date-display-single" content="2026-07-20T00:00:00-04:00">Lunes, 20 Julio 2026</span>
  <div id="euro"><strong> EUR   672,11223344 </strong></div>
  <div id="yuan"><strong> CNY   86,55667788 </strong></div>
  <div id="lira"><strong> TRY   15,44556677 </strong></div>
  <div id="rublo"><strong> RUB   7,88990011 </strong></div>
  <div id="dolar"><strong> USD   621,53000000 </strong></div>
</body></html>
```

`bcv_home_no_fv.html`: same but WITHOUT the `<span class="date-display-single">` line.
`bcv_home_no_eur.html`: same as `bcv_home.html` but WITHOUT the `id="euro"` line.
`bcv_home_no_usd.html`: same as `bcv_home.html` but WITHOUT the `id="dolar"` line.

- [ ] **Step 2: Write the failing tests**

Append to `test_bcv_query_tool.py`:

```python
from datetime import date

import requests


def _fixture(name):
    path = os.path.join(os.path.dirname(__file__), "fixtures", name)
    with open(path, encoding="utf-8") as handle:
        return handle.read()


class _FakeResponse:
    def __init__(self, text, status_code=200, reason="OK"):
        self.text = text
        self.status_code = status_code
        self.reason = reason


@tagged("post_install", "-at_install", "bcv_rate")
class TestGetBcvRateOfTheDay(TransactionCase):
    def _fetch(self, response=None, side_effect=None):
        with patch.object(binaural_bcv_query, "_http_get",
                          side_effect=side_effect,
                          return_value=response) as mock_get:
            result = binaural_bcv_query.get_bcv_rate_of_the_day(self.env["res.company"])
        return result, mock_get

    def test_happy_path_parses_all_and_fv(self):
        result, _ = self._fetch(_FakeResponse(_fixture("bcv_home.html")))
        self.assertIsNone(result["error"])
        self.assertEqual(result["date"], date(2026, 7, 20))
        self.assertEqual(result["rates"]["USD"], 621.53)
        self.assertEqual(result["rates"]["EUR"], 672.11223344)
        self.assertEqual(set(result["rates"]), {"USD", "EUR", "CNY", "RUB", "TRY"})

    def test_missing_fecha_valor_is_error_not_today(self):
        result, _ = self._fetch(_FakeResponse(_fixture("bcv_home_no_fv.html")))
        self.assertEqual(result["error"]["type"], "NoFechaValor")
        self.assertIsNone(result["rates"])

    def test_missing_eur_is_omitted_not_zero(self):
        result, _ = self._fetch(_FakeResponse(_fixture("bcv_home_no_eur.html")))
        self.assertIsNone(result["error"])
        self.assertNotIn("EUR", result["rates"])
        self.assertIn("USD", result["rates"])

    def test_missing_usd_is_parsing_error(self):
        result, _ = self._fetch(_FakeResponse(_fixture("bcv_home_no_usd.html")))
        self.assertEqual(result["error"]["type"], "ParsingError")

    def test_http_500_maps_status_code(self):
        result, _ = self._fetch(_FakeResponse("boom", status_code=503, reason="Unavailable"))
        self.assertEqual(result["error"]["type"], "503")

    def test_ssl_error_mapped(self):
        result, _ = self._fetch(side_effect=requests.exceptions.SSLError("bad chain"))
        self.assertEqual(result["error"]["type"], "SSLError")

    def test_timeout_mapped(self):
        result, _ = self._fetch(side_effect=requests.exceptions.Timeout("slow"))
        self.assertEqual(result["error"]["type"], "Timeout")

    def test_connection_error_mapped(self):
        result, _ = self._fetch(side_effect=requests.exceptions.ConnectionError("down"))
        self.assertEqual(result["error"]["type"], "ConnectionError")
```

- [ ] **Step 3: Run tests — expected FAIL** (current code guesses FV=today, returns EUR 0.0, no SSLError branch)

- [ ] **Step 4: Reimplement the function body**

Replace the whole `get_bcv_rate_of_the_day` implementation with:

```python
_CURRENCY_CONTAINER_IDS = {
    "USD": "dolar",
    "EUR": "euro",
    "CNY": "yuan",
    "RUB": "rublo",
    "TRY": "lira",
}


def _error(err_type, message):
    _logger.error("BCV query error [%s]: %s", err_type, message)
    return {"rates": None, "date": False, "error": {"type": err_type, "message": message}}


def get_bcv_rate_of_the_day(self):
    """Fetch today's published BCV board from the official homepage.

    Returns {'rates': {code: VES-per-unit}, 'date': Fecha Valor, 'error': None}
    or {'rates': None, 'date': False, 'error': {'type', 'message'}}.
    Missing non-USD currencies are omitted; missing USD or missing Fecha Valor
    is an error (the caller must never guess dates: rates are stored under
    their real Fecha Valor).
    """
    try:
        response = _http_get(BCV_BASE_URL)
    except requests.exceptions.SSLError as exc:
        return _error("SSLError", "TLS verification failed (refresh tools/certs/bcv_chain.pem?): %s" % exc)
    except requests.exceptions.Timeout as exc:
        return _error("Timeout", str(exc))
    except requests.exceptions.ConnectionError as exc:
        return _error("ConnectionError", str(exc))
    except Exception as exc:  # noqa: BLE001 — cron must never die on fetch
        return _error("Unknown", str(exc))

    if response.status_code != 200:
        return _error(str(response.status_code), "HTTP %s: %s" % (response.status_code, response.reason))

    soup = BeautifulSoup(response.text, "html.parser")

    date_span = soup.find("span", class_="date-display-single")
    if not (date_span and date_span.get("content")):
        return _error("NoFechaValor", "Fecha Valor span not found in BCV homepage")
    try:
        fecha_valor = datetime.fromisoformat(date_span["content"]).date()
    except (ValueError, TypeError) as exc:
        return _error("NoFechaValor", "Unparseable Fecha Valor %r: %s" % (date_span.get("content"), exc))

    rates = {}
    for code, container_id in _CURRENCY_CONTAINER_IDS.items():
        container = soup.find(id=container_id)
        if not container:
            _logger.warning("BCV: currency block %r (%s) missing, omitted", container_id, code)
            continue
        try:
            rates[code] = parse_bcv_number(container.text)
        except ValueError as exc:
            _logger.warning("BCV: unparseable %s value: %s", code, exc)

    if "USD" not in rates:
        return _error("ParsingError", "USD rate not found in BCV homepage")

    return {"rates": rates, "date": fecha_valor, "error": None}
```

Also delete the now-unused `fields` import if nothing else in the file uses it.

- [ ] **Step 5: Run ALL tool tests — expected PASS**

- [ ] **Step 6: Commit**

```bash
git add tools/binaural_bcv_query.py l10n_ve_currency_rate_live/tests/
git commit -m "feat(bcv): strict Fecha Valor, omitted missing currencies, mapped TLS errors"
```

---

### Task 4: Official SMC history fetcher

**Files:**
- Modify: `l10n_ve/tools/binaural_bcv_query.py`
- Create: `l10n_ve/l10n_ve_currency_rate_live/tests/fixtures/smc_sample.xls` (built from a real download)
- Test: `test_bcv_query_tool.py`

**Interfaces:**
- Produces: `get_bcv_rate_history(self, date_from, date_to) -> {'rates_by_date': {date: {'USD': float}}, 'error': None|{...}}`. Dates absent from the result inside the range = non-banking days. Task 8 consumes this.

- [ ] **Step 1: VERIFICATION — inspect the real SMC source**

```bash
curl -sL --cacert /home/moi/Documentos/odoo-docker-dev/l10n_ve/tools/certs/bcv_chain.pem \
  "https://www.bcv.org.ve/estadisticas/tipo-cambio-de-referencia-smc" | grep -oE 'href="[^"]+\.xls[x]?"' | head
```

Download the newest listed file, open it with `python3 -c "import xlrd; wb = xlrd.open_workbook('<file>'); sh = wb.sheet_by_index(0); print([sh.row_values(r) for r in range(12)])"` and record: sheet layout, date column, USD "Venta" column, header rows. **Adjust the column constants in Step 4 and rebuild the fixture from a truncated copy of the real file (keep ~10 data rows).** If BCV is down, defer this task and continue with Task 5; `backfill()` degrades gracefully when history errors.

- [ ] **Step 2: Write the failing tests**

Append to `test_bcv_query_tool.py`:

```python
@tagged("post_install", "-at_install", "bcv_rate")
class TestGetBcvRateHistory(TransactionCase):
    def test_parses_fixture_rows(self):
        fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "smc_sample.xls")
        with open(fixture_path, "rb") as handle:
            payload = handle.read()
        with patch.object(binaural_bcv_query, "_download_smc_workbooks",
                          return_value=[payload]):
            result = binaural_bcv_query.get_bcv_rate_history(
                self.env["res.company"], date(2026, 7, 13), date(2026, 7, 17))
        self.assertIsNone(result["error"])
        self.assertTrue(result["rates_by_date"])
        for day, rates in result["rates_by_date"].items():
            self.assertGreaterEqual(day, date(2026, 7, 13))
            self.assertLessEqual(day, date(2026, 7, 17))
            self.assertGreater(rates["USD"], 0)

    def test_network_error_reported(self):
        with patch.object(binaural_bcv_query, "_download_smc_workbooks",
                          side_effect=requests.exceptions.ConnectionError("down")):
            result = binaural_bcv_query.get_bcv_rate_history(
                self.env["res.company"], date(2026, 7, 13), date(2026, 7, 17))
        self.assertEqual(result["error"]["type"], "ConnectionError")
        self.assertEqual(result["rates_by_date"], {})
```

- [ ] **Step 3: Run tests — expected FAIL** (functions missing)

- [ ] **Step 4: Implement**

Append to `binaural_bcv_query.py` (adjust the three `SMC_*` constants to what Step 1 found):

```python
SMC_PAGE_URL = "https://www.bcv.org.ve/estadisticas/tipo-cambio-de-referencia-smc"
SMC_HEADER_ROWS = 8   # rows to skip before data — VERIFY against real file
SMC_DATE_COL = 0      # column holding the value date — VERIFY
SMC_USD_SALE_COL = 5  # column holding USD "Venta" — VERIFY


def _download_smc_workbooks(limit=2):
    """Return the raw bytes of the newest SMC .xls files linked on the page."""
    page = _http_get(SMC_PAGE_URL)
    page.raise_for_status()
    soup = BeautifulSoup(page.text, "html.parser")
    hrefs = []
    for anchor in soup.find_all("a", href=True):
        href = anchor["href"]
        if href.lower().endswith((".xls", ".xlsx")):
            hrefs.append(href if href.startswith("http") else requests.compat.urljoin(BCV_BASE_URL, href))
    workbooks = []
    for href in hrefs[:limit]:
        response = _http_get(href)
        response.raise_for_status()
        workbooks.append(response.content)
    return workbooks


def get_bcv_rate_history(self, date_from, date_to):
    """Official USD history from the BCV SMC statistics workbooks.

    Returns {'rates_by_date': {date: {'USD': float}}, 'error': None | {...}}.
    A date missing from the result within [date_from, date_to] means BCV
    published no rate for it (non-banking day).
    """
    import xlrd

    rates_by_date = {}
    try:
        workbooks = _download_smc_workbooks()
    except requests.exceptions.SSLError as exc:
        return {"rates_by_date": {}, "error": {"type": "SSLError", "message": str(exc)}}
    except requests.exceptions.Timeout as exc:
        return {"rates_by_date": {}, "error": {"type": "Timeout", "message": str(exc)}}
    except requests.exceptions.ConnectionError as exc:
        return {"rates_by_date": {}, "error": {"type": "ConnectionError", "message": str(exc)}}
    except Exception as exc:  # noqa: BLE001
        return {"rates_by_date": {}, "error": {"type": "Unknown", "message": str(exc)}}

    for payload in workbooks:
        try:
            workbook = xlrd.open_workbook(file_contents=payload)
            for sheet_index in range(workbook.nsheets):
                sheet = workbook.sheet_by_index(sheet_index)
                for row in range(SMC_HEADER_ROWS, sheet.nrows):
                    try:
                        raw_date = sheet.cell_value(row, SMC_DATE_COL)
                        if isinstance(raw_date, float):
                            value_date = datetime(*xlrd.xldate_as_tuple(raw_date, workbook.datemode)[:3]).date()
                        else:
                            value_date = datetime.strptime(str(raw_date).strip(), "%d/%m/%Y").date()
                        usd_value = sheet.cell_value(row, SMC_USD_SALE_COL)
                        usd = float(usd_value) if isinstance(usd_value, float) else parse_bcv_number(str(usd_value))
                    except (ValueError, IndexError, TypeError):
                        continue
                    if date_from <= value_date <= date_to and usd > 0:
                        rates_by_date.setdefault(value_date, {"USD": usd})
        except Exception as exc:  # noqa: BLE001 — one broken workbook must not kill backfill
            _logger.warning("BCV SMC: unreadable workbook skipped: %s", exc)

    return {"rates_by_date": rates_by_date, "error": None}
```

- [ ] **Step 5: Run tests — expected PASS** (fixture built from the real layout)

- [ ] **Step 6: Commit**

```bash
git add tools/binaural_bcv_query.py l10n_ve_currency_rate_live/tests/
git commit -m "feat(bcv): official SMC statistics history fetcher for backfill"
```

---

### Task 5: Log model — source selection, suspect flag, activity mixin

**Files:**
- Modify: `l10n_ve/l10n_ve_currency_rate_live/models/bcv_rate_log.py`
- Modify: `l10n_ve/l10n_ve_currency_rate_live/views/bcv_rate_log_views.xml`
- Modify: `l10n_ve/l10n_ve_currency_rate_live/__manifest__.py` (version `17.0.1.1.3` → `17.0.2.0.0`)
- Create: `l10n_ve/l10n_ve_currency_rate_live/migrations/17.0.2.0.0/pre-migration.py`
- Test: create `l10n_ve/l10n_ve_currency_rate_live/tests/test_bcv_rate_log.py` (add to tests `__init__.py`)

**Interfaces:**
- Produces on `bcv.rate.log`: `rate_source` selection gains `('smc', 'BCV Histórico (SMC)')`; new `suspect = fields.Boolean`; model inherits `mail.activity.mixin`. `date` field semantics = **Fecha Valor** (the tree view already labels it that). Tasks 7–8 create rows with these fields.

- [ ] **Step 1: Write the failing test**

`tests/test_bcv_rate_log.py`:

```python
from odoo import fields
from odoo.tests import TransactionCase, tagged


@tagged("post_install", "-at_install", "bcv_rate")
class TestBcvRateLog(TransactionCase):
    def test_smc_source_and_suspect_flag(self):
        log = self.env["bcv.rate.log"].create({
            "date": fields.Date.today(),
            "rate_usd": 621.53,
            "rate_source": "smc",
            "status": "success",
            "suspect": True,
        })
        self.assertEqual(log.rate_source, "smc")
        self.assertTrue(log.suspect)

    def test_activity_mixin_available(self):
        self.assertIn("activity_ids", self.env["bcv.rate.log"]._fields)
```

Add `from . import test_bcv_rate_log` to `tests/__init__.py`.

- [ ] **Step 2: Run — expected FAIL** (invalid selection value `smc`)

- [ ] **Step 3: Implement**

In `bcv_rate_log.py`:

```python
class BcvRateLog(models.Model):
    _name = 'bcv.rate.log'
    _inherit = ['mail.activity.mixin']
    _description = 'BCV Rate Query Log'
    _order = 'created_at desc'
```

```python
    date = fields.Date('Fecha Valor', required=True)
    rate_source = fields.Selection([
        ('bcv', 'BCV'),
        ('smc', 'BCV Histórico (SMC)'),
        ('manual', 'Manual')
    ], string='Fuente de tasa', default='bcv', required=True)
    suspect = fields.Boolean(
        'Sospechosa', default=False,
        help='Tasa retenida por desviarse demasiado de la última tasa vigente; requiere confirmación manual.')
```

(Only `date` label, `rate_source` selection, `_inherit` and the new `suspect` field change; everything else stays.)

In `bcv_rate_log_views.xml` tree view, after `<field name="rate_source"/>` add:

```xml
                <field name="suspect" optional="show"/>
```

Manifest: `"version": "17.0.2.0.0",`.

`migrations/17.0.2.0.0/pre-migration.py`:

```python
def migrate(cr, version):
    # Field removed in this release (spec B13/D6); drop the orphan column so
    # future ORM upgrades never trip over it (see odoo.sh incident history).
    cr.execute("ALTER TABLE res_company DROP COLUMN IF EXISTS can_update_habil_days")
```

- [ ] **Step 4: Run tests — expected PASS**

- [ ] **Step 5: Commit**

```bash
git add l10n_ve_currency_rate_live/
git commit -m "feat(bcv): log source SMC, suspect flag, activity mixin, v17.0.2.0.0 migration"
```

---

### Task 6: Service core — Caracas clock, needs-fetch, single write path, state

**Files:**
- Create: `l10n_ve/l10n_ve_currency_rate_live/models/bcv_rate_service.py`
- Modify: `l10n_ve/l10n_ve_currency_rate_live/models/__init__.py`
- Test: create `tests/test_bcv_rate_service.py` (add to tests `__init__.py`)

**Interfaces (consumed by Tasks 7–11):**
- `_caracas_now() -> aware datetime`, `_caracas_today() -> date`, `_publication_cutoff_passed() -> bool` (>= 17:00 Caracas)
- `_needs_fetch(company, today) -> bool`
- `_store_rate(company, date_value, rates: {code: float}) -> bool` — THE only `res.currency.rate` writer
- `get_state(company) -> {'governing_rate', 'governing_date', 'next_rate', 'next_date', 'is_banking_day', 'stale_days', 'last_log'}`
- Constants: `PUBLICATION_HOUR = 17`, `SUSPECT_THRESHOLD_PERCENT = 20.0`, `FAILURE_ACTIVITY_DAYS = 2`

- [ ] **Step 1: Write the failing tests**

`tests/test_bcv_rate_service.py`:

```python
from datetime import date, datetime, timedelta
from unittest.mock import patch

import pytz

from odoo import fields
from odoo.tests import TransactionCase, tagged

from odoo.addons.l10n_ve_currency_rate_live.models.bcv_rate_service import BcvRateService

CARACAS = pytz.timezone("America/Caracas")


def _caracas(dt_naive):
    return CARACAS.localize(dt_naive)


@tagged("post_install", "-at_install", "bcv_rate")
class BcvServiceCase(TransactionCase):
    def setUp(self):
        super().setUp()
        self.service = self.env["bcv.rate.service"]
        self.usd = self.env.ref("base.USD")
        self.vef = self.env.ref("base.VEF")
        self.company = self.env.company
        self.company.currency_id = self.vef
        self.usd.active = True

    def _rate_row(self, day, value, company=None):
        return self.env["res.currency.rate"].create({
            "currency_id": self.usd.id,
            "name": day,
            "inverse_company_rate": value,
            "company_id": (company or self.company).id,
        })

    def _patch_now(self, naive):
        return patch.object(BcvRateService, "_caracas_now", return_value=_caracas(naive))


@tagged("post_install", "-at_install", "bcv_rate")
class TestServiceCore(BcvServiceCase):
    def test_cutoff_morning_false_evening_true(self):
        with self._patch_now(datetime(2026, 7, 16, 9, 0)):
            self.assertFalse(self.service._publication_cutoff_passed())
        with self._patch_now(datetime(2026, 7, 16, 17, 30)):
            self.assertTrue(self.service._publication_cutoff_passed())

    def test_needs_fetch_no_rows(self):
        with self._patch_now(datetime(2026, 7, 16, 9, 0)):
            self.assertTrue(self.service._needs_fetch(self.company, date(2026, 7, 16)))

    def test_no_fetch_when_future_row_exists(self):
        self._rate_row(date(2026, 7, 17), 622.0)
        with self._patch_now(datetime(2026, 7, 16, 18, 0)):
            self.assertFalse(self.service._needs_fetch(self.company, date(2026, 7, 16)))

    def test_today_row_morning_satisfied_evening_not(self):
        self._rate_row(date(2026, 7, 16), 621.5)
        with self._patch_now(datetime(2026, 7, 16, 9, 0)):
            self.assertFalse(self.service._needs_fetch(self.company, date(2026, 7, 16)))
        with self._patch_now(datetime(2026, 7, 16, 18, 0)):
            self.assertTrue(self.service._needs_fetch(self.company, date(2026, 7, 16)))

    def test_store_rate_creates_and_updates_idempotently(self):
        created = self.service._store_rate(self.company, date(2026, 7, 20), {"USD": 621.53, "EUR": 672.11})
        self.assertTrue(created)
        again = self.service._store_rate(self.company, date(2026, 7, 20), {"USD": 621.53, "EUR": 672.11})
        self.assertFalse(again)  # no-op, nothing changed
        rows = self.env["res.currency.rate"].search([
            ("name", "=", date(2026, 7, 20)), ("company_id", "=", self.company.id)])
        self.assertEqual(len(rows), 2)  # USD + EUR
        changed = self.service._store_rate(self.company, date(2026, 7, 20), {"USD": 630.00})
        self.assertTrue(changed)

    def test_store_rate_ignores_zero_and_company_currency(self):
        self.assertFalse(self.service._store_rate(self.company, date(2026, 7, 20), {"USD": 0.0, "VEF": 1.0}))

    def test_get_state_governing_by_date_not_write_date(self):
        old = self._rate_row(date(2026, 7, 10), 600.0)
        self._rate_row(date(2026, 7, 15), 620.0)
        old.write({"inverse_company_rate": 601.0})  # edited later; must NOT become governing
        with self._patch_now(datetime(2026, 7, 16, 9, 0)):
            state = self.service.get_state(self.company)
        self.assertEqual(state["governing_date"], date(2026, 7, 15))
        self.assertEqual(state["governing_rate"], 620.0)
        self.assertFalse(state["is_banking_day"])
        self.assertEqual(state["stale_days"], 1)

    def test_get_state_next_published(self):
        self._rate_row(date(2026, 7, 16), 621.0)
        self._rate_row(date(2026, 7, 17), 622.0)
        with self._patch_now(datetime(2026, 7, 16, 18, 0)):
            state = self.service.get_state(self.company)
        self.assertEqual(state["next_date"], date(2026, 7, 17))
        self.assertEqual(state["next_rate"], 622.0)
        self.assertTrue(state["is_banking_day"])
```

- [ ] **Step 2: Run — expected FAIL** (`bcv.rate.service` unknown)

- [ ] **Step 3: Implement**

`models/bcv_rate_service.py`:

```python
import logging
from datetime import datetime

import pytz

from odoo import api, fields, models
from odoo.tools import float_compare

_logger = logging.getLogger(__name__)

PUBLICATION_HOUR = 17          # BCV posts next banking day's board ~16:30–18:00 Caracas
SUSPECT_THRESHOLD_PERCENT = 20.0
FAILURE_ACTIVITY_DAYS = 2
CARACAS_TZ = pytz.timezone("America/Caracas")


class BcvRateService(models.AbstractModel):
    _name = "bcv.rate.service"
    _description = "BCV Rate Service (single write path)"

    # -- clock -------------------------------------------------------------
    @api.model
    def _caracas_now(self):
        return pytz.utc.localize(fields.Datetime.now()).astimezone(CARACAS_TZ)

    @api.model
    def _caracas_today(self):
        return self._caracas_now().date()

    @api.model
    def _publication_cutoff_passed(self):
        return self._caracas_now().hour >= PUBLICATION_HOUR

    # -- queries -----------------------------------------------------------
    @api.model
    def _usd(self):
        return self.env.ref("base.USD", raise_if_not_found=False)

    @api.model
    def _usd_domain(self, company):
        return [("currency_id", "=", self._usd().id), ("company_id", "=", company.id)]

    @api.model
    def _needs_fetch(self, company, today):
        """Idempotency gate: nothing to do when the next Fecha Valor is already
        captured — or when today's is captured and BCV has not yet published
        the next board (before the publication cutoff)."""
        if not self._usd():
            return False
        Rate = self.env["res.currency.rate"].sudo()
        if Rate.search_count(self._usd_domain(company) + [("name", ">", today)]):
            return False
        if Rate.search_count(self._usd_domain(company) + [("name", "=", today)]):
            return self._publication_cutoff_passed()
        return True

    # -- single write path (spec D5/B12) ------------------------------------
    @api.model
    def _store_rate(self, company, date_value, rates):
        """Upsert res.currency.rate rows for the given Fecha Valor.

        `rates` maps currency codes to VES-per-unit values. Returns True when
        any row was created or changed. The ONLY writer of currency rates in
        this module.
        """
        Rate = self.env["res.currency.rate"].sudo()
        Currency = self.env["res.currency"]
        changed = False
        for code, value in (rates or {}).items():
            if not value or value <= 0:
                continue
            currency = Currency.search([("name", "=", code)], limit=1)
            if not currency or currency == company.currency_id:
                continue
            row = Rate.search([
                ("currency_id", "=", currency.id),
                ("name", "=", date_value),
                ("company_id", "=", company.id),
            ], limit=1)
            if row:
                if float_compare(row.inverse_company_rate, value, precision_digits=4) != 0:
                    row.write({"inverse_company_rate": value})
                    changed = True
            else:
                Rate.create({
                    "currency_id": currency.id,
                    "name": date_value,
                    "inverse_company_rate": value,
                    "company_id": company.id,
                })
                changed = True
        return changed

    # -- wizard/state ------------------------------------------------------
    @api.model
    def get_state(self, company):
        today = self._caracas_today()
        Rate = self.env["res.currency.rate"].sudo()
        governing = Rate.search(self._usd_domain(company) + [("name", "<=", today)],
                                order="name desc", limit=1)
        nxt = Rate.search(self._usd_domain(company) + [("name", ">", today)],
                          order="name asc", limit=1)
        last_log = self.env["bcv.rate.log"].search(
            [("company_id", "=", company.id)], order="created_at desc", limit=1)
        governing_date = governing.name if governing else False
        return {
            "governing_rate": governing.inverse_company_rate if governing else 0.0,
            "governing_date": governing_date,
            "next_rate": nxt.inverse_company_rate if nxt else 0.0,
            "next_date": nxt.name if nxt else False,
            "is_banking_day": bool(governing and governing_date == today),
            "stale_days": (today - governing_date).days if governing else -1,
            "last_log": last_log,
        }
```

Add `from . import bcv_rate_service` to `models/__init__.py`.

Note: `stale_days` in the weekend test expects `1` for a governing rate dated yesterday. `is_banking_day` False + `stale_days >= 3` is the wizard's "unusually stale" signal (Task 11).

- [ ] **Step 4: Run tests — expected PASS**

- [ ] **Step 5: Commit**

```bash
git add l10n_ve_currency_rate_live/
git commit -m "feat(bcv): rate service core — Caracas clock, idempotency gate, single write path"
```

---

### Task 7: `sync()` — manual precedence, suspect guard, failure activity

**Files:**
- Modify: `l10n_ve/l10n_ve_currency_rate_live/models/bcv_rate_service.py`
- Test: `tests/test_bcv_rate_service.py`

**Interfaces:**
- Produces: `sync(companies=None, automatic=True) -> bool`. Fetches at most ONCE per call (shared across companies). Creates `bcv.rate.log` rows only on store / change / error / suspect — silent no-ops create nothing. Task 9's override and Task 10's cron and Task 11's wizard call this.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_bcv_rate_service.py`:

```python
def _bcv_ok(fv, usd=621.53):
    return {"rates": {"USD": usd, "EUR": 672.11}, "date": fv, "error": None}


def _bcv_err(err_type="ConnectionError"):
    return {"rates": None, "date": False, "error": {"type": err_type, "message": "boom"}}


@tagged("post_install", "-at_install", "bcv_rate")
class TestSync(BcvServiceCase):
    def _sync(self, tool_result, now=datetime(2026, 7, 16, 9, 0)):
        with self._patch_now(now), \
             patch.object(BcvRateService, "_fetch_board", return_value=tool_result) as mock_fetch:
            ok = self.service.sync(self.company)
        return ok, mock_fetch

    def test_stores_under_real_fecha_valor(self):
        ok, _ = self._sync(_bcv_ok(date(2026, 7, 16)))
        self.assertTrue(ok)
        row = self.env["res.currency.rate"].search(
            [("name", "=", date(2026, 7, 16)), ("currency_id", "=", self.usd.id),
             ("company_id", "=", self.company.id)])
        self.assertEqual(row.inverse_company_rate, 621.53)
        log = self.env["bcv.rate.log"].search([("company_id", "=", self.company.id)])
        self.assertEqual(len(log), 1)
        self.assertEqual(log.status, "success")
        self.assertEqual(log.date, date(2026, 7, 16))

    def test_stores_future_fecha_valor(self):
        # Friday evening: BCV already shows Monday's board (spec C2/C3)
        ok, _ = self._sync(_bcv_ok(date(2026, 7, 20)), now=datetime(2026, 7, 17, 18, 0))
        self.assertTrue(ok)
        self.assertTrue(self.env["res.currency.rate"].search_count(
            [("name", "=", date(2026, 7, 20)), ("company_id", "=", self.company.id)]))

    def test_idempotent_second_sync_no_fetch_no_log(self):
        self._sync(_bcv_ok(date(2026, 7, 16)))
        ok, mock_fetch = self._sync(_bcv_ok(date(2026, 7, 16)))
        self.assertTrue(ok)
        mock_fetch.assert_not_called()  # _needs_fetch gate short-circuits
        self.assertEqual(self.env["bcv.rate.log"].search_count(
            [("company_id", "=", self.company.id)]), 1)

    def test_error_logged_and_no_rate_written(self):
        ok, _ = self._sync(_bcv_err())
        self.assertFalse(ok)
        self.assertFalse(self.env["res.currency.rate"].search_count(
            [("company_id", "=", self.company.id), ("currency_id", "=", self.usd.id)]))
        log = self.env["bcv.rate.log"].search([("company_id", "=", self.company.id)])
        self.assertEqual(log.status, "error")
        self.assertEqual(log.error_type, "ConnectionError")

    def test_fallback_writes_no_rows(self):
        # spec D5: with an older governing rate present, an outage stores NOTHING new
        self._rate_row(date(2026, 7, 15), 620.0)
        self._sync(_bcv_err())
        self.assertEqual(self.env["res.currency.rate"].search_count(
            [("company_id", "=", self.company.id), ("currency_id", "=", self.usd.id)]), 1)

    def test_manual_rate_precedence(self):
        self.env["bcv.rate.log"].sudo().with_user(self.env.ref("base.user_root")).create({
            "date": date(2026, 7, 16), "rate_usd": 700.0, "rate_source": "manual",
            "status": "success", "company_id": self.company.id,
        })
        ok, mock_fetch = self._sync(_bcv_ok(date(2026, 7, 16)))
        self.assertTrue(ok)
        mock_fetch.assert_not_called()
        row = self.env["res.currency.rate"].search(
            [("name", "=", date(2026, 7, 16)), ("currency_id", "=", self.usd.id),
             ("company_id", "=", self.company.id)])
        self.assertEqual(row.inverse_company_rate, 700.0)

    def test_suspect_rate_withheld(self):
        self._rate_row(date(2026, 7, 15), 620.0)
        ok, _ = self._sync(_bcv_ok(date(2026, 7, 16), usd=620.0 * 1.5))  # +50% deviation
        self.assertTrue(ok)  # handled, not a crash
        self.assertFalse(self.env["res.currency.rate"].search_count(
            [("name", "=", date(2026, 7, 16)), ("company_id", "=", self.company.id)]))
        log = self.env["bcv.rate.log"].search(
            [("company_id", "=", self.company.id)], order="created_at desc", limit=1)
        self.assertTrue(log.suspect)

    def test_activity_after_consecutive_error_days(self):
        Log = self.env["bcv.rate.log"].sudo()
        for offset in (2, 1):
            log = Log.create({
                "date": date(2026, 7, 16) - timedelta(days=offset),
                "status": "error", "error_type": "ConnectionError",
                "company_id": self.company.id,
            })
            log.created_at = fields.Datetime.now() - timedelta(days=offset)
        self._sync(_bcv_err())
        last = Log.search([("company_id", "=", self.company.id)],
                          order="created_at desc", limit=1)
        self.assertTrue(last.activity_ids)
```

- [ ] **Step 2: Run — expected FAIL** (`sync` / `_fetch_board` missing)

- [ ] **Step 3: Implement**

Append to `bcv_rate_service.py` (inside the class), plus the import at top:

```python
from ...tools import binaural_bcv_query
```

(Match the exact relative-import style used today by `bcv_rate_helper.py` — it is the proven-working path.)

```python
    # -- fetch wrapper (patched in tests) -----------------------------------
    @api.model
    def _fetch_board(self):
        return binaural_bcv_query.get_bcv_rate_of_the_day(self)

    @api.model
    def _log(self, company, vals):
        base = {"company_id": company.id, "automatico": self.env.context.get("bcv_automatic", True)}
        base.update(vals)
        return self.env["bcv.rate.log"].sudo().create(base)

    @api.model
    def _apply_manual_rate(self, company, today):
        manual = self.env["bcv.rate.log"].sudo().search([
            ("rate_source", "=", "manual"), ("date", "=", today),
            ("company_id", "=", company.id),
        ], order="created_at desc", limit=1)
        if manual and manual.rate_usd:
            self._store_rate(company, today, {"USD": manual.rate_usd})
            return True
        return False

    @api.model
    def _is_suspect(self, company, today, usd_value):
        Rate = self.env["res.currency.rate"].sudo()
        governing = Rate.search(self._usd_domain(company) + [("name", "<=", today)],
                                order="name desc", limit=1)
        if not governing or not governing.inverse_company_rate:
            return False
        deviation = abs(usd_value - governing.inverse_company_rate) / governing.inverse_company_rate * 100.0
        return deviation > SUSPECT_THRESHOLD_PERCENT

    @api.model
    def _maybe_raise_failure_activity(self, company, log):
        """After FAILURE_ACTIVITY_DAYS distinct days with errors and no success,
        schedule a warning activity on the last log row (once)."""
        Log = self.env["bcv.rate.log"].sudo()
        today = self._caracas_today()
        distinct_error_days = set()
        recent = Log.search([
            ("company_id", "=", company.id),
            ("created_at", ">=", fields.Datetime.to_string(
                self._caracas_now().replace(tzinfo=None) - timedelta(days=FAILURE_ACTIVITY_DAYS + 1))),
        ])
        if any(r.status == "success" for r in recent):
            return
        for row in recent:
            if row.status == "error":
                distinct_error_days.add(row.created_at.date())
        if len(distinct_error_days) < FAILURE_ACTIVITY_DAYS:
            return
        if log.activity_ids:
            return
        log.activity_schedule(
            "mail.mail_activity_data_warning",
            summary="BCV sin respuesta hace %s días" % len(distinct_error_days),
            note="No se ha podido obtener la tasa BCV. Verifique el sitio del BCV "
                 "o registre una tasa manual desde el wizard de Tasa BCV.",
            user_id=self.env.ref("base.user_admin").id,
        )

    # -- public entry points -------------------------------------------------
    @api.model
    def sync(self, companies=None, automatic=True):
        """Idempotent synchronization. Fetches the BCV board at most once and
        applies it per company. Returns False when any company ends in error."""
        self = self.with_context(bcv_automatic=automatic)
        if companies is None:
            companies = self.env["res.company"].search([])
        today = self._caracas_today()
        board = None
        ok = True
        for company in companies:
            try:
                if self._apply_manual_rate(company, today):
                    continue
                if not self._needs_fetch(company, today):
                    continue
                if board is None:
                    board = self._fetch_board()
                ok = self._apply_board(company, board, today) and ok
            except Exception:
                _logger.exception("[%s] BCV sync failed", company.name)
                ok = False
        return ok

    @api.model
    def _apply_board(self, company, board, today):
        if board.get("error"):
            log = self._log(company, {
                "date": today, "status": "error",
                "error_type": board["error"].get("type", "Unknown"),
                "error_message": board["error"].get("message", ""),
            })
            self._maybe_raise_failure_activity(company, log)
            return False

        fecha_valor = board["date"]
        usd_value = board["rates"].get("USD", 0.0)
        if self._is_suspect(company, today, usd_value):
            self._log(company, {
                "date": fecha_valor, "rate_usd": usd_value, "status": "error",
                "suspect": True, "error_type": "Suspect",
                "error_message": "Desviación mayor a %s%% frente a la tasa vigente; "
                                 "retenida hasta confirmación manual." % SUSPECT_THRESHOLD_PERCENT,
            })
            return True

        if self._store_rate(company, fecha_valor, board["rates"]):
            self._log(company, {
                "date": fecha_valor, "rate_usd": usd_value,
                "status": "success", "rate_source": "bcv",
            })
        return True
```

Add `from datetime import timedelta` to the file's imports.

- [ ] **Step 4: Run tests — expected PASS**

- [ ] **Step 5: Commit**

```bash
git add l10n_ve_currency_rate_live/
git commit -m "feat(bcv): idempotent sync with manual precedence, suspect guard and failure activity"
```

---

### Task 8: `backfill()` from official SMC history

**Files:**
- Modify: `l10n_ve/l10n_ve_currency_rate_live/models/bcv_rate_service.py`
- Test: `tests/test_bcv_rate_service.py`

**Interfaces:**
- Produces: `backfill(companies=None, max_days=30) -> bool`. Fills missing banking days from `get_bcv_rate_history`; absent dates = non-banking (spec D6/C7/C8). Task 10's cron calls it after `sync()`.

- [ ] **Step 1: Write the failing tests**

```python
@tagged("post_install", "-at_install", "bcv_rate")
class TestBackfill(BcvServiceCase):
    def _backfill(self, history, now=datetime(2026, 7, 16, 9, 0)):
        with self._patch_now(now), \
             patch.object(BcvRateService, "_fetch_history",
                          return_value=history) as mock_hist:
            ok = self.service.backfill(self.company)
        return ok, mock_hist

    def test_fills_gap_skips_non_banking(self):
        # last stored Friday 10th; server off 13th–15th; today Thu 16th
        self._rate_row(date(2026, 7, 10), 620.0)
        history = {"rates_by_date": {
            date(2026, 7, 13): {"USD": 621.0},
            date(2026, 7, 14): {"USD": 621.5},
            date(2026, 7, 15): {"USD": 622.0},
            # 11th/12th weekend: absent = non-banking
        }, "error": None}
        ok, _ = self._backfill(history)
        self.assertTrue(ok)
        for day, expected in ((date(2026, 7, 13), 621.0), (date(2026, 7, 15), 622.0)):
            row = self.env["res.currency.rate"].search(
                [("name", "=", day), ("currency_id", "=", self.usd.id),
                 ("company_id", "=", self.company.id)])
            self.assertEqual(row.inverse_company_rate, expected)
        self.assertFalse(self.env["res.currency.rate"].search_count(
            [("name", "=", date(2026, 7, 11)), ("company_id", "=", self.company.id)]))
        logs = self.env["bcv.rate.log"].search([
            ("company_id", "=", self.company.id), ("rate_source", "=", "smc")])
        self.assertEqual(len(logs), 3)

    def test_no_gap_no_history_call(self):
        self._rate_row(date(2026, 7, 13), 618.0)
        self._rate_row(date(2026, 7, 14), 619.0)
        self._rate_row(date(2026, 7, 15), 620.0)
        self._rate_row(date(2026, 7, 16), 621.0)
        ok, mock_hist = self._backfill({"rates_by_date": {}, "error": None})
        self.assertTrue(ok)
        mock_hist.assert_not_called()

    def test_history_error_is_soft(self):
        self._rate_row(date(2026, 7, 10), 620.0)
        ok, _ = self._backfill({"rates_by_date": {},
                                "error": {"type": "ConnectionError", "message": "down"}})
        self.assertFalse(ok)  # reported, but no exception

    def test_fresh_db_skips_backfill(self):
        ok, mock_hist = self._backfill({"rates_by_date": {}, "error": None})
        self.assertTrue(ok)
        mock_hist.assert_not_called()
```

Note for `test_no_gap_no_history_call`: weekday gaps inside the window trigger a history call even when today is covered — the setup stores 13th–16th contiguously so no weekday is missing (11th–12th are weekend; see implementation: candidates exclude weekends optimistically BUT a weekend date missing from history stays absent — storing candidates is driven by history content, weekends only avoid pointless fetches).

- [ ] **Step 2: Run — expected FAIL**

- [ ] **Step 3: Implement**

Append to the service class:

```python
    @api.model
    def _fetch_history(self, date_from, date_to):
        return binaural_bcv_query.get_bcv_rate_history(self, date_from, date_to)

    @api.model
    def backfill(self, companies=None, max_days=30):
        """Fill missing banking-day rates from the official SMC history.

        A date absent from the SMC result is a non-banking day and stays empty.
        Weekends are excluded from the candidate scan only to avoid pointless
        fetches; SMC content is the final authority on banking days.
        """
        if companies is None:
            companies = self.env["res.company"].search([])
        today = self._caracas_today()
        Rate = self.env["res.currency.rate"].sudo()
        history = None
        ok = True
        for company in companies:
            if not self._usd():
                continue
            last = Rate.search(self._usd_domain(company) + [("name", "<=", today)],
                               order="name desc", limit=1)
            if not last:
                continue  # fresh DB: sync() owns the first capture
            start = max(last.name + timedelta(days=1), today - timedelta(days=max_days))
            candidates = [
                start + timedelta(days=offset)
                for offset in range((today - start).days + 1)
                if (start + timedelta(days=offset)).isoweekday() <= 5
            ]
            existing = {
                row.name
                for row in Rate.search(self._usd_domain(company) + [("name", ">=", start)])
            }
            missing = [day for day in candidates if day not in existing]
            if not missing:
                continue
            if history is None:
                history = self._fetch_history(min(missing), today)
            if history.get("error"):
                _logger.warning("[%s] BCV backfill: history unavailable: %s",
                                company.name, history["error"].get("message"))
                ok = False
                continue
            for day in missing:
                day_rates = history["rates_by_date"].get(day)
                if not day_rates:
                    continue  # non-banking day
                if self._store_rate(company, day, day_rates):
                    self._log(company, {
                        "date": day, "rate_usd": day_rates.get("USD", 0.0),
                        "status": "success", "rate_source": "smc",
                    })
        return ok
```

- [ ] **Step 4: Run tests — expected PASS**

- [ ] **Step 5: Commit**

```bash
git add l10n_ve_currency_rate_live/
git commit -m "feat(bcv): backfill missing banking days from official SMC history"
```

---

### Task 9: Enterprise routing + dead flag removal

**Files:**
- Modify: `l10n_ve/l10n_ve_currency_rate_live/models/res_company.py` (full rewrite, it only holds BCV code)
- Modify: `l10n_ve/l10n_ve_currency_rate_live/models/res_config_settings.py`
- Modify: `l10n_ve/l10n_ve_currency_rate_live/views/res_config_settings.xml`
- Test: `tests/test_bcv_rate_service.py`

**Interfaces:**
- Produces: `res.company.update_currency_rates()` override routing provider `bcv` → `service.sync(...)`, others → `super()`. `_parse_bcv_data` and `can_update_habil_days` are DELETED (spec B2/B13/B16, D6).

- [ ] **Step 1: Write the failing tests**

```python
@tagged("post_install", "-at_install", "bcv_rate")
class TestEnterpriseRouting(BcvServiceCase):
    def test_bcv_companies_routed_to_sync_others_untouched(self):
        company_b = self.env["res.company"].create({"name": "Sucursal B", "currency_id": self.vef.id})
        (self.company | company_b).write({"currency_provider": "bcv"})
        with patch.object(BcvRateService, "sync", return_value=True) as mock_sync:
            result = (self.company | company_b).update_currency_rates()
        self.assertTrue(result)
        mock_sync.assert_called_once()
        routed = mock_sync.call_args.args[0]
        self.assertEqual(set(routed.ids), {self.company.id, company_b.id})

    def test_weekend_settings_button_does_not_crash(self):
        # spec B16 regression: full Enterprise entry point on a Saturday
        self.company.currency_provider = "bcv"
        with self._patch_now(datetime(2026, 7, 18, 10, 0)), \
             patch.object(BcvRateService, "_fetch_board",
                          return_value=_bcv_ok(date(2026, 7, 20))):
            result = self.company.update_currency_rates()
        self.assertTrue(result)

    def test_habil_flag_removed(self):
        self.assertNotIn("can_update_habil_days", self.env["res.company"]._fields)
```

- [ ] **Step 2: Run — expected FAIL**

- [ ] **Step 3: Implement — replace `models/res_company.py` entirely with:**

```python
from odoo import fields, models


class ResCompany(models.Model):
    _inherit = "res.company"

    currency_provider = fields.Selection(
        selection_add=[("bcv", "Venezuelan Central Bank")]
    )

    def update_currency_rates(self):
        """Route BCV companies through bcv.rate.service (single write path);
        every other provider keeps the standard Enterprise flow."""
        bcv_companies = self.filtered(lambda company: company.currency_provider == "bcv")
        other_companies = self - bcv_companies
        result = True
        if bcv_companies:
            result = self.env["bcv.rate.service"].sync(bcv_companies, automatic=False)
        if other_companies:
            result = super(ResCompany, other_companies).update_currency_rates() and result
        return result
```

DELETE `models/res_config_settings.py` (its only content was the removed flag) and remove its import from `models/__init__.py`. After this task `models/__init__.py` imports `bcv_rate_helper, bcv_rate_log, bcv_rate_service, res_company` — the helper import is removed in Task 10.

In `views/res_config_settings.xml`, remove the whole `<div id="l10n_ve_currency_rate_live_div">…</div>` block AND the two `can_update_habil_days` nodes inside it (lines 10–20 of the current file), leaving the `<separator string="Exchange Rate Synchronization" />` inside the xpath. Final arch content:

```xml
                <xpath expr="//block[@name='l10n_ve_rate_block']" position="inside">
                    <separator string="Exchange Rate Synchronization" />
                </xpath>
```

- [ ] **Step 4: Run tests — expected PASS** (also rerun the whole `bcv_rate` tag)

- [ ] **Step 5: Commit**

```bash
git add l10n_ve_currency_rate_live/
git commit -m "feat(bcv): route Enterprise update_currency_rates through the service; drop habil-days flag"
```

---

### Task 10: Hourly cron, `run_hourly`, post-init, helper removal

**Files:**
- Create: `l10n_ve/l10n_ve_currency_rate_live/data/ir_cron.xml`
- Delete: `l10n_ve/l10n_ve_currency_rate_live/models/bcv_rate_helper.py`
- Modify: `models/__init__.py`, `models/bcv_rate_service.py`, `__init__.py` (root), `__manifest__.py`
- Test: `tests/test_bcv_rate_service.py`

**Interfaces:**
- Produces: `bcv.rate.service.run_hourly()` (cron target; exception-proof). XML id `l10n_ve_currency_rate_live.ir_cron_bcv_rate_sync`.

- [ ] **Step 1: Write the failing tests**

```python
@tagged("post_install", "-at_install", "bcv_rate")
class TestCron(BcvServiceCase):
    def test_run_hourly_calls_sync_then_backfill(self):
        with patch.object(BcvRateService, "sync", return_value=True) as mock_sync, \
             patch.object(BcvRateService, "backfill", return_value=True) as mock_backfill:
            self.service.run_hourly()
        mock_sync.assert_called_once()
        mock_backfill.assert_called_once()

    def test_run_hourly_survives_exceptions(self):
        with patch.object(BcvRateService, "sync", side_effect=RuntimeError("boom")), \
             patch.object(BcvRateService, "backfill", return_value=True) as mock_backfill:
            self.service.run_hourly()  # must not raise
        mock_backfill.assert_called_once()

    def test_cron_record_exists_hourly(self):
        cron = self.env.ref("l10n_ve_currency_rate_live.ir_cron_bcv_rate_sync")
        self.assertEqual(cron.interval_type, "hours")
        self.assertEqual(cron.interval_number, 1)
        self.assertTrue(cron.active)

    def test_helper_model_gone(self):
        self.assertNotIn("bcv.rate.helper", self.env)
```

- [ ] **Step 2: Run — expected FAIL**

- [ ] **Step 3: Implement**

Append to the service class:

```python
    @api.model
    def run_hourly(self):
        """Hourly cron entry point. Each phase is isolated: a sync crash must
        never block backfill, and vice versa. Overdue runs execute at server
        boot, which is what heals powered-off servers (spec C7/C8)."""
        for step_name, step in (("sync", self.sync), ("backfill", self.backfill)):
            try:
                step()
            except Exception:
                _logger.exception("BCV run_hourly: %s failed", step_name)
```

Create `data/ir_cron.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<odoo>
    <record id="ir_cron_bcv_rate_sync" model="ir.cron" forcecreate="True">
        <field name="name">BCV: sincronización de tasa (horaria)</field>
        <field name="model_id" ref="model_bcv_rate_service"/>
        <field name="state">code</field>
        <field name="code">model.run_hourly()</field>
        <field name="interval_number">1</field>
        <field name="interval_type">hours</field>
        <field name="active" eval="True"/>
    </record>
</odoo>
```

Manifest `data` list: add `"data/ir_cron.xml"` (keep existing entries).

Delete `models/bcv_rate_helper.py`; update `models/__init__.py` to exactly:

```python
from . import bcv_rate_log
from . import bcv_rate_service
from . import res_company
```

Root `__init__.py` — replace `setup_currency_update` with:

```python
def setup_currency_update(env):
    env = api.Environment(env.cr, SUPERUSER_ID, {})
    env.company.write({
        "currency_provider": "bcv",
        "currency_interval_unit": "daily",
        "currency_next_execution_date": datetime.date.today() + relativedelta(days=+1),
    })
    try:
        env["bcv.rate.service"].sync(env.company, automatic=True)
    except Exception:
        pass
```

- [ ] **Step 4: Run tests — expected PASS**

- [ ] **Step 5: Commit**

```bash
git add l10n_ve_currency_rate_live/
git rm l10n_ve_currency_rate_live/models/bcv_rate_helper.py 2>/dev/null || git add -A l10n_ve_currency_rate_live/models/
git commit -m "feat(bcv): hourly idempotent cron, remove legacy fallback helper"
```

---

### Task 11: Wizard rewrite — read-only state, explicit actions

**Files:**
- Modify: `l10n_ve/l10n_ve_currency_rate_live/wizard/bcv_rate_wizard.py` (full rewrite)
- Modify: `l10n_ve/l10n_ve_currency_rate_live/wizard/bcv_rate_wizard_view.xml`
- Test: create `tests/test_bcv_rate_wizard.py` (add to tests `__init__.py`)

**Interfaces:**
- Consumes: `bcv.rate.service.get_state(company)`, `sync(companies, automatic=False)`.
- Produces: `bcv.rate.wizard` fields `governing_rate, governing_date, next_rate, next_date, is_banking_day, stale_days, status_message, error_message`; actions `action_refresh_rate`, `action_update_prices`, `action_view_history`. The "use last known rate" button is REMOVED (spec D5 — the last known rate already governs).

- [ ] **Step 1: Write the failing tests**

`tests/test_bcv_rate_wizard.py`:

```python
from datetime import date, datetime
from unittest.mock import patch

from odoo.exceptions import UserError
from odoo.tests import Form, TransactionCase, tagged

from odoo.addons.l10n_ve_currency_rate_live.models.bcv_rate_service import BcvRateService
from .test_bcv_rate_service import BcvServiceCase, _bcv_ok, _bcv_err, _caracas


@tagged("post_install", "-at_install", "bcv_rate")
class TestBcvRateWizard(BcvServiceCase):
    def _open(self, now=datetime(2026, 7, 16, 9, 0)):
        # Form() runs default_get like the real client; plain create({}) would not.
        with self._patch_now(now):
            return Form(self.env["bcv.rate.wizard"]).save()

    def test_open_makes_no_http_and_no_logs(self):
        with patch.object(BcvRateService, "_fetch_board") as mock_fetch:
            self._open()
        mock_fetch.assert_not_called()
        self.assertFalse(self.env["bcv.rate.log"].search_count([]))

    def test_shows_governing_by_date(self):
        self._rate_row(date(2026, 7, 15), 620.0)
        wizard = self._open()
        self.assertEqual(wizard.governing_rate, 620.0)
        self.assertEqual(wizard.governing_date, date(2026, 7, 15))
        self.assertFalse(wizard.is_banking_day)

    def test_refresh_success_updates_state(self):
        wizard = self._open()
        with self._patch_now(datetime(2026, 7, 16, 9, 0)), \
             patch.object(BcvRateService, "_fetch_board",
                          return_value=_bcv_ok(date(2026, 7, 16))):
            wizard.action_refresh_rate()
        self.assertEqual(wizard.governing_rate, 621.53)
        self.assertTrue(wizard.is_banking_day)
        self.assertFalse(wizard.error_message)

    def test_refresh_failure_shows_error(self):
        wizard = self._open()
        with self._patch_now(datetime(2026, 7, 16, 9, 0)), \
             patch.object(BcvRateService, "_fetch_board", return_value=_bcv_err()):
            wizard.action_refresh_rate()
        self.assertTrue(wizard.error_message)

    def test_update_prices_requires_governing_rate(self):
        wizard = self._open()
        with self.assertRaises(UserError):
            wizard.action_update_prices()

    def test_update_prices_writes_no_currency_rates(self):
        self._rate_row(date(2026, 7, 16), 621.53)
        wizard = self._open(now=datetime(2026, 7, 16, 10, 0))
        before = self.env["res.currency.rate"].search_count([])
        with patch.object(type(self.env["product.pricelist"]),
                          "_update_product_prices", create=True, return_value=True):
            wizard.action_update_prices()
        self.assertEqual(self.env["res.currency.rate"].search_count([]), before)
```

- [ ] **Step 2: Run — expected FAIL**

- [ ] **Step 3: Rewrite `wizard/bcv_rate_wizard.py` entirely:**

```python
from odoo import api, fields, models, _
from odoo.exceptions import UserError


class BcvRateWizard(models.TransientModel):
    _name = 'bcv.rate.wizard'
    _description = 'Wizard to consult BCV rate and update prices'

    company_id = fields.Many2one('res.company', string='Compañía',
                                 default=lambda self: self.env.company)
    governing_rate = fields.Float(string='Tasa vigente (Bs/USD)', digits=(12, 4), readonly=True)
    governing_date = fields.Date(string='Fecha Valor vigente', readonly=True)
    next_rate = fields.Float(string='Próxima tasa publicada', digits=(12, 4), readonly=True)
    next_date = fields.Date(string='Próxima Fecha Valor', readonly=True)
    is_banking_day = fields.Boolean(readonly=True)
    stale_days = fields.Integer(readonly=True)
    status_message = fields.Text(string='Estado', readonly=True)
    error_message = fields.Text(string='Mensaje de error', readonly=True)

    @api.model
    def default_get(self, fields_list):
        """Read-only snapshot of the service state. NO network, NO writes."""
        res = super().default_get(fields_list)
        res.update(self._state_vals())
        return res

    @api.model
    def _state_vals(self, error_message=''):
        state = self.env['bcv.rate.service'].get_state(self.env.company)
        if not state['governing_date']:
            status = _('No hay ninguna tasa USD registrada. Consulte el BCV o '
                       'registre una tasa manual.')
        elif state['is_banking_day']:
            status = _('Hoy es día bancario. Rige la tasa del %s.') % state['governing_date']
        else:
            status = _('Hoy no es día bancario (el BCV no publicó tasa para hoy). '
                       'Rige la tasa del %s.') % state['governing_date']
            if state['stale_days'] >= 3:
                status += _(' Atención: la tasa vigente tiene %s días; verifique si '
                            'el BCV estuvo inaccesible.') % state['stale_days']
        if state['next_date']:
            status += _(' Ya está registrada la próxima tasa: %s Bs/USD para el %s.') % (
                state['next_rate'], state['next_date'])
        return {
            'governing_rate': state['governing_rate'],
            'governing_date': state['governing_date'],
            'next_rate': state['next_rate'],
            'next_date': state['next_date'],
            'is_banking_day': state['is_banking_day'],
            'stale_days': state['stale_days'],
            'status_message': status,
            'error_message': error_message,
        }

    def action_refresh_rate(self):
        """Explicit user-triggered BCV consultation."""
        self.ensure_one()
        service = self.env['bcv.rate.service']
        ok = service.sync(self.company_id, automatic=False)
        error_message = ''
        if not ok:
            last_log = self.env['bcv.rate.log'].search(
                [('company_id', '=', self.company_id.id), ('status', '=', 'error')],
                order='created_at desc', limit=1)
            error_message = last_log.error_message or _('No se pudo consultar el BCV.')
        self.write(self._state_vals(error_message=error_message))
        return self._reopen()

    def action_update_prices(self):
        """Update reference-pricelist prices with the GOVERNING rate.
        Never writes res.currency.rate (spec D5): the governing rate already
        rules by date."""
        self.ensure_one()
        if not self.governing_rate or not self.governing_date:
            raise UserError(_('No hay una tasa vigente. Consulte el BCV o registre '
                              'una tasa manual antes de actualizar precios.'))
        pricelist_model = self.env['product.pricelist']
        if hasattr(pricelist_model, '_update_product_prices'):
            pricelist_model._update_product_prices()
        return {
            'type': 'ir.actions.client',
            'tag': 'display_notification',
            'params': {
                'title': _('Éxito'),
                'message': _('Precios actualizados con la tasa vigente del %s '
                             '(%.4f Bs/USD)') % (self.governing_date, self.governing_rate),
                'sticky': False,
                'next': {'type': 'ir.actions.act_window_close'},
            },
        }

    def action_view_history(self):
        return {
            'type': 'ir.actions.act_window',
            'name': _('Historial BCV'),
            'res_model': 'bcv.rate.log',
            'view_mode': 'tree,form',
            'target': 'current',
        }

    def _reopen(self):
        return {
            'type': 'ir.actions.act_window',
            'res_model': 'bcv.rate.wizard',
            'view_mode': 'form',
            'res_id': self.id,
            'target': 'new',
        }
```

(The Enterprise menu self-healing hack from the old `default_get` is deleted; the menu parent is already correct in the view XML.)

- [ ] **Step 4: Rewrite the form view arch in `bcv_rate_wizard_view.xml`** (records/actions/menus stay; only the `<form>` changes):

```xml
            <form string="Consultar Tasa BCV">
                <sheet>
                    <div class="alert alert-danger" role="alert" invisible="not error_message">
                        <h4>⚠️ Error al consultar el BCV</h4>
                        <p><field name="error_message" readonly="1"/></p>
                        <p>La última tasa registrada sigue vigente. Si la falla persiste,
                           registre una tasa manual (requiere permiso especial).</p>
                    </div>
                    <div class="alert alert-info" role="alert" invisible="not status_message">
                        <p><field name="status_message" readonly="1"/></p>
                    </div>
                    <group>
                        <field name="governing_rate" widget="monetary"
                               options="{'currency_field': 'company_id.currency_id'}"/>
                        <field name="governing_date"/>
                        <field name="next_rate" invisible="not next_date"/>
                        <field name="next_date" invisible="not next_date"/>
                        <field name="is_banking_day" invisible="1"/>
                        <field name="stale_days" invisible="1"/>
                        <field name="company_id" invisible="1"/>
                    </group>
                </sheet>
                <footer>
                    <button name="action_refresh_rate" string="Consultar BCV" type="object"
                            class="btn-primary" data-hotkey="q"/>
                    <button name="action_update_prices" string="Actualizar Precios" type="object"
                            class="btn-secondary" data-hotkey="w"/>
                    <button name="action_view_history" string="Ver Historial" type="object"
                            class="btn-secondary" data-hotkey="h"/>
                    <button string="Cerrar" class="btn-secondary" special="cancel" data-hotkey="x"/>
                </footer>
            </form>
```

- [ ] **Step 5: Run tests — expected PASS** (all wizard tests + rerun full `bcv_rate` tag)

- [ ] **Step 6: Commit**

```bash
git add l10n_ve_currency_rate_live/
git commit -m "feat(bcv): read-only wizard over service state; no side effects on open"
```

---

### Task 12: `lida_reference_prices` KeyError guard (spec B10)

**Files:**
- Modify: `l10n_ve/lida_reference_prices/models/product_pricelist.py:139-161`
- Test: create `l10n_ve/lida_reference_prices/tests/__init__.py` + `tests/test_update_prices_guard.py`; add `'tests'` package import via manifest auto-discovery (tests dir only needs `__init__.py`).

**Interfaces:**
- Changes `_update_product_prices()` to raise `UserError` with a clear message when no rate exists, instead of `KeyError`.

- [ ] **Step 1: Write the failing test**

`lida_reference_prices/tests/__init__.py`:

```python
from . import test_update_prices_guard
```

`lida_reference_prices/tests/test_update_prices_guard.py`:

```python
from odoo.exceptions import UserError
from odoo.tests import TransactionCase, tagged


@tagged("post_install", "-at_install", "bcv_rate")
class TestUpdatePricesGuard(TransactionCase):
    def test_no_rates_raises_usererror_not_keyerror(self):
        company = self.env.company
        company.currency_id = self.env.ref("base.VEF")
        pricelist = self.env["product.pricelist"].create({
            "name": "Ref USD", "currency_id": self.env.ref("base.USD").id})
        company.reference_pricelist_id = pricelist
        self.env["res.currency.rate"].search([]).unlink()
        with self.assertRaises(UserError):
            self.env["product.pricelist"]._update_product_prices()
```

- [ ] **Step 2: Run** (`--test-tags bcv_rate -u lida_reference_prices` added to the module list) — expected FAIL with `KeyError: 'foreign_rate'`

- [ ] **Step 3: Implement** — in `_update_product_prices`, replace:

```python
        rate = Rate.compute_rate(ref_pricelist.currency_id.id, today)['foreign_rate']
```

with:

```python
        rate_values = Rate.compute_rate(ref_pricelist.currency_id.id, today)
        rate = rate_values.get('foreign_rate') if rate_values else 0.0
        if not rate:
            raise UserError(_(
                'No hay ninguna tasa registrada para %s. Consulte el BCV desde el '
                'wizard de Tasa BCV antes de actualizar precios.'
            ) % ref_pricelist.currency_id.name)
```

Add `from odoo.exceptions import UserError` and `_` to that file's imports if missing.

- [ ] **Step 4: Run tests — expected PASS**

- [ ] **Step 5: Commit**

```bash
git add lida_reference_prices/
git commit -m "fix(prices): clear UserError instead of KeyError when no rate exists"
```

---

### Task 13: Full 17.0 verification + CHANGELOG

**Files:**
- Modify: `l10n_ve/CHANGELOG.md`

- [ ] **Step 1: Full module test run**

```bash
cd /home/moi/Documentos/odoo-docker-dev
docker compose run --rm odoo17 odoo -d test_bcv_full -i l10n_ve_currency_rate_live,lida_reference_prices -u l10n_ve_currency_rate_live,lida_reference_prices --test-tags bcv_rate,l10n_ve_rate --stop-after-init
```

Expected: `0 failed, 0 error(s)`. Also upgrade-path check on a copy of a real DB if available: `-u l10n_ve_currency_rate_live` must run the 17.0.2.0.0 migration cleanly.

- [ ] **Step 2: Manual smoke (use the `verify` skill at execution time)** — open the wizard: no network on open; press "Consultar BCV" (with BCV up) → governing/next dates correct; Settings → "Update now" works; cron visible in Technical → Scheduled Actions.

- [ ] **Step 3: CHANGELOG entry + commit**

Add under a new `## l10n_ve_currency_rate_live 17.0.2.0.0` heading in `CHANGELOG.md`: hourly idempotent sync, real Fecha Valor storage (future included), official SMC backfill, TLS verified with bundled CA, suspect-rate guard, wizard without side effects, removal of `can_update_habil_days` and of the last-known-rate button, `bcv.rate.helper` removed, multi-company fix. Then:

```bash
git add CHANGELOG.md && git commit -m "docs: changelog for BCV rate resilience 17.0.2.0.0"
```

---

### Task 14: Odoo 18 port

**Files:**
- Branch: `l10n_ve` repo — `18.0-lida` (or the repo's existing 18 branch)
- Modify (18 branch only): `l10n_ve_currency_rate_live/views/bcv_rate_log_views.xml`, `wizard/bcv_rate_wizard.py`, `wizard/bcv_rate_wizard_view.xml` (if needed), `__manifest__.py` (version `18.0.2.0.0`, migration folder renamed `18.0.2.0.0`)

- [ ] **Step 1: Locate/create the 18 branch and land the feature**

```bash
cd /home/moi/Documentos/odoo-docker-dev/l10n_ve
git fetch origin && git branch -r | grep '18'
# If an 18 branch exists: checkout it and merge/cherry-pick feature/bcv-rate-resilience.
# If not: STOP and confirm with the user how the 18 code line will be created —
# porting the whole localization is outside this plan's scope.
```

- [ ] **Step 2: VERIFICATION — Enterprise 18 API** (needs 18 enterprise source, e.g. on odoo.sh or a local checkout)

```bash
grep -n "def update_currency_rates" <path-to-18-enterprise>/currency_rate_live/models/res_config_settings.py
grep -n "currency_provider = fields.Selection" <path-to-18-enterprise>/currency_rate_live/models/res_config_settings.py
python3 -c "print('check res.currency.rate fields inverse_company_rate/company_rate exist in 18 core')"
grep -rn "inverse_company_rate" <path-to-18-odoo>/addons/base/models/res_currency.py
```

Expected: same method name/signature and fields present. If `update_currency_rates` moved or changed signature, adapt the Task 9 override accordingly and record the difference in the CHANGELOG.

- [ ] **Step 3: View syntax port (`tree` → `list` in Odoo 18)**

- `views/bcv_rate_log_views.xml`: `<tree …>` → `<list …>` (same attributes), closing tag too; action `view_mode`: `tree,form` → `list,form`.
- `wizard/bcv_rate_wizard.py` `action_view_history`: `'view_mode': 'tree,form'` → `'list,form'`.
- Rename `migrations/17.0.2.0.0/` → `migrations/18.0.2.0.0/`; manifest version `18.0.2.0.0`.

- [ ] **Step 4: Run the full test suite on 18**

Same command as Task 13 but against the Odoo 18 container/env used for the 18 branch (e.g. service `odoo18` or odoo.sh dev build). Expected: `0 failed, 0 error(s)` — the service/tool tests are version-agnostic by design.

- [ ] **Step 5: Commit on the 18 branch**

```bash
git add -A && git commit -m "feat(bcv): port BCV rate resilience to Odoo 18 (list views, v18.0.2.0.0)"
```

---

## Execution notes

- After Task 13, run the superpowers:requesting-code-review skill before merging; use superpowers:finishing-a-development-branch for the merge/PR decision on the submodule repo.
- Real-world validation of Task 2 (TLS bundle) and Task 4 Step 1 (SMC layout) depends on BCV being reachable; both tasks state their degraded path.
