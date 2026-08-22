/**
 * GetMyPoliciesTest
 * -----------------
 * Authorization/relevance tested directly against the queryPolicies seam.
 * Resolver fail-closed branches covered here; the resolver's authenticated happy-path
 * is validated via the channel integration test (MessagingEndUser can't be inserted in tests).
 *
 * NOTE: User_Policy__c.Name is an Auto Number field (not writable). Tests never set Name;
 * they read the system-assigned value when a specific policy number is needed.
 * ASSUMPTION: only the two master-detail parents are required on insert.
 */
@isTest
private class GetMyPoliciesTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'HH');
        insert acc;
        Contact a = new Contact(LastName = 'A', AccountId = acc.Id);
        Contact b = new Contact(LastName = 'B', AccountId = acc.Id);
        insert new List<Contact>{ a, b };

        List<User_Policy__c> ps = new List<User_Policy__c>();
        for (String st : new List<String>{'Active','Pending','Suspended','Cancelled','Expired'}) {
            ps.add(new User_Policy__c(
                Contact__c = a.Id, Account__c = acc.Id,
                Status__c = st, Policy_Type__c = 'Travel & Liability Insurance',
                Expiration_Date__c = Date.today().addDays(30)));
        }
        // B: one Home policy (Policy_Type distinguishes it from A's Auto policies for isolation checks).
        ps.add(new User_Policy__c(
            Contact__c = b.Id, Account__c = acc.Id,
            Status__c = 'Active', Policy_Type__c = 'Property & Asset Insurance'));
        insert ps;
    }

    private static Id cId(String ln) { return [SELECT Id FROM Contact WHERE LastName = :ln LIMIT 1].Id; }

    // Name is auto-number: read the system-assigned value when a test needs a real policy number.
    private static String policyName(Id contactId, String status) {
        return [SELECT Name FROM User_Policy__c
                WHERE Contact__c = :contactId AND Status__c = :status LIMIT 1].Name;
    }

    private static GetMyPolicies.Result run(Id contactId, String policyNumber, String scope) {
        return GetMyPolicies.queryPolicies(contactId, policyNumber, scope);
    }

    // ---- Authorization / relevance ----

    @isTest static void currentDefault_excludesHistorical_includesSuspended() {
        GetMyPolicies.Result r = run(cId('A'), null, null);
        System.assertEquals(true, r.found);
        System.assertEquals(3, r.policyCount, 'CURRENT = Active+Pending+Suspended');
        System.assert(r.policies.contains('Suspended'), 'Suspended must be returned, not hidden');
        System.assert(!r.policies.contains('Cancelled'));
        System.assert(!r.policies.contains('Expired'));
    }

    @isTest static void historicalScope_returnsClosedOnly() {
        GetMyPolicies.Result r = run(cId('A'), null, 'HISTORICAL');
        System.assertEquals(2, r.policyCount);
        System.assert(r.policies.contains('Cancelled') && r.policies.contains('Expired'));
    }

    @isTest static void allScope_returnsEverything() {
        System.assertEquals(5, run(cId('A'), null, 'ALL').policyCount);
    }

    @isTest static void specificNumber_returnsCancelledPolicy() {
        String cancelled = policyName(cId('A'), 'Cancelled');
        GetMyPolicies.Result r = run(cId('A'), cancelled, null);
        System.assertEquals(true, r.found);
        System.assertEquals(1, r.policyCount);
        System.assert(r.policies.contains('Cancelled'));
    }

    @isTest static void nonOwner_seesNoneOfOwnersPolicies() {
        Id b = cId('B');
        String bName = [SELECT Name FROM User_Policy__c WHERE Contact__c = :b LIMIT 1].Name;
        GetMyPolicies.Result r = run(b, null, 'ALL');
        // B has exactly 1 policy; A has 5. Count==1 proves A's are excluded (else it'd be 6).
        System.assertEquals(1, r.policyCount, 'B must see only their own single policy');
        System.assert(r.policies.contains(bName), 'B sees their own policy');
    }

    @isTest static void nonOwnedSpecific_equalsNonexistent_noOracle() {
        String aName = policyName(cId('A'), 'Active');           // exists, belongs to A
        GetMyPolicies.Result notOwned = run(cId('B'), aName, null);
        GetMyPolicies.Result missing  = run(cId('B'), 'ZZZ-DOES-NOT-EXIST', null);
        System.assertEquals(false, notOwned.found);
        System.assertEquals(notOwned.found, missing.found, 'Enumeration oracle');
        System.assertEquals(notOwned.policies, missing.policies);
    }

    @isTest static void overflow_capsAndFlags() {
        Id a = cId('A');
        Account acc = [SELECT Id FROM Account LIMIT 1];
        List<User_Policy__c> many = new List<User_Policy__c>();
        for (Integer i = 0; i < 55; i++) {
            many.add(new User_Policy__c(Contact__c = a, Account__c = acc.Id,
                Status__c = 'Active', Policy_Type__c = 'Travel & Liability Insurance'));
        }
        insert many;
        Test.startTest();
        GetMyPolicies.Result r = run(a, null, 'ALL');
        Test.stopTest();
        System.assertEquals(true, r.truncated);
        System.assertEquals(50, r.policyCount);
    }

    @isTest static void nullContact_failsClosed() {
        GetMyPolicies.Result r = run(null, null, null);
        System.assertEquals(false, r.found);
        System.assertEquals('[]', r.policies);
    }

    // ---- Resolver fail-closed ----

    @isTest static void resolver_blankInput_returnsNull() {
        System.assertEquals(null, GetMyPolicies.resolveVerifiedContactId(null));
        System.assertEquals(null, GetMyPolicies.resolveVerifiedContactId(''));
    }

    @isTest static void resolver_malformedId_returnsNull() {
        System.assertEquals(null, GetMyPolicies.resolveVerifiedContactId('not-an-id'));
    }

    @isTest static void resolver_unknownEndUser_returnsNull() {
        System.assertEquals(null, GetMyPolicies.resolveVerifiedContactId('0Mw000000000000AAA'));
    }

    @isTest static void run_unresolvedEndUser_failsClosed() {
        GetMyPolicies.Request req = new GetMyPolicies.Request();
        req.messagingEndUserId = '0Mw000000000000AAA';
        GetMyPolicies.Result r = GetMyPolicies.run(new List<GetMyPolicies.Request>{ req })[0];
        System.assertEquals(false, r.found);
    }
}