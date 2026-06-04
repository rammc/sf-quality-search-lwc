/**
 * Integration tests against the deployed Default CMDT config.
 *
 * The OSS package ships with a Default config that mirrors the original
 * hardcoded behaviour: Contact (B2B) + Account (Person) with email / phone
 * / birthdate as qualitative inputs and first / last name / city as
 * filters. These tests verify that the service loads + validates that
 * config end-to-end.
 *
 * Whitelist failure paths (admin types a non-existent field name into a
 * CMDT record) are exercised indirectly: the service silently drops bad
 * rows from the in-memory config. Direct negative tests would require
 * Apex stub-based CMDT mocking which is intentionally out of scope for V1.
 */
@isTest
private class QualitySearchConfigServiceTest {
    @isTest
    static void loadsDefaultConfig() {
        Test.startTest();
        QualitySearchConfig cfg = QualitySearchConfigService.load('Default');
        Test.stopTest();

        System.assertEquals('Default', cfg.developerName);
        System.assertEquals(2, cfg.qualitativeThreshold);
        System.assertEquals(50, cfg.hardResultLimit);
        System.assert(cfg.inputs.size() >= 3, 'Default must expose at least 3 inputs.');
        System.assert(cfg.objects.size() >= 1, 'Default must validate at least one object.');
    }

    @isTest
    static void exposesQualitativeAndFilterInputs() {
        QualitySearchConfig cfg = QualitySearchConfigService.load('Default');
        Set<String> roles = new Set<String>();
        for (QualitySearchConfig.InputDef i : cfg.inputs)
            roles.add(i.role);
        System.assert(roles.contains('Qualitative'), 'Default should expose Qualitative inputs.');
        System.assert(roles.contains('Filter'), 'Default should expose Filter inputs.');
    }

    @isTest
    static void blankNameDefaultsToDefault() {
        QualitySearchConfig cfg = QualitySearchConfigService.load('');
        System.assertEquals('Default', cfg.developerName);
    }

    @isTest
    static void unknownConfigThrows() {
        Boolean thrown = false;
        try {
            QualitySearchConfigService.load('Does_Not_Exist');
        } catch (QualitySearchConfigService.ConfigException e) {
            thrown = true;
        }
        System.assert(thrown, 'Unknown config name must throw.');
    }

    @isTest
    static void orderedInputsSortsBySortOrder() {
        QualitySearchConfig cfg = QualitySearchConfigService.load('Default');
        List<QualitySearchConfig.InputDef> ordered = cfg.getOrderedInputs();
        Integer prev = -1;
        for (QualitySearchConfig.InputDef i : ordered) {
            Integer s = (i.sortOrder == null) ? 999999 : i.sortOrder;
            System.assert(s >= prev, 'Inputs must come back in ascending sortOrder.');
            prev = s;
        }
    }

    @isTest
    static void contactObjectIsB2BVariantAndHasMatchFields() {
        QualitySearchConfig cfg = QualitySearchConfigService.load('Default');
        Boolean foundContactB2B = false;
        for (QualitySearchConfig.ObjectDef o : cfg.objects) {
            if (o.objectApiName == 'Contact' && o.variant == 'B2B_Contact') {
                foundContactB2B = true;
                System.assert(!o.matchFields.isEmpty(), 'Contact B2B must have match fields after validation.');
                System.assert(!o.displayFields.isEmpty(), 'Contact B2B must have display fields after validation.');
            }
        }
        System.assert(foundContactB2B, 'Default config must include a B2B Contact object.');
    }
}
