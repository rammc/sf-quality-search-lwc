# Quality Search LWC

> Salesforce Lightning Web Component for high-confidence customer lookup
> that deliberately bypasses record-level sharing for authorised users —
> with field-level security, anti-enumeration, and a full audit trail kept
> intact.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Salesforce API 62.0+](https://img.shields.io/badge/Salesforce%20API-62.0%2B-blue)
![SLDS 2 hooks](https://img.shields.io/badge/SLDS-2-blueviolet)

---

## The problem

You have a private sharing model. Most of the time that is exactly what
you want. But there are roles — service stewards, fraud reviewers, contact
centre agents handling a one-off call — who legitimately need to **find a
specific customer they don't own** so they can verify identity and help.

The usual workarounds are bad:

- **Share more broadly.** Over-broad sharing rules erode the model you
  spent effort designing.
- **Recompute sharing at runtime.** Operationally painful, brittle.
- **Give the team "View All".** Disproportionate; also undermines audit.

This component offers a different trade-off: a **narrow, audited bypass**.
The user must provide enough qualitative identifiers up front to prove
they are looking at a specific person; the controller queries past
record sharing for just that one lookup; every call is logged; everything
else (field-level security, object access, anti-enumeration) stays fully
enforced.

## What it gives you

- A Lightning Web Component (`qualitySearch`) you can drop onto an App
  Page, Utility Bar, or Home Page.
- An `@AuraEnabled` Apex controller that runs the privileged lookup behind
  a 2-of-3 identifier gate.
- A `Quality_Search_Audit__c` custom object capturing every call, with
  values minimised for GDPR / DSGVO.
- Two Permission Sets: one for users, one for auditors.
- Custom Permission, Custom Labels, Tab, and an App Page FlexiPage so the
  whole thing is usable immediately after deploy.
- An Apex test class with 16 tests at 100% coverage covering the security
  contract end-to-end.

## Use case

> A customer calls the service desk. The agent does not own the record.
> The customer gives the agent their email address and date of birth.
> The agent types both into Quality Search. One match returns; the agent
> sees the verifying details (city, phone, account) on screen, confirms
> the caller is who they say they are, and then opens the record by name
> on the appropriate path.

The agent never had ambient access to that record. The agent does have an
audit row recording that they performed this lookup, with which identifier
types, and which record Id they retrieved.

## Security architecture

### 1. Sharing bypass is isolated

```text
QualitySearchController   ← with sharing
└── PrivilegedFinder      ← private without sharing  (the ONLY bypass)
    └── Database.queryWithBinds(..., AccessLevel.SYSTEM_MODE)
```

Only the two SOQL statements inside `PrivilegedFinder` run without sharing.
Nothing else does. The privileged class is private — it cannot be invoked
from outside the controller.

### 2. FLS is enforced — via `stripInaccessible`, NOT `USER_MODE`

`WITH USER_MODE` would re-impose record sharing, which defeats the entire
point of this component. Instead, the query runs in `SYSTEM_MODE`
(bypassing both sharing and FLS), and then the result is passed through
`Security.stripInaccessible(AccessType.READABLE, rows)`, which nullifies
any field the running user does not have FLS on. `Id` is never stripped,
so the record itself survives the strip even if all visible fields would
have been removed.

### 3. The 2-of-3 gate

The controller refuses to query unless at least **two** of the three
qualitative identifiers are present:

|  Email  |  Phone  |  Birthdate  |
| :-----: | :-----: | :---------: |

These three fields are the gate. Optional filters (Last Name, First Name,
City) **only narrow** an already-authorised search; they never count
toward the 2-of-3 rule.

### 4. Exact match only

No `LIKE`, no wildcards, no case-insensitive fuzzy matching beyond what
SOQL `=` already does for text. A correctly identified customer matches
zero or one records.

### 5. Anti-enumeration refusal

If the gated query somehow matches more than 50 records, the controller
returns `tooManyResults = true` and zero rows. The UI prompts for a
tighter search. The audit still captures the refusal (`searchType =
'None'`, `resultCount = combined hit count`).

### 6. Server-side permission gate

`FeatureManagement.checkPermission('Quality_Search_Access')` is the first
line of `search()`. Hiding the LWC is a UX concession, not a security
control.

### 7. Every call writes an audit row

The audit captures *which* identifier types were used, never the values:

```text
Parameters_Used__c    : "Email+Birthdate"
Filters_Used__c       : "LastName+City"
Result_Count__c       : 1
Matched_Record_Ids__c : "001xx0000000ABC"
Search_Type__c        : "PersonAccount"
CreatedById           : (who searched)
CreatedDate           : (when)
```

The audit object is OWD `Private`; only the `Quality_Search_Auditor`
permission set grants read.

### 8. SOQL injection is impossible

Every WHERE clause is a static fragment. Every user-supplied value is
passed to `Database.queryWithBinds` as a bind parameter. Test
`injectionPayloadProducesNoMatch` proves this.

## What is deployed

```
force-app/main/default/
├── classes/
│   ├── QualitySearchController.cls          ← @AuraEnabled entry + privileged finder
│   ├── QualitySearchAudit.cls               ← audit DML
│   └── QualitySearchControllerTest.cls      ← 16 tests, 100% coverage
├── customPermissions/
│   └── Quality_Search_Access                ← the gate
├── flexipages/
│   └── Quality_Search                       ← App Page hosting the LWC
├── labels/
│   └── CustomLabels                         ← 3 user-facing strings (en_US)
├── lwc/
│   └── qualitySearch/                       ← LWC bundle
├── objects/
│   └── Quality_Search_Audit__c/             ← OWD Private, 5 fields
├── permissionsets/
│   ├── Quality_Search_User                  ← run the search
│   └── Quality_Search_Auditor               ← read the audit trail
└── tabs/
    └── Quality_Search                       ← surfaces the App Page
```

## Installation

### Prerequisites

- Salesforce CLI (`sf`) v2.x
- A target org running API 62.0 or later
- Person Accounts enabled if you want B2C lookup (otherwise the
  Person Account branch returns empty harmlessly)

### Deploy

```bash
git clone https://github.com/rammc/sf-quality-search-lwc.git
cd sf-quality-search-lwc

# Authorize your org once
sf org login web -a my-org

# Deploy the package
sf project deploy start -o my-org

# Run the tests
sf apex run test -o my-org --class-names QualitySearchControllerTest \
  --result-format human --code-coverage --wait 10
```

### Configure

1. **Assign `Quality_Search_User`** to the agents who should be able to
   run the search.

   ```bash
   sf org assign permset -o my-org --name Quality_Search_User
   ```

2. **Assign `Quality_Search_Auditor`** to compliance / security staff who
   need to read the audit trail. The search users do NOT get this.

3. **Surface the component.** The package ships with a Tab + App Page
   named *Quality Search*. Open it via `/lightning/n/Quality_Search` or
   add the Tab to a Lightning App.

4. **(Optional) Define an audit retention job.** See "Operational notes"
   below.

## Usage

1. Open the *Quality Search* tab.
2. Optionally narrow with First Name / Last Name / City.
3. Provide **at least two** of Email / Phone / Birthdate.
4. Click *Search*. A matched customer renders as a detail card, marked
   "Business Contact" or "Person Account".

The Search button is disabled until the 2-of-3 rule is satisfied. The
controller re-validates the same rule server-side — disabling the UI
button is only a UX convenience.

## Known limitations

### Phone normalisation depends on stored format

The controller strips everything except digits and `+` from the user
input and matches that exact string against `MobilePhone`, `Phone`,
`HomePhone`, `OtherPhone`, `AssistantPhone` (and the Person* equivalents).
Exact match against a stored phone is therefore **only reliable when the
stored value is also normalised** — ideally E.164.

If your org stores phones in mixed formats (`+49 30 1234567`,
`030-1234567`, etc.), do one of the following before relying on phone
match:

- Add a formula field that normalises phones on read, and change the
  controller to match against that field.
- Normalise on write via a trigger / Flow.

The component is fully usable on Email + Birthdate without touching
phone normalisation.

### Shield Platform Encryption

If `Email` or `MobilePhone` are encrypted with **probabilistic**
encryption, exact-match SOQL filtering on them is impossible at the
platform level — encrypted or not. Use **deterministic** encryption for
any field you intend to query exactly.

### Person Account RecordType developer name

The test fixture assumes a `PersonAccount` developer-name RecordType.
If your org renames it (some industry templates do), update the lookup
in `QualitySearchControllerTest.setup`.

## Operational notes

### GDPR / DSGVO posture

This component intentionally bypasses sharing to retrieve PII. Before
go-live, document:

- **Lawful basis** (Art. 6 GDPR) and **purpose** for the bypass.
- The **roles** authorised to hold `Quality_Search_User`.
- A **retention period** for `Quality_Search_Audit__c` records and a
  scheduled job that enforces it.
- Whether this component triggers a **Data Protection Impact Assessment**.
  In most organisations it should.

### Anomaly detection

Consider Event Monitoring or Transaction Security to flag unusual search
volume per user. The audit table is the data source; one record per call
makes anomaly queries trivial.

### Monitoring

The audit object's `Search_Type__c = 'None'` value distinguishes
no-result calls from too-broad refusals from successful matches. A
dashboard split by this field tells you whether the component is being
used as designed.

## Architecture diagram

```
┌──────────────────────────────────────────────────────────────────┐
│ LWC  qualitySearch                                               │
│   - 6 inputs (3 qualitative + 3 filters)                         │
│   - Client-side 2-of-3 hint                                      │
│   - Imperative call to QualitySearchController.search            │
└──────────────────────────────────────────────────────────────────┘
                              │  flat String args
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│ Apex  QualitySearchController            (with sharing)          │
│   1. checkPermission('Quality_Search_Access')                    │
│   2. enforce 2-of-3 gate                                         │
│   3. normalise inputs                                            │
│   4. delegate to PrivilegedFinder ────────────┐                  │
│   5. Security.stripInaccessible                ▼                 │
│   6. build DTOs                  ┌────────────────────────────┐  │
│   7. enforce >50 refusal         │ PrivilegedFinder           │  │
│   8. call QualitySearchAudit.log │  (private without sharing) │  │
│   9. return SearchResult         │                            │  │
│                                  │ - Contact query            │  │
│                                  │ - Account (Person) query   │  │
│                                  │ - SYSTEM_MODE              │  │
│                                  │ - queryWithBinds           │  │
│                                  └────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
                              │  audit row (without sharing)
                              ▼
                  Quality_Search_Audit__c  (OWD Private)
```

## Testing

```bash
sf apex run test -o my-org --class-names QualitySearchControllerTest \
  --result-format human --code-coverage --wait 10
```

Expect:

- 16/16 tests pass
- 100% line coverage on `QualitySearchController`
- 100% line coverage on `QualitySearchAudit`

Tests cover: permission gate, 2-of-3 gate, B2B match, Person Account
match, invalid birthdate, SOQL injection literal, audit-row content,
no-result audit, too-broad refusal, phone normalisation, filter
narrowing, filter-alone gate rejection, audit filter capture.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The bar is "does this preserve
the security contract?" — please read that file before opening a PR
that touches the controller.

## License

[MIT](LICENSE). Use it, fork it, ship it.

## Acknowledgements

- Salesforce Lightning Design System (SLDS 2) for the styling hooks.
- The Salesforce Apex documentation for `Security.stripInaccessible` and
  `Database.queryWithBinds`, which together make the security model
  expressible.
