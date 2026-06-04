/**
 * Quality Search — config-driven, high-confidence customer lookup.
 *
 * ─── Architecture overview ────────────────────────────────────────────────
 *
 *   Search behaviour (which objects to query, which fields to match, which
 *   fields to display, the gate threshold, the result limit) is described
 *   by a {@link QualitySearchConfig} loaded from custom metadata. The
 *   controller does not hardcode any field name.
 *
 *      LWC
 *       │
 *       │  (1) getFormConfig(configName)        → render dynamic form
 *       │  (2) search(configName, inputs)       → run privileged lookup
 *       ▼
 *      QualitySearchController     (with sharing)
 *       │     - permission gate
 *       │     - load + validate config
 *       │     - enforce qualitative gate (N of M qualitative inputs)
 *       │     - delegate to finder
 *       │     - Security.stripInaccessible on every returned row
 *       │     - too-many-results refusal
 *       │     - audit
 *       ▼
 *      QualitySearchConfigService  (with sharing)
 *       │     - read CMDT
 *       │     - whitelist-validate every Object & Field name against
 *       │       Schema describe (the SOQL-injection defence for
 *       │       admin-supplied identifiers)
 *       ▼
 *      QualitySearchFinder         (without sharing)
 *       │     - the ONLY sharing-bypass surface
 *       │     - composes dynamic SOQL from validated names + binds only
 *       │     - runs Database.queryWithBinds in SYSTEM_MODE
 *       │     - phone-group OR collapse
 *
 * ─── LWC integration ──────────────────────────────────────────────────────
 *
 *   Both @AuraEnabled methods take flat parameter types. We do NOT use
 *   Apex inner classes as parameters — the LWC → Aura → Apex boundary
 *   deserialises strongly-typed inner classes unreliably (fields silently
 *   arrive as null). Generic Map<String, String> works.
 */
public with sharing class QualitySearchController {
    // ─── DTOs returned to the LWC ─────────────────────────────────────────

    public class SearchResult {
        /** True when the combined query matched more than the config's
         *  hard result limit. `matches` is empty in that case. */
        @AuraEnabled
        public Boolean tooManyResults = false;
        @AuraEnabled
        public List<MatchDTO> matches = new List<MatchDTO>();
    }

    public class MatchDTO {
        @AuraEnabled
        public Id recordId;
        @AuraEnabled
        public String objectDevName;
        @AuraEnabled
        public String displayType;
        @AuraEnabled
        public String displayName;
        @AuraEnabled
        public List<DisplayField> fields = new List<DisplayField>();
    }

    public class DisplayField {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String fieldType; // text | email | phone | date
        @AuraEnabled
        public Object value;
    }

    public class FormConfigDTO {
        @AuraEnabled
        public String configName;
        @AuraEnabled
        public Integer qualitativeThreshold;
        @AuraEnabled
        public List<QualitySearchConfig.InputDef> inputs;
    }

    // ─── Entry points ─────────────────────────────────────────────────────

    /** Cacheable: pure read from CMDT, no side effects. The LWC uses this
     *  to render the input form. */
    @AuraEnabled(cacheable=true)
    public static FormConfigDTO getFormConfig(String configName) {
        QualitySearchConfig cfg = QualitySearchConfigService.load(configName);
        FormConfigDTO out = new FormConfigDTO();
        out.configName = cfg.developerName;
        out.qualitativeThreshold = cfg.qualitativeThreshold;
        out.inputs = cfg.orderedInputs();
        return out;
    }

    /** Not cacheable: writes an audit record (DML). Call imperatively from
     *  the LWC.
     *
     *  @param configName  name of a Quality_Search_Config__mdt
     *  @param inputs      raw user values keyed by InputDef.developerName.
     *                     Map<String,String> deserialises cleanly from the
     *                     LWC unlike strongly-typed Apex inner classes.
     */
    @AuraEnabled
    public static SearchResult search(String configName, Map<String, String> inputs) {
        if (!FeatureManagement.checkPermission('Quality_Search_Access')) {
            throw new AuraHandledException(System.Label.QualitySearch_AccessDenied);
        }
        if (inputs == null)
            inputs = new Map<String, String>();

        QualitySearchConfig cfg;
        try {
            cfg = QualitySearchConfigService.load(configName);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'QualitySearch config load failed: ' + e.getMessage());
            throw new AuraHandledException(System.Label.QualitySearch_AccessDenied);
        }

        // ── Gate: at least N qualitative inputs filled ────────────────────
        List<String> qualitativeFilled = new List<String>();
        List<String> filterFilled = new List<String>();
        for (QualitySearchConfig.InputDef i : cfg.inputs) {
            String v = inputs.get(i.developerName);
            if (String.isBlank(v))
                continue;
            if (i.role == 'Qualitative')
                qualitativeFilled.add(i.developerName);
            else if (i.role == 'Filter')
                filterFilled.add(i.developerName);
        }
        if (qualitativeFilled.size() < cfg.qualitativeThreshold) {
            throw new AuraHandledException(System.Label.QualitySearch_MinParams);
        }

        // ── Privileged query (matchers run per-field inside the finder) ──
        QualitySearchFinder finder = new QualitySearchFinder();
        List<QualitySearchFinder.ObjectResult> objectResults;
        try {
            objectResults = finder.findAll(cfg, inputs);
        } catch (QualitySearchMatchers.InvalidValueException e) {
            // Most common cause is a malformed date — translate to the
            // dedicated label so the LWC can show a clear message.
            throw new AuraHandledException(System.Label.QualitySearch_InvalidDate);
        }

        // ── Anti-enumeration refusal ─────────────────────────────────────
        Integer combinedSize = 0;
        for (QualitySearchFinder.ObjectResult r : objectResults) {
            combinedSize += r.rows.size();
        }

        SearchResult result = new SearchResult();
        if (combinedSize > cfg.hardResultLimit) {
            result.tooManyResults = true;
            QualitySearchAudit.log(
                cfg.developerName,
                qualitativeFilled,
                filterFilled,
                new List<Id>(),
                combinedSize,
                new List<String>()
            );
            return result;
        }

        // ── FLS strip + DTO build ────────────────────────────────────────
        List<Id> matchedIds = new List<Id>();
        List<String> hittingObjectDevs = new List<String>();
        for (QualitySearchFinder.ObjectResult r : objectResults) {
            if (r.rows.isEmpty())
                continue;
            SObjectAccessDecision decision = Security.stripInaccessible(AccessType.READABLE, r.rows);
            List<SObject> safeRows = decision.getRecords();
            if (safeRows.isEmpty())
                continue;
            hittingObjectDevs.add(r.objectDef.developerName);
            for (SObject row : safeRows) {
                result.matches.add(toDTO(row, r.objectDef));
                matchedIds.add(row.Id);
            }
        }

        QualitySearchAudit.log(
            cfg.developerName,
            qualitativeFilled,
            filterFilled,
            matchedIds,
            combinedSize,
            hittingObjectDevs
        );
        return result;
    }

    // ─── DTO building ─────────────────────────────────────────────────────

    private static MatchDTO toDTO(SObject row, QualitySearchConfig.ObjectDef obj) {
        MatchDTO d = new MatchDTO();
        d.recordId = (Id) row.get('Id');
        d.objectDevName = obj.developerName;
        d.displayType = obj.displayTypeLabel;
        Object nameValue = readSafe(row, 'Name');
        d.displayName = (nameValue == null) ? null : String.valueOf(nameValue);
        for (QualitySearchConfig.FieldDef f : obj.displayFields) {
            DisplayField df = new DisplayField();
            df.label = f.uiLabel;
            df.fieldType = String.isBlank(f.displayFieldType) ? 'text' : f.displayFieldType;
            df.value = readSafe(row, f.fieldApiName);
            d.fields.add(df);
        }
        return d;
    }

    /** Reading a field that stripInaccessible removed would throw
     *  SObjectException. Guard with isSet first. */
    private static Object readSafe(SObject row, String field) {
        return row.isSet(field) ? row.get(field) : null;
    }
}
