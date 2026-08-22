# Agentforce RAG Pipeline — AWS & Data Cloud Configuration Guide

### Northwind Insurance — Unstructured Document Ingestion for Retrieval-Augmented Generation

---

| | |
|---|---|
| **Document type** | Technical Configuration Guide / Runbook |
| **Status** | Active — retriever, prompt template, and Agentforce agent built and verified end-to-end |
| **Version** | 2.0 |
| **Last updated** | 28 June 2026 |
| **Owner** | Anshul Sharma |
| **Environment** | Windows + WSL Ubuntu · AWS (`eu-north-1`) · Salesforce Agentforce + Data Cloud (Data 360) Developer Edition |
| **Audience** | Salesforce / platform engineers reproducing this pipeline |

---

> **Repository note.** This runbook covers the AWS and Data Cloud configuration only — the
> half of the system that lives outside source control. The Salesforce metadata it produces
> (prompt templates, agent, Apex, flows) is versioned in this repository; see
> [`docs/architecture.md`](architecture.md) for how the two halves fit together, and
> [`docs/policy-data-access.md`](policy-data-access.md) for the structured-data path that was
> built after §B.6 of this document was written.

## Table of Contents

1. [Overview](#1-overview)
   - 1.1 [Purpose](#11-purpose)
   - 1.2 [Architecture Summary](#12-architecture-summary)
   - 1.3 [Scope](#13-scope)
   - 1.4 [Document Conventions](#14-document-conventions)
2. [Prerequisites](#2-prerequisites)
3. [Part A — AWS Configuration](#part-a--aws-configuration)
   - A.1 [S3 Buckets](#a1-s3-buckets)
   - A.2 [Read-Only IAM User (Ingestion)](#a2-read-only-iam-user-ingestion)
   - A.3 [Admin IAM User (Deployment)](#a3-admin-iam-user-deployment)
   - A.4 [WSL Tooling](#a4-wsl-tooling)
   - A.5 [Crypto Material (RSA Key + x509 Certificate)](#a5-crypto-material-rsa-key--x509-certificate)
   - A.6 [Salesforce External Client App (Deployment Prerequisite)](#a6-salesforce-external-client-app-deployment-prerequisite)
   - A.7 [File-Notifier Installer](#a7-file-notifier-installer)
   - A.8 [Configuration File: `input_parameters_s3.conf`](#a8-configuration-file-input_parameters_s3conf)
   - A.9 [Deployment Credentials — The Assume-Role Pattern](#a9-deployment-credentials--the-assume-role-pattern)
   - A.10 [Run the Installer](#a10-run-the-installer)
   - A.11 [Post-Deployment Hardening (Required)](#a11-post-deployment-hardening-required)
4. [Part B — Data Cloud (Data 360) Configuration](#part-b--data-cloud-data-360-configuration)
   - B.1 [S3 Connection](#b1-s3-connection)
   - B.2 [Unstructured Data Lake Object (UDLO)](#b2-unstructured-data-lake-object-udlo)
   - B.3 [Search Index & Content Harmonization](#b3-search-index--content-harmonization)
   - B.4 [Trigger Ingestion](#b4-trigger-ingestion)
   - B.5 [Verify Ingestion](#b5-verify-ingestion)
   - B.6 [Structured CRM Grounding](#b6-structured-crm-grounding)
   - B.7 [Retriever](#b7-retriever)
   - B.8 [Prompt Template](#b8-prompt-template)
   - B.9 [Agent Configuration](#b9-agent-configuration)
   - B.10 [Security](#b10-security)
   - B.11 [Evaluation](#b11-evaluation)
   - B.12 [Scaling to a Production Document Corpus](#b12-scaling-to-a-production-document-corpus)
5. [Appendix A — Resource Inventory](#appendix-a--resource-inventory)
6. [Appendix B — Troubleshooting Matrix](#appendix-b--troubleshooting-matrix)
7. [Appendix C — Security Checklist](#appendix-c--security-checklist)
8. [Appendix D — Revision History](#appendix-d--revision-history)

---

## 1. Overview

### 1.1 Purpose

This guide documents the complete configuration required to ingest unstructured PDF documents from Amazon S3 into Salesforce Data Cloud (Data 360) for use as a Retrieval-Augmented Generation (RAG) knowledge source by an internal Agentforce Service Agent. It is written as a reproducible runbook: every step includes the exact commands, a verification check, and — where applicable — the failure modes encountered during the original build and their resolutions.

### 1.2 Architecture Summary

**Pattern:** AWS S3 stores the raw documents; **Data Cloud is the RAG engine**, performing ingestion, chunking, embedding, indexing, and retrieval. Structured CRM data (Account, Case, Contact) is grounded natively in Data Cloud. There is no Bedrock, MuleSoft, or EC2 in this design.

> **Key concept.** Unstructured S3 ingestion into Data Cloud is **event-driven**, not polling-based. A Data Lake Object never auto-populates and has no manual "refresh" control. Documents are ingested **only when a file-change notification fires**, and that notification is produced by an **AWS Lambda function** deployed by Salesforce's installer script. The build order therefore is: provision S3 and identities → deploy the Lambda notifier → configure the Data Cloud objects → trigger a file change to make data flow.

```
                 (1) ObjectCreated event
   [ S3 bucket ] ───────────────────────▶ [ Lambda: file notifier ]
   PDFs (auto/,                                      │ (2) calls Data Cloud
   home/, general/)                                  ▼     Ingestion API (JWT)
                                          [ Data Cloud / Data 360 ]
                                            • UDLO (file references)
                                            • Search Index (chunk + embed)
                                            • Retriever ──▶ Prompt ──▶ Agent
   [ Salesforce CRM ] ──▶ [ DMOs / Data Graph ] (structured grounding)
```

### 1.3 Scope

**In scope:** AWS S3, IAM, Secrets Manager, and Lambda configuration; the Salesforce External Client App; the Data Cloud connection, UDLO, search index, and ingestion verification; the retriever, prompt template, and Agentforce agent — all built and verified end-to-end (§B.7–B.9); and bulk ingestion of an existing production corpus (§B.12).

**Next phase (outlined, not yet built):** structured grounding via a custom `Policy` object (master-detail to Contact) as a second grounding source, plus citation enablement, security hardening, and the evaluation harness — see §B.6, §B.10–B.11.

### 1.4 Document Conventions

> **Note.** Supplementary context.

> **Tip.** A recommended practice.

> **Verify.** A checkpoint to confirm before proceeding.

> **Pitfall.** A failure mode encountered during the build, with its fix. These cover gaps not documented in the vendor guides.

> **Warning.** A security- or data-integrity-critical action.

Placeholders such as `YOUR-BUCKET-NAME`, `YOUR_ACCOUNT_ID`, and `YOUR_ADMIN_USERNAME` must be replaced with environment-specific values.

---

## 2. Prerequisites

- An AWS account with the ability to create IAM users, roles, S3 buckets, Lambda functions, and Secrets Manager secrets.
- A Salesforce **Agentforce + Data Cloud Developer Edition** org with Data Cloud, Einstein Generative AI, and Agentforce enabled.
- Windows with **WSL Ubuntu** for all terminal operations.
- Source documents in a **supported format: HTML, TXT, or PDF only** (Markdown is not supported; HTML yields the best chunking because the semantic chunker splits on heading tags).

> **Note.** Data Cloud provisioning is asynchronous and can take up to one hour. It is ready when *Your Home Org Details* is shown in Data Cloud Setup and the Data Cloud app appears in the App Launcher. Developer Edition orgs are reclaimed after 45 days of inactivity.

---

# Part A — AWS Configuration

## A.1 S3 Buckets

Two buckets are required:

| Bucket | Purpose |
|---|---|
| `northwind-insurance` | Stores the source PDF documents |
| `northwind-lambda-code` | Stores the file-notifier Lambda deployment package |

**Folder layout** (decide before uploading — folder paths become retrieval metadata):

```
northwind-insurance/        (bucket root)
├── auto/        → auto policy PDFs
├── home/        → home policy PDFs
└── general/     → claims process, FAQ PDFs
```

> **Verify.** At the bucket root you should see `auto/`, `home/`, and `general/` directly — not nested under an additional parent folder.

> **Pitfall — directory alignment.** The S3 bucket, the Data Cloud connection's parent directory, and the UDLO directory must all resolve to the **same physical path**. The original build assumed a `northwind-insurance/` subfolder *inside* the bucket while the files were at the root; this resolved to `northwind-insurance/northwind-insurance/` — a path that does not exist — and ingested nothing. Confirm path alignment before proceeding.

## A.2 Read-Only IAM User (Ingestion)

This identity is used by the **Data Cloud S3 connection** to read the bucket. It follows least privilege: read-only, scoped to a single bucket.

**Step 1 — Create the policy.** IAM → Policies → Create policy → JSON (replace `YOUR-BUCKET-NAME`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListThisBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME"
    },
    {
      "Sid": "ReadObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::YOUR-BUCKET-NAME/*"
    }
  ]
}
```

Name it `DataCloudS3ReadOnly`.

> **Pitfall — two statements are mandatory.** `s3:ListBucket` acts on the **bucket** ARN (no `/*`); `s3:GetObject` acts on the **object** ARN (`/*`). Using the wrong ARN type produces "Access Denied." Ingestion requires read access only — do **not** grant `PutObject`/`DeleteObject` (those are needed only for activation, i.e. writing data back out).

**Step 2 — Create the user.** IAM → Users → Create user → `datacloud-s3-reader` → **do not enable console access** → attach `DataCloudS3ReadOnly`.

**Step 3 — Generate the access key.** User → Security credentials → Create access key → *Command Line Interface (CLI)* → record the **Access Key ID** and **Secret** (shown once). These are entered into the Data Cloud connection (§B.1).

## A.3 Admin IAM User (Deployment)

A **separate** identity used only to deploy the Lambda pipeline, which creates IAM roles, Secrets Manager secrets, a Lambda function, and an S3 event notification.

- IAM → Users → Create user → `aws-admin` → **no console access** → attach `AdministratorAccess`.
- Security credentials → Create access key → CLI → record the **Access Key ID** (begins with `AKIA…`) and **Secret**.

> **Warning.** Never create access keys for the AWS **root** user — root keys cannot be scoped or safely rotated. Always use a dedicated admin IAM user.

## A.4 WSL Tooling

```bash
# jq and utilities
sudo apt-get update
sudo apt-get install -y jq unzip curl
jq --version

# AWS CLI v2 (official installer — the apt package is outdated)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
aws --version
```

## A.5 Crypto Material (RSA Key + x509 Certificate)

The notifier authenticates to Salesforce using a JWT signed by an RSA key, whose certificate is uploaded to the External Client App. In a dedicated WSL folder:

```bash
openssl genrsa -out salesforce.key 2048
openssl req -new -x509 -key salesforce.key -out salesforce.crt -days 365
openssl pkcs8 -topk8 -nocrypt -in salesforce.key -out salesforce.pem
```

| File | Used by |
|---|---|
| `salesforce.crt` | External Client App (uploaded as the certificate) |
| `salesforce.pem` | Lambda function (PKCS8 private key) |
| `salesforce.key` | Retained locally |

> **Pitfall — JWT failures.** Upload only the **`.crt`** to the app (never the `.pem`/`.key`). Use a **single** `.crt`/`.pem`/`.key` set for both the app and the Lambda; do not regenerate midway. Treat all three as secrets — never commit them to source control or place them in the S3 bucket.

> **Pitfall — `realpath` does not verify existence.** `realpath file` prints a constructed path even when the file is absent. Always confirm with `ls -l <path>`.

## A.6 Salesforce External Client App (Deployment Prerequisite)

The Lambda authenticates against this app, so it must exist before the installer runs. (Classic Connected Apps are retired in newer orgs; External Client Apps are the supported replacement and provide the same JWT bearer flow and Consumer Key.)

**Create the app.** Setup → **External Client App Manager** → New External Client App.
- Name (e.g. `Northwind_S3_Notifier`) and contact email; **Distribution State: Local**.
- Expand **API (Enable OAuth Settings)** → enable OAuth.
- **Callback URL:** `http://localhost:1717/OauthRedirect` (required field; JWT does not use it, but it must match `CALLBACK_URL` in the config file).
- **OAuth Scopes:** `cdp_ingest_api` (Manage Data 360 Ingestion API data), `api` (Manage user data via APIs), and `refresh_token, offline_access` (Perform requests at any time).
- **Flow Enablement:** enable **JWT Bearer Flow** and upload **`salesforce.crt`**.
- **Security:** **uncheck "Require Proof Key for Code Exchange (PKCE)."**
- Create the app; confirm status **Enabled**.

**Configure policies.** App → **Policies** tab → Edit → OAuth Policies → set **"Admin approved users are pre-authorized"** and add the System Administrator profile → Save.

**Retrieve the Consumer Key.** App → **Settings** tab → OAuth Settings → **Consumer Key and Secret** → copy the **Consumer Key** (used as `CONSUMER_KEY_VALUE` in §A.8).

> **Pitfall — PKCE.** Leaving "Require PKCE" enabled causes the Lambda's JWT token request to fail in a way that is difficult to diagnose. Ensure it is unchecked.

## A.7 File-Notifier Installer

```bash
git clone https://github.com/forcedotcom/file-notifier-for-blob-store.git
cd file-notifier-for-blob-store/installers/aws
ls   # input_parameters_s3.conf, setup_s3_file_notification.sh, setup_s3_file_notification_us_gov.sh
```

The Lambda package is at `../../cloud_function_zips/aws_lambda_function.zip`.

> **Note — script selection.** Use `setup_s3_file_notification.sh`. The `_us_gov.sh` variant targets AWS GovCloud endpoints and will fail on commercial regions such as `eu-north-1`.

> **Pitfall — locating the package.** If the zip is not where expected:
> ```bash
> find ~ -name "aws_lambda_function.zip" 2>/dev/null
> ```
> If the repository uses Git LFS and the zip downloads as a ~130-byte pointer instead of the real binary:
> ```bash
> sudo apt-get install -y git-lfs && git lfs install && git lfs pull
> ```
> Alternatively, download that single file from GitHub's web UI ("Download raw").

## A.8 Configuration File: `input_parameters_s3.conf`

Edit the file in `installers/aws`. Values used in this build:

| Variable | Value / Note |
|---|---|
| `SF_USERNAME` | Salesforce admin username |
| `SF_LOGIN_URL` | `https://login.salesforce.com/` (production / Developer Edition) |
| `SF_AUDIENCE_URL` | `https://login.salesforce.com/` — **replace the placeholder**, or leave empty to default to `SF_LOGIN_URL` |
| `AWS_ACCOUNT_ID` | 12-digit account ID (from `aws sts get-caller-identity` → `Account`) |
| `REGION` | Bucket region, e.g. `eu-north-1` |
| `EVENT_S3_SOURCE_BUCKET` | `northwind-insurance` |
| `EVENT_S3_SOURCE_KEY` | **EMPTY** (no slash) — watches the whole bucket; correct when files span multiple root folders |
| `LAMBDA_FUNC_S3_BUCKET` | `northwind-lambda-code` |
| `LAMBDA_FUNC_LOC_S3_KEY` | `aws_lambda_function.zip` |
| `SOURCE_CODE_LOCAL_PATH` | **Absolute** path to the zip |
| `LAMBDA_ROLE` | `northwind-s3-notifier-role` (any string; created by the script) |
| `LAMBDA_FUNC_NAME` | `northwind-s3-notifier` (any string) |
| `CONSUMER_KEY_NAME` | `northwind-consumer-key` (a Secrets Manager **secret name**) |
| `CONSUMER_KEY_VALUE` | The External Client App's **Consumer Key** |
| `RSA_PRIVATE_KEY_NAME` | `northwind-rsa-key` (a Secrets Manager **secret name**) |
| `PEM_FILE_PATH` | **Absolute** path to `salesforce.pem` |
| `CALLBACK_URL` | Must match the app's callback, e.g. `http://localhost:1717/OauthRedirect` |

> **Pitfall — secret names vs. secret values.** `RSA_PRIVATE_KEY_NAME` and `CONSUMER_KEY_NAME` are the **names** of secrets the script creates in AWS Secrets Manager — not the key contents. The actual values are supplied via `PEM_FILE_PATH` and `CONSUMER_KEY_VALUE`.

> **Pitfall — `EVENT_S3_SOURCE_KEY`.** This must be **empty** when documents span multiple root folders, so the notifier watches the entire bucket. Setting it to the bucket name or a non-existent subfolder is a recurring error that results in zero ingestion. The notifier watching more broadly than the UDLO is acceptable — the UDLO determines what is actually ingested.

## A.9 Deployment Credentials — The Assume-Role Pattern

The installer requires **all three** of `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, **and `AWS_SESSION_TOKEN`** as environment variables, **and** it performs IAM API calls. This combination is the central obstacle:

| Credential type | Prefix | Session token? | Can call IAM? | Outcome |
|---|---|:---:|:---:|---|
| Long-lived admin keys | `AKIA…` | No | Yes | Script **halts** at the credentials prompt (no token) |
| `aws sts get-session-token` | `ASIA…` | Yes | **No** (barred from IAM without MFA) | Reaches Step 2, fails: `InvalidClientTokenId` |
| **`aws sts assume-role`** | `ASIA…` | **Yes** | **Yes** | **Succeeds** |

The required credentials come from **`assume-role`**.

**Step 1 — Create an assumable admin role.** IAM → Roles → Create role → Custom trust policy → attach `AdministratorAccess` → name `northwind-deploy-role`:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::YOUR_ACCOUNT_ID:user/YOUR_ADMIN_USERNAME" },
    "Action": "sts:AssumeRole"
  }]
}
```

> **Note.** `YOUR_ADMIN_USERNAME` is the admin IAM user from §A.3 (the one with `AdministratorAccess`) — not the read-only user and not root. Copy its full ARN from IAM → Users.

**Step 2 — Assume the role:**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts assume-role \
  --role-arn arn:aws:iam::YOUR_ACCOUNT_ID:role/northwind-deploy-role \
  --role-session-name northwind-deploy
```

**Step 3 — Export the returned credentials (in the terminal only):**

```bash
export AWS_ACCESS_KEY_ID=<AccessKeyId>
export AWS_SECRET_ACCESS_KEY=<SecretAccessKey>
export AWS_SESSION_TOKEN=<SessionToken>
```

**Step 4 — Validate with an IAM call** (not `get-caller-identity`):

```bash
aws iam list-roles --max-items 1
```

A successful response (any role JSON) confirms the credentials can call IAM. This is the go/no-go check.

> **Pitfall — `get-caller-identity` is misleading.** It is on STS's always-allowed list and succeeds even with credentials that are forbidden from IAM. When the next operation is an IAM call, validate with `aws iam list-roles`.

> **Warning — credential handling.** `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, and `.pem` contents must never leave the terminal (no chat, tickets, screenshots, or source control). Share only non-sensitive values (ARN, account ID, access-key ID prefix, region). If a secret is exposed, regenerate it immediately; session tokens also expire automatically (~1 hour).

## A.10 Run the Installer

In the **same shell** where the IAM validation succeeded (assume-role sessions expire in ~1 hour):

```bash
cd ~/file-notifier-for-blob-store/installers/aws
chmod +x setup_s3_file_notification.sh
./setup_s3_file_notification.sh input_parameters_s3.conf   # the config argument is mandatory
```

> **Pitfall — missing argument.** Running the script without the config file prints `Usage: ... <config_file>` and exits. Always pass `input_parameters_s3.conf`.

**Expected flow:** four readiness prompts → validation (`No validation errors`) → `Step 1/16: Successfully logged into AWS` → **Step 2/16 creates `northwind-s3-notifier-role`** → Steps 3–16 create the Secrets Manager secrets, the Lambda function, and the S3 event notification → a **pause printing an authentication link and code**.

**At the authentication pause (Linux/WSL):** copy the link into a browser, enter the code, approve the requested scopes, then return to the terminal — the script resumes automatically. A clean run ends near Step 16 with a resource summary and no error block.

> **Verify.** The closing summary lists the source bucket, Lambda name, role ARN, region, and event-notification name. All steps should report success.

> **Note — idempotency & logs.** The script is safe to re-run; it skips existing resources and continues from the failure point. All output is written to `log_<timestamp>.txt` in the same folder — consult it to identify the exact failing stage.

**Authentication-stage failure checks:**

| Symptom | Likely cause | Action |
|---|---|---|
| `400` after approving | Certificate not matched to the `.pem`, or wrong/expired Consumer Key | Re-verify the key set; recreate if needed |
| `403` | Org URL unreachable or scopes not set | Confirm scopes and that the org URL loads in a browser |
| Persistent auth failure | Username-password flow disabled | Enable Setup → OAuth and OpenID Connect Settings → *Allow OAuth Username-Password Flows* (a documented fix; enable only if required) |

## A.11 Post-Deployment Hardening (Required)

> **Warning — deactivate the deployment access key.** The admin access key (`AKIA…`) was needed only for the one-time deployment. The running pipeline authenticates via the Lambda execution role and Secrets Manager and does **not** use it. Leaving a long-lived admin key active is an unnecessary, high-value credential exposure.
>
> **Action:** IAM → `aws-admin` → Security credentials → **Deactivate** (then delete) the access key. This does not affect the deployed pipeline.

Additional hardening:

- Retain the read-only `datacloud-s3-reader` user — Data Cloud uses it continuously.
- If `northwind-deploy-role` is no longer needed, it can be left in place (it is only assumable by your admin user) or removed.
- Confirm no secrets remain in shell history or local files outside the intended key store.

---

# Part B — Data Cloud (Data 360) Configuration

## B.1 S3 Connection

> **Note — terminology.** A **Connection** is the credentialed link to S3 (created here). A **Data Stream** is scheduled ingestion for *structured* data (CSV/Parquet) and is **not** used. A **UDLO** is the unstructured equivalent, created next.

Setup → **Data Cloud Setup** → **Other Connectors** (newer UI: *External Integrations → More Connectors*) → New → **Amazon S3** → Next.

- **Connection Name:** `Northwind_S3`.
- **Authentication: Access Key/Secret Based** — *not* Identity Provider (IdP auth supports structured data only).
- Enter the **read-only** user's Access Key + Secret (`datacloud-s3-reader`).
- **Bucket Name:** `northwind-insurance`; **Parent Directory:** `/` (root).
- **Test Connection** → expect *"Connection was established"* → Save.

> **Verify.** A failed test usually indicates a wrong region, mistyped secret, or a bucket name that does not match the IAM policy.

## B.2 Unstructured Data Lake Object (UDLO)

App Launcher → Data Cloud → **Data Lake Objects** → New → **From External Files** → Amazon S3 → select `Northwind_S3`.

- **Directory is required and cannot be empty.** Because the documents span three root folders, add **three directory entries** (use *Add more files* / *More Files*, up to five):
  - `auto/` — File Name Pattern `*.pdf`
  - `home/` — File Name Pattern `*.pdf`
  - `general/` — File Name Pattern `*.pdf`
- **Object Name / API Name:** `Northwind_Insurance_New`.
- Map to a **New** UDMO (e.g. `Northwind_Insurance_New`), Data Space `default`; fields auto-map.

> **Pitfall — directory binding is permanent.** A UDLO's Directory **cannot be edited after creation**, and a UDLO **cannot be deleted without raising a Salesforce support case**. Configure the directory correctly the first time. If it is wrong, create a new UDLO — a stranded, empty UDLO is inert and does not interfere.

> **Pitfall — file extension case.** Patterns are case-sensitive (`*.pdf` ≠ `*.PDF`). A case mismatch silently skips files.

## B.3 Search Index & Content Harmonization

On the final UDLO screen, enable **both** options:

- **Enable semantic search with system defaults** — creates the search index (chunking + vectorization).
- **Enable Unstructured Content Harmonization** — extracts text from the binary PDFs so there is content to chunk.

> **Pitfall.** Without **Content Harmonization**, a PDF UDLO references only file metadata (name, path, size) with no extracted text — the index has nothing to chunk and retrieval returns nothing. Enable both for a PDF corpus.

> **Verify.** Confirm a search index configuration exists for the UDMO (Search Index tab). It will show **zero chunks until data is ingested** — this is expected, not a failure. If no config exists, create one: Search Index → New → Easy Setup → select the UDMO.

## B.4 Trigger Ingestion

The event notification fires only on **file activity**. Documents uploaded *before* the pipeline existed have not generated an event. **Re-upload (overwrite) the PDFs** in each folder to emit `ObjectCreated` events, which invoke the Lambda → Data Cloud Ingestion API → UDLO ingestion. Allow several minutes for harmonization and chunking.

> **Tip — at scale.** Re-uploading by hand is fine for a few files. To backfill an existing corpus of hundreds of documents already in S3, re-put every object in place with a single CLI command — see §B.12.

## B.5 Verify Ingestion

1. **Lambda invocation:** AWS console → Lambda → `northwind-s3-notifier` → Monitor → CloudWatch logs. A recent, error-free invocation confirms the trigger fired. (A `400`/`403` here indicates the Salesforce authentication side — certificate/key pairing or scopes.)
2. **Directory table:** `Northwind_Insurance_New` → **Total Records** should reach ~5 (one row per file).
3. **Chunks:** In **Data Explorer**, the Object dropdown contains a separate object whose name includes **`chunk`** (e.g. `…_chunk`). Selecting it lists the extracted text chunks. A companion `…_index` object holds the vectors.

> **Verify.** Text chunks present in the `…_chunk` object confirm the ingestion pipeline is functioning end-to-end and the corpus is retrievable.

> **Note.** If Total Records remains blank, check the UDLO **Refresh History** ("No Refresh History Yet" indicates no notification has fired), confirm directory alignment (§A.1), and confirm file-type/case.

## B.6 Structured CRM Grounding

Unstructured documents are grounded through the search-index retriever (§B.7). **Structured** customer data is grounded differently — and choosing the right mechanism per data type is a design decision, not a default.

For customer-context answers, ingest **Account / Case / Contact** into Data Cloud as DMOs and model a **Data Graph** (a flattened view of related records) so the agent grounds on a customer's policies and claims in a single payload.

**Planned next phase — a `Policy` custom object** (master-detail to Contact), populated with real records, as a second grounding source so the agent can answer "what is *this* policyholder's coverage / renewal date / premium."

> **Pitfall — do not reflexively vectorise structured data.** It is tempting to "repeat the PDF pipeline" on the `Policy` object — index, embed, retrieve. For *exact-value* questions (policy number, renewal date, premium) this is the **wrong** tool: semantic search fuzzes precise values and costs more. A **direct record-lookup action** (Query Records, or a Flow/Apex action filtered by the running user's Contact) is more accurate and cheaper. RAG earns its place on prose; structured records usually want a deterministic query. Decide this in upfront scoping **before** building the object.

## B.7 Retriever

The retriever is the queryable RAG endpoint. It wraps the **search index** (the vectors), not the chunk DMO directly. Built as an **individual retriever** over the PDF index; structured grounding (§B.6) is handled separately.

### Prerequisite checks (before building)

A `Ready` index status alone can still mask an empty-result trap. Confirm **both**:

1. **Search index run status = `Ready`.** Data Cloud → Search Indexes → open the index → the field **"Search Index Last Run Status"** reads `Ready`. (There is no field literally named "Status"; this is the one.)
2. **The index DMO (`…_index`, the IDMO) actually contains vector records.** The retriever searches the vectors in the `…_index` object, *not* the chunks in `…_chunk`. Data Explorer → Object = **Data Model Object** → select the **`…_index`** object → confirm vector records are present (one per chunk). A `Ready` status over an empty IDMO yields a retriever that returns nothing.

### Build

App Launcher → **Data Cloud** → **AI Models** tab → **Retrievers** → **New Retriever**.

1. **Type → Individual Retriever** (grounds on exactly one search index). *Ensemble* combines multiple individual retrievers and is reserved for multi-source grounding once each leg is proven.
2. **Source → Data Cloud**, **default** data space (verify the corpus was not deployed to a non-default space).
3. Select the PDF **chunk DMO** (`Northwind_Insurance_New`) and the **search index config** showing `Ready`.
4. **Filters → All Documents** for the baseline. (Metadata filters on the `auto`/`home`/`general` folder path can scope retrieval later — see §B.12.)
5. **Configure Retriever Results:**
   - **Number of results → 5** (default 20 is noise/token burn for Q&A).
   - **Fields to Return → the `Chunk` field is mandatory** — it carries the actual text. Without it the retriever matches the right chunks but returns no readable content (silent empty grounding).
     - **Field Label:** `Chunk` (freeform).
     - **Field Name:** the picker is a nested tree → navigate **RelatedAttributes → [`…chunk` object] → Chunk**. (`DirectAttributes` = structured fields; **`RelatedAttributes` = chunk content** — this branch is the key.)
     - *(Optional)* add a source filename/title under `DirectAttributes` for traceability — needed later for citations.
   - **Citations → Off** for now.
6. **Save → Activate → Activate.**

> **Pitfall — label ≠ API name.** Record the retriever's **API Name** from the detail page. Spaces in the label become underscores in the API name and a suffix may be appended; a space-vs-underscore mismatch downstream fails **silently**. Copy it verbatim — you need it for the agent action (§B.9).

> **Verify.** Test the retriever in isolation in Prompt Builder (§B.8) before wiring it to an agent.

## B.8 Prompt Template

Built in **Prompt Builder** as a **Knowledge Answers** template (the dropdown label for "Answer Questions with Knowledge"). API name `NorthWind_RAG`.

> **Pitfall — Field Generation will not list an unstructured object.** Field Generation binds to a record object + field to *generate into*; an unstructured corpus has no such target, so the object won't appear. That is expected — use **Knowledge Answers**, the RAG-native type. Confirm you are in it: the **Inputs** panel shows built-in **`Query`** and **`Retriever`** (`RetrieverIdOrName`) inputs. (A *Flex* template has neither — you hand-build every input.)

### Prompt body

Three slots; the retriever lives in exactly one (CONTEXT):

```
You are a Northwind Insurance assistant. Answer the QUESTION using ONLY
the information in CONTEXT below.

QUESTION:
{Input:Query}

CONTEXT:
{Retrievers:<your retriever>}

If CONTEXT does not contain the answer, reply exactly:
"I don't have that information in the policy documents."
Do not infer coverage details that aren't explicitly stated.
```

- **QUESTION** ← insert the **Query** input.
- **CONTEXT** ← insert the **retriever** resource (Insert Resource → Retrievers → select yours). This is the **only** place the retriever belongs; the inserted resource carries the Chunk / top-5 output config from §B.7.
- The refusal line is **literal text** — do not merge the retriever into it.

> **Tip — the refusal clause is a guardrail, not polish.** For insurance, a fabricated coverage answer is a liability. The "if not found, say so" instruction stays in production.

> **Note.** A mini-class model is fine for *verification* — you read the **Resolved Prompt**, not the generated answer, to confirm retrieval. Upgrade the model only when answer quality matters.

### Verify (this is the proof)

**Save & Preview** → **Query** = a question known to be answerable from a specific document; **Retriever ID** = the retriever API name → run.

- **Pass = your actual chunks appear inside the CONTEXT section of the Resolved Prompt.** This simultaneously proves the retriever fires *and* that Output Fields = `Chunk` is wired. Empty CONTEXT = output field unset or retriever-ID mismatch.
- **Negative test:** ask an out-of-corpus question. Semantic search has **no "no match" state** — the retriever still returns its top-k (irrelevant) chunks; the LLM must **refuse anyway**. This proves the guardrail holds when the retriever returns irrelevant content — the realistic failure mode.

**Save → Activate.**

## B.9 Agent Configuration

Built in the **new Agentforce Builder** (GA Feb 2026). **Topics are being rebranded to Subagents** — both terms appear mid-rebrand. Agent API name `Northwind_Insurance_Agent`.

### Create the agent shell

Setup → **Agentforce Agents** → **New Agent** → **Agentforce Service Agent** (customer-facing; testable entirely in the builder simulator, no channel needed).

- **Company** field is corpus-specific — the agent grounds its persona here.
- ✅ Enable **"Keep a record of conversations with enhanced event logs"** — turns on **interaction tracing**, used to confirm routing and retriever firing.

> **Pitfall — skip "Select data sources" (step 4); add nothing.** Attaching a source here spins up the **Agentforce Data Library** quick-start: its *own* retriever, index, and default knowledge action — a shadow RAG stack that ignores the retriever and template built above. An agent with both stacks misroutes to the wrong one. Leaving it empty is deliberate.

### Prune and repurpose subagents

> **Pitfall — the agent must be DEACTIVATED to edit subagents.** Do all edits in one deactivated pass.

The Service Agent template generates ~8 generic (hotel/retail) subagents.

- **Delete the boilerplate** (Account Management, Case Management, Delivery Issues, Order Inquiries, Reservation Management, Service Customer Verification). Overlapping scopes increase misrouting risk.
- **Keep Escalation.**
- **Repurpose "General FAQ"** (`GeneralFAQ_…`) — it hides the default **"Answer Questions with Knowledge" / DynamicRetriever** action, which searches empty Salesforce Knowledge articles and competes with your retriever. Open it → **Actions** → **remove** that action.

### Add the prompt template as an Agent Action

In the subagent → **This Subagent's Actions** → **New** → select the **NorthWind RAG** template (it surfaces directly once activated).

| Field | Setting |
|---|---|
| **Agent Action Description** | Specific — the planner reads it to decide when to fire. |
| **Loading Text** | e.g. "Checking the Northwind policy documents…" |
| **Input: Query** | Description = the policyholder's question. Require input ✅ / Collect from user ❌ |
| **Input: RetrieverIdOrName** | **The binding — see pitfall below.** Require input ✅ / Collect from user ❌ |
| **Input: Output language** | Optional — leave empty. |
| **Input: Citation Mode** | Optional — leave empty for the first clean test. |
| **Input: isPreviewOnly** | **Must be FALSE** (true = resolves prompt without generating an answer). |
| **Output: Prompt Response (`promptResponse`)** | ✅ **Check "Show in conversation"** — this is the answer. |
| **Output: Prompt Generation ID / Citations** | "Show in conversation" OFF (metadata). |

> **Pitfall — the RetrieverIdOrName binding (highest-risk field).** This UI has **no fixed-value field.** With *Require input* on and *Collect from user* off, the reasoning engine supplies the value from the **Description** — so pin the retriever by writing its exact API name into the description: *"…Always use exactly this value and never ask the user: `<RETRIEVER_API_NAME>`."* Copy the API name from the retriever detail page. Never let the customer type a retriever ID.

> **Pitfall — "Show in conversation" off = invisible answer.** If `promptResponse` does not show in conversation, the agent grounds correctly but the user sees nothing. At least one output must show; this is the one.

### Classification, Scope, Instruction

Author all three free of "knowledge articles" language (there is no Knowledge store).

- **Classification Description** (routing *in*): trigger conditions — coverage, exclusions, deductibles, limits, premiums, endorsements, claims.
- **Scope** (behavior *inside*): grounded content only, no general knowledge, explicit refuse-and-escalate fallback.
- **Topic instruction:** "When a user asks about … use the NorthWind RAG action … if it returns no information, offer to escalate."

### Activate and test

On Activate, "Configuration Issues Detected" appears. Triage:

| Warning | Verdict |
|---|---|
| Not connected to an Agentforce Data Library | **Expected & safe** (shadow stack intentionally avoided) |
| No connected channels | **Expected** (simulator needs none) |
| No conversation escalation flow | **Acceptable** for a demo |
| "No response" subagents overlap | **Noise** — ignore |
| Conflict / overlap among *kept* subagents | **Investigate** via the Activation Checklist |

When only expected warnings remain → **Ignore & Activate**.

**Simulator (Conversation Preview)** — run three probes and read the **interaction trace** for each:

1. **Happy path** ("what's excluded from home insurance?") → grounded answer naming real exclusions.
2. **Negative** ("do aliens exist?") → clean refusal — proves the guardrail survives the *agent's reasoning layer*, not just the template.
3. **Routing** ("how do I file a claim?") → routes to the policy subagent, answers from the claims chunk.

**Pass = the trace shows:** routed to subagent → invoked NorthWind RAG → retriever fired → grounded response shown.

> **Pitfall — subagent edits only persist when the agent is DEACTIVATED.** If a rename/classification/scope edit "doesn't stick", that's why. Pattern: **deactivate → edit → save → reopen and verify → reactivate.**

## B.10 Security

- **Secure retrieval / dynamic grounding:** agents access only data the running user is authorized to see (role-based access, field-level security, sharing). Test that a restricted user cannot surface restricted records via the agent.
- **Policy-Based Governance:** author field-, object-, and record-level access policies that apply across Agentforce.
- **Data masking is disabled by default** — enable it for PII before loading production data.
- **Einstein Trust Layer:** zero data retention with the model provider plus toxicity and prompt-injection detection (defense-in-depth, not a guarantee). Treat ingested documents as a prompt-injection vector and test with a deliberately "poisoned" document.

## B.11 Evaluation

Maintain a small regression set, re-run on every change to chunking, prompt, or retriever:

- **Retrieval quality** — question → expected chunk (precision/recall@k).
- **Grounding faithfulness** — does the answer follow from the retrieved chunks?
- **Citation accuracy** — does the cited source contain the claim?
- **Refusal behavior** — does an out-of-corpus question produce a correct decline?

## B.12 Scaling to a Production Document Corpus

The demo ingests ~5 PDFs. A real product whose documents (FAQ, functional, privacy, user agreement) already live in S3 — hundreds of files — uses the **same pipeline with no per-file upload**. The connector reads S3 directly; the UDLO **Directory** field (§B.2) points at whole folders.

### Backfilling existing files

S3 event notifications are **not retroactive** — files present before the notifier existed never generated an `ObjectCreated` event and will not ingest on their own. Re-put every object in place to emit one event per file; Data Cloud backfills the corpus. One command, no UI, nothing uploaded into Salesforce:

```bash
aws s3 cp s3://northwind-insurance/ s3://northwind-insurance/ \
  --recursive \
  --metadata-directive REPLACE
```

> **Warning.** Verify the flags against your bucket (KMS, ACLs, storage class) before running on the full corpus; a careless copy can alter object metadata or encryption.

### What actually needs engineering at scale

Ingestion mechanics are essentially free. The real work:

1. **Format.** Supported formats are **HTML, TXT, PDF only** (§2); HTML chunks best (the semantic chunker splits on heading tags). Convert `.docx` and other formats to one of these before backfill, or those files silently never chunk.
2. **Retrieval across heterogeneous doc types (the real design decision).** An FAQ, a user agreement, and a functional spec have very different structure and query patterns; one index with uniform chunking retrieves unevenly. Either tag documents with a `doc_type` and use **retriever metadata filters** (§B.7) to scope queries, or build **separate indexes/retrievers per category** and let the agent route. (Recall the Event S3 Source Key must be **empty** when documents span multiple root-level folders — §A.)
3. **Cost / metering.** Data Cloud bills on ingestion, embedding, and index storage. Model consumption before committing a large, long-document corpus — it is recurring, not one-time.

---

## Appendix A — Resource Inventory

**AWS**

| Resource | Name |
|---|---|
| S3 bucket (documents) | `northwind-insurance` |
| S3 bucket (Lambda code) | `northwind-lambda-code` |
| IAM user (ingestion, read-only) | `datacloud-s3-reader` |
| IAM policy | `DataCloudS3ReadOnly` |
| IAM user (deployment, admin) | `aws-admin` |
| IAM role (assumable admin) | `northwind-deploy-role` |
| IAM role (Lambda execution) | `northwind-s3-notifier-role` |
| Secrets Manager secrets | `northwind-rsa-key`, `northwind-consumer-key` |
| Lambda function | `northwind-s3-notifier` |
| S3 event notification | `Event_<timestamp>` on `northwind-insurance` |

**Salesforce / Data Cloud**

| Resource | Name / Detail |
|---|---|
| External Client App | `Northwind_S3_Notifier` (JWT bearer; cert `salesforce.crt`; scopes `cdp_ingest_api`, `api`, `refresh_token`/`offline_access`; PKCE off; admin pre-authorized) |
| S3 Connection | `Northwind_S3` (Access Key/Secret; parent `/`) |
| UDLO / UDMO | `Northwind_Insurance_New` (directories `auto/`, `home/`, `general/`; pattern `*.pdf`) |
| Search index | Semantic search + content harmonization; produces `…_chunk` and `…_index` objects |
| Retriever | `Northwind_Insurance_New Retriever` (individual; over the PDF search index; returns `Chunk`; top-k 5) — **record exact API Name from detail page** |
| Prompt template | `NorthWind_RAG` (Knowledge Answers type; Query + Retriever inputs) |
| Agent | `Northwind_Insurance_Agent` (Agentforce Service Agent; enhanced event logs on) |
| Agent action | Reference action → `NorthWind_RAG` prompt template (e.g. `NorthWind_RAG_…`) |
| Subagent (active) | `General FAQ` (repurposed → policy questions); plus `Escalation` |

**Crypto material:** `salesforce.key` · `salesforce.crt` (→ app) · `salesforce.pem` (→ Lambda)

## Appendix B — Troubleshooting Matrix

| Symptom | Cause | Resolution |
|---|---|---|
| Script halts at "export all three" | Long-lived `AKIA` keys (no session token) | Use **assume-role** credentials (§A.9) |
| `InvalidClientTokenId` on `GetRole` | `get-session-token` credentials barred from IAM | Use **assume-role** credentials (§A.9) |
| `Usage: ... <config_file>` then exit | Script run without the config argument | Pass `input_parameters_s3.conf` |
| `get-caller-identity` works but IAM call fails | Wrong credential type; that command is always allowed | Validate with `aws iam list-roles` |
| `realpath` prints a path but `ls` fails | `realpath` does not check existence | Always `ls -l` the path |
| Lambda zip is ~130 bytes | Git LFS pointer, not the binary | `git lfs install && git lfs pull`, or download raw from GitHub |
| Auth step returns `400`/`403` | Certificate/key mismatch, scopes, or PKCE enabled | Verify key set, scopes; disable PKCE; enable username-password flow if required |
| UDLO empty, "No Refresh History Yet" | No file notification has fired | Re-upload a file to trigger; verify directory alignment |
| Zero ingestion despite a deployed pipeline | Path mismatch or wrong file-type/case | Align bucket + connection + UDLO paths; match `*.pdf` case |
| Chunks absent but file rows present | Content Harmonization not enabled, or index still building | Enable harmonization; confirm search index is built |
| Retriever returns nothing; chunks exist in `…_chunk` | The `…_index` (IDMO) has no vectors | Verify vector records in the `…_index` object, not just chunks (§B.7) |
| Unstructured object not selectable in a prompt template | Using **Field Generation** type (binds to a record object/field) | Use the **Knowledge Answers** template type (§B.8) |
| Resolved Prompt CONTEXT is empty | Retriever Output Fields missing `Chunk`, or retriever-ID mismatch | Set Output Fields = `Chunk`; confirm the API name (§B.7–B.8) |
| Agent grounds correctly but user sees no answer | `promptResponse` output "Show in conversation" is off | Enable Show in conversation on the Prompt Response output (§B.9) |
| Prompt resolves but no answer is generated | `isPreviewOnly` input set true | Set `isPreviewOnly` = false (§B.9) |
| Agent answers generic / ignores the custom retriever | Data Library attached at agent creation, or default knowledge action still present | Skip the Data Library; remove the default "Answer Questions with Knowledge" action (§B.9) |
| Subagent rename / classification / scope edit does not persist | Agent was not deactivated before editing | Deactivate → edit → save → verify → reactivate (§B.9) |
| Retriever-ID input filled unpredictably by the agent | No fixed-value field; reasoning engine fills it | Pin the exact API name in the input **Description** with an "always use exactly this value" instruction (§B.9) |

## Appendix C — Security Checklist

- [ ] Root user has **no** access keys.
- [ ] Machine IAM users (`datacloud-s3-reader`, `aws-admin`) have **no** console access.
- [ ] Ingestion user is **read-only**, scoped to a single bucket.
- [ ] **Deployment admin access key (`AKIA…`) deactivated/deleted after deployment (§A.11).**
- [ ] No secrets (`.pem`, secret keys, session tokens) committed to source control or stored in the S3 bucket.
- [ ] Data Cloud **data masking enabled** before loading production data.
- [ ] Secure-retrieval test performed: a restricted user cannot surface restricted records via the agent.
- [ ] Prompt-injection test performed against the knowledge base.

## Appendix D — Revision History

| Version | Date | Author | Summary |
|---|---|---|---|
| 1.0 | 27 Jun 2026 | Anshul Sharma | Initial release. Documents the full AWS + Data Cloud configuration through verified end-to-end ingestion (chunks confirmed in Data Explorer). Added post-deployment key-deactivation requirement (§A.11) and security checklist (Appendix C). |
| 2.0 | 28 Jun 2026 | Anshul Sharma | Built and verified the retrieval/grounding chain end-to-end. Expanded §B.7 (Retriever), added §B.8 (Prompt Template) and §B.9 (Agent Configuration); renumbered Security → §B.10 and Evaluation → §B.11; added §B.12 (scaling to a production corpus, incl. the S3 backfill command). Enhanced §B.6 with the planned `Policy` object and the vectorise-vs-direct-lookup decision. Updated the resource inventory and troubleshooting matrix with retriever/prompt/agent gotchas. |

---

*End of document.*
