/**
 * ListMyPolicies
 * --------------
 * Agentforce invocable: "show me my policies".
 *
 * Returns the caller's ACTIVE policies by default, expiration ascending,
 * capped at PolicyAccessService.LIST_MAX (5) with an overflow flag.
 *
 * The cap is a PRESENTATION limit only. GetPolicyDetails is not bound by it —
 * a user may ask about any policy they own, including ones outside this list.
 *
 * Identity is resolved server-side (see PolicyAccessService). The LLM never
 * supplies, and cannot influence, the contact used for scoping.
 */
public with sharing class ListMyPolicies {

    public class Request {
        // Bind to $Context.MessagingEndUserId. Never collect from the user.
        @InvocableVariable(
            label='Messaging End User Id (bind to $Context.MessagingEndUserId)')
        public String messagingEndUserId;

        @InvocableVariable(
            label='Scope: ACTIVE (default) | CURRENT | HISTORICAL | ALL | explicit status list')
        public String scope;
    }

    @InvocableMethod(
        label='List My Policies'
        description='Lists the signed-in customer\'s policies. Defaults to ACTIVE only, soonest expiry first, maximum 5. Identity comes from the messaging session; never ask the user who they are. To include cancelled or expired policies, set scope to HISTORICAL or ALL.'
        category='Northwind Policies')
    public static List<PolicyAccessService.Result> run(List<Request> requests) {
        List<PolicyAccessService.Result> out = new List<PolicyAccessService.Result>();
        if (requests == null || requests.isEmpty()) return out;

        // Resolve every identity up front — no SOQL inside the loop.
        List<String> meuIds = new List<String>();
        for (Request req : requests) {
            meuIds.add(req == null ? null : req.messagingEndUserId);
        }
        Map<String, Id> resolved = PolicyAccessService.resolveVerifiedContactIds(meuIds);

        for (Request req : requests) {
            Id contactId = (req == null || String.isBlank(req.messagingEndUserId))
                ? null
                : resolved.get(req.messagingEndUserId);

            // Fallback: the messaging chain is unreadable when Agentforce runs the action
            // as the signed-in customer. Then the running user IS the customer, so use
            // their own contact. Never another's; guests and contactless users get null
            // and continue to fail closed.
            if (contactId == null) {
                contactId = PolicyAccessService.resolveRunningUserContactId();
            }

            out.add(PolicyAccessService.listPolicies(
                contactId,                          // null => fail closed
                req == null ? null : req.scope,
                PolicyAccessService.LIST_MAX));
        }
        return out;
    }
}