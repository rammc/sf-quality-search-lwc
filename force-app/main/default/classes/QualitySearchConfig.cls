/**
 * In-memory representation of a Quality Search configuration loaded from the
 * Quality_Search_*__mdt CMDTs. Used by the controller, finder and LWC bridge.
 *
 * Constructed exclusively by {@link QualitySearchConfigService}; do not
 * instantiate from outside. The service applies whitelist validation against
 * Schema describe before populating any of these structures, so by the time
 * a `QualitySearchConfig` instance exists, every Object_API_Name__c and
 * Field_API_Name__c it references is guaranteed to exist on the live schema.
 */
public class QualitySearchConfig {

    public String  developerName;
    public String  description;
    public Integer qualitativeThreshold;
    public Integer hardResultLimit;
    public List<InputDef>  inputs  = new List<InputDef>();
    public List<ObjectDef> objects = new List<ObjectDef>();

    /** A logical user input — one form field on the LWC. */
    public class InputDef {
        @AuraEnabled public String developerName;
        @AuraEnabled public String label;
        @AuraEnabled public String inputType;   // text | email | tel | date
        @AuraEnabled public String role;        // Qualitative | Filter
        @AuraEnabled public Integer sortOrder;
    }

    /** One queryable object inside the config. */
    public class ObjectDef {
        public String developerName;
        public String objectApiName;
        public String variant;             // B2B_Contact | Person_Account | Standard
        public String displayTypeLabel;
        public Integer sortOrder;
        public List<FieldDef> matchFields   = new List<FieldDef>();
        public List<FieldDef> displayFields = new List<FieldDef>();
    }

    /** One field on an object. Match fields participate in WHERE; display
     *  fields appear on the result card. A Field with Role = Both is added
     *  to BOTH collections so the rest of the code can treat them uniformly.
     */
    public class FieldDef {
        public String fieldApiName;
        public String matchInputDev;   // developerName of the matched InputDef (null for Display-only)
        public String matchStrategy;   // Exact | Phone | Date
        public String phoneGroup;      // OR-group key within one object (null when no group)
        public String uiLabel;
        public String displayFieldType; // text | email | phone | date
        public Integer sortOrder;
    }

    /** Helper for the LWC bridge: surfaces inputs in render order. */
    @AuraEnabled
    public List<InputDef> orderedInputs() {
        List<InputDef> copy = new List<InputDef>(inputs);
        copy.sort(new InputComparator());
        return copy;
    }

    private class InputComparator implements Comparator<InputDef> {
        public Integer compare(InputDef a, InputDef b) {
            Integer aS = (a.sortOrder == null) ? 999999 : a.sortOrder;
            Integer bS = (b.sortOrder == null) ? 999999 : b.sortOrder;
            return aS - bS;
        }
    }
}
