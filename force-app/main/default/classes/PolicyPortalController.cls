/**
 * PolicyPortalController
 * ----------------------
 * LWC controller for the Northwind customer portal: dashboard, application form,
 * and policy detail.
 *
 * Deliberately thin on reads. Identity resolution and contact scoping live in
 * PolicyAccessService and are NOT reimplemented here — the portal and the agent
 * must never disagree about who may see what.
 *
 * ============================ SECURITY NOTES ============================
 * 1. The contact is derived from the RUNNING USER (PolicyAccessService
 *    .resolveRunningUserContactId), never from a parameter. There is deliberately no
 *    contactId / recordId argument on any method: a portal page is trivially callable
 *    with hand-edited arguments, so accepting one would hand every customer a way to
 *    read or write another customer's policies.
 *
 * 2. createPolicy accepts ONLY the five fields the customer legitimately chooses.
 *    Contact, Account, Status and every derived date/amount are set server-side. A
 *    caller cannot issue a policy to someone else, back-date cover, or self-approve.
 *
 * 3. KNOWN, ACCEPTED RISK — createPolicy inserts directly, which requires site users to
 *    hold create on User_Policy__c, edit FLS on its fields, and edit on their own
 *    Contact record. Those permissions apply to the REST API too, so this method is NOT
 *    the only way a customer can create a policy: a determined caller can POST an
 *    Active policy for any amount and skip every validation below. This was a deliberate
 *    product decision to keep the stack to LWC + Apex. The alternative — running the
 *    insert through an autolaunched flow in system context — keeps customers read-only
 *    and makes this method the only door; revisit before this handles real money.
 *
 * 4. Derived values (dates, deductible) are computed here and returned to the client
 *    for preview only. The client never sends them back — a recomputed server value
 *    always wins.
 * =======================================================================
 */
public with sharing class PolicyPortalController {

    // Portal shows the full book, not the chat reply's top-5.
    private static final Integer PORTAL_MAX_ROWS = 200;

    // A new application is never auto-approved.
    private static final String NEW_POLICY_STATUS = 'Pending';

    /**
     * Tenure token -> months. Single source of truth: also returned to the client so
     * the form's live preview and the server agree by construction.
     */
    private static final Map<String, Integer> TENURE_MONTHS = new Map<String, Integer>{
        '6M'  => 6,
        '12M' => 12,
        '18M' => 18,
        '3Y'  => 36,
        '5Y'  => 60,
        '10Y' => 120,
        '15Y' => 180
    };

    private static final List<String> TENURE_ORDER = new List<String>{
        '6M', '12M', '18M', '3Y', '5Y', '10Y', '15Y'
    };

    private static final Map<String, String> TENURE_LABELS = new Map<String, String>{
        '6M'  => '6 months',
        '12M' => '12 months',
        '18M' => '18 months',
        '3Y'  => '3 years',
        '5Y'  => '5 years',
        '10Y' => '10 years',
        '15Y' => '15 years'
    };

    // Months between instalments, per payment frequency.
    private static final Map<String, Integer> FREQUENCY_MONTHS = new Map<String, Integer>{
        'Monthly'   => 1,
        'Quarterly' => 3,
        'Annually'  => 12
    };

    /**
     * Deductible as a fraction of sum insured, by payment frequency.
     * Paying further in advance carries less collection risk, so it earns a lower
     * deductible. These rates are a product decision, parked here so there is exactly
     * one place to change them.
     */
    private static final Map<String, Decimal> DEDUCTIBLE_RATE = new Map<String, Decimal>{
        'Monthly'   => 0.0200,
        'Quarterly' => 0.0150,
        'Annually'  => 0.0100
    };

    /* ====================================================================
     * Shapes
     * ==================================================================== */

    public class PortalData {
        @AuraEnabled public String greetingName;
        @AuraEnabled public Boolean isResolved;
        @AuraEnabled public Integer totalCount;
        @AuraEnabled public List<Object> policies;

        public PortalData() {
            this.greetingName = '';
            this.isResolved = false;
            this.totalCount = 0;
            this.policies = new List<Object>();
        }
    }

    public class Option {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
        @AuraEnabled public Integer months;      // tenure / frequency interval
        @AuraEnabled public Decimal rate;        // deductible rate, frequencies only

        public Option(String value, String label, Integer months, Decimal rate) {
            this.value = value;
            this.label = label;
            this.months = months;
            this.rate = rate;
        }
    }

    public class ApplyOptions {
        @AuraEnabled public List<Option> policyTypes;
        @AuraEnabled public List<Option> tenures;
        @AuraEnabled public List<Option> frequencies;
        @AuraEnabled public Boolean canApply;
        @AuraEnabled public String blockedReason;
    }

    /* ====================================================================
     * Reads
     * ==================================================================== */

    /**
     * Everything the dashboard needs in one round trip. `scope` accepts the
     * PolicyAccessService tokens; the portal asks for ALL and filters client-side.
     */
    @AuraEnabled(cacheable=true)
    public static PortalData getPortalData(String scope) {
        PortalData data = new PortalData();

        Id contactId = PolicyAccessService.resolveRunningUserContactId();
        data.greetingName = greetingFor(contactId);
        if (contactId == null) {
            return data;                       // guest / no Contact => empty, not an error
        }
        data.isResolved = true;

        PolicyAccessService.Result r = PolicyAccessService.listPolicies(
            contactId, String.isBlank(scope) ? 'ALL' : scope, PORTAL_MAX_ROWS, true);

        data.policies   = (List<Object>) JSON.deserializeUntyped(r.policies);
        data.totalCount = r.policyCount;
        return data;
    }

    /**
     * Picklist values come from the schema rather than a hard-coded list, so adding a
     * policy type in Setup surfaces on the form with no code change.
     */
    @AuraEnabled(cacheable=true)
    public static ApplyOptions getApplyOptions() {
        ApplyOptions opts = new ApplyOptions();
        opts.policyTypes = picklistOptions(User_Policy__c.Policy_Type__c);
        opts.frequencies = new List<Option>();
        for (Option o : picklistOptions(User_Policy__c.Payment_Frequency__c)) {
            Integer months = FREQUENCY_MONTHS.get(o.value);
            Decimal rate   = DEDUCTIBLE_RATE.get(o.value);
            if (months == null) continue;       // unknown frequency => not offered
            opts.frequencies.add(new Option(o.value, o.label, months, rate));
        }

        opts.tenures = new List<Option>();
        for (String key : TENURE_ORDER) {
            opts.tenures.add(new Option(key, TENURE_LABELS.get(key), TENURE_MONTHS.get(key), null));
        }

        Id contactId = PolicyAccessService.resolveRunningUserContactId();
        opts.canApply = contactId != null && accountFor(contactId) != null;
        opts.blockedReason = opts.canApply
            ? null
            : 'We could not find the account linked to your profile, so applications are unavailable right now.';
        return opts;
    }

    /**
     * One policy belonging to the signed-in customer. Routed through
     * PolicyAccessService.findPolicyByNumber so the detail view inherits the same
     * contact scoping and the same no-enumeration-oracle behaviour as the agent.
     */
    @AuraEnabled(cacheable=true)
    public static Object getPolicyDetail(String policyNumber) {
        Id contactId = PolicyAccessService.resolveRunningUserContactId();
        PolicyAccessService.Result r =
            PolicyAccessService.findPolicyByNumber(contactId, policyNumber);
        if (!r.found) return null;

        List<Object> rows = (List<Object>) JSON.deserializeUntyped(r.policies);
        return rows.isEmpty() ? null : rows[0];
    }

    /* ====================================================================
     * Create
     * ==================================================================== */

    /**
     * Create a policy application for the signed-in customer.
     * Returns the new policy number; the client then reads the record back through
     * getPolicyDetail, so the detail page always reflects what is actually stored.
     */
    @AuraEnabled
    public static String createPolicy(String policyType,
                                      String tenure,
                                      Decimal sumInsured,
                                      String paymentFrequency,
                                      Decimal premiumAmount) {

        Id contactId = PolicyAccessService.resolveRunningUserContactId();
        if (contactId == null) {
            throw problem('We could not identify your account. Please sign in again.');
        }
        Id accountId = accountFor(contactId);
        if (accountId == null) {
            throw problem('Your profile is not linked to an account, so a policy cannot be issued.');
        }

        // ---- validate every input against the schema, not against the client ----
        if (!picklistValues(User_Policy__c.Policy_Type__c).contains(policyType)) {
            throw problem('Choose a policy type.');
        }
        if (!TENURE_MONTHS.containsKey(tenure)) {
            throw problem('Choose a tenure.');
        }
        if (!FREQUENCY_MONTHS.containsKey(paymentFrequency)
                || !picklistValues(User_Policy__c.Payment_Frequency__c).contains(paymentFrequency)) {
            throw problem('Choose a payment frequency.');
        }
        if (sumInsured == null || sumInsured <= 0) {
            throw problem('Enter a sum insured greater than zero.');
        }
        if (premiumAmount == null || premiumAmount <= 0) {
            throw problem('Enter a premium amount greater than zero.');
        }
        if (premiumAmount > sumInsured) {
            throw problem('The premium cannot be larger than the sum insured.');
        }

        // ---- derive everything else server-side ----
        Datetime effective  = Datetime.now();
        Datetime expiration = effective.addMonths(TENURE_MONTHS.get(tenure));
        Date nextPayment    = nextPaymentDate(effective, expiration, paymentFrequency);
        Decimal deductible  = (sumInsured * DEDUCTIBLE_RATE.get(paymentFrequency))
                                  .setScale(2, System.RoundingMode.HALF_UP);

        User_Policy__c p = new User_Policy__c(
            Contact__c               = contactId,          // derived, never supplied
            Account__c               = accountId,          // derived, never supplied
            Status__c                = NEW_POLICY_STATUS,  // never client-controlled
            Policy_Type__c           = policyType,
            Sum_Insured__c           = sumInsured,
            Premium_Amount__c        = premiumAmount,
            Payment_Frequency__c     = paymentFrequency,
            Effective_Date__c        = effective,
            Expiration_Date__c       = expiration,
            Next_Payment_Due_Date__c = nextPayment,
            Deductable__c            = deductible
        );

        // Direct DML, by design decision. This requires the site user to hold create on
        // User_Policy__c, edit FLS on its fields, and edit on their own Contact record
        // (master-detail inserts check the parent). Those grants also make the REST API
        // a second, unvalidated way in — see the security note at the top of this class.
        try {
            insert p;
        } catch (DmlException e) {
            throw problem('We could not save your application: ' + e.getDmlMessage(0));
        }

        // Name is an Auto Number, so it only exists after the insert.
        return [SELECT Name FROM User_Policy__c WHERE Id = :p.Id LIMIT 1].Name;
    }

    /* ====================================================================
     * Helpers
     * ==================================================================== */

    /**
     * First instalment after cover starts. Returns null when the whole term is paid
     * up front (e.g. a 6 month policy paid annually) — there is no further payment
     * due inside the term, and inventing one would be wrong.
     */
    @TestVisible
    private static Date nextPaymentDate(Datetime effective, Datetime expiration, String frequency) {
        Datetime due = effective.addMonths(FREQUENCY_MONTHS.get(frequency));
        return due > expiration ? null : due.date();
    }

    private static Id accountFor(Id contactId) {
        if (contactId == null) return null;
        List<Contact> cs = [SELECT AccountId FROM Contact WHERE Id = :contactId LIMIT 1];
        return cs.isEmpty() ? null : cs[0].AccountId;
    }

    private static List<Option> picklistOptions(Schema.SObjectField field) {
        List<Option> out = new List<Option>();
        for (Schema.PicklistEntry pe : field.getDescribe().getPicklistValues()) {
            if (pe.isActive()) out.add(new Option(pe.getValue(), pe.getLabel(), null, null));
        }
        return out;
    }

    private static Set<String> picklistValues(Schema.SObjectField field) {
        Set<String> out = new Set<String>();
        for (Schema.PicklistEntry pe : field.getDescribe().getPicklistValues()) {
            if (pe.isActive()) out.add(pe.getValue());
        }
        return out;
    }

    private static AuraHandledException problem(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);   // without this the client sees only "Script-thrown exception"
        return e;
    }

    /**
     * First name for the greeting. Falls back to the User's own first name, then to a
     * neutral word — the dashboard must never render "Hi, null".
     */
    private static String greetingFor(Id contactId) {
        if (contactId != null) {
            List<Contact> cs = [
                SELECT FirstName, Name FROM Contact WHERE Id = :contactId WITH USER_MODE LIMIT 1
            ];
            if (!cs.isEmpty()) {
                if (String.isNotBlank(cs[0].FirstName)) return cs[0].FirstName;
                if (String.isNotBlank(cs[0].Name))      return cs[0].Name;
            }
        }
        String fromUser = UserInfo.getFirstName();
        return String.isNotBlank(fromUser) ? fromUser : 'there';
    }
}