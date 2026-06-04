/**
 * Writes the Quality Search audit trail.
 *
 * Runs `without sharing` so search users — who do NOT need read access to
 * `Quality_Search_Audit__c` — can still create the audit row. Standard Apex
 * DML executes in system mode by default (CRUD/FLS are not auto-enforced),
 * so the insert succeeds regardless of whether the caller has Create
 * permission on the audit object.
 *
 * ─── Data minimisation (GDPR / DSGVO) ─────────────────────────────────────
 *
 *   The audit captures WHICH input types were used, never the values.
 *   A typical record looks like:
 *
 *     Config_Name__c        : "Default"
 *     Parameters_Used__c    : "email+birthdate"
 *     Filters_Used__c       : "lastName+city"
 *     Result_Count__c       : 1
 *     Matched_Record_Ids__c : "003xx0000000ABC,001xx0000000XYZ"
 *     Search_Type__c        : "Default_Account_Person"
 *     CreatedById           : (running user — who did the search)
 *     CreatedDate           : (when)
 *
 *   Search_Type__c contains the comma-separated DeveloperNames of the
 *   Quality_Search_Object__mdt rows that returned at least one match,
 *   or "None" when the result set was empty or refused.
 */
public without sharing class QualitySearchAudit {
    public static void log(
        String configName,
        List<String> qualitativeInputsProvided,
        List<String> filterInputsProvided,
        List<Id> matchedIds,
        Integer resultCount,
        List<String> hittingObjectDevNames
    ) {
        List<String> idStrings = new List<String>();
        for (Id i : matchedIds)
            idStrings.add(String.valueOf(i));

        String searchType = (hittingObjectDevNames == null || hittingObjectDevNames.isEmpty())
            ? 'None'
            : String.join(hittingObjectDevNames, ',');

        Quality_Search_Audit__c rec = new Quality_Search_Audit__c(
            Config_Name__c = configName,
            Parameters_Used__c = String.join(safe(qualitativeInputsProvided), '+'),
            Filters_Used__c = String.join(safe(filterInputsProvided), '+'),
            Result_Count__c = resultCount,
            Matched_Record_Ids__c = String.join(idStrings, ','),
            Search_Type__c = searchType
        );
        insert rec;
    }

    private static List<String> safe(List<String> in_) {
        return in_ == null ? new List<String>() : in_;
    }
}
