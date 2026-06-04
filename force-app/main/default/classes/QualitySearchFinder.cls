/**
 * Generic, config-driven privileged query layer for Quality Search.
 *
 * ─── Security boundary ────────────────────────────────────────────────────
 *
 *   This is the ONLY surface in the package that runs `without sharing` and
 *   executes SOQL in `AccessLevel.SYSTEM_MODE`. Both choices are deliberate
 *   and load-bearing:
 *
 *     - `without sharing` lets the search find records the running user
 *       does not own and is not shared.
 *     - `SYSTEM_MODE` bypasses both sharing AND FLS for the query itself;
 *       the controller re-applies FLS via Security.stripInaccessible
 *       BEFORE returning anything to the LWC.
 *
 *   Do NOT change the AccessLevel to `USER_MODE` — that re-imposes record
 *   sharing and defeats the entire purpose of this package.
 *
 * ─── How the SOQL is composed ─────────────────────────────────────────────
 *
 *   - Static WHERE fragments only (column names + bind references).
 *   - Every user-supplied value is passed as a bind via Database.queryWithBinds.
 *   - The variant on each ObjectDef adds at most one static IsPersonAccount
 *     filter. No user input ever influences variant selection.
 *   - Field API names come from QualitySearchConfig, which validates them
 *     against Schema.fields.getMap before this code ever sees them — see
 *     {@link QualitySearchConfigService}.
 *
 *   The class therefore is not vulnerable to SOQL injection even though
 *   the WHERE clause is composed dynamically.
 *
 * ─── Phone-group OR ───────────────────────────────────────────────────────
 *
 *   Fields with the same `phoneGroup` value on the same object are combined
 *   into a single OR-clause with one shared bind value. This implements the
 *   "match the user-typed phone against MobilePhone, Phone, HomePhone, ..."
 *   pattern generically.
 */
public without sharing class QualitySearchFinder {
    /** Result of one object's privileged query. */
    public class ObjectResult {
        public QualitySearchConfig.ObjectDef objectDef;
        public List<SObject> rows;
    }

    /**
     * Run the privileged query for every object in the config that has at
     * least one match value present.
     *
     * @param cfg         validated configuration
     * @param rawValues   raw user input keyed by InputDef.developerName.
     *                    Blank / missing values are skipped per field; the
     *                    per-field Match_Strategy normalises before binding.
     * @return one ObjectResult per object that actually contributed
     *         predicates; an object whose match fields had no values gets
     *         skipped entirely (we don't want a WHERE-less full-table scan).
     */
    public List<ObjectResult> findAll(QualitySearchConfig cfg, Map<String, String> rawValues) {
        List<ObjectResult> results = new List<ObjectResult>();
        for (QualitySearchConfig.ObjectDef obj : cfg.objects) {
            ObjectResult r = findOne(cfg, obj, rawValues);
            if (r != null)
                results.add(r);
        }
        return results;
    }

    private ObjectResult findOne(
        QualitySearchConfig cfg,
        QualitySearchConfig.ObjectDef obj,
        Map<String, String> rawValues
    ) {
        Map<String, Object> binds = new Map<String, Object>();
        List<String> clauses = new List<String>();

        // 1) Variant filter (static, no user input)
        String variantClause = variantClauseFor(obj.variant);
        if (variantClause != null)
            clauses.add(variantClause);

        // 2) Group match fields by phone-group; ungrouped fields produce
        //    one clause each. Normalisation runs per field via the matcher
        //    registry — see QualitySearchMatchers.
        Map<String, List<QualitySearchConfig.FieldDef>> grouped = new Map<String, List<QualitySearchConfig.FieldDef>>();
        Integer bindCounter = 0;
        for (QualitySearchConfig.FieldDef f : obj.matchFields) {
            String raw = rawValues.get(f.matchInputDev);
            if (String.isBlank(raw))
                continue;
            Object value = QualitySearchMatchers.forStrategy(f.matchStrategy).normalise(raw);
            if (value == null)
                continue;

            if (String.isNotBlank(f.phoneGroup)) {
                // Phone-group: defer until all members are seen, then emit one OR.
                List<QualitySearchConfig.FieldDef> bucket = grouped.get(f.phoneGroup);
                if (bucket == null) {
                    bucket = new List<QualitySearchConfig.FieldDef>();
                    grouped.put(f.phoneGroup, bucket);
                }
                bucket.add(f);
            } else {
                String bindKey = 'b' + bindCounter++;
                clauses.add(f.fieldApiName + ' = :' + bindKey);
                binds.put(bindKey, value);
            }
        }
        // 2b) Emit phone-group OR clauses; one shared bind per group.
        //     All members of a group must share the same input AND the same
        //     match strategy, so re-normalising any one of them is safe.
        for (String groupKey : grouped.keySet()) {
            List<QualitySearchConfig.FieldDef> bucket = grouped.get(groupKey);
            QualitySearchConfig.FieldDef firstField = bucket[0];
            Object value = QualitySearchMatchers.forStrategy(firstField.matchStrategy)
                .normalise(rawValues.get(firstField.matchInputDev));
            String bindKey = 'b' + bindCounter++;
            binds.put(bindKey, value);

            List<String> ors = new List<String>();
            for (QualitySearchConfig.FieldDef f : bucket) {
                ors.add(f.fieldApiName + ' = :' + bindKey);
            }
            clauses.add('(' + String.join(ors, ' OR ') + ')');
        }

        // Skip objects with no predicates beyond the variant — a variant-only
        // query would scan the entire object. The 2-of-3 gate at the controller
        // prevents this in normal flow, but a config with all-Filter inputs and
        // zero qualitative match-fields for this object could still produce an
        // empty bind set.
        Integer userClauseCount = clauses.size() - (variantClause == null ? 0 : 1);
        if (userClauseCount == 0)
            return null;

        // 3) SELECT clause: Id + Name + every display field.
        Set<String> selectFields = new Set<String>{ 'Id', 'Name' };
        for (QualitySearchConfig.FieldDef f : obj.displayFields) {
            selectFields.add(f.fieldApiName);
        }

        String soql =
            'SELECT ' +
            String.join(new List<String>(selectFields), ', ') +
            ' FROM ' +
            obj.objectApiName +
            ' WHERE ' +
            String.join(clauses, ' AND ') +
            ' LIMIT ' +
            (cfg.hardResultLimit + 1);

        List<SObject> rows = Database.queryWithBinds(soql, binds, AccessLevel.SYSTEM_MODE);

        ObjectResult r = new ObjectResult();
        r.objectDef = obj;
        r.rows = rows;
        return r;
    }

    private static String variantClauseFor(String variant) {
        if (variant == 'B2B_Contact')
            return 'IsPersonAccount = FALSE';
        if (variant == 'Person_Account')
            return 'IsPersonAccount = TRUE';
        return null; // Standard: no scoping clause
    }
}
