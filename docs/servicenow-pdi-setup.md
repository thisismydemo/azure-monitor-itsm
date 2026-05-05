# ServiceNow PDI Developer Environment Setup

This guide walks through getting a free ServiceNow Personal Developer Instance (PDI) and configuring it for the Azure Monitor integration. If you don't want to use a live SNOW instance at all, skip to [Local Mock (No SNOW account required)](#local-mock-no-snow-account-required).

## What is a PDI?

A ServiceNow PDI is a free, full-featured ServiceNow instance available to any developer who registers at [developer.servicenow.com](https://developer.servicenow.com). It includes ITSM, ITOM, Table API, Integration Hub, Flow Designer — everything needed to test this integration.

**PDI facts:**
- Completely free — no credit card, no trial expiry
- Same platform as enterprise ServiceNow — full Table API, Business Rules, CMDB
- Hibernates after ~10 days of inactivity (you get email warnings before it sleeps)
- Wakes back up in ~5 minutes when you log in; or request a new one if it expired
- Outbound email is disabled by ServiceNow (not relevant for this integration)
- Do NOT use ServiceNow Learning Lab instances — those are temporary and get wiped

---

## Step 1: Get a PDI

1. Go to [developer.servicenow.com](https://developer.servicenow.com)
2. Click **Sign In** → **Create Account** (free)
3. After login, click **Start Building** or go to **My Instance** in the header
4. Click **Request Instance**
5. Select your ServiceNow release — **Washington DC (or later)** recommended for this integration
6. Wait 2–5 minutes for provisioning
7. Copy your instance URL (e.g., `https://dev123456.service-now.com`) and note your admin credentials

---

## Step 2: First Login and Orientation

1. Open your instance URL in a browser and log in as `admin`
2. On first login you may see a **Setup Wizard** — you can dismiss it
3. Key navigation for this integration:

| Where to go | How to get there |
|---|---|
| Incidents list | **Service Desk → Incidents** (or search `incident.list` in the nav filter) |
| Users | **User Administration → Users** |
| Business Rules | **System Definition → Business Rules** |
| REST API Explorer | **System Web Services → REST API Explorer** |
| Application Registry | **System OAuth → Application Registry** |

4. Verify the Table API works from your browser:
   ```
   https://dev123456.service-now.com/api/now/table/incident?sysparm_limit=5
   ```
   You should see a JSON response with sample incidents (browser will prompt for credentials).

---

## Step 3: Wake a Hibernated Instance

If your PDI hibernated:

1. Go to [developer.servicenow.com](https://developer.servicenow.com) → **My Instance**
2. Click **Wake Up** — the instance will be available in ~5 minutes
3. If the instance expired, click **Request Instance** to get a fresh one
   - Note: a fresh instance loses any customizations (Business Rules, users) — re-run `New-SnowPdiSetup.ps1` to restore them

---

## Step 4: Automated Setup (Recommended)

Run `New-SnowPdiSetup.ps1` to create the integration service account and verify the API:

```powershell
.\deploy\scripts\New-SnowPdiSetup.ps1 `
  -SnowInstanceUrl https://dev123456.service-now.com `
  -AdminUsername admin
```

The script will:
- Create the `azure_monitor_svc` service account
- Assign `itil` + `rest_service` roles
- Create and close a test incident
- Optionally create the Business Rule (if you provide `-CloseLogicAppWebhookUrl`)

---

## Step 5: Manual Setup (Alternative)

### Create the Integration User

1. Navigate to **User Administration → Users**
2. Click **New**
3. Fill in:
   - **User ID**: `azure_monitor_svc`
   - **First/Last name**: `Azure Monitor Integration`
   - **Password**: Choose a strong password (this goes in Key Vault)
   - **Active**: Checked
4. Save the record

### Assign Roles

On the new user record:
1. Scroll to the **Roles** related list
2. Click **Edit**
3. Add: `itil`, `rest_service`
4. Click **Save**

---

## Step 6: Configure the Business Rule (Bi-Directional Close)

The Business Rule fires the Close Logic App when an Azure Monitor-sourced incident is resolved.

### Get the Close Logic App Webhook URL

```powershell
# After deploying the Close Logic App
(Get-AzLogicAppTriggerCallbackUrl -ResourceGroupName rg-azure-monitor-itsm `
  -Name 'Azure-Monitor-Close-ITSM-HTTP-API' `
  -TriggerName 'When_a_HTTP_request_is_received').Value
```

### Create the Business Rule

1. In SNOW, navigate to **System Definition → Business Rules**
2. Click **New**
3. Configure:
   - **Name**: `Azure Monitor Close Alert on Ticket Complete`
   - **Table**: `Incident [incident]`
   - **Advanced**: Checked
   - **When**: After
   - **Insert**: Unchecked, **Update**: Checked
4. In the **Filter Conditions** tab, add:
   - `State | is | Resolved`
5. In the **Advanced** tab, paste the script from `src/servicenow/snow-automation-rule-script.js`
6. Replace `<CLOSE-LOGIC-APP-WEBHOOK-URL>` with the URL from the previous step
7. Save

---

## Step 7: Verify in the SNOW UI

After running `Test-Integration.ps1`, confirm in the PDI:

1. Navigate to **Service Desk → Incidents**
2. Search for the test incident — short description will contain "TestAlertRule-Integration"
3. Open the record and verify:
   - **Correlation ID** field = the Azure Monitor `alertId` (starts with `/subscriptions/`)
   - **Impact**, **Urgency**, **Priority** match the Sev2 → Moderate mapping
   - **State** = Resolved (if the close was also tested)

To see incoming REST API calls in the PDI:
1. Go to **System Log → All** (search `syslog.list` in the nav filter)
2. Filter **Source = REST** — all inbound Table API calls from the Logic App appear here

---

## Step 8: Test the Integration

```powershell
# Run the end-to-end test
.\deploy\scripts\Test-Integration.ps1 -ResourceGroupName rg-azure-monitor-itsm
```

This will:
1. POST a sample metric alert to the Alert Logic App
2. Poll SNOW for the created incident (correlation_id matching the test alertId)
3. Report the SNOW incident number on success

---

## SNOW Table API Reference

Base URL: `https://{instance}.service-now.com/api/now/table/{tableName}`

| Operation | Method | Endpoint | Notes |
|---|---|---|---|
| Create incident | POST | `/api/now/table/incident` | Returns `sys_id` |
| Update incident | PATCH | `/api/now/table/incident/{sys_id}` | |
| Query by correlation_id | GET | `/api/now/table/incident?sysparm_query=correlation_id=...` | |
| Lookup CI | GET | `/api/now/table/cmdb_ci_computer?sysparm_query=name=...` | Used for CI field |

---

## Correlation ID Pattern

The Azure Monitor `alertId` is stored in SNOW's `correlation_id` field:

```
/subscriptions/{subscriptionId}/providers/Microsoft.AlertsManagement/alerts/{alertGuid}
```

The Close Logic App uses `correlation_id` to find and close the right Azure Monitor alert.  
The Business Rule identifies Azure Monitor-sourced tickets by checking if `correlation_id` starts with `/subscriptions/`.

---

## REST API Explorer (PDI Built-In)

The PDI includes a built-in REST API Explorer — useful for manually testing API calls before the Logic App is wired up:

1. In your PDI, navigate to **System Web Services → REST API Explorer**
2. Select **Table API → POST /now/table/{tableName}**
3. Set `tableName = incident`
4. Paste a sample body from `samples/snow-responses/incident-created.json`
5. Click **Send** — you'll see the full request/response with headers

This lets you verify your service account has the correct permissions before deploying the Logic Apps.

---

## Local Mock (No SNOW Account Required)

If you don't have a PDI yet (or want fully offline development), use the included Docker mock:

```bash
cd dev/docker
docker-compose up
```

This starts [json-server](https://github.com/typicode/json-server) on `http://localhost:3000` with routes that mirror the ServiceNow Table API:

| SNOW Table API | Mock equivalent |
|---|---|
| `POST /api/now/table/incident` | `POST http://localhost:3000/api/now/table/incident` |
| `GET /api/now/table/incident?sysparm_query=...` | `GET http://localhost:3000/api/now/table/incident` |
| `PATCH /api/now/table/incident/{id}` | `PATCH http://localhost:3000/api/now/table/incident/{id}` |

Pre-seeded data is in `dev/docker/mock-snow-db.json` — add/edit records there.

**To test with the mock instead of SNOW:**
1. Set `ItsmApiIntegrationCode` in Key Vault to your machine's public IP + port 3000
2. Set `ItsmApiUserName` / `ItsmApiSecret` to any values (json-server doesn't check auth)
3. Run the Logic App — it will POST to the mock endpoint
4. Verify the incident was recorded: `curl http://localhost:3000/incident`

> **Note:** The mock is for local Logic App payload development only. It does not send webhooks back to the Close Logic App (no Business Rule equivalent). Use a real PDI for full bi-directional testing.

---

## Dev Container

Open this repo in VS Code and click **Reopen in Container** — the Dev Container in `dev/.devcontainer/` includes:

- Azure CLI + Bicep extension
- Terraform ≥ 1.5
- PowerShell 7 + Az module (auto-installed on container create)
- GitHub CLI
- VS Code extensions: Bicep, Terraform, PowerShell, Logic Apps, REST Client

Port 3000 is automatically forwarded from the container so `docker-compose up` in `dev/docker/` works without any extra configuration.
