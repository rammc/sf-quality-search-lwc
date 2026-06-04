/**
 * End-to-end tests for {@link QualitySearchController} against the deployed
 * "Default" CMDT config.
 *
 * Covers:
 *   - Permission gate (user without custom permission rejected)
 *   - 2-of-N qualitative gate (single input rejected, two accepted)
 *   - Filters alone do NOT satisfy the gate
 *   - B2B Contact match + B2C Person Account match
 *   - Filter narrows the result; mismatched filter excludes
 *   - Phone-group OR across MobilePhone / Phone / HomePhone
 *   - Anti-enumeration refusal (>hardLimit hits)
 *   - Audit row content (config name, parameter types, search type),
 *     and the absence of identifier VALUES in the audit
 *   - Injection safety (SOQL payload in input is treated as literal)
 *   - Invalid date surfaces as the dedicated label
 *   - getFormConfig returns ordered inputs the LWC can render
 *
 * ─── Test setup notes ─────────────────────────────────────────────────────
 *
 *   MIXED_DML_OPERATION: Apex forbids mixing DML on "setup" objects (User,
 *   PermissionSet, ...) with DML on "non-setup" objects in one transaction
 *   unless the setup-object DML is wrapped in `System.runAs`. The setup
 *   inserts test data first and wraps user creation in
 *   `System.runAs(new User(Id = UserInfo.getUserId()))`.
 *
 *   Person Account RecordType: assumes a `PersonAccount` developer-name
 *   RecordType. If your org renames it, change the lookup below.
 */
@isTest
private class QualitySearchControllerTest {
    private static final String SEARCHER_ALIAS = 'qsSrch';
    private static final String NOPERM_ALIAS = 'qsNoP';

    @testSetup
    static void setup() {
        // Non-setup DML first.
        Account biz = new Account(Name = 'BizCorp Industries');
        insert biz;

        List<Contact> contacts = new List<Contact>{
            new Contact(
                FirstName = 'Alice',
                LastName = 'Anderson',
                Email = 'alice@example.com',
                MobilePhone = '+491701234567',
                Birthdate = Date.newInstance(1985, 5, 15),
                AccountId = biz.Id,
                MailingCity = 'Berlin',
                MailingCountry = 'Germany'
            ),
            new Contact(
                FirstName = 'Bob',
                LastName = 'Burns',
                Email = 'bob@example.com',
                MobilePhone = '+491709999999',
                Birthdate = Date.newInstance(1990, 8, 20),
                AccountId = biz.Id
            ),
            // A contact whose number lives in `HomePhone` — used to prove
            // the phone-group OR collapses across all standard phone fields.
            new Contact(
                FirstName = 'Helga',
                LastName = 'Hagen',
                Email = 'helga@example.com',
                HomePhone = '+498912345678',
                Birthdate = Date.newInstance(1972, 11, 3),
                AccountId = biz.Id
            )
        };
        insert contacts;

        Id personAcctRtId = Schema.SObjectType.Account
            .getRecordTypeInfosByDeveloperName()
            .get('PersonAccount')
            .getRecordTypeId();
        Account pa = new Account(
            FirstName = 'Carol',
            LastName = 'Customer',
            RecordTypeId = personAcctRtId,
            PersonEmail = 'carol@example.com',
            PersonMobilePhone = '+491705554444',
            PersonBirthdate = Date.newInstance(1978, 3, 10)
        );
        insert pa;

        // Setup-object DML in runAs to avoid MIXED_DML_OPERATION.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
            User searcher = buildUser(standardProfile.Id, SEARCHER_ALIAS);
            User noPerm = buildUser(standardProfile.Id, NOPERM_ALIAS);
            insert new List<User>{ searcher, noPerm };

            PermissionSet ps = [SELECT Id FROM PermissionSet WHERE Name = 'Quality_Search_User' LIMIT 1];
            insert new PermissionSetAssignment(AssigneeId = searcher.Id, PermissionSetId = ps.Id);
        }
    }

    private static User buildUser(Id profileId, String alias) {
        String uniq = alias + DateTime.now().getTime();
        return new User(
            ProfileId = profileId,
            Alias = alias,
            Username = uniq + '@qs.test.local',
            Email = uniq + '@qs.test.local',
            FirstName = 'QS',
            LastName = alias,
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            TimeZoneSidKey = 'America/Los_Angeles'
        );
    }

    private static User searcher() {
        return [SELECT Id FROM User WHERE Alias = :SEARCHER_ALIAS LIMIT 1];
    }

    private static User noPerm() {
        return [SELECT Id FROM User WHERE Alias = :NOPERM_ALIAS LIMIT 1];
    }

    /** Convenience: build the inputs map with the standard Default keys. */
    private static Map<String, String> inputs(
        String email,
        String phone,
        String birthdate,
        String firstName,
        String lastName,
        String city
    ) {
        return new Map<String, String>{
            'Default_email' => email,
            'Default_phone' => phone,
            'Default_birthdate' => birthdate,
            'Default_firstName' => firstName,
            'Default_lastName' => lastName,
            'Default_city' => city
        };
    }

    private static Map<String, String> inputs(String email, String phone, String birthdate) {
        return inputs(email, phone, birthdate, null, null, null);
    }

    // ─── Permission + parameter gates ─────────────────────────────────────

    @isTest
    static void permissionGateRejectsUnauthorisedUser() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(noPerm()) {
            try {
                QualitySearchController.search('Default', inputs('alice@example.com', '+491701234567', null));
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'User without permission must be rejected.');
    }

    @isTest
    static void singleQualitativeInputIsRejected() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(searcher()) {
            try {
                QualitySearchController.search('Default', inputs('alice@example.com', null, null));
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'Single qualitative input must be rejected.');
    }

    @isTest
    static void filtersAloneDoNotSatisfyGate() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(searcher()) {
            try {
                QualitySearchController.search('Default', inputs(null, null, null, 'Alice', 'Anderson', 'Berlin'));
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'Filters alone must not satisfy the gate.');
    }

    // ─── Match paths ──────────────────────────────────────────────────────

    @isTest
    static void emailAndPhoneMatchB2BContact() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search('Default', inputs('alice@example.com', '+491701234567', null));
        }
        Test.stopTest();
        System.assertEquals(false, result.tooManyResults);
        System.assertEquals(1, result.matches.size());
        QualitySearchController.MatchDTO m = result.matches[0];
        System.assertEquals('Default_Contact_B2B', m.objectDevName);
        System.assertEquals('Business Contact', m.displayType);
        System.assertEquals('Alice Anderson', m.displayName);
    }

    @isTest
    static void emailAndPhoneMatchPersonAccount() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search('Default', inputs('carol@example.com', '+491705554444', null));
        }
        Test.stopTest();
        System.assertEquals(1, result.matches.size());
        QualitySearchController.MatchDTO m = result.matches[0];
        System.assertEquals('Default_Account_Person', m.objectDevName);
        System.assertEquals('Person Account', m.displayType);
    }

    @isTest
    static void emailAndBirthdateMatchContact() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search('Default', inputs('bob@example.com', null, '1990-08-20'));
        }
        Test.stopTest();
        System.assertEquals(1, result.matches.size());
        System.assertEquals('Bob Burns', result.matches[0].displayName);
    }

    @isTest
    static void phoneGroupOrAcrossMobileHomePhone() {
        // Helga's number is on HomePhone, not MobilePhone. The phone-group
        // OR clause must catch it.
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search('Default', inputs('helga@example.com', '+498912345678', null));
        }
        Test.stopTest();
        System.assertEquals(
            1,
            result.matches.size(),
            'Phone-group OR must match against HomePhone, not only MobilePhone.'
        );
        System.assertEquals('Helga Hagen', result.matches[0].displayName);
    }

    // ─── Filter narrowing ─────────────────────────────────────────────────

    @isTest
    static void cityFilterKeepsMatchingContact() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search(
                'Default',
                inputs('alice@example.com', '+491701234567', null, null, null, 'Berlin')
            );
        }
        Test.stopTest();
        System.assertEquals(1, result.matches.size());
    }

    @isTest
    static void lastNameFilterExcludesNonMatch() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search(
                'Default',
                inputs('alice@example.com', '+491701234567', null, null, 'Mismatched', null)
            );
        }
        Test.stopTest();
        System.assertEquals(0, result.matches.size());
    }

    // ─── Negative paths ───────────────────────────────────────────────────

    @isTest
    static void invalidDateSurfacesAsDedicatedLabel() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(searcher()) {
            try {
                QualitySearchController.search('Default', inputs('alice@example.com', null, 'not-a-date'));
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'Invalid birthdate must throw.');
    }

    @isTest
    static void injectionPayloadProducesNoMatch() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search(
                'Default',
                inputs('alice@example.com\' OR Name LIKE \'%', '+491701234567', null)
            );
        }
        Test.stopTest();
        System.assertEquals(false, result.tooManyResults);
        System.assertEquals(
            0,
            result.matches.size(),
            'Injection payload must be treated as literal and return no match.'
        );
    }

    // ─── Audit ────────────────────────────────────────────────────────────

    @isTest
    static void auditCapturesConfigNameAndInputTypes() {
        Test.startTest();
        System.runAs(searcher()) {
            QualitySearchController.search(
                'Default',
                inputs('alice@example.com', '+491701234567', null, null, 'Anderson', null)
            );
        }
        Test.stopTest();

        Quality_Search_Audit__c a = [
            SELECT Config_Name__c, Parameters_Used__c, Filters_Used__c, Result_Count__c, Search_Type__c
            FROM Quality_Search_Audit__c
            LIMIT 1
        ];
        System.assertEquals('Default', a.Config_Name__c);
        // Order of inputs in Parameters_Used__c follows the config sort order:
        // email (10) then phone (20). Birthdate not provided.
        System.assertEquals('Default_email+Default_phone', a.Parameters_Used__c);
        System.assertEquals('Default_lastName', a.Filters_Used__c);
        System.assertEquals('Default_Contact_B2B', a.Search_Type__c);
        System.assertEquals(1, a.Result_Count__c);
        // Raw identifier values must never appear in the audit
        System.assert(!a.Parameters_Used__c.contains('alice@example.com'));
        System.assert(!a.Parameters_Used__c.contains('+491701234567'));
        System.assert(!a.Filters_Used__c.contains('Anderson'));
    }

    @isTest
    static void noResultsStillWritesAudit() {
        Test.startTest();
        System.runAs(searcher()) {
            QualitySearchController.search('Default', inputs('unknown@example.com', '+490000000000', null));
        }
        Test.stopTest();

        List<Quality_Search_Audit__c> audits = [SELECT Search_Type__c, Result_Count__c FROM Quality_Search_Audit__c];
        System.assertEquals(1, audits.size());
        System.assertEquals('None', audits[0].Search_Type__c);
        System.assertEquals(0, audits[0].Result_Count__c);
    }

    @isTest
    static void tooManyResultsRefusesAndAuditsNone() {
        // Insert 51 contacts that share an email + birthdate to blow past
        // the hard limit on a single object.
        List<Contact> extras = new List<Contact>();
        Date dob = Date.newInstance(2000, 1, 1);
        for (Integer i = 0; i < 51; i++) {
            extras.add(new Contact(LastName = 'Bulk' + i, Email = 'bulk@example.com', Birthdate = dob));
        }
        insert extras;

        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = QualitySearchController.search('Default', inputs('bulk@example.com', null, '2000-01-01'));
        }
        Test.stopTest();

        System.assertEquals(true, result.tooManyResults);
        System.assertEquals(0, result.matches.size());
        Quality_Search_Audit__c a = [SELECT Search_Type__c FROM Quality_Search_Audit__c LIMIT 1];
        System.assertEquals('None', a.Search_Type__c);
    }

    // ─── getFormConfig (LWC bridge) ───────────────────────────────────────

    @isTest
    static void getFormConfigReturnsOrderedInputs() {
        QualitySearchController.FormConfigDTO dto;
        Test.startTest();
        dto = QualitySearchController.getFormConfig('Default');
        Test.stopTest();

        System.assertEquals('Default', dto.configName);
        System.assertEquals(2, dto.qualitativeThreshold);
        System.assert(dto.inputs.size() >= 3);
        Integer prevSort = -1;
        for (QualitySearchConfig.InputDef i : dto.inputs) {
            Integer s = (i.sortOrder == null) ? 999999 : i.sortOrder;
            System.assert(s >= prevSort, 'Form inputs must come back sorted.');
            prevSort = s;
        }
    }
}
