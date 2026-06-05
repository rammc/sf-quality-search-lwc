# Quality Search LWC

> Salesforce Lightning Web Component for high-confidence customer lookup
> that deliberately bypasses record-level sharing for authorised users —
> with field-level security, anti-enumeration, and a full audit trail kept
> intact. **Fields, objects, and the form layout are configured via Custom
> Metadata** — no Apex changes needed to support additional objects or
> identifier types.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Salesforce API 62.0+](https://img.shields.io/badge/Salesforce%20API-62.0%2B-blue)
![SLDS 2 hooks](https://img.shields.io/badge/SLDS-2-blueviolet)
![Tests: 29 passing](https://img.shields.io/badge/tests-29%20passing-brightgreen)

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
  Page, Utility Bar, or Home Page. **Form layout is data-driven** — no
  template changes needed to add fields or objects.
- A `@AuraEnabled` Apex controller that runs the privileged lookup behind
  a configurable N-of-M identifier gate.
- **Four Custom Metadata Types** that let admins describe one or more
  named configurations: which objects to search, which fields participate
  in matching vs. display, which match strategies apply, and how phone
  variants are OR-combined.
- A `Quality_Search_Audit__c` custom object capturing every call, with
  values minimised for GDPR / DSGVO.
- Two Permission Sets: one for users, one for auditors.
- A pluggable match-strategy registry (Exact / Phone / Date) that you can
  extend in Apex without touching the finder.
- A pre-seeded "Default" configuration that reproduces a typical
  Email/Phone/Birthdate lookup over Contact (B2B) and Person Account
  (B2C).
- 29 Apex tests, 100% coverage on Audit, 96% on Controller.

## Use case

> A customer calls the service desk. The agent does not own the record.
> The customer gives the agent their email address and date of birth.
> The agent types both into Quality Search. One match returns; the agent
> sees the verifying details (city, phone, account) on screen, confirms
> the caller is who they say they are, and then opens the record by name
> on the appropriate path.

The agent never had ambient access to that record. The agent does have an
audit row recording which configuration was used, which identifier types
were provided, and which record Id was retrieved.

---

## Architecture view

### Runtime flow

```
┌──────────────────────────────────────────────────────────────────────┐
│ Lightning Web Component: qualitySearch                               │
│   - @api configName  (App Builder design attribute, default 'Default')│
│   - @wire(getFormConfig, {configName})                               │
│       → renders inputs dynamically from CMDT                         │
│   - imperative search(configName, inputs)                            │
└──────────────────────────────────────────────────────────────────────┘
                              │  configName, Map<String,String> inputs
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Apex: QualitySearchController          (with sharing)                │
│   1.  FeatureManagement.checkPermission('Quality_Search_Access')     │
│   2.  ConfigService.load(configName) ─────► whitelist-validated cfg  │
│   3.  Enforce qualitativeThreshold from config                       │
│   4.  Delegate to QualitySearchFinder ────┐                          │
│   5.  Security.stripInaccessible (FLS)    │                          │
│   6.  Enforce hardResultLimit refusal     │                          │
│   7.  Build generic MatchDTO with         │                          │
│       displayFields[] from config         ▼                          │
│   8.  QualitySearchAudit.log    ┌────────────────────────────────┐   │
└─────────────────────────────────│ QualitySearchFinder            │   │
                                  │  (private without sharing)     │   │
                                  │                                │   │
                                  │  - the ONLY sharing-bypass     │   │
                                  │  - dynamic SOQL from validated │   │
                                  │    field names + bind vars     │   │
                                  │  - phone-group OR collapse     │   │
                                  │  - Database.queryWithBinds(    │   │
                                  │       soql, binds,             │   │
                                  │       AccessLevel.SYSTEM_MODE) │   │
                                  └────────────┬───────────────────┘   │
                                               │ raw rows               │
                                               ▼                        │
                                  ┌────────────────────────────────┐    │
                                  │ QualitySearchMatchers          │    │
                                  │  IFieldMatcher registry:       │    │
                                  │    - ExactMatcher              │    │
                                  │    - PhoneMatcher              │    │
                                  │    - DateMatcher               │    │
                                  └────────────────────────────────┘    │
                                                                        │
                                  ┌────────────────────────────────┐    │
                                  │ Quality_Search_Audit__c        │◀───┘
                                  │  (OWD Private)                 │
                                  │  Config_Name__c, Parameters,   │
                                  │  Filters, Result_Count,        │
                                  │  Matched_Record_Ids, Type      │
                                  └────────────────────────────────┘
```

### Configuration data model

```
┌─────────────────────────────────────┐
│  Quality_Search_Config__mdt         │   "Default"
│  ─────────────────────────────────  │   Threshold: 2  Limit: 50
│  Qualitative_Threshold__c           │
│  Hard_Result_Limit__c               │
│  Is_Active__c                       │
└──┬──────────────────────────────┬───┘
   │                              │
   │ 1 : N                        │ 1 : N
   ▼                              ▼
┌────────────────────────────┐  ┌─────────────────────────────────────┐
│ Quality_Search_Input__mdt  │  │ Quality_Search_Object__mdt          │
│ ────────────────────────── │  │ ───────────────────────────────────  │
│ UI_Label__c    "Email"     │  │ Object_API_Name__c   "Contact"      │
│ Input_Type__c  email       │  │ Variant__c           B2B_Contact    │
│ Role__c        Qualitative │  │ Display_Type_Label__c "Business..." │
│ Sort_Order__c  10          │  │ Sort_Order__c        10             │
└────────────────────────────┘  └──┬──────────────────────────────────┘
       ▲                           │ 1 : N
       │                           ▼
       │ Match_Input__c   ┌──────────────────────────────────────┐
       └──────────────────│ Quality_Search_Field__mdt            │
                          │ ──────────────────────────────────── │
                          │ Field_API_Name__c     "Email"        │
                          │ Role__c               Both           │
                          │   (Match / Display / Both)           │
                          │ Match_Input__c        → Input ref    │
                          │ Match_Strategy__c     Exact          │
                          │ Phone_Group__c        primary        │
                          │ UI_Label__c           "Email"        │
                          │ Display_Field_Type__c email          │
                          └──────────────────────────────────────┘
```

A single **Input** (e.g. "Email") can be mapped to multiple Fields across
multiple Objects — that is how one form input drives matching on
`Contact.Email`, `Account.PersonEmail`, `Lead.Email`, and so on in
parallel.

---

## Security architecture

### 1. Sharing bypass is isolated

```
QualitySearchController        ← with sharing
└── QualitySearchFinder        ← private without sharing  (the ONLY bypass)
    └── Database.queryWithBinds(..., AccessLevel.SYSTEM_MODE)
```

Only the two SOQL statements inside `QualitySearchFinder` run without
sharing. Nothing else does.

### 2. FLS is enforced — via `stripInaccessible`, NOT `USER_MODE`

`WITH USER_MODE` would re-impose record sharing, which defeats the entire
point of this component. The query runs in `SYSTEM_MODE` (bypassing both
sharing and FLS), and then the result is passed through
`Security.stripInaccessible(AccessType.READABLE, rows)`.

### 3. The N-of-M qualitative gate

The controller refuses to query unless at least the configured number of
qualitative inputs (Email / Phone / Birthdate by default) are filled.
Filter inputs (Last Name / First Name / City by default) **only narrow**
an already-authorised search; they never count toward the gate.

### 4. Exact match only

No `LIKE`, no wildcards, no fuzzy matching beyond what SOQL `=` already
does for text. A correctly identified customer matches zero or one
records.

### 5. Anti-enumeration refusal

If the gated query matches more than the configured hard limit, the
controller returns `tooManyResults = true` and zero rows. The audit
still captures the refusal.

### 6. Server-side permission gate

`FeatureManagement.checkPermission('Quality_Search_Access')` is the first
line of `search()`. Hiding the LWC is a UX concession, not a security
control.

### 7. Every call writes an audit row

The audit captures *which* identifier types were used, never the values:

```text
Config_Name__c        : "Default"
Parameters_Used__c    : "Default_email+Default_birthdate"
Filters_Used__c       : "Default_lastName+Default_city"
Result_Count__c       : 1
Matched_Record_Ids__c : "001xx0000000ABC"
Search_Type__c        : "Default_Account_Person"
CreatedById           : (who searched)
CreatedDate           : (when)
```

### 8. SOQL injection is impossible — even with admin-controlled field names

This is the critical part of the configurable design.

- Every WHERE clause is composed from **static fragments + bind references**.
- Every user-supplied value is passed to `Database.queryWithBinds` as a
  bind parameter.
- Every **admin-supplied** identifier (object API name, field API name)
  is **whitelist-validated** against `Schema.getGlobalDescribe()` /
  `SObjectType.getDescribe().fields` before it ever reaches a SOQL string.
  An admin who types `Email; DROP TABLE` into `Field_API_Name__c` has
  their CMDT row silently dropped from the in-memory config — the string
  is never concatenated into SOQL.

See `QualitySearchConfigService.loadFields` for the validation; see
`QualitySearchControllerTest.injectionPayloadProducesNoMatch` for the
user-input injection test.

---

## What is deployed

```
force-app/main/default/
├── classes/                                  ← 5 production + 3 test
│   ├── QualitySearchController.cls           ← @AuraEnabled entry
│   ├── QualitySearchConfig.cls               ← in-memory config DTO
│   ├── QualitySearchConfigService.cls        ← CMDT loader + whitelist
│   ├── QualitySearchFinder.cls               ← privileged finder
│   ├── QualitySearchMatchers.cls             ← match-strategy registry
│   ├── QualitySearchAudit.cls                ← audit DML
│   └── *Test.cls                             ← 29 tests, 100% / 96% cov
├── customMetadata/                           ← 31 Default-config records
│   ├── Quality_Search_Config.Default.*
│   ├── Quality_Search_Input.Default_*.*      (6 inputs)
│   ├── Quality_Search_Object.Default_*.*     (2 objects)
│   └── Quality_Search_Field.Default_*.*      (22 fields)
├── customPermissions/Quality_Search_Access
├── flexipages/Quality_Search                 ← App Page hosting the LWC
├── labels/CustomLabels                       ← 3 user-facing strings
├── lwc/qualitySearch/                        ← dynamic, config-driven
├── objects/
│   ├── Quality_Search_Audit__c/              ← OWD Private, 6 fields
│   ├── Quality_Search_Config__mdt/           ← CMDT type
│   ├── Quality_Search_Input__mdt/            ← CMDT type
│   ├── Quality_Search_Object__mdt/           ← CMDT type
│   └── Quality_Search_Field__mdt/            ← CMDT type
├── permissionsets/
│   ├── Quality_Search_User                   ← run the search
│   └── Quality_Search_Auditor                ← read the audit trail
└── tabs/Quality_Search
```

---

## Installation

### Prerequisites

- Salesforce CLI (`sf`) v2.x
- A target org running API 62.0 or later
- Person Accounts enabled if you want the seeded B2C lookup (otherwise
  remove the `Default_Account_Person` Object CMDT record or just deploy
  without it — the Person Account branch returns empty harmlessly)

### Deploy

```bash
git clone https://github.com/rammc/sf-quality-search-lwc.git
cd sf-quality-search-lwc
sf org login web -a my-org

# Pass 1 — CMDT type schemas, Apex, LWC, perms, audit object & fields
sf project deploy start -o my-org \
  --source-dir force-app/main/default/objects \
  --source-dir force-app/main/default/classes \
  --source-dir force-app/main/default/lwc \
  --source-dir force-app/main/default/customPermissions \
  --source-dir force-app/main/default/labels \
  --source-dir force-app/main/default/permissionsets \
  --source-dir force-app/main/default/flexipages \
  --source-dir force-app/main/default/tabs

# Pass 2 — seed the Default configuration records (separate pass so the
# CMDT types are fully provisioned before record deploy)
sf project deploy start -o my-org \
  --source-dir force-app/main/default/customMetadata

# Run the tests
sf apex run test -o my-org \
  --tests QualitySearchControllerTest \
  --tests QualitySearchConfigServiceTest \
  --tests QualitySearchMatchersTest \
  --result-format human --code-coverage --wait 10
```

> **Note on CMDT record deploy.** Pass 2 occasionally fails with a
> generic `UNKNOWN_EXCEPTION` on orgs where the just-deployed CMDT type
> hasn't fully propagated. If you hit this, wait 5–15 minutes and retry
> pass 2, **or** insert the records via the Apex Metadata API (see
> `scripts/seed-default-config.apex` for an example, or use any
> `Metadata.Operations.enqueueDeployment` snippet).

### Configure

```bash
sf org assign permset -o my-org --name Quality_Search_User
# Optional — for compliance reviewers
sf org assign permset -o my-org --name Quality_Search_Auditor
```

Surface the component via the *Quality Search* tab (`/lightning/n/Quality_Search`)
or add the LWC to any Lightning App Page or Utility Bar. The LWC has a
`Config Name` design attribute — leave it as `Default` or point at a
different `Quality_Search_Config__mdt` you create.

---

## Configuration: adding a custom object

Suppose you want Quality Search to also look up Leads. No code change is
required — add four CMDT rows:

1. **Quality_Search_Object__mdt** record
   ```
   DeveloperName        Default_Lead
   Config__c            Default
   Object_API_Name__c   Lead
   Variant__c           Standard   (no IsPersonAccount filter)
   Display_Type_Label__c "Lead"
   Sort_Order__c        30
   ```

2. **Quality_Search_Field__mdt** rows wiring each searchable / displayable
   field on Lead. Example (Email match + display):
   ```
   DeveloperName        Default_Lead_Email
   Object_Config__c     Default_Lead
   Field_API_Name__c    Email
   Role__c              Both
   Match_Input__c       Default_email     (re-uses the existing Email input)
   Match_Strategy__c    Exact
   UI_Label__c          "Email"
   Display_Field_Type__c email
   Sort_Order__c        10
   ```

   Repeat for Phone, MobilePhone, FirstName, LastName, Company, etc. —
   whatever the steward should see on a Lead hit.

3. (No Input rows to add — Lead reuses the inputs already declared on
   the Default config.)

That's it. Hard-reload the Lightning page and Leads will be queried in
addition to Contacts and Person Accounts on the next search.

**Whitelist enforcement**: if you type a non-existent field name into
`Field_API_Name__c`, the loader silently drops that row and logs a
warning at `LoggingLevel.WARN`. The search still works on the remaining
valid fields. No SOQL fragment composed from an admin-supplied name ever
runs without first being matched against `Schema.fields.getMap()`.

---

## Multi-config setups

Each LWC placement can render a different configuration via the
`Config Name` App Builder property. Typical pattern:

- `Default` — service agent everyday lookup
- `Fraud` — fraud reviewer with stricter threshold (e.g. 3-of-4) and a
  different display set
- `Onboarding` — limited to Lead only

Create one `Quality_Search_Config__mdt` per scenario, point separate
LWC instances at them, and gate each placement with its own Permission
Set if needed.

---

## Match strategies

| Strategy | Normalisation                                                      | Use for                          |
|----------|--------------------------------------------------------------------|----------------------------------|
| `Exact`  | Trim whitespace; SOQL `=` is already case-insensitive for text     | Email, names, IDs, addresses     |
| `Phone`  | Strip everything except digits and leading `+`                     | All phone variants               |
| `Date`   | Parse ISO `yyyy-MM-dd`; throw on malformed input                   | Birthdate, dates                 |

Add a new strategy by implementing `QualitySearchMatchers.IFieldMatcher`,
registering it in the `REGISTRY` map, and adding the picklist value to
`Quality_Search_Field__mdt.Match_Strategy__c`.

---

## Known limitations

### Phone normalisation depends on stored format

The `Phone` matcher strips everything except digits and `+` from the
user input. Exact match against a stored phone is therefore only
reliable when the stored value is also normalised (ideally E.164).
If your data is stored in mixed formats, either:

- Add a formula field that normalises on read and point the
  `Field_API_Name__c` at the formula instead of the raw phone field.
- Normalise on write via a trigger or Flow.

### CMDT records may need a second deploy pass

As noted in *Installation*, the standard `sf project deploy start` for
`customMetadata` records can fail with `UNKNOWN_EXCEPTION` immediately
after a fresh CMDT type deployment. Workaround: deploy in two passes
with a short wait between, or use the Apex Metadata API.

### CMDT DeveloperName 40-char limit

Salesforce enforces a 40-character maximum on `CustomMetadata.fullName`
(everything after the `.`). The seeded fields use the `Default_B2B_*`
and `Default_PA_*` prefixes to stay safely under that limit. Pick
similarly short prefixes for your own configurations.

### Shield Platform Encryption

If `Email` or `MobilePhone` are encrypted with **probabilistic**
encryption, exact-match SOQL filtering on them is impossible at the
platform level. Use **deterministic** encryption for any field you
intend to query exactly.

### Person Account RecordType developer name

The test fixture assumes a `PersonAccount` developer-name RecordType.
If your org renames it (some industry templates do), update the lookup
in `QualitySearchControllerTest.setup`.

### Relationship fields are not supported in V1

`Field_API_Name__c` currently accepts only direct fields on the queried
object. Dotted paths like `Account.Name` would require parsing,
relationship-aware describe validation, and SELECT-side handling. Open
issue if you need this.

---

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
makes anomaly queries trivial. `Config_Name__c` lets you split anomaly
thresholds per scenario.

### Monitoring

The audit object's `Search_Type__c = 'None'` value distinguishes
no-result calls from too-broad refusals from successful matches. A
dashboard split by `Config_Name__c` + `Search_Type__c` tells you whether
each configuration is being used as designed.

---

## Testing

```bash
sf apex run test -o my-org \
  --tests QualitySearchControllerTest \
  --tests QualitySearchConfigServiceTest \
  --tests QualitySearchMatchersTest \
  --result-format human --code-coverage --wait 10
```

Expect:

- 29/29 tests pass
- 100% line coverage on `QualitySearchAudit`
- 96% line coverage on `QualitySearchController`

Tests cover: permission gate, qualitative gate, B2B match, Person Account
match, invalid birthdate, SOQL injection literal, audit row content (incl.
new `Config_Name__c`), no-result audit, too-broad refusal, phone
normalisation, phone-group OR across MobilePhone/Phone/HomePhone, filter
narrowing, filter-alone gate rejection, config loading + whitelist,
ordered inputs for the LWC bridge, every match strategy.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). The bar is "does this preserve
the security contract?" — please read that file before opening a PR
that touches the controller, finder, or config service.

## License

[MIT](LICENSE). Use it, fork it, ship it.

## Acknowledgements

- Salesforce Lightning Design System (SLDS 2) for the styling hooks.
- The Salesforce Apex documentation for `Security.stripInaccessible`,
  `Database.queryWithBinds`, and the `Metadata.Operations` deployment
  API — together they make the security model expressible.
