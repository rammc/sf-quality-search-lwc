# Contributing

Thanks for considering a contribution. This is a small package with a sharp
security purpose, so the bar for changes is "does this preserve the security
contract?" rather than "does it add a feature?".

## Before opening a PR

1. **Run the Apex tests against a scratch org or dev sandbox.**
   ```bash
   sf project deploy start -o <org-alias>
   sf apex run test -o <org-alias> --class-names QualitySearchControllerTest --result-format human --code-coverage
   ```
   All 16 tests must pass and coverage on `QualitySearchController` /
   `QualitySearchAudit` must stay at 100%.

2. **Keep the security boundary intact.** In particular:
   - The outer `QualitySearchController` stays `with sharing`.
   - The `PrivilegedFinder` inner class stays `private without sharing` and
     is the ONLY place that uses `AccessLevel.SYSTEM_MODE`.
   - Do not switch the privileged SOQL to `USER_MODE` — that re-imposes
     record sharing and defeats the component.
   - Field-Level Security stays enforced via `Security.stripInaccessible`.
   - User-supplied values stay bound via `Database.queryWithBinds`; never
     concatenate into the SOQL string.
   - Exact match only. No `LIKE`, no wildcards, no fuzzy matching.
   - Every code path that returns a result must also write an audit row.
   - The audit row must NOT contain identifier values.

3. **Document changes** in the README's Changelog section if there is one,
   or in the PR description if not. If you change the security model,
   describe the new threat model.

## Style

- Apex: 4-space indent, no trailing whitespace, descriptive names. The
  existing file structure is a reasonable template.
- LWC: stick to the SLDS 2 styling hooks (`--slds-g-*`). Don't reintroduce
  deprecated SLDS 1 (`--lwc-*`) tokens.
- Comments: explain **why**, not what. The "what" is in the code.

## What is in scope

- Bug fixes to the security contract or the audit trail.
- Additional optional filter fields, as long as they cannot satisfy the
  2-of-3 gate on their own.
- Person Account support that handles non-default RecordType developer names.
- A retention job for `Quality_Search_Audit__c`.
- A scheduled phone-normalisation helper for orgs that store phones in
  mixed formats.

## What is out of scope

- Wildcard / fuzzy / `LIKE`-based search. There is a reason this component
  is exact-match only; if your use case needs fuzzy lookup, use a different
  tool.
- Removing the audit. The audit is the legal basis for the sharing bypass.
- Replacing `Security.stripInaccessible` with `WITH USER_MODE`. See above.

## Reporting security issues

Please do NOT open a public issue for a security finding. Open a private
security advisory on GitHub or email the maintainer; coordinated disclosure
will be honoured.
