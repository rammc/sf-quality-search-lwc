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
 *   The audit captures WHICH identifier and filter types were used, never
 *   the values themselves. A typical record looks like:
 *
 *     Parameters_Used__c    : "Email+Birthdate"
 *     Filters_Used__c       : "LastName+City"
 *     Result_Count__c       : 1
 *     Matched_Record_Ids__c : "003xx0000000ABC,001xx0000000XYZ"
 *     Search_Type__c        : "Contact" | "PersonAccount" | "Combined" | "None"
 *     CreatedById           : (running user — who did the search)
 *     CreatedDate           : (when)
 *
 *   Storing the actual email / phone / birthdate the user typed would
 *   create a high-risk PII log. The matched Id list is sufficient to
 *   reconstruct what was retrieved — which is the question an auditor or
 *   data protection officer will actually ask.
 *
 *   Retention: schedule a job to delete audit rows after the period
 *   documented in your privacy notice. See README "Operational notes".
 */
public without sharing class QualitySearchAudit {
    public static void log(
        String email,
        String phone,
        Date birthdate,
        String lastName,
        String firstName,
        String city,
        List<Id> matchedIds,
        Integer resultCount,
        String searchType
    ) {
        List<String> identifiers = new List<String>();
        if (email != null)
            identifiers.add('Email');
        if (phone != null)
            identifiers.add('Phone');
        if (birthdate != null)
            identifiers.add('Birthdate');

        List<String> filters = new List<String>();
        if (lastName != null)
            filters.add('LastName');
        if (firstName != null)
            filters.add('FirstName');
        if (city != null)
            filters.add('City');

        List<String> idStrings = new List<String>();
        for (Id i : matchedIds)
            idStrings.add(String.valueOf(i));

        Quality_Search_Audit__c rec = new Quality_Search_Audit__c(
            Parameters_Used__c = String.join(identifiers, '+'),
            Filters_Used__c = String.join(filters, '+'),
            Result_Count__c = resultCount,
            Matched_Record_Ids__c = String.join(idStrings, ','),
            Search_Type__c = searchType
        );
        insert rec;
    }
}
