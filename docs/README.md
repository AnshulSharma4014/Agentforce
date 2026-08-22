# Northwind Insurance Agentforce — Documentation

Documentation for the Northwind Insurance agent: a RAG pipeline over policy PDFs in Data
Cloud, plus a deterministic, identity-scoped path to each customer's own policy records.

## Start here

| Document | Read it when |
|---|---|
| **[Architecture](architecture.md)** | You want the whole picture in ten minutes — the two answer paths, the components, the trust boundaries |
| **[AWS & Data Cloud runbook](aws-datacloud-rag-runbook.md)** | You are building or rebuilding the ingestion pipeline: S3, Lambda notifier, UDLO, search index, retriever. Step-by-step, with every failure mode hit during the original build |
| **[Policy data access](policy-data-access.md)** | You are touching `User_Policy__c`, the Apex actions, or anything that decides *whose* records get returned |
| **[Agent design](agent-design.md)** | You are editing the agent script, subagent instructions, or prompt templates |
| **[Deployment](deployment.md)** | You need build order, deploy commands, permissions, sample data, or a map of what's in `force-app/` |

## The short version

- **Documents → Data Cloud RAG.** PDFs in S3 are ingested event-driven (an AWS Lambda file
  notifier calls the Data Cloud Ingestion API), chunked, embedded and indexed. A retriever
  feeds a Knowledge Answers prompt template that answers only from retrieved context.
- **Records → Apex, not vectors.** Policy numbers, statuses, dates and amounts come from a
  SOQL query scoped to a contact derived from the messaging session. The LLM supplies the
  question, never the identity.
- **The agent routes between the two** and is instructed never to state a record fact that
  did not come from an action result in the current turn.

## Conventions

The runbook uses callouts that carry through the other documents:

> **Note** — supplementary context · **Tip** — recommended practice ·
> **Verify** — a checkpoint before proceeding · **Pitfall** — a failure mode hit during the
> build, with its fix · **Warning** — security- or data-integrity-critical.

Placeholders such as `YOUR-BUCKET-NAME` and `YOUR_ACCOUNT_ID` must be replaced with
environment-specific values. Resource names throughout (`northwind-insurance`,
`Northwind_Insurance_New`, the retriever API name) are this build's actual names — expect to
substitute your own.
