/**
 * Tests for {@link QualitySearchController}. Covers:
 *
 *   - Permission gate: a user without the custom permission is rejected
 *   - 2-of-3 gate: single qualitative identifier rejected, two accepted
 *   - B2B Contact match and B2C Person Account match
 *   - Filter narrowing (LastName / City) without satisfying the gate
 *   - Anti-enumeration: >50 hits returns tooManyResults, audits as None
 *   - Audit minimisation: identifier values never appear in the audit row
 *   - Injection safety: SOQL payload in input is treated as literal
 *   - Phone normalisation
 *
 * ─── Note on MIXED_DML_OPERATION ──────────────────────────────────────────
 *
 *   Apex forbids mixing DML on "setup" objects (User, PermissionSet, ...)
 *   with DML on "non-setup" objects (Account, Contact, ...) in a single
 *   transaction unless the setup-object DML is wrapped in `System.runAs`.
 *   The @testSetup method therefore inserts test data first and then wraps
 *   user creation in `System.runAs(new User(Id = UserInfo.getUserId()))`.
 *
 * ─── Person Account RecordType ────────────────────────────────────────────
 *
 *   The Person Account test record is created by assigning the standard
 *   `PersonAccount` developer-name RecordType. If your org uses a different
 *   developer name (e.g. an industry template), change the lookup below.
 */
@isTest
private class QualitySearchControllerTest {
    private static final String SEARCHER_ALIAS = 'qsSrch';
    private static final String NOPERM_ALIAS = 'qsNoP';

    @testSetup
    static void setup() {
        // Non-setup DML first — see header note on MIXED_DML_OPERATION.
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

    private static QualitySearchController.SearchResult callSearch(String email, String phone, String birthdate) {
        return QualitySearchController.search(email, phone, birthdate, null, null, null);
    }

    private static QualitySearchController.SearchResult callSearch(
        String email,
        String phone,
        String birthdate,
        String lastName,
        String firstName,
        String city
    ) {
        return QualitySearchController.search(email, phone, birthdate, lastName, firstName, city);
    }

    @isTest
    static void permissionGateRejectsUnauthorisedUser() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(noPerm()) {
            try {
                callSearch('alice@example.com', '+491701234567', null);
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'User without permission must be rejected.');
    }

    @isTest
    static void paramCountGateRejectsSingleParam() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(searcher()) {
            try {
                callSearch('alice@example.com', null, null);
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'Single parameter must be rejected.');
    }

    @isTest
    static void paramCountGateAcceptsTwoParams() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = callSearch('alice@example.com', '+491701234567', null);
        }
        Test.stopTest();
        System.assertEquals(false, result.tooManyResults);
        System.assertEquals(1, result.matches.size());
        System.assertEquals('Contact', result.matches[0].recordType);
        System.assertEquals('Alice Anderson', result.matches[0].name);
    }

    @isTest
    static void personAccountMatchReturnsAccount() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = callSearch('carol@example.com', '+491705554444', null);
        }
        Test.stopTest();
        System.assertEquals(1, result.matches.size());
        QualitySearchController.MatchDTO m = result.matches[0];
        System.assertEquals('PersonAccount', m.recordType);
        System.assertEquals('carol@example.com', m.email);
        System.assertEquals(Date.newInstance(1978, 3, 10), m.birthdate);
    }

    @isTest
    static void invalidBirthdateThrows() {
        Boolean thrown = false;
        Test.startTest();
        System.runAs(searcher()) {
            try {
                callSearch('alice@example.com', null, 'not-a-date');
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
            result = callSearch('alice@example.com\' OR Name LIKE \'%', '+491701234567', null);
        }
        Test.stopTest();
        System.assertEquals(false, result.tooManyResults);
        System.assertEquals(
            0,
            result.matches.size(),
            'Injection payload must be treated as literal and return no match.'
        );
    }

    @isTest
    static void auditRecordIsWrittenWithoutRawValues() {
        Test.startTest();
        System.runAs(searcher()) {
            callSearch('alice@example.com', '+491701234567', null);
        }
        Test.stopTest();
        List<Quality_Search_Audit__c> audits = [
            SELECT Parameters_Used__c, Result_Count__c, Matched_Record_Ids__c, Search_Type__c
            FROM Quality_Search_Audit__c
        ];
        System.assertEquals(1, audits.size(), 'Exactly one audit row expected.');
        Quality_Search_Audit__c a = audits[0];
        System.assertEquals('Email+Phone', a.Parameters_Used__c);
        System.assertEquals('Contact', a.Search_Type__c);
        System.assertEquals(1, a.Result_Count__c);
        // Raw identifier values must never appear in the audit
        System.assert(!a.Parameters_Used__c.contains('alice@example.com'));
        System.assert(!a.Parameters_Used__c.contains('+491701234567'));
        System.assert(String.isNotBlank(a.Matched_Record_Ids__c));
    }

    @isTest
    static void noResultsStillWritesAudit() {
        Test.startTest();
        System.runAs(searcher()) {
            callSearch('unknown@example.com', '+490000000000', null);
        }
        Test.stopTest();
        List<Quality_Search_Audit__c> audits = [SELECT Search_Type__c, Result_Count__c FROM Quality_Search_Audit__c];
        System.assertEquals(1, audits.size());
        System.assertEquals('None', audits[0].Search_Type__c);
        System.assertEquals(0, audits[0].Result_Count__c);
    }

    @isTest
    static void phoneNormalisationStripsFormatChars() {
        String normalised = QualitySearchController.normalisePhone('+49 (170) 123-4567');
        System.assertEquals('+491701234567', normalised);
    }

    @isTest
    static void tooManyResultsRefusesAndAuditsNone() {
        // Insert 51 contacts sharing the same birthdate + email pattern
        // To trigger the refusal we need >50 results for a single query.
        List<Contact> extras = new List<Contact>();
        Date dob = Date.newInstance(2000, 1, 1);
        for (Integer i = 0; i < 51; i++) {
            extras.add(new Contact(LastName = 'Bulk' + i, Email = 'bulk@example.com', Birthdate = dob));
        }
        insert extras;

        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = callSearch('bulk@example.com', null, '2000-01-01');
        }
        Test.stopTest();

        System.assertEquals(true, result.tooManyResults);
        System.assertEquals(0, result.matches.size());
        List<Quality_Search_Audit__c> audits = [SELECT Search_Type__c, Result_Count__c FROM Quality_Search_Audit__c];
        System.assertEquals(1, audits.size());
        System.assertEquals('None', audits[0].Search_Type__c);
    }

    @isTest
    static void birthdateAndEmailCombinationMatchesContact() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = callSearch('bob@example.com', null, '1990-08-20');
        }
        Test.stopTest();
        System.assertEquals(1, result.matches.size());
        System.assertEquals('Bob Burns', result.matches[0].name);
    }

    @isTest
    static void filtersAloneDoNotSatisfyGate() {
        // Three optional filters set, zero qualitative identifiers — must be rejected.
        Boolean thrown = false;
        Test.startTest();
        System.runAs(searcher()) {
            try {
                callSearch(null, null, null, 'Anderson', 'Alice', 'Berlin');
            } catch (AuraHandledException e) {
                thrown = true;
            }
        }
        Test.stopTest();
        System.assert(thrown, 'Filters alone must not satisfy the 2-of-3 gate.');
    }

    @isTest
    static void lastNameFilterNarrowsResultToZero() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = callSearch('alice@example.com', '+491701234567', null, 'Mismatched', null, null);
        }
        Test.stopTest();
        System.assertEquals(0, result.matches.size(), 'Non-matching LastName filter must exclude Alice.');
    }

    @isTest
    static void cityFilterKeepsMatchingContact() {
        QualitySearchController.SearchResult result;
        Test.startTest();
        System.runAs(searcher()) {
            result = callSearch('alice@example.com', '+491701234567', null, null, null, 'Berlin');
        }
        Test.stopTest();
        System.assertEquals(1, result.matches.size());
        System.assertEquals('Alice Anderson', result.matches[0].name);
    }

    @isTest
    static void auditCapturesFiltersUsed() {
        Test.startTest();
        System.runAs(searcher()) {
            callSearch('alice@example.com', null, '1985-05-15', 'Anderson', null, 'Berlin');
        }
        Test.stopTest();
        Quality_Search_Audit__c a = [
            SELECT Parameters_Used__c, Filters_Used__c, Search_Type__c
            FROM Quality_Search_Audit__c
            LIMIT 1
        ];
        System.assertEquals('Email+Birthdate', a.Parameters_Used__c);
        System.assertEquals('LastName+City', a.Filters_Used__c);
        System.assertEquals('Contact', a.Search_Type__c);
    }
}
