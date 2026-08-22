/**
 * PolicyAccessServiceTest
 * -----------------------
 * Authorization and relevance tested directly against the listPolicies /
 * findPolicyByNumber seams. Resolver fail-closed branches covered here; the
 * resolver's authenticated happy path is validated via the channel integration
 * test, because MessagingEndUser records cannot be inserted in tests.
 *
 * NOTE: User_Policy__c.Name is an Auto Number (not writable). Tests never set
 * Name; they read the system-assigned value when a real policy number is needed.
 * This is also why number-matching tests derive their input FROM the assigned
 * value rather than asserting a hard-coded format — the org's Auto Number
 * display format is not assumed anywhere.
 */
@isTest
private class PolicyAccessServiceTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'HH');
        insert acc;

        Contact a = new Contact(LastName = 'A', AccountId = acc.Id);
        Contact b = new Contact(LastName = 'B', AccountId = acc.Id);
        insert new List<Contact>{ a, b };

        List<User_Policy__c> ps = new List<User_Policy__c>();

        // A: one policy per status, with staggered expirations for ordering assertions.
        Integer offset = 10;
        for (String st : new List<String>{ 'Active', 'Pending', 'Suspended', 'Cancelled', 'Expired' }) {
            ps.add(new User_Policy__c(
                Contact__c = a.Id, Account__c = acc.Id,
                Status__c = st, Policy_Type__c = 'Travel & Liability Insurance',
                Expiration_Date__c = Datetime.now().addDays(offset)));
            offset += 10;
        }

        // A: two extra Active policies expiring sooner, to prove ASC ordering.
        ps.add(new User_Policy__c(
            Contact__c = a.Id, Account__c = acc.Id,
            Status__c = 'Active', Policy_Type__c = 'Life Insurance',
            Expiration_Date__c = Datetime.now().addDays(2)));
        ps.add(new User_Policy__c(
            Contact__c = a.Id, Account__c = acc.Id,
            Status__c = 'Active', Policy_Type__c = 'Specialized Insurance',
            Expiration_Date__c = Datetime.now().addDays(5)));

        // B: a single Active policy, for cross-customer isolation checks.
        ps.add(new User_Policy__c(
            Contact__c = b.Id, Account__c = acc.Id,
            Status__c = 'Active', Policy_Type__c = 'Property & Asset Insurance',
            Expiration_Date__c = Datetime.now().addDays(3)));

        insert ps;
    }

    private static Id cId(String ln) {
        return [SELECT Id FROM Contact WHERE LastName = :ln LIMIT 1].Id;
    }

    private static String policyName(Id contactId, String status) {
        return [SELECT Name FROM User_Policy__c
                WHERE Contact__c = :contactId AND Status__c = :status LIMIT 1].Name;
    }

    private static PolicyAccessService.Result runList(Id contactId, String scopeToken) {
        return PolicyAccessService.listPolicies(contactId, scopeToken, PolicyAccessService.LIST_MAX);
    }

    private static PolicyAccessService.Result runFind(Id contactId, String policyNumber) {
        return PolicyAccessService.findPolicyByNumber(contactId, policyNumber);
    }

    /* ---- Listing: scope and relevance ---- */

    @isTest static void defaultScope_isActiveOnly() {
        PolicyAccessService.Result r = runList(cId('A'), null);
        System.assertEquals(true, r.found);
        System.assertEquals(3, r.policyCount, 'A has exactly 3 Active policies');
        System.assert(!r.policies.contains('Pending'),   'Pending must be excluded by default');
        System.assert(!r.policies.contains('Suspended'), 'Suspended must be excluded by default');
        System.assert(!r.policies.contains('Cancelled'));
        System.assert(!r.policies.contains('Expired'));
    }

    @isTest static void currentScope_includesPendingAndSuspended() {
        System.assertEquals(5, runList(cId('A'), 'CURRENT').policyCount);
    }

    @isTest static void historicalScope_returnsClosedOnly() {
        PolicyAccessService.Result r = runList(cId('A'), 'HISTORICAL');
        System.assertEquals(2, r.policyCount);
        System.assert(r.policies.contains('Cancelled') && r.policies.contains('Expired'));
    }

    @isTest static void explicitStatusList_isHonoured() {
        PolicyAccessService.Result r = runList(cId('A'), 'Expired');
        System.assertEquals(1, r.policyCount);
        System.assert(r.policies.contains('Expired'));
    }

    @isTest static void unrecognisedScope_doesNotWidenFilter() {
        // An unparseable scope must fall back to ACTIVE, never to ALL.
        System.assertEquals(3, runList(cId('A'), 'whatever-the-llm-said').policyCount);
    }

    @isTest static void allScope_returnsEverythingUpToCap() {
        PolicyAccessService.Result r = runList(cId('A'), 'ALL');
        System.assertEquals(5, r.policyCount, 'capped at LIST_MAX');
        System.assertEquals(true, r.truncated, 'A owns 7; overflow must be flagged');
    }

    @isTest static void ordering_isExpirationAscending() {
        PolicyAccessService.Result r = runList(cId('A'), null);
        List<Object> rows = (List<Object>) JSON.deserializeUntyped(r.policies);
        String prev = null;
        for (Object o : rows) {
            String exp = (String) ((Map<String, Object>) o).get('expirationDate');
            if (prev != null) {
                System.assert(prev <= exp, 'Expirations must ascend: ' + prev + ' then ' + exp);
            }
            prev = exp;
        }
    }

    @isTest static void listing_capIsFiveAndFlagsOverflow() {
        Id a = cId('A');
        Account acc = [SELECT Id FROM Account LIMIT 1];
        List<User_Policy__c> many = new List<User_Policy__c>();
        for (Integer i = 0; i < 10; i++) {
            many.add(new User_Policy__c(Contact__c = a, Account__c = acc.Id,
                Status__c = 'Active', Policy_Type__c = 'Life Insurance',
                Expiration_Date__c = Datetime.now().addDays(100 + i)));
        }
        insert many;

        Test.startTest();
        PolicyAccessService.Result r = runList(a, null);
        Test.stopTest();

        System.assertEquals(5, r.policyCount);
        System.assertEquals(true, r.truncated);
    }

    /* ---- Listing: isolation ---- */

    @isTest static void listing_isContactScoped() {
        PolicyAccessService.Result r = runList(cId('B'), 'ALL');
        // B owns exactly 1; A owns 7. A count of 1 proves A's are excluded.
        System.assertEquals(1, r.policyCount, 'B must see only their own policy');
    }

    @isTest static void listing_nullContactFailsClosed() {
        PolicyAccessService.Result r = runList(null, 'ALL');
        System.assertEquals(false, r.found);
        System.assertEquals(0, r.policyCount);
        System.assertEquals('[]', r.policies);
    }

    /* ---- Lookup by number ---- */

    @isTest static void lookup_exactNumberSucceeds() {
        Id a = cId('A');
        String name = policyName(a, 'Active');
        PolicyAccessService.Result r = runFind(a, name);
        System.assertEquals(true, r.found);
        System.assertEquals(1, r.policyCount);
        System.assert(r.policies.contains(name));
    }

    @isTest static void lookup_ignoresLeadingZerosAndPrefix() {
        Id a = cId('A');
        String name = policyName(a, 'Active');
        String digits = name.replaceAll('[^0-9]', '').replaceFirst('^0+', '');

        // Bare significant digits.
        System.assertEquals(true, runFind(a, digits).found, 'bare digits must match');
        // Arbitrary prefix and separators the user might type.
        System.assertEquals(true, runFind(a, 'policy P-' + digits).found, 'prefixed must match');
        // Re-padded with zeros.
        System.assertEquals(true, runFind(a, '000' + digits).found, 'zero-padded must match');
    }

    @isTest static void lookup_worksForExpiredPolicy() {
        // Lookup must NOT inherit the listing's Active-only default.
        Id a = cId('A');
        String expired = policyName(a, 'Expired');
        PolicyAccessService.Result r = runFind(a, expired);
        System.assertEquals(true, r.found, 'expired policies remain retrievable by number');
    }

    @isTest static void lookup_worksOutsideTopFive() {
        Id a = cId('A');
        // The Cancelled policy has the latest expiry and never appears in the Active top-5.
        String outside = policyName(a, 'Cancelled');
        System.assertEquals(true, runFind(a, outside).found,
            'the listing cap must not become a validation limit');
    }

    /* ---- Lookup: enumeration safety ---- */

    @isTest static void lookup_notOwnedIsIndistinguishableFromNonexistent() {
        Id b = cId('B');
        String aName = policyName(cId('A'), 'Active');   // exists, belongs to A

        PolicyAccessService.Result notOwned = runFind(b, aName);
        PolicyAccessService.Result missing  = runFind(b, '99999999');

        System.assertEquals(false, notOwned.found);
        System.assertEquals(false, missing.found);
        System.assertEquals(notOwned.found,       missing.found,       'enumeration oracle: found');
        System.assertEquals(notOwned.policies,    missing.policies,    'enumeration oracle: payload');
        System.assertEquals(notOwned.policyCount, missing.policyCount, 'enumeration oracle: count');
        System.assertEquals(notOwned.message,     missing.message,     'enumeration oracle: message');
        System.assertEquals(notOwned.policiesText, missing.policiesText);
        System.assertEquals(notOwned.policiesHtml, missing.policiesHtml);
    }

    @isTest static void lookup_nullContactFailsClosed() {
        String aName = policyName(cId('A'), 'Active');
        PolicyAccessService.Result r = runFind(null, aName);
        System.assertEquals(false, r.found);
        System.assertEquals('[]', r.policies);
    }

    @isTest static void lookup_blankAndNonNumericInput() {
        Id a = cId('A');
        System.assertEquals(false, runFind(a, null).found);
        System.assertEquals(false, runFind(a, '').found);
        System.assertEquals(false, runFind(a, 'my policy please').found);
    }

    /* ---- Normalization ---- */

    @isTest static void normalize_behaviour() {
        System.assertEquals('1007', PolicyAccessService.normalizeNumber('P-0001007'));
        System.assertEquals('1007', PolicyAccessService.normalizeNumber('1007'));
        System.assertEquals('1007', PolicyAccessService.normalizeNumber('  policy 1007! '));
        System.assertEquals('0',    PolicyAccessService.normalizeNumber('0000'));
        System.assertEquals(null,   PolicyAccessService.normalizeNumber('no digits here'));
        System.assertEquals(null,   PolicyAccessService.normalizeNumber(''));
        System.assertEquals(null,   PolicyAccessService.normalizeNumber(null));
    }

    /* ---- Resolver fail-closed ---- */

    @isTest static void resolver_blankAndMalformedInputs() {
        Map<String, Id> r = PolicyAccessService.resolveVerifiedContactIds(
            new List<String>{ null, '', '   ', 'not-an-id' });
        System.assertEquals(0, r.size(), 'nothing resolvable => empty map => fail closed');
    }

    @isTest static void resolver_emptyAndNullList() {
        System.assertEquals(0, PolicyAccessService.resolveVerifiedContactIds(null).size());
        System.assertEquals(0,
            PolicyAccessService.resolveVerifiedContactIds(new List<String>()).size());
    }

    @isTest static void resolver_unknownEndUser() {
        Map<String, Id> r = PolicyAccessService.resolveVerifiedContactIds(
            new List<String>{ '0Mw000000000000AAA' });
        System.assertEquals(0, r.size());
    }

    /* ---- Fallback identity: the running user's OWN contact ---- */

    @isTest static void fallback_internalUserWithoutContactIsNull() {
        // Tests run as an internal user with no linked Contact — the agent-user shape.
        // Must be null so every caller keeps failing closed.
        System.assertEquals(null, PolicyAccessService.resolveRunningUserContactId(),
            'a running user with no Contact must not resolve to one');
    }

    @isTest static void fallback_isCachedPerTransaction() {
        Integer before = Limits.getQueries();
        PolicyAccessService.resolveRunningUserContactId();
        PolicyAccessService.resolveRunningUserContactId();
        PolicyAccessService.resolveRunningUserContactId();
        System.assert(Limits.getQueries() - before <= 1,
            'fallback identity must be cached; queries used: '
                + (Limits.getQueries() - before));
    }

    @isTest static void fallback_doesNotRescueAnUnresolvedRequest() {
        // Unresolvable messaging id + a running user with no Contact => still closed.
        // Proves the fallback never invents access it cannot derive.
        PolicyAccessService.runningUserContactLoaded = false;
        PolicyAccessService.runningUserContact = null;

        ListMyPolicies.Request req = new ListMyPolicies.Request();
        req.messagingEndUserId = '0Mw000000000000AAA';
        PolicyAccessService.Result r =
            ListMyPolicies.run(new List<ListMyPolicies.Request>{ req })[0];
        System.assertEquals(false, r.found, 'unresolved identity must stay closed');
        System.assertEquals(0, r.policyCount);

        GetPolicyDetails.Request d = new GetPolicyDetails.Request();
        d.messagingEndUserId = '0Mw000000000000AAA';
        d.policyNumber = '12345';
        System.assertEquals(false,
            GetPolicyDetails.run(new List<GetPolicyDetails.Request>{ d })[0].found);
    }

    /* ---- Invocable entry points ---- */

    @isTest static void listInvocable_unresolvedFailsClosed() {
        ListMyPolicies.Request req = new ListMyPolicies.Request();
        req.messagingEndUserId = '0Mw000000000000AAA';
        PolicyAccessService.Result r =
            ListMyPolicies.run(new List<ListMyPolicies.Request>{ req })[0];
        System.assertEquals(false, r.found);
        System.assertEquals('[]', r.policies);
    }

    @isTest static void detailsInvocable_unresolvedFailsClosed() {
        GetPolicyDetails.Request req = new GetPolicyDetails.Request();
        req.messagingEndUserId = '0Mw000000000000AAA';
        req.policyNumber = '1007';
        PolicyAccessService.Result r =
            GetPolicyDetails.run(new List<GetPolicyDetails.Request>{ req })[0];
        System.assertEquals(false, r.found);
    }

    @isTest static void invocables_bulkSafe_noSoqlInLoop() {
        // 50 requests must not multiply identity queries.
        List<ListMyPolicies.Request> reqs = new List<ListMyPolicies.Request>();
        for (Integer i = 0; i < 50; i++) {
            ListMyPolicies.Request req = new ListMyPolicies.Request();
            req.messagingEndUserId = '0Mw000000000000AAA';
            reqs.add(req);
        }
        Test.startTest();
        Integer before = Limits.getQueries();
        List<PolicyAccessService.Result> out = ListMyPolicies.run(reqs);
        Integer used = Limits.getQueries() - before;
        Test.stopTest();

        System.assertEquals(50, out.size());
        // 2 identity hops + 1 cached fallback lookup, regardless of request count.
        System.assert(used <= 3,
            'identity resolution must be bulkified; queries used: ' + used);
    }

    @isTest static void invocables_emptyAndNullRequests() {
        System.assertEquals(0, ListMyPolicies.run(null).size());
        System.assertEquals(0, ListMyPolicies.run(new List<ListMyPolicies.Request>()).size());
        System.assertEquals(0, GetPolicyDetails.run(null).size());
        System.assertEquals(0, GetPolicyDetails.run(new List<GetPolicyDetails.Request>()).size());
    }

    /* ---- Rendering ---- */

    @isTest static void rendering_allThreeShapesPresent() {
        PolicyAccessService.Result r = runList(cId('A'), null);
        System.assert(String.isNotBlank(r.policies));
        System.assert(String.isNotBlank(r.policiesHtml), 'HTML shape for Adaptive Response Formats');
        System.assert(String.isNotBlank(r.policiesText), 'text fallback');
        System.assert(r.policiesHtml.contains('<ul>'));
    }

    @isTest static void rendering_emptyResultHasNoMarkup() {
        PolicyAccessService.Result r = runFind(cId('B'), '99999999');
        System.assertEquals('', r.policiesHtml);
        System.assertEquals('', r.policiesText);
    }
}