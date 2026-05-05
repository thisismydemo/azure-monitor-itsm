# CI/CD Pipeline Deployment

Deploy the Azure Monitor → ServiceNow integration from a CI/CD pipeline. All three examples use the PowerShell orchestrator (`Deploy-Solution.ps1`) with credentials stored in the pipeline's secret store.

!!! danger "Never store SNOW credentials in YAML"
    **Never** put SNOW passwords, API keys, or any credentials directly in pipeline YAML files. Always use the pipeline's native secret/variable store (GitHub Secrets, Azure DevOps Variable Groups, GitLab masked variables).

!!! tip "Auth recommendation"
    Use **OIDC / Workload Identity Federation** for the pipeline's Azure identity where possible — no client secrets to rotate. Managed Identity handles Azure resource auth after deployment.

---

## GitHub Actions

**File:** `.github/workflows/deploy-solution.yml`

Trigger: **Manual** (`workflow_dispatch`) with inputs for resource group, region, SNOW URL, username, and deployment method.

### Workflow

```yaml
name: Deploy Azure Monitor → ServiceNow Integration

on:
  workflow_dispatch:
    inputs:
      resource_group:
        description: 'Resource group name'
        required: true
        default: 'rg-azure-monitor-itsm'
      location:
        description: 'Azure region'
        required: true
        default: 'eastus'
      snow_instance_url:
        description: 'ServiceNow instance URL (e.g. https://dev123456.service-now.com)'
        required: true
      snow_username:
        description: 'ServiceNow integration account username'
        required: true
      deployment_method:
        description: 'IaC method'
        required: true
        default: 'Bicep'
        type: choice
        options: [Bicep, Terraform, ARM, Ansible]

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    name: Deploy Integration
    runs-on: ubuntu-latest
    environment: production

    steps:
      - uses: actions/checkout@v4

      - name: Azure Login (OIDC)
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}

      - name: Install Az PowerShell module
        shell: pwsh
        run: Install-Module Az -Scope CurrentUser -Force -AllowClobber

      - name: Deploy Integration
        shell: pwsh
        env:
          SNOW_PASSWORD: ${{ secrets.SNOW_PASSWORD }}
        run: |
          $pw = ConvertTo-SecureString $env:SNOW_PASSWORD -AsPlainText -Force
          .\deploy\scripts\Deploy-Solution.ps1 `
            -ResourceGroupName '${{ inputs.resource_group }}' `
            -Location '${{ inputs.location }}' `
            -SnowInstanceUrl '${{ inputs.snow_instance_url }}' `
            -SnowUsername '${{ inputs.snow_username }}' `
            -SnowPassword $pw `
            -DeploymentMethod ${{ inputs.deployment_method }} `
            -SkipTest
```

### Required GitHub Secrets

Configure these in **Settings → Secrets and variables → Actions**:

| Secret | Description |
|---|---|
| `AZURE_CLIENT_ID` | App registration client ID (for OIDC) |
| `AZURE_TENANT_ID` | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription ID |
| `SNOW_PASSWORD` | ServiceNow integration account password |

### OIDC Setup

To use OIDC (recommended over client secrets), configure a federated credential on your app registration:

1. In Azure AD → App registrations → your app → **Certificates & secrets → Federated credentials**
2. Add credential: **GitHub Actions** → enter your org/repo and `environment: production`
3. The workflow uses `id-token: write` permission to request the OIDC token automatically

---

## Azure DevOps

**File:** `deploy/pipelines/azure-pipelines.yml`

Trigger: **Manual** (no automatic trigger). Run from Pipelines → Run pipeline.

### Pipeline

```yaml
trigger: none  # Manual runs only

parameters:
  - name: resourceGroup
    displayName: Resource Group
    type: string
    default: rg-azure-monitor-itsm
  - name: location
    displayName: Azure Region
    type: string
    default: eastus
  - name: snowInstanceUrl
    displayName: ServiceNow Instance URL
    type: string
  - name: snowUsername
    displayName: ServiceNow Username
    type: string
  - name: deploymentMethod
    displayName: Deployment Method
    type: string
    default: Bicep
    values:
      - Bicep
      - Terraform
      - ARM
      - Ansible

variables:
  - group: azure-monitor-itsm-secrets  # Variable group containing SNOW_PASSWORD

pool:
  vmImage: ubuntu-latest

steps:
  - checkout: self

  - task: AzurePowerShell@5
    displayName: Deploy Azure Monitor → ServiceNow Integration
    inputs:
      azureSubscription: 'azure-monitor-itsm-service-connection'
      ScriptType: InlineScript
      Inline: |
        $pw = ConvertTo-SecureString '$(SNOW_PASSWORD)' -AsPlainText -Force
        .\deploy\scripts\Deploy-Solution.ps1 `
          -ResourceGroupName '${{ parameters.resourceGroup }}' `
          -Location '${{ parameters.location }}' `
          -SnowInstanceUrl '${{ parameters.snowInstanceUrl }}' `
          -SnowUsername '${{ parameters.snowUsername }}' `
          -SnowPassword $pw `
          -DeploymentMethod ${{ parameters.deploymentMethod }} `
          -SkipTest
      azurePowerShellVersion: LatestVersion
      pwsh: true
```

### Setup Steps

1. **Service connection**: Create an **AzureRM** service connection named `azure-monitor-itsm-service-connection` in **Project settings → Service connections**. Use Workload Identity Federation (OIDC) where available.

2. **Variable group**: Create a variable group named `azure-monitor-itsm-secrets` in **Pipelines → Library**:
   - Add `SNOW_PASSWORD` as a **secret variable**
   - Link the variable group to your pipeline

3. **Pipeline authorization**: The pipeline must be authorized to use both the service connection and variable group.

---

## GitLab CI

**File:** `deploy/pipelines/gitlab-ci.yml`

Trigger: **Manual** job (`when: manual`), runs only on the `main` branch.

### Pipeline

```yaml
default:
  image: mcr.microsoft.com/azure-cli:latest

variables:
  RESOURCE_GROUP: "rg-azure-monitor-itsm"
  LOCATION: "eastus"
  DEPLOYMENT_METHOD: "Bicep"
  # SNOW_INSTANCE_URL, SNOW_USERNAME: set in GitLab CI/CD Variables (not secret)
  # SNOW_PASSWORD, AZURE_CLIENT_SECRET: set as masked/protected CI/CD variables

stages:
  - deploy

deploy-integration:
  stage: deploy
  when: manual
  script:
    - az login --service-principal
        --username "$AZURE_CLIENT_ID"
        --password "$AZURE_CLIENT_SECRET"
        --tenant "$AZURE_TENANT_ID"
    - az account set --subscription "$AZURE_SUBSCRIPTION_ID"
    - apt-get update -qq && apt-get install -y -qq powershell
    - pwsh -Command |
        $pw = ConvertTo-SecureString '$SNOW_PASSWORD' -AsPlainText -Force
        ./deploy/scripts/Deploy-Solution.ps1
          -ResourceGroupName '$RESOURCE_GROUP'
          -Location '$LOCATION'
          -SnowInstanceUrl '$SNOW_INSTANCE_URL'
          -SnowUsername '$SNOW_USERNAME'
          -SnowPassword $pw
          -DeploymentMethod $DEPLOYMENT_METHOD
          -SkipTest
  environment:
    name: production
  only:
    - main
```

### Required GitLab CI/CD Variables

Configure in **Settings → CI/CD → Variables**:

| Variable | Type | Description |
|---|---|---|
| `AZURE_CLIENT_ID` | Variable | Service principal app ID |
| `AZURE_CLIENT_SECRET` | Masked + Protected | Service principal secret |
| `AZURE_TENANT_ID` | Variable | Azure tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Variable | Target subscription ID |
| `SNOW_INSTANCE_URL` | Variable | ServiceNow instance URL |
| `SNOW_USERNAME` | Variable | ServiceNow integration account username |
| `SNOW_PASSWORD` | Masked + Protected | ServiceNow integration account password |

---

## Security Notes

- **Never put SNOW credentials in pipeline YAML** — always use the pipeline's native secret store
- **Use OIDC / Workload Identity Federation** instead of long-lived client secrets for the pipeline's Azure identity where supported (GitHub Actions and Azure DevOps support this natively)
- **Deployed resources use Managed Identity** — the pipeline SPN is only used to call ARM deployment APIs; Logic Apps and Key Vault connections authenticate via Managed Identity at runtime
- **The `itsm-keyvault-connection-mi` connection name is hard-coded** in the Logic App templates — do not override it in pipeline parameters
- **Rotate the SNOW service account password regularly** and update the `ItsmApiSecret` Key Vault secret. Use `Set-KeyVaultSecrets.ps1 -UpdateOnly` after initial deployment
