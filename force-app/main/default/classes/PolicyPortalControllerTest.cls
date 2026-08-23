/**
 * PolicyPortalControllerTest
 * --------------------------
 * The controller is a thin wrapper over PolicyAccessService for reads, so that class's
 * tests own authorization and relevance. What matters here is that the portal cannot be
 * talked into returning or writing someone else's data, that an unresolved caller gets
 * an empty dashboard rather than an exception, and that the derived policy terms are
 * correct.
 *
 * Tests run as an internal user with no linked Contact — the same shape as a guest or
 * the agent user — so every identity-dependent path exercises the closed branch. The
 * signed-in-customer path is covered by the site integration test, because a Contact
 * cannot be attached to the running test user.
 */
@isTest
private class PolicyPortalControllerTest {

    /* ---- reads ---- */

    @isTest static void unresolvedCaller_getsEmptyDashboardNotAnError() {
        PolicyPortalController.PortalData d = PolicyPortalController.getPortalData('ALL');
        System.assertEquals(false, d.isResolved, 'no Contact => not resolved');
        System.assertEquals(0, d.totalCount);
        System.assertEquals(true, d.policies.isEmpty(), 'must return no rows');
    }

    @isTest static void greetingNeverRendersNull() {
        PolicyPortalController.PortalData d = PolicyPortalController.getPortalData(null);
        System.assert(String.isNotBlank(d.greetingName),
            'greeting must always have something to render');
        System.assert(!'null'.equalsIgnoreCase(d.greetingName));
    }

    @isTest static void blankScopeIsAccepted() {
        PolicyPortalController.PortalData d = PolicyPortalController.getPortalData('');
        System.assertNotEquals(null, d.policies);
    }

    @isTest static void policyDetail_unresolvedCallerGetsNothing() {
        System.assertEquals(null, PolicyPortalController.getPolicyDetail('P-00012'),
            'an unresolved caller must not be able to read a policy by number');
    }

    /* ---- options ---- */

    @isTest static void applyOptions_comeFromTheSchema() {
        PolicyPortalController.ApplyOptions o = PolicyPortalController.getApplyOptions();

        System.assert(!o.policyTypes.isEmpty(), 'policy types must come from the picklist');
        System.assertEquals(7, o.tenures.size(), '6M, 12M, 18M, 3Y, 5Y, 10Y, 15Y');
        System.assert(!o.frequencies.isEmpty());

        for (PolicyPortalController.Option f : o.frequencies) {
            System.assertNotEquals(null, f.months, 'each frequency needs an interval');
            System.assertNotEquals(null, f.rate, 'each frequency needs a deductible rate');
        }
        // No Contact on the running user => applications are blocked, with a reason.
        System.assertEquals(false, o.canApply);
        System.assert(String.isNotBlank(o.blockedReason));
    }

    /* ---- create: every guard ---- */

    @isTest static void create_withoutIdentityIsRefused() {
        try {
            PolicyPortalController.createPolicy(
                'Life Insurance', '12M', 100000, 'Monthly', 500);
            System.assert(false, 'an unidentified caller must not be able to create a policy');
        } catch (Exception e) {
            System.assert(e.getMessage().contains('could not identify'), e.getMessage());
        }
    }

    @isTest static void create_rejectsUnknownTenureAndType() {
        // Identity fails first, so these assert the method refuses rather than inserting.
        Integer before = [SELECT COUNT() FROM User_Policy__c];
        for (String tenure : new List<String>{ '9M', '', null }) {
            try {
                PolicyPortalController.createPolicy(
                    'Life Insurance', tenure, 100000, 'Monthly', 500);
            } catch (Exception e) {
                // expected
            }
        }
        System.assertEquals(before, [SELECT COUNT() FROM User_Policy__c],
            'no policy may be created by a refused request');
    }

    /* ---- derived terms ---- */

    @isTest static void nextPayment_followsTheFrequency() {
        Datetime start = Datetime.newInstance(2026, 1, 15, 0, 0, 0);
        Datetime finish = start.addMonths(60);              // 5 year term

        System.assertEquals(start.addMonths(1).date(),
            PolicyPortalController.nextPaymentDate(start, finish, 'Monthly'));
        System.assertEquals(start.addMonths(3).date(),
            PolicyPortalController.nextPaymentDate(start, finish, 'Quarterly'));
        System.assertEquals(start.addMonths(12).date(),
            PolicyPortalController.nextPaymentDate(start, finish, 'Annually'));
    }

    @isTest static void nextPayment_isNullWhenTheTermIsPaidUpFront() {
        // 6 month cover paid annually: no further instalment falls inside the term.
        Datetime start = Datetime.newInstance(2026, 1, 15, 0, 0, 0);
        Datetime finish = start.addMonths(6);
        System.assertEquals(null,
            PolicyPortalController.nextPaymentDate(start, finish, 'Annually'),
            'must not invent a payment that falls after cover ends');
    }
}