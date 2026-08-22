# Northwind Insurance — Agentforce RAG Agent

A Salesforce DX project for an Agentforce Service Agent that answers insurance questions two
different ways, on purpose:

- **"What does the policy say?"** — Retrieval-Augmented Generation over policy PDFs stored in
  Amazon S3 and ingested, chunked, embedded and indexed by **Data Cloud (Data 360)**.
- **"What do *I* hold?"** — a deterministic Apex query against `User_Policy__c`, scoped to a
  contact derived from the messaging session. No vectors, no guessing, no way for the model
  to influence whose records come back.

The agent routes between the two and is instructed never to state a fact about a customer's
records that did not come from an action result in the current turn.

📖 **Documentation lives in [`docs/`](docs/README.md)** — architecture, the AWS + Data Cloud
runbook, the security model, agent design, and deployment.

---

## Architecture at a glance

```
 KNOWLEDGE PATH                              RECORDS PATH
 [ S3: policy PDFs ]                         [ Messaging session ]
        | ObjectCreated                              | $Context.MessagingEndUserId
        v                                            v
 [ Lambda file notifier ] --Ingestion API-->  [ verified Contact ]
        v                                            v
 [ Data Cloud: UDLO -> chunks -> index ]     [ PolicyAccessService (Apex) ]
        v                                            v
 [ Retriever ] -> [ Prompt template ]        [ Flow: Policy_Actions_for_LLM ]
                          \                    /
                           v                  v
                    [ Agent: Northwind_RAG_Original ]
```

The AWS and Data Cloud half is configuration, not source — it is reproduced step by step in
[the runbook](docs/aws-datacloud-rag-runbook.md). Everything under `force-app/` is the
Salesforce half.

---

## Key components

| Component | Type | Purpose |
|---|---|---|
| [`Northwind_RAG_Original.agent`](force-app/main/default/aiAuthoringBundles/Northwind_RAG_Original/Northwind_RAG_Original.agent) | Agent Script | The current agent: router, escalation, and the Northwind knowledge subagent |
| [`Northwind_RAG_Knowledge_Answers`](force-app/main/default/genAiPromptTemplates/Northwind_RAG_Knowledge_Answers.genAiPromptTemplate-meta.xml) | Prompt Template | Knowledge Answers template; grounds on the Data Cloud retriever, refuses when context is empty |
| [`PolicyAccessService`](force-app/main/default/classes/PolicyAccessService.cls) | Apex | Identity resolution, contact-scoped querying, and rendering — the security core |
| [`ListMyPolicies`](force-app/main/default/classes/ListMyPolicies.cls) · [`GetPolicyDetails`](force-app/main/default/classes/GetPolicyDetails.cls) | Apex (invocable) | The two actions the agent can reach |
| [`Policy_Actions_for_LLM`](force-app/main/default/flows/Policy_Actions_for_LLM.flow-meta.xml) | Flow | Single action surface; dispatches to the right invocable |
| [`User_Policy__c`](force-app/main/default/objects/User_Policy__c/) | Custom Object | Policy records; `Contact__c` is the authorization key |
| [`Northwind_Agent_Policy_Access`](force-app/main/default/permissionsets/Northwind_Agent_Policy_Access.permissionset-meta.xml) | Permission Set | Exactly the read access the agent user needs |

The repo also carries the untouched `Local_Info_Agent` sample from the Salesforce DX
Agentforce template, historical agent bundle versions, and Experience Cloud boilerplate —
see [what is in this repository](docs/deployment.md#6-what-is-in-this-repository).

---

## The security model in one paragraph

Identity flows `$Context.MessagingEndUserId → MessagingEndUser.AuthenticatedEndUserId →
User.ContactId`, every hop platform-managed. A policy number supplied in conversation is a
**selector, not an authorization**: the contact is re-resolved on every invocation and
composed with the number. Anything unresolved — guest session, missing link, blank id — fails
closed with an empty result. A policy that belongs to someone else returns exactly what a
nonexistent policy returns, with no distinguishing message. Full rationale and the 28
regression tests that pin it: [`docs/policy-data-access.md`](docs/policy-data-access.md).

---

## Getting started

### Prerequisites

- **Agentforce + Data Cloud Developer Edition** org (Data Cloud, Einstein Generative AI and
  Agentforce enabled). Free DE org: [developer.salesforce.com/signup](https://developer.salesforce.com/signup)
- **Salesforce CLI** (`sf`) — [install guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm)
- **VS Code** with the Salesforce Extensions pack and the **Agentforce DX** extension —
  [Install Pro-Code Tools](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-dx-set-up-env.html)
- For the ingestion pipeline: an AWS account and **WSL Ubuntu** (see the runbook)

### Authorize an org

```bash
sf org login web --alias northwind --set-default
```

### Deploy

```bash
sf project deploy start --source-dir force-app --wait 30
```

### Run the tests

```bash
sf apex run test --tests PolicyAccessServiceTest --result-format human --wait 10
```

> **Build order matters.** The prompt templates reference a Data Cloud retriever by API name,
> so the AWS + Data Cloud pipeline must exist first. Follow
> [the runbook](docs/aws-datacloud-rag-runbook.md) Parts A and B, then deploy this repo and
> reconcile the retriever name — [deployment.md §1](docs/deployment.md#1-build-order).

### Scratch orgs

`config/project-scratch-def.json` includes the Agentforce features needed for an
Agentforce-ready scratch org:

```bash
sf org create scratch --definition-file config/project-scratch-def.json --alias AgentScratchOrg --set-default --target-dev-hub DevHub
```

A scratch org has no Data Cloud corpus, so the RAG half has to be rebuilt against it.

---

## Working on the agent

Agent behaviour is authored as an **Agent Script** file (`AiAuthoringBundle` metadata). Open
[`Northwind_RAG_Original.agent`](force-app/main/default/aiAuthoringBundles/Northwind_RAG_Original/Northwind_RAG_Original.agent)
in VS Code, edit, then publish with the Agentforce DX extension. To preview, right-click the
file and choose **AFDX: Preview This Agent**.

Two rules that save hours:

1. **Deactivate the agent before editing subagents** — edits made while active do not persist.
2. **Test from an authenticated messaging session**, not the plain simulator — the identity
   chain fails closed for guests, by design.

Test conversations to run after any change:
[agent-design.md §6](docs/agent-design.md#6-test-conversations).

If you use Agentforce Vibes, enable the `developing-agentforce`, `observing-agentforce` and
`testing-agentforce` skills; for other AI tools, copy them from the
[`sf-skills`](https://github.com/forcedotcom/sf-skills) repository.

---

## Secrets

Never commit the JWT key set (`salesforce.key` / `.pem` / `.crt`), AWS access keys, session
tokens, or a filled-in `input_parameters_s3.conf`. They belong in WSL and AWS Secrets Manager
only — see [runbook Appendix C](docs/aws-datacloud-rag-runbook.md#appendix-c--security-checklist).

---

## Further reading

- [_Agentforce DX Developer Guide_](https://developer.salesforce.com/docs/einstein/genai/guide/agent-dx.html)
- [_Agent Script_](https://developer.salesforce.com/docs/ai/agentforce/guide/agent-script.html)
- [_Salesforce DX Developer Guide_](https://developer.salesforce.com/docs/atlas.en-us.sfdx_dev.meta/sfdx_dev/sfdx_dev_intro.htm)
- [_Salesforce CLI Command Reference_](https://developer.salesforce.com/docs/atlas.en-us.sfdx_cli_reference.meta/sfdx_cli_reference/cli_reference.htm)
