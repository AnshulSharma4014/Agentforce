/**
 * GetPolicyDetails
 * ----------------
 * Agentforce invocable: look up ONE policy by the number the user supplied,
 * whether typed, clicked, or carried in conversation context.
 *
 * ============================ SECURITY NOTE ============================
 * The policy number is a SELECTOR, not an authorization. It arrives from the
 * conversation and is therefore untrusted at every turn — including turn 20,
 * when it may have come from a variable set at turn 3. The contact is ALWAYS
 * re-resolved from the messaging session on each invocation and composed with
 * the number. A number belonging to another customer returns exactly what a
 * nonexistent number returns.
 *
 * NOT limited to the top-5 listing and NOT status-filtered: any policy the
 * caller owns is retrievable here, including expired ones.
 * =======================================================================
 */
public with sharing class GetPolicyDetails {

    public class Request {
        // Bind to $Context.MessagingEndUserId. Never collect from the user.
        @InvocableVariable(
            label='Messaging End User Id (bind to $Context.MessagingEndUserId)')
        public String messagingEndUserId;

        @InvocableVariable(
            required=true
            label='Policy Number (as the user gave it — partial or prefixed is fine)')
        public String policyNumber;
    }

    @InvocableMethod(
        label='Get Policy Details'
        description='Retrieves one policy belonging to the signed-in customer by policy number. Accepts the number in any form the user typed, with or without a prefix or leading zeros. Works for ANY policy the customer owns, including expired ones and ones not shown in the list. Identity comes from the messaging session; never ask the user who they are or which account they hold.'
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

            out.add(PolicyAccessService.findPolicyByNumber(
                contactId,                                  // null => fail closed
                req == null ? null : req.policyNumber));
        }
        return out;
    }
}