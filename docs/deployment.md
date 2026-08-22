# Deployment and Repository Guide

> What is in this repo, what order to build things in, and which commands to run.

| | |
|---|---|
| **API version** | 67.0 (`sfdx-project.json`) |
| **Package directory** | `force-app` |
| **Related** | [Runbook](aws-datacloud-rag-runbook.md) · [Architecture](architecture.md) · [Policy data access](policy-data-access.md) |

---

## 1. Build order

The Salesforce metadata in this repository is only half the system, and it is the second
half. Nothing here works until the AWS + Data Cloud side exists, because the prompt templates
reference a retriever by API name.

1. **AWS + Data Cloud** — follow [the runbook](aws-datacloud-rag-runbook.md) Parts A and B
   through §B.7. Ends with an activated retriever and its API name in hand.
2. **Deploy this repo** (§3 below).
3. **Reconcile the retriever API name** — if your retriever differs from
   `Northwind_Insurance_New_Retriever_1Cx_m3pf6c6dea6`, update it in the prompt templates'
   `templateDataProviders` and in the agent script's `Retriever_Developer_Name` variable and
   `Input:RetrieverIdOrName` binding. There are several references; change them together.
4. **Assign permissions** (§4) and **load policy data** (§5).
5. **Publish and test the agent** — see [agent-design.md](agent-design.md#6-test-conversations).

---

## 2. Prerequisites

- Salesforce **Agentforce + Data Cloud Developer Edition** org, with Data Cloud, Einstein
  Generative AI and Agentforce enabled. Data Cloud provisioning is asynchronous and can take
  up to an hour; DE orgs are reclaimed after 45 days of inactivity.
- **Salesforce CLI** (`sf`).
- **VS Code** with the Salesforce Extensions pack and the **Agentforce DX** extension (for
  agent script authoring and the preview panel).
- For the AWS side: an AWS account able to create IAM users/roles, S3 buckets, Lambda
  functions and Secrets Manager secrets, plus **WSL Ubuntu** for the installer.

Authorize the org:

```bash
sf org login web --alias northwind --set-default
```

A scratch-org definition with the required Agentforce features is at
`config/project-scratch-def.json` — note that a scratch org gives you no Data Cloud corpus,
so the RAG half must be rebuilt against it.

---

## 3. Deploy

Everything:

```bash
sf project deploy start --source-dir force-app --wait 30
```

Just the policy path (fastest loop while iterating on Apex):

```bash
sf project deploy start --source-dir force-app/main/default/objects/User_Policy__c --source-dir force-app/main/default/classes --source-dir force-app/main/default/flows/Policy_Actions_for_LLM.flow-meta.xml --wait 20
```

Run the tests:

```bash
sf apex run test --tests PolicyAccessServiceTest --result-format human --wait 10
```

`manifest/package.xml` is a wildcard manifest for retrieving the agent-related types back
from the org:

```bash
sf project retrieve start --manifest manifest/package.xml
```

> **Order matters within a deploy.** `User_Policy__c` must exist before the Apex compiles, and
> the flow must exist before the agent script's action target resolves. A single
> whole-directory deploy handles this; piecemeal deploys may need two passes.

> **Flows deploy inactive-by-default in some org settings.** After deploying, confirm
> `Policy_Actions_for_LLM` is **Active** — the agent action silently fails against an inactive
> flow.

---

## 4. Permissions

Assign the agent permission set to the agent user (the one named in the agent script's
`access.default_agent_user`):

```bash
sf org assign permset --name Northwind_Agent_Policy_Access --on-behalf-of <agent-user>
```

What it grants and why each grant is load-bearing is documented in
[policy-data-access.md §7](policy-data-access.md#7-permissions-the-agent-user-needs). The
single most common silent failure is a missing field read on
`MessagingEndUser.AuthenticatedEndUserId`.

---

## 5. Sample data

`User_Policy__c` records are not in source control. Create a few against a Contact that is
linked to an authenticated community/Experience user, since the identity chain runs
`MessagingEndUser → User → Contact`. Minimum for a useful test set:

- 2–3 `Active` policies for one contact (verifies listing and ordering).
- 1 `Expired` policy (verifies that lookup is not status-filtered).
- 6+ policies for one contact (verifies the cap of 5 and the `truncated` flag).
- 1 policy on a *different* contact (verifies the not-owned response is indistinguishable
  from nonexistent).

`Name` is an auto number (`POL-{000000}`), so let the platform assign it and use the assigned
values in your tests.

---

## 6. What is in this repository

| Directory | Count | Notes |
|---|---|---|
| `aiAuthoringBundles/` | 23 bundles | `Northwind_RAG_Original` (current) + 21 historical snapshots + `Local_Info_Agent` sample |
| `genAiPlannerBundles/` | 23 | Planner bundles for the same versions |
| `bots/` | 2 agents | `Northwind_RAG_Original` (22 versions), `Northwind_Insurance_Agent` |
| `genAiPromptTemplates/` | 4 | 3 Northwind variants + `Get_Event_Info` (sample) |
| `classes/` | 38 classes | 7 Northwind, 5 sample, the rest Experience Cloud / self-registration boilerplate |
| `flows/` | 7 | `Policy_Actions_for_LLM` (Active), `Northwind_Omnichannel_Routing` (Active), 2 obsolete, 3 sample/system |
| `objects/` | 1 | `User_Policy__c` with 12 custom fields |
| `permissionsets/` | 13 | `Northwind_Agent_Policy_Access` is the project-owned one |
| `permissionsetgroups/` | 23 | Almost entirely org-standard (`force__…`) |

### Northwind-owned metadata

```
classes/    PolicyAccessService(+Test), ListMyPolicies, GetPolicyDetails,
            GetMyPolicies(+Test, superseded), TestApexAvailability
flows/      Policy_Actions_for_LLM, Northwind_Omnichannel_Routing
objects/    User_Policy__c
prompts/    Northwind_RAG_Knowledge_Answers, NorthWind_RAG, Northwind_RAG_Flex
agent/      Northwind_RAG_Original (bundle + planner + bot)
permset/    Northwind_Agent_Policy_Access
```

### Superseded metadata

Retained deliberately, but do not treat any of it as current:

| Component | Status |
|---|---|
| `Northwind_RAG_Original_1 … _21` bundles, `…_v1 … _v21` planners | Historical published versions |
| `LLM_Apex_Actions` flow | Obsolete; replaced by `Policy_Actions_for_LLM` |
| `List_My_Policies` flow | Obsolete; single-action precursor |
| `GetMyPolicies` / `GetMyPoliciesTest` | Superseded by `PolicyAccessService` + the two invocables |
| `Northwind_Insurance_Agent` | The UI-built first version from runbook §B.9 |
| `Testing_Flow_Wrapping_Subagent_Action`, `TestApexAvailability` | Spike proving Apex reachability through a flow |

### Inherited sample and org metadata

`Local_Info_Agent` and its `CheckWeather` / `CurrentDate` / `WeatherService` classes,
`Get_Resort_Hours` flow, `Get_Event_Info` prompt template, and the `Resort_*` permission sets
come from the Salesforce DX Agentforce template. The `Communities*`, `Site*`, `Lightning*`
and `MicrobatchSelfReg*` classes are standard Experience Cloud boilerplate pulled in with the
org retrieve. None of it is used by Northwind; it is kept so a full retrieve/deploy round-trip
stays clean.

---

## 7. Secrets

Nothing secret belongs in this repository. Specifically, never commit:

- `salesforce.key`, `salesforce.pem`, `salesforce.crt` (the JWT key set)
- AWS access keys, secret keys, or session tokens
- `input_parameters_s3.conf` with real values filled in

Those live only in WSL and AWS Secrets Manager; see runbook §A.5, §A.9 and Appendix C. The
`.gitignore` covers `.sf/`, `.sfdx/` and `.env`, but it does not know about key files you
create — check `git status` before committing.
