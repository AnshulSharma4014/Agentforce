# Policy Data Access — Structured Grounding and Its Security Model

> The deterministic half of the agent: how a customer's own policy records are reached,
> and why the LLM can never widen that reach.

| | |
|---|---|
| **Covers** | `User_Policy__c`, `PolicyAccessService`, `ListMyPolicies`, `GetPolicyDetails`, `Policy_Actions_for_LLM` |
| **Related** | [Architecture](architecture.md) · [Agent design](agent-design.md) · [Deployment](deployment.md) |

---

## 1. Why this exists

Runbook §B.6 flagged the decision and this is the build-out of it: **do not vectorise
structured records.** A retriever asked "when does my policy expire?" returns the chunks that
*look* most like the question — from any document, for any customer. A SOQL query filtered on
the verified contact returns that customer's row or nothing at all. For policy numbers,
statuses, dates and amounts, "nothing at all" is the correct failure and semantic similarity
is not an acceptable substitute.

So the structured path is ordinary Apex, and the whole design effort went into one question:
**what identity is the query scoped to, and can anything in the conversation influence it?**

---

## 2. Data model

`User_Policy__c` — "Northwind customer policy records."

| Field | Type | Notes |
|---|---|---|
| `Name` | Auto Number `POL-{000000}` | The policy number the customer sees |
| `Contact__c` | Lookup → Contact | **The authorization key.** Every query filters on it |
| `Account__c` | Lookup → Account | Reporting only; not used for access control |
| `Policy_Type__c` | Text | Auto / Home / etc. |
| `Status__c` | Text | `Active`, `Pending`, `Suspended`, `Cancelled`, `Expired` |
| `Effective_Date__c`, `Expiration_Date__c`, `Next_Payment_Due_Date__c` | Date | |
| `Payment_Frequency__c` | Text | |
| `Premium_Amount__c`, `Deductable__c`, `Sum_Insured__c` | Currency(18,2) | |
| `Agent__c` | Text | Servicing agent name |

Sharing model: `Private` externally, `ReadWrite` internally. `Status__c` is a plain text
field, so the status vocabulary lives in `PolicyAccessService` constants rather than in a
picklist — worth converting to a picklist before production.

---

## 3. Identity and authorization

### The chain

```
$Context.MessagingEndUserId              (platform-set on the messaging session)
   -> MessagingEndUser.AuthenticatedEndUserId    (null for guests)
   -> User.ContactId                             (the verified Contact)
   -> WHERE Contact__c = :contactId              (every customer-data query)
```

Every hop is platform-managed. The agent supplies `endUserId` from the linked variable
`@MessagingSession.MessagingEndUserId`; it is never collected from the user and never
inferred by the model.

### Four invariants

1. **Fail closed.** A missing hop — blank id, unknown `MessagingEndUser`, guest session
   (`AuthenticatedEndUserId` null), authenticated user with no linked Contact — yields a null
   `contactId`, and every entry point returns `found = false` with an empty result. There is
   no fallback path that queries without a contact.
2. **A policy number is a selector, not an authorization.** `GetPolicyDetails` re-resolves
   the contact on *every* invocation and composes it with the number. A number that arrived
   at turn 3 and is replayed at turn 20 still gets checked against the contact resolved at
   turn 20.
3. **No enumeration oracle.** Not-owned and nonexistent return byte-identical results: same
   `found`, same counts, same `message` (`No policy matching that number was found on this
   account.`). Do not add a friendlier "that policy exists but isn't yours" branch.
4. **Matching happens in memory, over the caller's own rows only.** The candidate set is
   contact-scoped by SOQL (capped at `LOOKUP_SCAN_MAX` = 200) *before* any number comparison.
   A loose match therefore cannot reach another customer's record — deliberately safer than a
   SOQL `LIKE` on `Name`.

### The one deliberate elevation

Identity derivation runs in an inner `IdentityResolver` class declared **without sharing**,
and its queries omit `WITH USER_MODE`. This is narrow and intentional:

- The Agentforce service user has no sharing visibility of community `User` records, so hop 2
  (`User.ContactId`) would return nothing and *every legitimate customer* would fail closed.
- The only input is a platform-set context id; no user- or LLM-supplied value reaches it.
- Each query is Id-equality on a single record derived from the previous hop.
- The only field read is `ContactId` — no customer data is selected there.
- Object and field permissions still apply; only record sharing is bypassed.
- Customer data (`User_Policy__c`) is queried elsewhere, under `with sharing` **and**
  `WITH USER_MODE`. The elevation does not extend to it.

The alternative — granting *View All Users* to the agent user — is materially broader: it
exposes every user record in the org rather than one field on one platform-designated record.

---

## 4. The classes

### `PolicyAccessService` (non-invocable core)

Owns identity resolution, querying and rendering, so the invocables own none of it.

| Member | Purpose |
|---|---|
| `LIST_MAX = 5` | Presentation cap for listings. **Not** a limit on what a customer may look up |
| `LOOKUP_SCAN_MAX = 200` | Upper bound on the per-contact candidate set scanned during number matching |
| `resolveVerifiedContactIds(List<String>)` | Bulkified resolution — two queries for any number of requests, no SOQL in loops |
| `listPolicies(contactId, scope, maxRows)` | Status-filtered, expiration ascending, `+1` row fetched to detect overflow |
| `findPolicyByNumber(contactId, rawInput)` | Format-agnostic single-policy lookup |
| `Result` | `found`, `truncated`, `ambiguous`, `policyCount`, `policies` (JSON), `policiesHtml`, `policiesText`, `message` |

**Scope tokens** (`statusesFor`): `ACTIVE` (default), `CURRENT` = Active + Pending +
Suspended, `HISTORICAL` = Cancelled + Expired, `ALL` = no filter, or an explicit
comma-separated status list such as `Expired,Cancelled`. Unrecognised input falls back to
`ACTIVE` — **it must never silently widen the filter**.

**Number normalisation** (`normalizeNumber`): strips non-digits and leading zeros, so
`1007`, `P-0001007` and `0001007` all resolve to the same record; all-zero input normalises
to `0`; input with no digits returns null and yields "No policy number was provided."
Multiple matches set `ambiguous = true` and list the candidates — safe, because every
candidate already belongs to the caller.

### `ListMyPolicies` (invocable)

"Show me my policies." Defaults to **ACTIVE only**, soonest expiry first, max 5, with
`truncated` set when more exist. Resolves all identities up front, then loops.

### `GetPolicyDetails` (invocable)

One policy by number, in whatever form the customer typed it. Deliberately **not** capped to
the top 5 and **not** status-filtered: any policy the caller owns is retrievable, expired
ones included.

### `GetMyPolicies` (superseded)

An earlier all-in-one invocable that carries its own copy of the resolver and query logic. It
is not referenced by the current agent. Keep it only as history — new work belongs in
`PolicyAccessService`.

---

## 5. The Flow wrapper

[`Policy_Actions_for_LLM`](../force-app/main/default/flows/Policy_Actions_for_LLM.flow-meta.xml)
(Autolaunched, Active) is the single action the agent sees.

**Inputs**

| Name | Meaning |
|---|---|
| `callableApexAction` | `listMyPolicies` or `getPolicyDetails` — the decision `Which Apex Action to Call?` branches on it |
| `endUserId` | Bound to the agent's `EndUserId` variable → `$Context.MessagingEndUserId` |
| `policyNumber` | Passed verbatim from the customer; required for `getPolicyDetails` |
| `policyScope` | `ACTIVE` / `CURRENT` / `HISTORICAL` / `ALL` |

**Outputs**: `found`, `policyCount`, `truncated`, `policiesInJSON`, `policiesInHTML`,
`policiesInPlainText`. In the agent script only `policiesInPlainText` is marked displayable —
the other shapes exist for future channel work (rich messaging, Experience Cloud) without an
Apex change.

`LLM_Apex_Actions` is the previous iteration of this flow and is `Obsolete`; the agent script
version that targeted it (`Northwind_RAG_Original_21`) is retained for history.

---

## 6. Tests

[`PolicyAccessServiceTest`](../force-app/main/default/classes/PolicyAccessServiceTest.cls)
covers 28 cases, organised around the invariants rather than around methods:

- **Scope:** default is active-only; `CURRENT`/`HISTORICAL`/`ALL`; explicit status lists;
  unrecognised scope does not widen.
- **Listing:** expiration ordering; cap of 5 with the overflow flag; contact scoping; null
  contact fails closed.
- **Lookup:** exact number; leading zeros and prefixes ignored; expired policies; policies
  outside the top 5; **not-owned indistinguishable from nonexistent**; null contact fails
  closed; blank and non-numeric input.
- **Resolver:** blank/malformed input, empty and null lists, unknown end user.
- **Invocables:** unresolved identity fails closed; bulk-safe with no SOQL in loops; empty
  and null request lists.
- **Rendering:** all three shapes present; empty results carry no markup.

`MessagingEndUser` records cannot be inserted in tests, so the *authenticated* branch of the
resolver is validated by an integration test in a real messaging session, not by unit tests.
That is why `queryPolicies`/`listPolicies` take a `contactId` parameter: it makes the
authorization logic directly testable.

Run them:

```bash
sf apex run test --tests PolicyAccessServiceTest --result-format human --wait 10
```

---

## 7. Permissions the agent user needs

[`Northwind_Agent_Policy_Access`](../force-app/main/default/permissionsets/Northwind_Agent_Policy_Access.permissionset-meta.xml)
grants exactly:

- Read on `User_Policy__c` (plus field-level read on every field the queries select), `Contact`,
  `Account`, and `MessagingEndUser`.
- Field read on `MessagingEndUser.AuthenticatedEndUserId` — **the resolver silently fails
  closed without this**, which presents as "I couldn't find any policies" for every customer.
- `AccessGeniePlatform`, `ExecutePromptTemplates`, `ManagePromptTemplates`.
- Data Cloud `default` data space scope.

No create, edit or delete anywhere. If policy answers come back empty for everyone, check
this permission set before debugging the code.

---

## 8. Extending this safely

- **New field on the answer?** Add it to the `SELECT` lists in `listPolicies` *and*
  `findPolicyByNumber`, to `populate`, and to the permission set's field permissions.
- **New action?** Put the logic in `PolicyAccessService`, add a thin invocable, then add a
  branch to `Policy_Actions_for_LLM` and re-activate the flow.
- **Never** add a parameter that lets the caller specify a contact, account or user id. The
  contact is derived, always.
- **Never** make a not-found response more informative. The generic message is the control.
- Keep identity resolution bulkified — resolve first, then loop.
