# Architecture — Northwind Insurance Agentforce Agent

> How the pieces fit together, and why each answer path exists.

| | |
|---|---|
| **Scope** | End-to-end design: document RAG, structured policy lookup, and the agent that routes between them |
| **Org** | Agentforce + Data Cloud (Data 360) Developer Edition |
| **Related** | [AWS & Data Cloud runbook](aws-datacloud-rag-runbook.md) · [Policy data access](policy-data-access.md) · [Agent design](agent-design.md) · [Deployment](deployment.md) |

---

## 1. The two answer paths

The agent answers two categorically different kinds of question, and it uses a different
mechanism for each. This split is the central design decision in the project.

| Question | Example | Path | Why |
|---|---|---|---|
| **What does the policy say?** | "What's excluded from home cover?" | Unstructured RAG over PDFs in Data Cloud | Prose has no schema; semantic retrieval is the right tool |
| **What do *I* hold?** | "When does my policy expire?" | Deterministic Apex query against `User_Policy__c` | Exact values must be exact; vectors fuzz them, cost more, and cannot enforce record ownership |

Vectorising the policy records would have been the "consistent" choice and the wrong one.
Semantic search has no notion of *whose* record it returned; a SOQL filter on the verified
contact does. The rationale is recorded in §B.6 of the
[runbook](aws-datacloud-rag-runbook.md) and enforced in code by
[`PolicyAccessService`](../force-app/main/default/classes/PolicyAccessService.cls).

---

## 2. System diagram

```
 UNSTRUCTURED PATH (knowledge)                    STRUCTURED PATH (customer records)
 -----------------------------                    ----------------------------------
 [ S3: northwind-insurance ]                      [ Messaging session ]
   auto/ home/ general/  *.pdf                      $Context.MessagingEndUserId
            |  (1) ObjectCreated                             |
            v                                                v  MessagingEndUser
 [ Lambda: northwind-s3-notifier ]                  .AuthenticatedEndUserId
            |  (2) Ingestion API (JWT)                       v  User.ContactId
            v                                        [ verified Contact ]
 [ Data Cloud / Data 360 ]                                   |
   - UDLO  Northwind_Insurance_New                           v
   - Search index -> ..._chunk / ..._index     [ PolicyAccessService (Apex) ]
            |                                     Contact__c = :contactId
            v                                        |           |
 [ Retriever ]                                       v           v
   Northwind_Insurance_New_Retriever_...     ListMyPolicies   GetPolicyDetails
            |                                        +-----+-----+
            v                                              v
 [ Prompt template ]                           [ Flow: Policy_Actions_for_LLM ]
   Northwind_RAG_Knowledge_Answers                         |
            |                                              |
            +--------------+-------------------------------+
                           v
            [ Agent: Northwind_RAG_Original ]
              subagent "Northwind RAG Knowledge Subagent"
              + Agent Router / Escalation / Ambiguous Question
                           |
                           v
                  Messaging channel / Preview
```

Everything left of the join is configured in AWS and Data Cloud and is **not** in this
repository — it is reproduced from the [runbook](aws-datacloud-rag-runbook.md). Everything
right of it is Salesforce metadata under `force-app/`.

---

## 3. Component inventory

### Configured outside source control (AWS + Data Cloud)

| Component | Name | Notes |
|---|---|---|
| S3 bucket (documents) | `northwind-insurance` | `auto/`, `home/`, `general/` at bucket root |
| S3 bucket (Lambda code) | `northwind-lambda-code` | Deployment package only |
| Lambda notifier | `northwind-s3-notifier` | Deployed by Salesforce's `file-notifier-for-blob-store` installer |
| IAM (ingestion) | `datacloud-s3-reader` | Read-only, single bucket |
| External Client App | `Northwind_S3_Notifier` | JWT bearer, PKCE off, `cdp_ingest_api` + `api` |
| S3 connection | `Northwind_S3` | Access key/secret auth (IdP auth is structured-only) |
| UDLO / UDMO | `Northwind_Insurance_New` | Semantic search + content harmonization enabled |
| Retriever | `Northwind_Insurance_New_Retriever_1Cx_m3pf6c6dea6` | Individual retriever, top-5, returns `Chunk` |

The retriever's API name is the coupling point: it is hard-wired into the prompt templates'
data providers and pinned in the agent script variable `Retriever_Developer_Name`. Rebuild
the retriever and every one of those references must change together.

### Versioned in this repository

| Component | Type | Path |
|---|---|---|
| `Northwind_RAG_Original` | Agent script (current, targets `v22`) | [`Northwind_RAG_Original.agent`](../force-app/main/default/aiAuthoringBundles/Northwind_RAG_Original/Northwind_RAG_Original.agent) |
| `Northwind_RAG_Knowledge_Answers` | Prompt template (Knowledge Answers) | [`genAiPromptTemplates/`](../force-app/main/default/genAiPromptTemplates/Northwind_RAG_Knowledge_Answers.genAiPromptTemplate-meta.xml) |
| `PolicyAccessService` | Apex — identity, query, rendering | [`PolicyAccessService.cls`](../force-app/main/default/classes/PolicyAccessService.cls) |
| `ListMyPolicies`, `GetPolicyDetails` | Apex invocables | [`classes/`](../force-app/main/default/classes/) |
| `Policy_Actions_for_LLM` | Flow (Active) — action dispatcher | [`Policy_Actions_for_LLM.flow-meta.xml`](../force-app/main/default/flows/Policy_Actions_for_LLM.flow-meta.xml) |
| `User_Policy__c` | Custom object | [`User_Policy__c/`](../force-app/main/default/objects/User_Policy__c/) |
| `Northwind_Agent_Policy_Access` | Permission set for the agent user | [`permissionsets/`](../force-app/main/default/permissionsets/Northwind_Agent_Policy_Access.permissionset-meta.xml) |
| `Northwind_Omnichannel_Routing` | Routing flow (Active) | [`flows/`](../force-app/main/default/flows/Northwind_Omnichannel_Routing.flow-meta.xml) |

Full listing, including superseded and template-inherited metadata, is in
[deployment.md](deployment.md#6-what-is-in-this-repository).

---

## 4. Request flow, in order

**Knowledge question** — "what does home insurance exclude?"

1. Agent Router classifies the intent and transitions to the Northwind RAG Knowledge Subagent.
2. The subagent invokes the `Northwind_RAG_Knowledge_Answers` prompt template with
   `Input:Query` = the user's question and `Input:RetrieverIdOrName` pinned to the retriever
   API name.
3. The template's data provider calls the retriever (`searchText` = the query,
   `outputFieldNames` = `["Chunk"]`, `resultCount` = 5) and splices the chunks into CONTEXT.
4. The model answers from CONTEXT only, or emits the exact refusal string.

**Record question** — "when does POL-000123 expire?"

1. Same routing; the subagent selects the `Policy_Actions_for_LLM` action instead.
2. It passes `callableApexAction` = `getPolicyDetails`, `policyNumber` verbatim from the
   user, and `endUserId` = `@variables.EndUserId` (linked to
   `@MessagingSession.MessagingEndUserId` — never collected from the user).
3. The flow branches on `callableApexAction` and calls the matching Apex invocable.
4. Apex re-resolves the verified contact from the messaging session, composes it with the
   policy number, and returns JSON / HTML / plain text plus `found`, `truncated`,
   `policyCount`.
5. Only `policiesInPlainText` is marked displayable; the model narrates around it.

**Mixed question** — "how do I claim on POL-000123?" — uses both: record fields from Apex,
procedure wording from the retriever. The subagent instructions state this explicitly.

---

## 5. Why a Flow sits between the agent and Apex

The agent could call the two invocables directly. It calls
[`Policy_Actions_for_LLM`](../force-app/main/default/flows/Policy_Actions_for_LLM.flow-meta.xml)
instead, which switches on a `callableApexAction` string. Consequences worth knowing:

- **One action surface.** The planner chooses a string value rather than picking between two
  similarly-described tools — fewer misroutes in practice.
- **Output shaping without redeploying Apex.** Which of JSON/HTML/text is displayable, and
  the progress-indicator text, are flow- and agent-script-level settings.
- **Cost:** an extra hop to debug, and the flow must be re-activated after edits. The
  earlier `LLM_Apex_Actions` flow is retained at `status = Obsolete`; the current agent
  targets `Policy_Actions_for_LLM`.

---

## 6. Trust boundaries

| Boundary | What crosses it | Control |
|---|---|---|
| Customer → agent | Free text, policy numbers | Treated as selectors, never as identity |
| Agent → Apex | `callableApexAction`, `policyNumber`, `policyScope`, `endUserId` | `endUserId` bound to platform context, not user input |
| Apex → data | Verified `Contact__c` filter | `WITH USER_MODE` plus `with sharing` on customer data |
| Documents → prompt | Retrieved chunks | Ingested PDFs are a prompt-injection surface; see runbook §B.10 |

The identity chain and its fail-closed behaviour are documented in detail in
[policy-data-access.md](policy-data-access.md#3-identity-and-authorization).

---

## 7. Known gaps

- **Citations are off.** `isCitationEnabled` is false on all templates; answers cite no
  source document. Enabling them requires a source-filename field on the retriever output.
- **Data masking is off** in Data Cloud (the default). Required before any real PII.
- **No automated evaluation harness.** The regression checklist in runbook §B.11 is manual.
- **Guest sessions get nothing.** Unauthenticated messaging sessions fail closed by design —
  there is no guest experience for record questions.
- **Superseded metadata is retained** (22 historical agent bundles, `GetMyPolicies`, obsolete
  flows); see [deployment.md](deployment.md#superseded-metadata).
