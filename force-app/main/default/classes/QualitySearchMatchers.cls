/**
 * Pluggable normalisers for Quality Search match values.
 *
 * Each strategy takes the raw user-supplied String and returns either a
 * bind-ready value (String or Date) or `null` to indicate "skip this
 * match" — for example when an empty Date string is submitted.
 *
 * Add a new strategy by:
 *   1. Implementing {@link IFieldMatcher}
 *   2. Registering it in {@link #REGISTRY}
 *   3. Adding the new picklist value to Quality_Search_Field__mdt.Match_Strategy__c
 *
 * Matchers are pure (no DML, no SOQL) — composition with the privileged
 * finder is therefore trivial.
 */
public class QualitySearchMatchers {
    public interface IFieldMatcher {
        /** Returns null when the value should be ignored (blank / unparseable
         *  optional input). Throws InvalidValueException when the value is
         *  present but malformed and the caller should surface that as an
         *  end-user error. */
        Object normalise(String raw);
    }

    public class InvalidValueException extends Exception {
    }

    /** SOQL `=` on text fields is already case-insensitive, so Exact just
     *  trims whitespace. */
    public class ExactMatcher implements IFieldMatcher {
        public Object normalise(String raw) {
            if (String.isBlank(raw))
                return null;
            return raw.trim();
        }
    }

    /** Strips everything that isn't a digit or a leading `+`. Exact match
     *  against a stored phone is therefore only reliable when the stored
     *  value is also normalised. See README "Known limitations". */
    public class PhoneMatcher implements IFieldMatcher {
        public Object normalise(String raw) {
            if (String.isBlank(raw))
                return null;
            String stripped = raw.replaceAll('[^0-9+]', '');
            return String.isBlank(stripped) ? null : stripped;
        }
    }

    /** Parses ISO yyyy-MM-dd from the date input. Anything else throws so
     *  the caller can surface the user-facing label. */
    public class DateMatcher implements IFieldMatcher {
        public Object normalise(String raw) {
            if (String.isBlank(raw))
                return null;
            try {
                return Date.valueOf(raw);
            } catch (Exception e) {
                throw new InvalidValueException('Not a valid date: ' + raw);
            }
        }
    }

    private static final Map<String, IFieldMatcher> REGISTRY = new Map<String, IFieldMatcher>{
        'Exact' => new ExactMatcher(),
        'Phone' => new PhoneMatcher(),
        'Date' => new DateMatcher()
    };

    public static IFieldMatcher forStrategy(String strategy) {
        IFieldMatcher m = REGISTRY.get(strategy);
        if (m == null) {
            throw new InvalidValueException('Unknown match strategy: ' + strategy);
        }
        return m;
    }
}
