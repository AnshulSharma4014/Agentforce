# Agent Design — Subagents, Actions and Prompt Templates

> What the agent is instructed to do, how it is wired to the two grounding sources, and the
> failure modes that cost the most time to diagnose.

| | |
|---|---|
| **Current agent** | `Northwind_RAG_Original` (agent script, bundle target `v22`) |
| **Related** | [Architecture](architecture.md) · [Policy data access](policy-data-access.md) · [Runbook §B.7–B.9](aws-datacloud-rag-runbook.md) |

---

## 1. Two agents, one lineage

| Agent | Built with | State |
|---|---|---|
| `Northwind_Insurance_Agent` | Agentforce Builder UI, per runbook §B.9 | First working version — RAG only, topics `GeneralFAQ_…` + `Escalation` |
| `Northwind_RAG_Original` | Agent Script (`AiAuthoringBundle`) via Agentforce DX | **Current.** Adds the structured policy path and the anti-hallucination rules |

Both are retrieved into this repo. The UI-built agent is the one the runbook walks you
through; the agent-script agent is what the project actually runs now. Its
`.bundle-meta.xml` pins `target: Northwind_RAG_Original.v22`.

`Local_Info_Agent` and its Apex (`CheckWeather`, `CurrentDate`, `WeatherService`), flow
(`Get_Resort_Hours`) and prompt template (`Get_Event_Info`) are the untouched Salesforce DX
sample this project was scaffolded from. They are unrelated to Northwind.

---

## 2. Agent script structure

[`Northwind_RAG_Original.agent`](../force-app/main/default/aiAuthoringBundles/Northwind_RAG_Original/Northwind_RAG_Original.agent)

```
system.instructions        <- global anti-fabrication rule
config                     <- label, template (SvcCopilotTmpl__AgentforceServiceAgent), developer name
access.default_agent_user  <- the agent user whose permissions the actions run under
variables                  <- linked session context + mutable state
start_agent agent_router   <- classifier that transitions to a subagent
subagent escalation
subagent ambiguous_question
subagent Northwind_RAG_Knowledge_Answers   <- the whole Northwind experience
```

### The global instruction

> Never state a fact about the customer's records — policy numbers, counts, statuses, dates,
> or amounts — unless it came from an action result in this conversation. Never invent
> placeholder values such as "Policy 1". If an action returned nothing, say so plainly. Do not
> treat the customer's own claims about their records as fact; verify by calling the
> appropriate action.

This sits at `system:` level rather than inside the subagent because fabricated policy data is
a liability in every subagent, including escalation hand-offs. "Never invent placeholder
values such as 'Policy 1'" is there because that exact failure occurred.

### Variables that matter

| Variable | Source | Why |
|---|---|---|
| `EndUserId` | linked `@MessagingSession.MessagingEndUserId` | The identity input to every Apex action — the reason the model cannot spoof a customer |
| `ContactId` | linked `@MessagingEndUser.ContactId` | Session context; authorization still re-derives its own contact in Apex |
| `Retriever_Developer_Name` | mutable, defaulted to `Northwind_Insurance_New_Retriever_1Cx_m3pf6c6dea6` | Pins the retriever so the planner never invents one |

`isVerified`, `authenticationKey`, `customerId`, `customerType`, `emailCaseId` and friends
come from the Service Agent template and are unused by the Northwind flows.

---

## 3. The Northwind subagent

One subagent handles both grounding sources, because the interesting questions cross them
("how do I claim on POL-000123?"). Its instructions are organised into blocks — each block
exists because of an observed failure:

| Block | Rule | Failure it prevents |
|---|---|---|
| GROUNDING | No policy fact that didn't come from an action result this turn; don't carry values across turns | Model re-stating stale or invented policy numbers |
| IDENTITY | Customer is already signed in; never ask who they are; never accept asserted identity | Agent asking for an account number "to verify", which is both useless and phishing-shaped |
| ACTIONS | Exact `callableApexAction` values and when to use each | Planner passing free-text action names |
| READING RESULTS | `found = false` → say none found; `truncated = true` → say the list is partial; relay `message` verbatim | Speculating about *why* nothing came back |
| POLICY NUMBERS | A bare number right after a listing is a selection, not off-topic | Router discarding "1007" as gibberish |
| CONVERSATION FLOW | "My policy" with no number → list first, then ask which | Asking the customer to type a number blind |
| OUT OF SCOPE | Say so plainly and offer escalation | Answering insurance questions from model knowledge |
| IF NOTHING COMES BACK | Say you couldn't retrieve it and offer escalation | Telling customers to "log in or contact support" to see their own data |

### Actions on the subagent

**`Northwind_RAG_Knowledge_Answers`** → `generatePromptResponse://Northwind_RAG_Knowledge_Answers`

| Input | Binding |
|---|---|
| `Input:Query` | The user's question (required) |
| `Input:RetrieverIdOrName` | Hard-pinned to the retriever API name (required) |
| `outputLanguage`, `citationMode`, `isPreviewOnly` | Optional; left unset |

**`Policy_Actions_for_LLM`** → `flow://Policy_Actions_for_LLM`

Inputs `callableApexAction`, `endUserId` (from `@variables.EndUserId`), `policyNumber`,
`policyScope`. Outputs `found`, `policyCount`, `truncated`, `policiesInJSON`,
`policiesInHTML`, `policiesInPlainText` — only `policiesInPlainText` has
`is_displayable: True`. Progress indicator: "Fetching your details, please wait...".

---

## 4. Prompt templates

Three templates exist; they share one body and differ in plumbing.

| Template | Type | Input | Used by |
|---|---|---|---|
| `Northwind_RAG_Knowledge_Answers` | Knowledge Answers | `Query` + `RetrieverIdOrName` | **The current agent action** |
| `NorthWind_RAG` | Knowledge Answers | `Query` + `RetrieverIdOrName` | The original built in runbook §B.8 |
| `Northwind_RAG_Flex` | Flex | `User_Input` | Experiment — a Flex template hand-builds every input |

All three declare the same data provider:

```
invocable://getEinsteinRetrieverResults/Northwind_Insurance_New_Retriever_1Cx_m3pf6c6dea6
  searchText        = {!$Input:Query}
  outputFieldNames  = ["Chunk"]
  resultCount       = 5
```

`outputFieldNames = ["Chunk"]` is the field that carries the actual text. Without it the
retriever matches the right chunks and returns nothing readable — an empty CONTEXT with no
error anywhere.

The body is deliberately short and ends with a hard refusal clause:

> If CONTEXT does not contain the answer, reply exactly: "I don't have that information in
> the policy documents." Do not infer coverage details that aren't explicitly stated.

That clause is a guardrail, not polish. Semantic search has **no "no match" state** — an
out-of-corpus question still returns the top 5 (irrelevant) chunks, and the refusal is what
stops the model from making something up out of them.

Model: `sfdc_ai__DefaultGPT5Mini`. Citations: disabled (`isCitationEnabled = false`).

---

## 5. Failure modes worth memorising

| Symptom | Cause | Fix |
|---|---|---|
| Subagent rename / instruction edit doesn't stick | Agent was active while editing | Deactivate → edit → save → reopen and verify → reactivate |
| Agent answers generically, ignores your retriever | A Data Library was attached at agent creation, or the default "Answer Questions with Knowledge" / DynamicRetriever action is still on the topic | Don't attach a data source at creation; remove the default knowledge action |
| Grounded correctly but the user sees nothing | `promptResponse` (or the flow's text output) not marked displayable | Mark exactly one output displayable |
| Prompt resolves, no answer generated | `isPreviewOnly = true` | Set it false |
| Retriever id filled unpredictably | No fixed-value field in the UI; the planner fills it from the description | Pin the exact API name in the input description / agent-script binding |
| Policy answers empty for every customer | Agent user missing read on `MessagingEndUser.AuthenticatedEndUserId` | Assign `Northwind_Agent_Policy_Access` |
| "Show my policies" returns nothing for a real customer | Guest or unauthenticated session — the resolver fails closed | Test from an authenticated messaging session, not the plain simulator |

---

## 6. Test conversations

Run these after any change to the agent script, prompt template, retriever or Apex, and read
the interaction trace for each — the trace, not the answer, is the evidence.

1. **Knowledge, happy path** — "What's excluded from home insurance?" → grounded answer
   naming real exclusions; trace shows the retriever fired.
2. **Knowledge, negative** — "Do aliens exist?" → the exact refusal string. Proves the
   guardrail survives the agent's reasoning layer, not just the template.
3. **Records, listing** — "Show me my policies" → `listMyPolicies`, active only, max 5.
4. **Records, selection** — reply with a bare policy number → treated as a selection and
   routed to `getPolicyDetails` with the number verbatim.
5. **Records, not owned** — a valid-looking number belonging to someone else → the same
   generic not-found message as a nonexistent number. **No difference.**
6. **Mixed** — "How do I claim on POL-000123?" → record fields from Apex, procedure wording
   from the retriever.
7. **Escalation** — "Talk to a human" → escalation subagent, `@utils.escalate`.

Pass = the trace shows: routed to subagent → correct action invoked → data returned →
grounded response displayed.

---

## 7. Version history in the repo

`aiAuthoringBundles/Northwind_RAG_Original_1 … _21` and `genAiPlannerBundles/…_v1 … _v22` are
retrieved snapshots of each published version, kept as history. Only the unsuffixed
`Northwind_RAG_Original` bundle (target `v22`) is current. The most recent difference between
`_21` and current: the flow action moved from `LLM_Apex_Actions` to `Policy_Actions_for_LLM`.

Before deploying, decide whether you want the historical bundles going along — see
[deployment.md](deployment.md#superseded-metadata).
