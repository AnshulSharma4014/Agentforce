/**
 * PolicyAccessService
 * -------------------
 * Shared, non-invocable core for the Northwind policy actions.
 *
 * Owns three things, so the two invocable entry points own none of them:
 *   1. Identity resolution from the messaging session (server-side, bulkified).
 *   2. Contact-scoped querying of User_Policy__c.
 *   3. Rendering (JSON / HTML / text).
 *
 * ============================ SECURITY NOTES ============================
 * 1. Identity chain (all hops platform-managed => non-spoofable):
 *      $Context.MessagingEndUserId
 *        -> MessagingEndUser.AuthenticatedEndUserId   (null for guests)
 *        -> User.ContactId
 *    `AuthenticatedEndUserId` is set by the platform at authentication. The null
 *    check IS the guest gate; the LLM/client cannot forge it. Any missing hop =>
 *    null contactId => fail closed.
 *
 * 2. `Contact__c = :contactId` is the SOLE authorization control on policy data.
 *    contactId is derived here, NEVER accepted from the user, the LLM, or a
 *    conversation variable. A policy number supplied by the user is a SELECTOR,
 *    not an authorization: every lookup composes it with the resolved contact.
 *
 * 3. NO ENUMERATION ORACLE: not-owned and nonexistent are indistinguishable —
 *    same `found`, same counts, same `message`. Do not add a "that policy exists
 *    but isn't yours" branch, however helpful it sounds.
 *
 * 4. Number matching runs in memory over the CALLER'S OWN policies only. The
 *    candidate set is contact-scoped before any matching occurs, so a loose
 *    match can never reach another customer's record. This is deliberately
 *    safer than SOQL `LIKE` on Name.
 *
 * 5. Resolution queries run WITHOUT USER_MODE and, in the IdentityResolver inner
 *    class, WITHOUT SHARING. Both are deliberate and narrow: identity derivation
 *    reads one field (User.ContactId) on one platform-designated record. Trust is
 *    that AuthenticatedEndUserId is platform-set, not that FLS or sharing gates it.
 *    Customer-data queries keep `with sharing` AND `WITH USER_MODE` — the elevation
 *    does not extend to them. See IdentityResolver for the full rationale.
 *    The Agent User needs read on MessagingEndUser.AuthenticatedEndUserId.
 * =======================================================================
 */
public with sharing class PolicyAccessService {

    // Listing cap (Requirement 2). Lookup is deliberately NOT bound by this.
    public static final Integer LIST_MAX = 5;

    // Upper bound on the per-contact candidate set scanned during number matching.
    public static final Integer LOOKUP_SCAN_MAX = 200;

    private static final Set<String> ACTIVE_ONLY  = new Set<String>{ 'Active' };
    private static final Set<String> CURRENT      = new Set<String>{ 'Active', 'Pending', 'Suspended' };
    private static final Set<String> HISTORICAL   = new Set<String>{ 'Cancelled', 'Expired' };
    private static final Set<String> ALL_STATUSES = new Set<String>{
        'Active', 'Pending', 'Suspended', 'Cancelled', 'Expired'
    };

    // Single generic not-found message. Used for BOTH not-owned and nonexistent.
    @TestVisible
    private static final String MSG_NOT_FOUND =
        'No policy matching that number was found on this account.';

    /* ====================================================================
     * Result
     * ==================================================================== */

    public class Result {
        @InvocableVariable(label='Found') public Boolean found;
        @InvocableVariable(label='Truncated (more exist than returned)') public Boolean truncated;
        @InvocableVariable(label='Ambiguous (input matched multiple policies)') public Boolean ambiguous;
        @InvocableVariable(label='Policy Count') public Integer policyCount;
        @InvocableVariable(label='Policies (JSON)') public String policies;
        @InvocableVariable(label='Policies (HTML)') public String policiesHtml;
        @InvocableVariable(label='Policies (Plain Text)') public String policiesText;
        @InvocableVariable(label='Message') public String message;

        public Result() {
            this.found = false;
            this.truncated = false;
            this.ambiguous = false;
            this.policyCount = 0;
            this.policies = '[]';
            this.policiesHtml = '';
            this.policiesText = '';
            this.message = '';
        }
    }

    /* ====================================================================
     * Identity resolution — bulkified (no SOQL in loops)
     * ==================================================================== */

    /**
     * Resolve many messaging end user ids to verified Contact ids in two queries.
     * Unresolvable inputs are simply absent from the returned map => caller fails closed.
     */
    public static Map<String, Id> resolveVerifiedContactIds(List<String> messagingEndUserIds) {
        return new IdentityResolver().resolve(messagingEndUserIds);
    }

    /**
     * FALLBACK identity: the Contact of the user actually running this transaction.
     *
     * WHY IT EXISTS: on authenticated Experience Cloud messaging, Agentforce executes
     * actions AS THE SIGNED-IN CUSTOMER, not as the agent user. That identity cannot read
     * MessagingEndUser — the object is not in the Customer Community Plus license, so no
     * permission set can grant it — and hop 1 therefore fails for every real site session.
     * Here the running user IS the customer, so their own Id is the identity.
     *
     * WHY IT IS NOT A HOLE: there is no input. The only value that can ever come back is
     * the running user's own ContactId. UserInfo.getUserId() is platform-set and cannot be
     * forged, supplied by the LLM, or influenced by anything in the conversation. It cannot
     * return another customer's contact under any circumstance.
     *
     * GUEST GATE: `UserInfo.getUserType() == 'Guest'` is rejected outright, and any user
     * without a linked Contact returns null. Both fail closed. This — not the presence of a
     * MessagingEndUserId — is the authentication check: every messaging session has a
     * MessagingEndUser record, guests included, so its presence proves a session exists,
     * never that the person is signed in.
     *
     * Cached per transaction: one query no matter how many requests are bulkified.
     */
    public static Id resolveRunningUserContactId() {
        if (runningUserContactLoaded) return runningUserContact;
        runningUserContactLoaded = true;          // set first: never retry per row
        runningUserContact = null;

        if ('Guest'.equalsIgnoreCase(UserInfo.getUserType())) {
            return null;                          // unauthenticated => fail closed
        }
        List<User> us = [
            SELECT ContactId FROM User WHERE Id = :UserInfo.getUserId() LIMIT 1
        ];
        if (!us.isEmpty()) runningUserContact = us[0].ContactId;
        return runningUserContact;                // null for internal users => fail closed
    }

    // Per-transaction cache for the fallback identity. @TestVisible so tests can reset it.
    @TestVisible
    private static Boolean runningUserContactLoaded = false;
    @TestVisible
    private static Id runningUserContact = null;

    /**
     * Identity derivation runs WITHOUT SHARING, deliberately and narrowly.
     *
     * WHY: the running identity is the Agentforce service user, which has no sharing
     * visibility of community User records. Without this, hop 2 (User.ContactId) returns
     * nothing and the resolver fails closed for every legitimate customer.
     *
     * WHY THIS IS NOT A HOLE:
     *   - The only input is $Context.MessagingEndUserId, set by the platform. No user-
     *     or LLM-supplied value reaches these queries.
     *   - Each query is Id-equality on a single record, derived from the previous hop.
     *   - The only field read out is ContactId. No customer data is selected here.
     *   - Object-level and FLS permissions still apply; only record sharing is bypassed.
     *   - Customer data (User_Policy__c) is queried elsewhere, under `with sharing`
     *     AND `WITH USER_MODE`. This elevation does not extend to it.
     *
     * The narrower alternative would be granting "View All Users" to the agent user,
     * which is materially broader: it exposes every user record in the org rather than
     * one field on one platform-designated record.
     */
    private without sharing class IdentityResolver {

        public Map<String, Id> resolve(List<String> messagingEndUserIds) {
            Map<String, Id> out = new Map<String, Id>();
            if (messagingEndUserIds == null || messagingEndUserIds.isEmpty()) return out;

            // Coerce to Id, discarding blanks and malformed values.
            Map<Id, String> meuIdToRaw = new Map<Id, String>();
            for (String raw : messagingEndUserIds) {
                if (String.isBlank(raw)) continue;
                try {
                    meuIdToRaw.put((Id) raw.trim(), raw);
                } catch (Exception e) {
                    // malformed => fail closed, no entry
                }
            }
            if (meuIdToRaw.isEmpty()) return out;

            // Hop 1: messaging end user -> authenticated User (null for guests).
            Map<Id, Id> meuToUser = new Map<Id, Id>();
            Set<Id> userIds = new Set<Id>();
            Set<Id> meuIds = meuIdToRaw.keySet();
            
            try {
                for (MessagingEndUser meu : [
                    SELECT Id, AuthenticatedEndUserId
                    FROM MessagingEndUser
                    WHERE Id IN :meuIds
                ]) {
                    if (meu.AuthenticatedEndUserId == null) continue;   // GUEST => fail closed
                    meuToUser.put(meu.Id, meu.AuthenticatedEndUserId);
                    userIds.add(meu.AuthenticatedEndUserId);
                }
            } catch (System.QueryException e) {
                // MessagingEndUser is not available to every license — Customer Community
                // Plus among them — so this THROWS rather than returning nothing, and the
                // raw error is the near-undebuggable "Variable does not exist: tmpVar1".
                // That is the normal case on authenticated Experience Cloud messaging,
                // where Agentforce runs actions as the signed-in customer.
                //
                // Return empty and let the caller fall back to the running user's own
                // contact (resolveRunningUserContactId). Logged, not silent, because a
                // failure here in an AGENT-user context would mean something is wrong.
                System.debug(LoggingLevel.ERROR,
                    'MessagingEndUser unreadable for running user '
                    + UserInfo.getUserName() + ' (' + UserInfo.getUserType()
                    + '); falling back to running-user identity. ' + e.getMessage());
                return out;
            }
            if (userIds.isEmpty()) return out;

            // Hop 2: User -> Contact. ContactId is the ONLY field read.
            Map<Id, Id> userToContact = new Map<Id, Id>();
            for (User u : [SELECT Id, ContactId FROM User WHERE Id IN :userIds]) {
                if (u.ContactId == null) continue;   // authenticated but no Contact => fail closed
                userToContact.put(u.Id, u.ContactId);
            }

            for (Id meuId : meuToUser.keySet()) {
                Id contactId = userToContact.get(meuToUser.get(meuId));
                if (contactId != null) {
                    out.put(meuIdToRaw.get(meuId), contactId);
                }
            }
            return out;
        }
    }

    /* ====================================================================
     * Status scope
     * ==================================================================== */

    /**
     * Resolve a scope token to a status filter.
     * Default (null/blank/unrecognised) is ACTIVE ONLY.
     * Accepts: ACTIVE | CURRENT | HISTORICAL | ALL | comma-separated status names.
     * Returns null to mean "no status filter" (ALL).
     */
    @TestVisible
    private static Set<String> statusesFor(String scope) {
        if (String.isBlank(scope)) return ACTIVE_ONLY;

        String s = scope.trim().toUpperCase();
        if (s == 'ACTIVE')     return ACTIVE_ONLY;
        if (s == 'CURRENT')    return CURRENT;
        if (s == 'HISTORICAL') return HISTORICAL;
        if (s == 'ALL')        return null;

        // Explicit status list, e.g. "Expired,Cancelled".
        Set<String> explicitStatuses = new Set<String>();
        for (String part : scope.split(',')) {
            String candidate = part.trim().toLowerCase();
            for (String valid : ALL_STATUSES) {
                if (valid.toLowerCase() == candidate) explicitStatuses.add(valid);
            }
        }
        // Unrecognised input must not silently widen the filter.
        return explicitStatuses.isEmpty() ? ACTIVE_ONLY : explicitStatuses;
    }

    /* ====================================================================
     * Listing
     * ==================================================================== */

    /**
     * Policies for one contact, status-filtered, expiration ascending, capped.
     * Public so the invocable classes can call it, and so authorization is
     * unit-tested directly with contactId values rather than through the resolver.
     */
    public static Result listPolicies(Id contactId, String scope, Integer maxRows) {
        Result r = new Result();
        if (contactId == null) return r;   // FAIL CLOSED (unresolved / guest)

        Integer cap = (maxRows == null || maxRows <= 0) ? LIST_MAX : maxRows;
        Integer q = cap + 1;               // +1 detects overflow
        Set<String> statuses = statusesFor(scope);

        List<User_Policy__c> rows;
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

        if (rows.size() > cap) {
            r.truncated = true;
            while (rows.size() > cap) rows.remove(rows.size() - 1);
        }

        populate(r, rows, false);
        if (!r.found) {
            r.message = 'No matching policies were found on this account.';
        }
        return r;
    }

    /* ====================================================================
     * Lookup by policy number
     * ==================================================================== */

    /**
     * Find one policy by a user-supplied number, within the caller's own policies.
     *
     * Deliberately NOT limited to the listing cap and NOT status-filtered — a user
     * may ask about any policy they own, including expired ones and ones outside
     * the displayed top 5.
     *
     * Matching is format-agnostic: both the input and each candidate Name are
     * reduced to significant digits, so "1007", "P-0001007" and "0001007" all
     * resolve to the same record.
     */
    public static Result findPolicyByNumber(Id contactId, String rawInput) {
        Result r = new Result();
        if (contactId == null) return r;   // FAIL CLOSED

        String needle = normalizeNumber(rawInput);
        if (needle == null) {
            r.message = 'No policy number was provided.';
            return r;
        }

        // Contact-scoped BEFORE any matching. This is the authorization boundary.
        Integer scanCap = LOOKUP_SCAN_MAX;
        List<User_Policy__c> candidates = [
            SELECT Name, Policy_Type__c, Status__c, Effective_Date__c, Expiration_Date__c,
                   Next_Payment_Due_Date__c, Payment_Frequency__c, Premium_Amount__c,
                   Deductable__c, Sum_Insured__c
            FROM User_Policy__c
            WHERE Contact__c = :contactId
            WITH USER_MODE
            ORDER BY Expiration_Date__c ASC NULLS LAST
            LIMIT :scanCap
        ];

        List<User_Policy__c> matches = new List<User_Policy__c>();
        for (User_Policy__c p : candidates) {
            if (needle == normalizeNumber(p.Name)) matches.add(p);
        }

        if (matches.isEmpty()) {
            // Identical response for not-owned and nonexistent. Do not differentiate.
            r.message = MSG_NOT_FOUND;
            return r;
        }

        if (matches.size() > 1) {
            // Ambiguous only among the caller's OWN policies, so listing them is safe.
            r.ambiguous = true;
            populate(r, matches, true);
            r.message = 'That number matches more than one of your policies. '
                      + 'Please confirm which one you mean.';
            return r;
        }

        populate(r, matches, true);
        return r;
    }

    /**
     * Reduce any policy-number representation to significant digits.
     * Strips non-digits and leading zeros so partial and prefixed forms match.
     * Returns null when the input carries no digits at all.
     */
    @TestVisible
    private static String normalizeNumber(String input) {
        if (String.isBlank(input)) return null;
        String digits = input.replaceAll('[^0-9]', '');
        if (String.isBlank(digits)) return null;
        String trimmed = digits.replaceFirst('^0+', '');
        return String.isBlank(trimmed) ? '0' : trimmed;   // input was all zeros
    }

    /* ====================================================================
     * Rendering
     * ==================================================================== */

    /**
     * Populate the three output shapes.
     * `detailed` = full field set (single-policy view); otherwise a compact
     * picker view — the list is for choosing, not for disclosing everything.
     */
    private static void populate(Result r, List<User_Policy__c> rows, Boolean detailed) {
        Date today = Date.today();
        List<Map<String, Object>> out = new List<Map<String, Object>>();

        for (User_Policy__c p : rows) {
            Map<String, Object> m = new Map<String, Object>{
                'policyNumber'   => p.Name,
                'policyType'     => p.Policy_Type__c,
                'status'         => p.Status__c,
                'expirationDate' => dateStr(p.Expiration_Date__c)
            };
            if (detailed) {
                m.put('effectiveDate',      dateStr(p.Effective_Date__c));
                m.put('nextPaymentDueDate', p.Next_Payment_Due_Date__c == null
                                              ? null : String.valueOf(p.Next_Payment_Due_Date__c));
                m.put('paymentFrequency',   p.Payment_Frequency__c);
                m.put('premiumAmount',      p.Premium_Amount__c);
                m.put('deductible',         p.Deductable__c);
                m.put('sumInsured',         p.Sum_Insured__c);
                m.put('daysToExpiration',   p.Expiration_Date__c == null
                                              ? null : today.daysBetween(p.Expiration_Date__c.date()));
                m.put('daysToNextPayment',  p.Next_Payment_Due_Date__c == null
                                              ? null : today.daysBetween(p.Next_Payment_Due_Date__c));
            }
            out.add(m);
        }

        r.policyCount  = out.size();
        r.found        = !out.isEmpty();
        r.policies     = JSON.serialize(out);
        r.policiesHtml = toHtml(rows, detailed);
        r.policiesText = toText(rows, detailed);
    }

    private static String dateStr(Datetime dt) {
        return dt == null ? null : String.valueOf(dt.date());
    }

    // escapeHtml4 is an INSTANCE method on String in Apex (unlike escapeSingleQuotes,
    // which is static). Calling it as String.escapeHtml4(s) will not compile.
    private static String esc(String s) {
        return String.isBlank(s) ? '' : s.escapeHtml4();
    }

    /**
     * HTML for Adaptive Response Formats.
     * All values originate from picklists, auto-number, numeric and date fields —
     * there is no free-text field on the object — but everything is escaped anyway.
     */
    private static String toHtml(List<User_Policy__c> rows, Boolean detailed) {
        if (rows == null || rows.isEmpty()) return '';

        if (detailed && rows.size() == 1) {
            User_Policy__c p = rows[0];
            String h = '<div><h3>Policy ' + esc(p.Name) + '</h3><ul>';
            h += '<li><b>Type:</b> ' + esc(p.Policy_Type__c) + '</li>';
            h += '<li><b>Status:</b> ' + esc(p.Status__c) + '</li>';
            h += '<li><b>Effective:</b> ' + esc(dateStr(p.Effective_Date__c)) + '</li>';
            h += '<li><b>Expires:</b> ' + esc(dateStr(p.Expiration_Date__c)) + '</li>';
            if (p.Premium_Amount__c != null) {
                h += '<li><b>Premium:</b> ' + String.valueOf(p.Premium_Amount__c) + '</li>';
            }
            if (p.Deductable__c != null) {
                h += '<li><b>Deductible:</b> ' + String.valueOf(p.Deductable__c) + '</li>';
            }
            if (p.Sum_Insured__c != null) {
                h += '<li><b>Sum insured:</b> ' + String.valueOf(p.Sum_Insured__c) + '</li>';
            }
            if (p.Next_Payment_Due_Date__c != null) {
                h += '<li><b>Next payment due:</b> '
                   + esc(String.valueOf(p.Next_Payment_Due_Date__c)) + '</li>';
            }
            h += '</ul></div>';
            return h;
        }

        String h = '<ul>';
        for (User_Policy__c p : rows) {
            h += '<li><b>' + esc(p.Name) + '</b> — ' + esc(p.Policy_Type__c)
               + ' (' + esc(p.Status__c) + ')';
            if (p.Expiration_Date__c != null) {
                h += ', expires ' + esc(dateStr(p.Expiration_Date__c));
            }
            h += '</li>';
        }
        return h + '</ul>';
    }

    /** Plain-text fallback for channels that do not render HTML. */
    private static String toText(List<User_Policy__c> rows, Boolean detailed) {
        if (rows == null || rows.isEmpty()) return '';

        List<String> lines = new List<String>();
        if (detailed && rows.size() == 1) {
            User_Policy__c p = rows[0];
            lines.add('Policy ' + p.Name);
            lines.add('Type: ' + p.Policy_Type__c);
            lines.add('Status: ' + p.Status__c);
            lines.add('Effective: ' + dateStr(p.Effective_Date__c));
            lines.add('Expires: ' + dateStr(p.Expiration_Date__c));
            if (p.Premium_Amount__c != null) lines.add('Premium: ' + p.Premium_Amount__c);
            if (p.Deductable__c != null)     lines.add('Deductible: ' + p.Deductable__c);
            if (p.Sum_Insured__c != null)    lines.add('Sum insured: ' + p.Sum_Insured__c);
            if (p.Next_Payment_Due_Date__c != null) {
                lines.add('Next payment due: ' + p.Next_Payment_Due_Date__c);
            }
            return String.join(lines, '\n');
        }

        Integer i = 1;
        for (User_Policy__c p : rows) {
            String line = i + '. ' + p.Name + ' — ' + p.Policy_Type__c + ' (' + p.Status__c + ')';
            if (p.Expiration_Date__c != null) line += ', expires ' + dateStr(p.Expiration_Date__c);
            lines.add(line);
            i++;
        }
        return String.join(lines, '\n');
    }
}