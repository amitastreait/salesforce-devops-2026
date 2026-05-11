# Salesforce DX - GitHub Actions CI/CD Pipeline

This repository automates Salesforce deployments across four environments using a **reusable template** pattern. All environment workflows delegate to `template.yaml` via `workflow_call`. The pipeline uses a **PR-driven model**: open/synchronize PRs trigger validation (dry-run), and merging a PR triggers the actual deployment - using a **Quick Deploy** pattern to reuse the already-validated job and skip re-running tests.

---

## Architecture

```
abc_feature/** ──► sf.yaml             ─┐
staging        ──► sf_staging.yaml     ─┤
UAT / uat      ──► sf_uat.yaml         ├──► template.yaml  (Common Pipeline)
main / master  ──► sf_production.yaml  ─┘

workflow_dispatch ──► dispatch.yaml    (manual utility runs)
```

---

## Workflows

### `template.yaml` - Common Pipeline (reusable)

Single source of truth for all pipeline logic. Called via `workflow_call`.

| Property | Value |
|----------|-------|
| Trigger | `workflow_call` |
| Inputs | `envionment` (required), `runner` (required, default: `ubuntu-latest`), `env_alias` (required) |
| Secrets | `SLACK_WEBHOOK_URL` (optional); all others inherited from caller via `secrets: inherit` |
| Default test level | `RunSpecifiedTests` |

### `sf.yaml` - Dev Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `dev` |
| Trigger | Push to `abc_feature/**` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| Permissions | `contents: read`, `pull-requests: write`, `actions: read` |
| Calls | `template.yaml` with `envionment: dev` |

### `sf_staging.yaml` - Staging Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `staging` |
| Trigger | Pull Request (`opened`, `synchronize`) targeting `staging` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| `env_alias` | `uat` |
| Permissions | `contents: read`, `pull-requests: write`, `actions: read` |
| Calls | `template.yaml` with `envionment: staging` |

### `sf_uat.yaml` - UAT Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `UAT` |
| Trigger | Pull Request (`opened`, `synchronize`) targeting `UAT` or `uat` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| `env_alias` | `uat` |
| Permissions | `contents: read`, `pull-requests: write`, `actions: read` |
| Calls | `template.yaml` with `envionment: UAT` |

### `sf_production.yaml` - Production Pipeline

| Property | Value |
|----------|-------|
| GitHub Environment | `production` |
| Trigger | Pull Request (`opened`, `synchronize`) targeting `main` or `master` |
| Path Filter | `force-app/**` |
| Runner | `macos-latest` |
| `env_alias` | `prod` |
| Permissions | `contents: read`, `pull-requests: write`, `actions: read` |
| Calls | `template.yaml` with `envionment: production` |

### `dispatch.yaml` - Manual Dispatch Workflow

Utility workflow with configurable inputs for ad-hoc runs:

| Input | Type | Options / Default |
|-------|------|-------------------|
| `name` | string | Free text (default: `monalisa`) |
| `environment` | choice | `dev`, `UAT`, `production` |
| `test-level` | choice | `RunSpecifiedTests`, `RunLocalTests`, `RunRelevantTests`, `DefaultTests` |
| `use-emoji` | boolean | `true` / `false` |
| `message` | string | Free text (optional) |
| `runner` | choice | `ubuntu-latest`, `windows-latest`, `macos-latest` |

---

## Pipeline Steps (template.yaml)

### Setup Phase - always runs

```
 1. Checkout code                  (fetch-depth: 0)
 2. Setup Node.js                  (>=24)
 3. Setup Java                     (>=11, Zulu distribution)
 4. Setup Python                   (>=3.10)
 5. Read PR Body                   (READ_PRBODY.py → apex_test_classes env var)
 6. Update .env.<env_alias> file   (inject AWS_ACCESS_KEY, AWS_ACCESS_SECRET, SITE_ADMIN, SITE_DOMAIN)
 7. Load .env file                 (xom9ikk/dotenv@v2, mode: <env_alias>)
 8. Install Salesforce CLI         (npm install -g @salesforce/cli)
 9. Verify SF CLI version
10. Install SF Code Analyzer       (open PRs only)
11. Install SFDX Git Delta         (sfdx-git-delta plugin)
12. Generate Delta Files           (sf sgd source delta HEAD~1 → HEAD, API 66.0 → ./delta)
13. Decrypt server.key             (AES-256-CBC via openssl)
14. Authenticate with Salesforce   (sf org login jwt)
```

### PR Phase - `opened` / `synchronize` (validate only, `--dry-run`)

```
15. Run Salesforce Code Analyzer        (open PRs only - not merged)
16. Quality Gate                        (fail on Sev1/Sev2 or >10 total violations)
17. SonarQube Scan                      (open PRs only - Apex language, SonarSource/sonarqube-scan-action@v8)
18a. Validate - With Specific Tests     (apex_test_classes != 'No Apex classes found')
18b. Validate - Default Test Level      (apex_test_classes == 'No Apex classes found')
18c. Validate - RunRelevantTests        (apex_test_classes == 'RunRelevantTests')
19. Enforce 82% Code Coverage           (CODE_COVERAGE.py deploy-result.json)
20. Validate Pre-Destructive Changes    (if <types> found in destructiveChanges/destructiveChanges.xml)
21. Post Validation Job ID as PR Comment (hidden comment: <!-- sf-validation-id -->)
```

### Merge Phase - PR `closed` + `merged == true` (actual deploy)

```
22. Read Validation Job ID from PR Comment
23. Deploy Pre-Destructive Changes      (if <types> found in destructiveChanges/destructiveChanges.xml)
24. Quick Deploy                        (reuse validated job ID → skip test re-runs)
    └─ fallback if expired/failed ──►
25a. Deploy - RunRelevantTests          (apex_test_classes == 'RunRelevantTests', no quick deploy)
25b. Deploy - Default Test Level        (apex_test_classes == 'No Apex classes found', no quick deploy)
25c. Deploy - With Specific Tests       (apex_test_classes != 'No Apex classes found', no quick deploy)
26. Deploy Post-Destructive Changes     (if <types> found in destructiveChanges/postDestructiveChanges.xml)
```

### Notification Phase - always runs

```
27. Notify Slack via curl  (status emoji, workflow name, repo, branch, actor, event, run URL)
```

---

## PR Body → Apex Test Classes

`READ_PRBODY.py` parses `github.event.pull_request.body` and sets the `apex_test_classes` environment variable, which controls which validate/deploy path runs:

| `apex_test_classes` value | Validate step | Deploy step |
|---------------------------|---------------|-------------|
| Specific class names | `RunSpecifiedTests --tests <classes>` | `RunSpecifiedTests --tests <classes>` |
| `RunRelevantTests` | `RunRelevantTests` | `RunRelevantTests` |
| `No Apex classes found` | Default test level | Default test level |

---

## Quick Deploy Pattern

The pipeline avoids re-running tests on merge by reusing the Salesforce validation job from the open PR:

```
PR Opened/Sync  →  Validate (dry-run)  →  Store job ID in PR comment
PR Merged       →  Read job ID from PR comment
                →  sf project deploy quick --job-id <id>
                →  Falls back to full deploy if quick deploy fails/expired
```

The validation ID is posted as a hidden PR comment (`<!-- sf-validation-id -->`). On merge, older validation comments are cleaned up before posting a new one to keep the PR tidy.

---

## Delta Deployment (SFDX Git Delta)

Only changed metadata is deployed. `sfdx-git-delta` generates a delta `package.xml` and source directory between `HEAD~1` and `HEAD`:

```bash
mkdir delta
sf sgd source delta \
  --from "HEAD~1" --to "HEAD" \
  --generate-delta \
  --ignore-file .sgdignore \
  --output-dir ./delta \
  --ignore-whitespace \
  --api-version 66.0 \
  --source-dir force-app/main/default
```

All deploy steps use `delta/force-app/main/default` as the source directory.

---

## Destructive Changes

The pipeline supports pre- and post-destructive metadata removal in two separate passes:

| File | When validated | When deployed |
|------|---------------|---------------|
| `destructiveChanges/destructiveChanges.xml` | Open PR (dry-run) | On merge (before main deploy) |
| `destructiveChanges/postDestructiveChanges.xml` | - | On merge (after main deploy) |

Both steps are skipped if no `<types>` are present in the respective XML file.

---

## Environment Variable Injection

Before loading the `.env` file, the pipeline appends secrets into `.env.<env_alias>`:

```bash
echo "AWS_ACCESS_KEY= <secret>"     >> .env.<env_alias>
echo "AWS_ACCESS_SECRET= <secret>"  >> .env.<env_alias>
echo "SITE_ADMIN= <secret>"         >> .env.<env_alias>
echo "SITE_DOMAIN= <secret>"        >> .env.<env_alias>
```

The file is then loaded into the runner environment using `xom9ikk/dotenv@v2` with `mode: <env_alias>`. Environment `.env` files committed to the repo: `.env.uat`, `.env.prod`.

---

## Authentication - JWT Flow

Authentication uses an **External Client App** with JWT (certificate-based). The private key is stored encrypted in the repository and decrypted at runtime.

**Decrypt the key at runtime:**
```bash
openssl enc -nosalt -aes-256-cbc -d \
  -in <ENCRYPTION_KEY_FILE> \
  -out <JWT_KEY_FILE> \
  -base64 \
  -K <DECRYPTION_KEY> \
  -iv <DECRYPTION_IV>
```

**Authenticate with Salesforce:**
```bash
sf org login jwt \
  --client-id <CONSUMER_KEY> \
  --jwt-key-file <JWT_KEY_FILE> \
  --username <DEPLOYMENT_USER_USERNAME> \
  --set-default \
  --alias <ORG_DEFAULT_ALIAS> \
  --instance-url <HUB_LOGIN_URL>
```

---

## One-Time Setup

### Step 1 - Generate the Certificate

```bash
# Generate encrypted private key
openssl genpkey -aes-256-cbc -algorithm RSA \
  -pass pass:<YOUR_PASSPHRASE> \
  -out assets/dev/server.pass.key \
  -pkeyopt rsa_keygen_bits:2048

# Strip the passphrase
openssl rsa -passin pass:<YOUR_PASSPHRASE> \
  -in assets/dev/server.pass.key \
  -out assets/dev/server.key

# Generate a CSR
openssl req -new -key assets/dev/server.key -out assets/dev/server.csr

# Self-sign the certificate (365 days)
openssl x509 -req -sha256 -days 365 \
  -in assets/dev/server.csr \
  -signkey assets/dev/server.key \
  -out assets/dev/server.crt
```

### Step 2 - Create an External Client App in Salesforce

1. Go to **Setup > External Client Apps > New External Client App**.
2. Enable **OAuth Settings**.
3. Set the callback URL to `http://localhost:1717/OauthRedirect`.
4. Upload `server.crt` under **Use Digital Signatures**.
5. Add the required OAuth scopes (API, refresh token, etc.).
6. Note the **Consumer Key** - this is your `CONSUMER_KEY` secret.

### Step 3 - Encrypt the Private Key for GitHub Actions

```bash
# Generate AES-256 key and IV
openssl enc -aes-256-cbc -k <YOUR_PASSPHRASE> -P -md sha1 -nosalt

# Encrypt server.key
openssl enc -nosalt -aes-256-cbc \
  -in assets/dev/server.key \
  -out assets/dev/server.key.enc \
  -base64 \
  -K <KEY_FROM_ABOVE> \
  -iv <IV_FROM_ABOVE>
```

Commit `assets/dev/server.key.enc` to the repository. **Never commit the raw `server.key`.**

### Step 4 - Authenticate Locally (one-time verification)

```bash
sf org login jwt \
  --client-id <YOUR-CLIENT-ID> \
  --jwt-key-file assets/dev/server.key \
  --username <deployment-user-name> \
  --set-default --alias DEV_INT_ORG \
  --instance-url https://test.salesforce.com
```

---

## GitHub Environments & Secrets

Create four GitHub Environments (`dev`, `staging`, `UAT`, `production`) under **Settings > Environments**, each with the secrets and variables below.

### Secrets (per environment)

| Secret | Description |
|--------|-------------|
| `CONSUMER_KEY` | External Client App client ID |
| `ENCRYPTION_KEY` | AES encryption key |
| `DECRYPTION_KEY` | AES key to decrypt `server.key.enc` at runtime |
| `DECRYPTION_IV` | AES IV to decrypt `server.key.enc` at runtime |
| `ENCRYPTION_KEY_FILE` | Path to the encrypted key file (e.g. `assets/dev/server.key.enc`) |
| `JWT_KEY_FILE` | Path where the decrypted key is written (e.g. `assets/dev/server.key`) |
| `DEPLOYMENT_USER_USERNAME` | Salesforce username for deployment |
| `SLACK_WEBHOOK_URL` | Slack incoming webhook URL |
| `SLACK_API_KEY` | Slack API key |
| `SONAR_TOKEN` | SonarQube authentication token |
| `AWS_ACCESS_KEY` | AWS access key (injected into .env file) |
| `AWS_ACCESS_SECRET` | AWS secret key (injected into .env file) |
| `SITE_ADMIN` | Site admin credential (injected into .env file) |
| `SITE_DOMAIN` | Site domain (injected into .env file) |

### Variables (per environment)

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `ORG_DEFAULT_ALIAS` | `DEV_INT_ORG` | Salesforce org alias |
| `HUB_LOGIN_URL` | `https://test.salesforce.com` | `test.salesforce.com` for sandboxes, `login.salesforce.com` for production |
| `NODE_VERSION` | `>=24` | Node.js version |
| `SF_CLI_VERSION` | `latest` | Salesforce CLI version |
| `PYTHON_VERSION` | `>=3.10` | Python version |

### Organization-Level Variable

| Variable | Description |
|----------|-------------|
| `ORGANIZATION_VARIABLE` | Shared variable available across all environments |

---

## Code Quality Gate

Two static analysis tools run on every open (not merged) PR:

### Salesforce Code Analyzer (`forcedotcom/run-code-analyzer@v2`)

Results saved as `sfca_results.html` / `sfca_results.json` and uploaded as artifacts. Pipeline fails if:

| Condition | Threshold |
|-----------|-----------|
| Severity 1 violations | > 0 |
| Severity 2 violations | > 0 |
| Total violations | > 10 |

### SonarQube (`SonarSource/sonarqube-scan-action@v8`)

Scans Apex source with the following configuration:

| Setting | Value |
|---------|-------|
| Language | `apex` |
| Coverage inclusions | `**/*Test.cls` |
| Exclusions | `.cmp`, `fflib_*.cls`, `.yml`, `.js`, `.xml`, `.css`, `.html`, web fonts, SVGs, static resources |

---

## Code Coverage Enforcement

After every dry-run validation on a PR, `CODE_COVERAGE.py` parses `deploy-result.json` and enforces a minimum of **82% Apex code coverage**. The job fails if coverage falls below this threshold.

---

## Slack Notifications

Every pipeline run sends a Slack notification on completion (success or failure) via `curl` POST with `if: always()`:

| Field | Value |
|-------|-------|
| Status | Success (✅) or Failure (❌) |
| Repository | `github.repository` |
| Branch | `github.ref_name` |
| Triggered by | `github.actor` |
| Event | `github.event_name` |
| Run URL | Direct link to the Actions run |

---

## Branch Strategy

```
abc_feature/**  ──►  Dev         (push only)
staging         ──►  Staging     (PR opened/synchronize)
UAT / uat       ──►  UAT         (PR opened/synchronize)
main / master   ──►  Production  (PR opened/synchronize)
```

> Deployments are triggered by a **merged PR** (`pull_request.merged == true && action == 'closed'`), not by a direct push event.

---

## Tool Versions

| Tool | Version |
|------|---------|
| Salesforce CLI | `latest` |
| Node.js | `>=24` |
| Java (Zulu) | `>=11` |
| Python | `>=3.10` |
| Salesforce API (delta generation) | `66.0` |
| Salesforce API (source) | `65.0` |
| Default Runner (template) | `ubuntu-latest` |
| Runner (all callers) | `macos-latest` |
