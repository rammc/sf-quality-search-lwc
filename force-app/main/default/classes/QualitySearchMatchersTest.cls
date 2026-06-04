/**
 * Pure unit tests for the match-strategy registry. No SOQL, no DML —
 * matchers are deliberately side-effect-free.
 */
@isTest
private class QualitySearchMatchersTest {
    @isTest
    static void exactMatcherTrimsAndPassesThrough() {
        QualitySearchMatchers.IFieldMatcher m = QualitySearchMatchers.forStrategy('Exact');
        System.assertEquals('Alice', m.normalise('  Alice  '));
    }

    @isTest
    static void exactMatcherReturnsNullForBlank() {
        QualitySearchMatchers.IFieldMatcher m = QualitySearchMatchers.forStrategy('Exact');
        System.assertEquals(null, m.normalise(''));
        System.assertEquals(null, m.normalise('   '));
        System.assertEquals(null, m.normalise(null));
    }

    @isTest
    static void phoneMatcherStripsFormatChars() {
        QualitySearchMatchers.IFieldMatcher m = QualitySearchMatchers.forStrategy('Phone');
        System.assertEquals('+491701234567', m.normalise('+49 (170) 123-4567'));
        System.assertEquals('030456789', m.normalise('030/456 789'));
        System.assertEquals('+12025551212', m.normalise('+1 (202) 555-1212'));
    }

    @isTest
    static void phoneMatcherReturnsNullForOnlyNoise() {
        QualitySearchMatchers.IFieldMatcher m = QualitySearchMatchers.forStrategy('Phone');
        System.assertEquals(null, m.normalise('---'));
        System.assertEquals(null, m.normalise(''));
    }

    @isTest
    static void dateMatcherParsesIso() {
        QualitySearchMatchers.IFieldMatcher m = QualitySearchMatchers.forStrategy('Date');
        System.assertEquals(Date.newInstance(1985, 5, 15), m.normalise('1985-05-15'));
    }

    @isTest
    static void dateMatcherThrowsOnGarbage() {
        QualitySearchMatchers.IFieldMatcher m = QualitySearchMatchers.forStrategy('Date');
        Boolean thrown = false;
        try {
            m.normalise('15.05.1985');
        } catch (QualitySearchMatchers.InvalidValueException e) {
            thrown = true;
        }
        System.assert(thrown, 'Non-ISO date must throw.');
    }

    @isTest
    static void unknownStrategyThrows() {
        Boolean thrown = false;
        try {
            QualitySearchMatchers.forStrategy('Fuzzy');
        } catch (QualitySearchMatchers.InvalidValueException e) {
            thrown = true;
        }
        System.assert(thrown, 'Unknown strategy must throw.');
    }
}
