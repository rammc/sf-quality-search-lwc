/**
 * Loads named Quality Search configurations from the Quality_Search_*__mdt
 * CMDTs and validates them against the live Schema before returning.
 *
 * ─── Why this class exists ────────────────────────────────────────────────
 *
 *   Admins configure the search via CMDT records. Those records contain
 *   plain-text Object and Field API names that ultimately become part of
 *   dynamic SOQL. Without validation, an admin (accidentally or maliciously)
 *   could put `Contact WHERE Id IN (SELECT Id FROM Contact) OR 1=1` style
 *   garbage into a name field and break the SOQL or, worse, alter its
 *   semantics.
 *
 *   This service walks every configured object + field and verifies, via
 *   `Schema.getGlobalDescribe` / `SObjectType.getDescribe().fields`, that
 *   the names refer to real, accessible artefacts. Anything that fails the
 *   whitelist check is dropped from the in-memory config with an Apex log.
 *
 *   The resulting `QualitySearchConfig` is therefore safe to feed directly
 *   into dynamic SOQL builders without re-validating each name later.
 *
 * ─── Caching ──────────────────────────────────────────────────────────────
 *
 *   Configs are cached per-transaction (static Map). They do not cross
 *   transaction boundaries; CMDT lookups are cheap and the absolute
 *   correctness of "we always see the latest deployed config" beats a few
 *   microseconds saved by a longer-lived cache.
 */
public with sharing class QualitySearchConfigService {
    /** Transaction-local cache, keyed by config developer name. */
    private static Map<String, QualitySearchConfig> CACHE = new Map<String, QualitySearchConfig>();

    /** Load and validate a named config. Throws if not found, inactive, or
     *  if validation cannot produce at least one queryable object with at
     *  least one match field. */
    public static QualitySearchConfig load(String configName) {
        if (String.isBlank(configName)) {
            configName = 'Default';
        }
        if (CACHE.containsKey(configName)) {
            return CACHE.get(configName);
        }

        Quality_Search_Config__mdt mdt = readConfigMdt(configName);
        if (mdt == null) {
            throw new ConfigException('No Quality_Search_Config__mdt named ' + configName);
        }
        if (mdt.Is_Active__c != true) {
            throw new ConfigException('Quality Search config ' + configName + ' is not active.');
        }

        QualitySearchConfig cfg = new QualitySearchConfig();
        cfg.developerName = mdt.DeveloperName;
        cfg.description = mdt.Description__c;
        cfg.qualitativeThreshold = (Integer) mdt.Qualitative_Threshold__c;
        cfg.hardResultLimit = (Integer) mdt.Hard_Result_Limit__c;

        cfg.inputs = loadInputs(mdt.Id);
        cfg.objects = loadObjects(mdt.Id, cfg.inputs);

        if (cfg.objects.isEmpty()) {
            throw new ConfigException('Config ' + configName + ' has no queryable objects after validation.');
        }

        CACHE.put(configName, cfg);
        return cfg;
    }

    // ─── CMDT reads ───────────────────────────────────────────────────────

    private static Quality_Search_Config__mdt readConfigMdt(String devName) {
        List<Quality_Search_Config__mdt> rows = [
            SELECT Id, DeveloperName, Description__c, Qualitative_Threshold__c, Hard_Result_Limit__c, Is_Active__c
            FROM Quality_Search_Config__mdt
            WHERE DeveloperName = :devName
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static List<QualitySearchConfig.InputDef> loadInputs(Id configId) {
        List<QualitySearchConfig.InputDef> result = new List<QualitySearchConfig.InputDef>();
        for (Quality_Search_Input__mdt row : [
            SELECT DeveloperName, UI_Label__c, Input_Type__c, Role__c, Sort_Order__c
            FROM Quality_Search_Input__mdt
            WHERE Config__c = :configId
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            QualitySearchConfig.InputDef d = new QualitySearchConfig.InputDef();
            d.developerName = row.DeveloperName;
            d.label = row.UI_Label__c;
            d.inputType = row.Input_Type__c;
            d.role = row.Role__c;
            d.sortOrder = (row.Sort_Order__c == null) ? null : Integer.valueOf(row.Sort_Order__c);
            result.add(d);
        }
        return result;
    }

    private static List<QualitySearchConfig.ObjectDef> loadObjects(
        Id configId,
        List<QualitySearchConfig.InputDef> inputs
    ) {
        Set<String> knownInputDevs = new Set<String>();
        for (QualitySearchConfig.InputDef i : inputs)
            knownInputDevs.add(i.developerName);

        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        List<QualitySearchConfig.ObjectDef> result = new List<QualitySearchConfig.ObjectDef>();

        for (Quality_Search_Object__mdt row : [
            SELECT Id, DeveloperName, Object_API_Name__c, Variant__c, Display_Type_Label__c, Sort_Order__c
            FROM Quality_Search_Object__mdt
            WHERE Config__c = :configId
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            // Whitelist: object must actually exist in the org.
            Schema.SObjectType sot = globalDescribe.get(row.Object_API_Name__c);
            if (sot == null) {
                System.debug(
                    LoggingLevel.WARN,
                    'QualitySearchConfigService: dropping unknown object ' + row.Object_API_Name__c
                );
                continue;
            }

            QualitySearchConfig.ObjectDef o = new QualitySearchConfig.ObjectDef();
            o.developerName = row.DeveloperName;
            o.objectApiName = row.Object_API_Name__c;
            o.variant = row.Variant__c;
            o.displayTypeLabel = row.Display_Type_Label__c;
            o.sortOrder = (row.Sort_Order__c == null) ? null : Integer.valueOf(row.Sort_Order__c);

            Map<String, Schema.SObjectField> fieldMap = sot.getDescribe().fields.getMap();
            loadFields(row.Id, knownInputDevs, fieldMap, o);

            // Drop objects with no usable match fields — they could only ever
            // contribute empty result sets.
            if (!o.matchFields.isEmpty()) {
                result.add(o);
            } else {
                System.debug(
                    LoggingLevel.WARN,
                    'QualitySearchConfigService: dropping object ' + o.objectApiName + ' (no validated match fields).'
                );
            }
        }
        return result;
    }

    private static void loadFields(
        Id objectConfigId,
        Set<String> knownInputDevs,
        Map<String, Schema.SObjectField> fieldMap,
        QualitySearchConfig.ObjectDef o
    ) {
        for (Quality_Search_Field__mdt row : [
            SELECT
                DeveloperName,
                Field_API_Name__c,
                Role__c,
                Match_Strategy__c,
                Phone_Group__c,
                UI_Label__c,
                Display_Field_Type__c,
                Sort_Order__c,
                Match_Input__r.DeveloperName
            FROM Quality_Search_Field__mdt
            WHERE Object_Config__c = :objectConfigId
            ORDER BY Sort_Order__c ASC NULLS LAST
        ]) {
            // Whitelist 1: field must exist on the object.
            if (!fieldMap.containsKey(row.Field_API_Name__c.toLowerCase())) {
                System.debug(
                    LoggingLevel.WARN,
                    'QualitySearchConfigService: dropping unknown field ' +
                        o.objectApiName +
                        '.' +
                        row.Field_API_Name__c
                );
                continue;
            }

            String matchInput = (row.Match_Input__r == null) ? null : row.Match_Input__r.DeveloperName;

            // Whitelist 2: Match/Both rows must reference a known Input.
            if (row.Role__c != 'Display') {
                if (matchInput == null || !knownInputDevs.contains(matchInput)) {
                    System.debug(
                        LoggingLevel.WARN,
                        'QualitySearchConfigService: dropping field ' +
                            o.objectApiName +
                            '.' +
                            row.Field_API_Name__c +
                            ' — Match/Both requires a valid Match_Input.'
                    );
                    continue;
                }
                if (String.isBlank(row.Match_Strategy__c)) {
                    System.debug(
                        LoggingLevel.WARN,
                        'QualitySearchConfigService: dropping field ' +
                            o.objectApiName +
                            '.' +
                            row.Field_API_Name__c +
                            ' — Match/Both requires Match_Strategy.'
                    );
                    continue;
                }
            }

            QualitySearchConfig.FieldDef f = new QualitySearchConfig.FieldDef();
            f.fieldApiName = row.Field_API_Name__c;
            f.matchInputDev = matchInput;
            f.matchStrategy = row.Match_Strategy__c;
            f.phoneGroup = row.Phone_Group__c;
            f.uiLabel = row.UI_Label__c;
            f.displayFieldType = row.Display_Field_Type__c;
            f.sortOrder = (row.Sort_Order__c == null) ? null : Integer.valueOf(row.Sort_Order__c);

            if (row.Role__c == 'Match' || row.Role__c == 'Both') {
                o.matchFields.add(f);
            }
            if (row.Role__c == 'Display' || row.Role__c == 'Both') {
                o.displayFields.add(f);
            }
        }
    }

    /** Allow tests to start from a clean cache between scenarios. */
    @TestVisible
    private static void clearCache() {
        CACHE.clear();
    }

    public class ConfigException extends Exception {
    }
}
