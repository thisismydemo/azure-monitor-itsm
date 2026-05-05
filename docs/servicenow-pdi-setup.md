# ServiceNow PDI Developer Environment Setup

This guide walks through getting a free ServiceNow Personal Developer Instance (PDI) and configuring it for the Azure Monitor integration.

## What is a PDI?

A ServiceNow PDI is a free, full-featured ServiceNow instance available to any developer who registers at [developer.servicenow.com](https://developer.servicenow.com). It includes ITSM, ITOM, Table API, Integration Hub, Flow Designer — everything needed to test this integration.

**Important notes:**
- The instance hibernates after ~10 days of inactivity — you'll get email warnings
- Outbound email is disabled (not relevant for this integration)
- Log back in or request a new instance to keep it alive

---

## Step 1: Get a PDI

1. Go to [developer.servicenow.com](https://developer.servicenow.com)
2. Sign in or create a free developer account
3. Click **Request Instance** in the top navigation
4. Select your preferred ServiceNow release (Washington DC or later recommended)
5. Note your instance URL (e.g., `https://dev123456.service-now.com`) and admin credentials

---

## Step 2: Automated Setup (Recommended)

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

## Step 3: Manual Setup (Alternative)

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

## Step 4: Configure the Business Rule (Bi-Directional Close)

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

## Step 5: Test the Integration

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
