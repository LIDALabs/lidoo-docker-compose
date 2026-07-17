# BCV Rate Resilience — Odoo 18 Port Guide

**Status:** the 17.0 implementation is complete and tested on branch `feature/bcv-rate-resilience` (submodule `l10n_ve`, based on `origin/17.0-lida`). This guide is the ready-to-apply checklist for the Odoo 18 line.

## Why this is a separate step (blocker)

There is currently **no Odoo 18 code line to port onto**:
- The `l10n_ve` submodule has no `18.0` / `18.0-lida` branch (local or remote).
- `docker-compose.yaml` has no `odoo18` service; the `enterprise/` checkout on disk is Odoo 17.
- `l10n_ve_currency_rate_live` depends on the whole localization (`l10n_ve_rate`, `lida_reference_prices`, `account_accountant`), so it cannot install or be tested on 18 in isolation.

Porting the entire localization to Odoo 18 is a large, separate effort outside this BCV feature's scope. **Decision needed from the maintainer:** create/point to an 18 branch of the localization and an 18 runtime, then apply the small deltas below. The service/tool layer of this feature is deliberately version-agnostic, so the port is mechanical once an 18 environment exists.

## Deltas to apply on the 18 branch

The Python service (`bcv_rate_service.py`), the tool (`tools/binaural_bcv_query.py`), `sync`/`backfill`/cron logic, `mail.thread`/`mail.activity.mixin`, `pytz`/`America/Caracas`, and the access-control model are all **unchanged** between 17 and 18. Only the following are version-specific:

### 1. List view tag `tree` → `list` (Odoo 18 renamed the tag)
`l10n_ve_currency_rate_live/views/bcv_rate_log_views.xml`:
- Line ~7: `<tree string="BCV Rate Logs" decoration-success=... decoration-danger=... create="0">` → `<list ...>`
- Line ~18: `</tree>` → `</list>`
- Line ~72: `<field name="view_mode">tree,form</field>` → `list,form`

### 2. Action `view_mode` in Python
`l10n_ve_currency_rate_live/wizard/bcv_rate_wizard.py`:
- Line ~97 (`action_view_history`): `'view_mode': 'tree,form'` → `'list,form'`
- Line ~105 (`_reopen`): `'view_mode': 'form'` — **unchanged** (form view).

The wizard form view (`bcv_rate_wizard_view.xml`) uses `<form>` only — no change.

### 3. Manifest version + migration folder
`l10n_ve_currency_rate_live/__manifest__.py`: `"version": "17.0.2.0.0"` → `"18.0.2.0.0"`.
Rename `migrations/17.0.2.0.0/` → `migrations/18.0.2.0.0/` (the `pre-migration.py` dropping `can_update_habil_days` is unchanged).

### 4. Verifications to run on 18 (do NOT assume — check against the real 18 source)
- `res.company.update_currency_rates()` still exists with the same signature in 18's `currency_rate_live/models/res_config_settings.py` (our override calls `super(...).update_currency_rates()`). If it moved/changed, adapt the override in `models/res_company.py`.
- `currency_provider = fields.Selection(selection_add=[("bcv", ...)])` still valid in 18.
- `res.currency.rate` still has `inverse_company_rate` and `company_rate` (7 references in `models/`). These exist since Odoo 16, so expected present — confirm.
- `mail.mail_activity_data_warning` xmlid and `base.user_admin` exist in 18 (both used by `_maybe_raise_failure_activity`).

### 5. Test on 18
Run the same suite against an 18 test DB:
`odoo -d test_bcv18 -u l10n_ve_currency_rate_live,lida_reference_prices --test-enable --test-tags bcv_rate --stop-after-init`
The tests are version-agnostic; expect the same green result. The `Form(...)` wizard test and the `patch.object(BcvRateService, ...)` patches work identically in 18.

## Also carry over the two deferred, BCV-reachability follow-ups (same on both versions)
- Generate `tools/certs/bcv_chain.pem` (see `tools/certs/README.md`).
- Validate the SMC `.xls` column constants against a real BCV SMC workbook.
