/**
 * GetMyPolicies
 * -------------
 * Agentforce invocable. Resolves the VERIFIED contact from the messaging session
 * (server-side, LLM never sees it), then returns that contact's policies.
 *
 * Identity chain (all hops platform-managed => non-spoofable):
 *   $Context.MessagingEndUserId
 *     -> MessagingEndUser.AuthenticatedEndUserId   (the authenticated User; null for guests)
 *     -> User.ContactId                            (the Contact)
 *
 * ============================ SECURITY NOTES ============================
 * 1. `AuthenticatedEndUserId` is set by the platform at authentication. Guests have it
 *    null. That null-check IS the guest gate - the LLM/client cannot forge it. Any
 *    missing hop => resolveVerifiedContactId returns null => fail closed.
 * 2. `Contact__c = :contactId` in queryPolicies is the SOLE authorization control on
 *    policy data. contactId is derived here, never accepted from the user/LLM.
 * 3. queryPolicies is a separate @TestVisible seam so the authorization logic is unit-
 *    tested directly with contactId values. The resolver's authenticated path is validated
 *    via the channel integration test (MessagingEndUser records can't be inserted in tests).
 * 4. NO ENUMERATION ORACLE: not-owned and nonexistent both yield found=false / empty.
 * 5. Resolution queries run WITHOUT USER_MODE on purpose: identity derivation over platform
 *    session/User objects; trust is that AuthenticatedEndUserId is platform-set, not FLS.
 *    The customer-data query keeps USER_MODE. (with sharing still applies.) The Agent User
 *    needs read on MessagingEndUser.AuthenticatedEndUserId and User.ContactId.
 * =======================================================================
 */
public with sharing class GetMyPolicies {

    private static final Integer MAX_ROWS = 50;
    private static final Set<String> CURRENT_STATUSES    = new Set<String>{'Active','Pending','Suspended'};
    private static final Set<String> HISTORICAL_STATUSES = new Set<String>{'Cancelled','Expired'};

    public class Request {
        // Bind to $Context.MessagingEndUserId in the action config. Never user-collectable.
        @InvocableVariable(required=true label='Messaging End User Id (bind to $Context.MessagingEndUserId)')
        public String messagingEndUserId;

        @InvocableVariable(label='Specific Policy Number (optional; exact match)')
        public String policyNumber;

        @InvocableVariable(label='Scope: CURRENT (default) | HISTORICAL | ALL')
        public String scope;
    }

    public class Result {
        @InvocableVariable public Boolean found;
        @InvocableVariable public Boolean truncated;
        @InvocableVariable public Integer policyCount;
        @InvocableVariable public String  policies;   // JSON array; [] when none
    }

    @InvocableMethod(
        label='Get My Policies (Scoped)'
        description='Resolves the verified contact from the messaging session, then returns that contact\'s policies.')
    public static List<Result> run(List<Request> requests) {
        List<Result> out = new List<Result>();
        for (Request req : requests) {
            Id contactId = resolveVerifiedContactId(req == null ? null : req.messagingEndUserId);
            out.add(queryPolicies(
                contactId,
                req == null ? null : req.policyNumber,
                req == null ? null : req.scope));
        }
        return out;
    }

    /**
     * Resolve the verified Contact from the messaging end user. Fail closed at every hop.
     * Returns null for: blank/invalid input, missing MessagingEndUser, guest
     * (AuthenticatedEndUserId null), or an authenticated User with no linked Contact.
     */
    @TestVisible
    private static Id resolveVerifiedContactId(String messagingEndUserId) {
        if (String.isBlank(messagingEndUserId)) return null;

        Id meuId;
        try { meuId = (Id) messagingEndUserId; } catch (Exception e) { return null; }

        List<MessagingEndUser> meus = [
            SELECT AuthenticatedEndUserId
            FROM MessagingEndUser
            WHERE Id = :meuId
            LIMIT 1
        ];
        if (meus.isEmpty() || meus[0].AuthenticatedEndUserId == null) {
            return null;   // no end user, or GUEST => fail closed
        }

        List<User> users = [
            SELECT ContactId FROM User WHERE Id = :meus[0].AuthenticatedEndUserId LIMIT 1
        ];
        if (users.isEmpty() || users[0].ContactId == null) {
            return null;   // authenticated but no linked Contact => fail closed
        }
        return users[0].ContactId;
    }

    /**
     * Authorization + query. `Contact__c = :contactId` is the sole scoping control.
     * Separate seam so the security path is unit-tested directly (contactId in, Result out).
     */
    @TestVisible
    private static Result queryPolicies(Id contactId, String policyNumber, String scope) {
        Result r = new Result();
        r.found = false; r.truncated = false; r.policyCount = 0; r.policies = '[]';

        if (contactId == null) return r;   // FAIL CLOSED (unresolved / guest)

        Integer q = MAX_ROWS + 1;
        List<User_Policy__c> rows;

        if (String.isNotBlank(policyNumber)) {
            String name = policyNumber.trim();
            rows = [
                SELECT Name, Policy_Type__c, Status__c, Effective_Date__c, Expiration_Date__c,
                       Next_Payment_Due_Date__c, Payment_Frequency__c, Premium_Amount__c,
                       Deductable__c, Sum_Insured__c
                FROM User_Policy__c
                WHERE Name = :name AND Contact__c = :contactId
                WITH USER_MODE
                LIMIT 1
            ];
        } else {
            Set<String> statuses = statusesFor(scope);
            if (statuses == null) {
                rows = [
                    SELECT Name, Policy_Type__c, Status__c, Effective_Date__c, Expiration_Date__c,
                           Next_Payment_Due_Date__c, Payment_Frequency__c, Premium_Amount__c,
                           Deductable__c, Sum_Insured__c
                    FROM User_Policy__c
                    WHERE Contact__c = :contactId
                    WITH USER_MODE
                    ORDER BY Expiration_Date__c ASC NULLS LAST
                    LIMIT :q
                ];
            } else {
                rows = [
                    SELECT Name, Policy_Type__c, Status__c, Effective_Date__c, Expiration_Date__c,
                           Next_Payment_Due_Date__c, Payment_Frequency__c, Premium_Amount__c,
                           Deductable__c, Sum_Insured__c
                    FROM User_Policy__c
                    WHERE Contact__c = :contactId AND Status__c IN :statuses
                    WITH USER_MODE
                    ORDER BY Expiration_Date__c ASC NULLS LAST
                    LIMIT :q
                ];
            }
        }

        if (rows.size() > MAX_ROWS) {
            r.truncated = true;
            while (rows.size() > MAX_ROWS) rows.remove(rows.size() - 1);
        }

        Date today = Date.today();
        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (User_Policy__c p : rows) {
            out.add(new Map<String, Object>{
                'policyNumber'       => p.Name,
                'policyType'         => p.Policy_Type__c,
                'status'             => p.Status__c,
                'effectiveDate'      => String.valueOf(p.Effective_Date__c),
                'expirationDate'     => String.valueOf(p.Expiration_Date__c),
                'nextPaymentDueDate' => String.valueOf(p.Next_Payment_Due_Date__c),
                'paymentFrequency'   => p.Payment_Frequency__c,
                'premiumAmount'      => p.Premium_Amount__c,
                'deductible'         => p.Deductable__c,
                'sumInsured'         => p.Sum_Insured__c,
                'daysToExpiration'   => (p.Expiration_Date__c != null) ? today.daysBetween(p.Expiration_Date__c?.date()) : null,
                'daysToNextPayment'  => (p.Next_Payment_Due_Date__c != null) ? today.daysBetween(p.Next_Payment_Due_Date__c) : null
            });
        }

        r.policyCount = out.size();
        r.found       = !out.isEmpty();
        r.policies    = JSON.serialize(out);
        return r;
    }

    private static Set<String> statusesFor(String scope) {
        String s = (scope == null) ? '' : scope.trim().toUpperCase();
        if (s == 'ALL')        return null;
        if (s == 'HISTORICAL') return HISTORICAL_STATUSES;
        return CURRENT_STATUSES;
    }
}