param(
    [string]$ConfigPath = "config/tenants.json"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($env:GITHUB_TOKEN)) {
    throw "GITHUB_TOKEN is not set."
}

if (-not (Test-Path $ConfigPath)) {
    throw "Configuration file not found: $ConfigPath"
}

$Tenants = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

$Headers = @{
    Accept = "application/vnd.github+json"
    Authorization = "Bearer $env:GITHUB_TOKEN"
    "X-GitHub-Api-Version" = "2022-11-28"
}

function New-RulesetPayload([string]$Name, [string]$Branch) {
    return @{
        name = $Name
        target = "branch"
        enforcement = "active"
        conditions = @{
            ref_name = @{
                include = @("refs/heads/$Branch")
                exclude = @()
            }
        }
        rules = @(
            @{ type = "deletion" }
            @{ type = "non_fast_forward" }
            @{
                type = "pull_request"
                parameters = @{
                    required_approving_review_count = 1
                    dismiss_stale_reviews_on_push = $true
                    require_code_owner_review = $false
                    require_last_push_approval = $false
                    required_review_thread_resolution = $true
                }
            }
            @{
                type = "required_status_checks"
                parameters = @{
                    strict_required_status_checks_policy = $true
                    do_not_enforce_on_create = $false
                    required_status_checks = @(
                        @{ context = "Branch Route Validation" }
                    )
                }
            }
        )
        bypass_actors = @()
    }
}

foreach ($Tenant in $Tenants) {
    $Owner = [string]$Tenant.owner
    $Repo = [string]$Tenant.repo
    $Sample = [string]$Tenant.sample

    if ([string]::IsNullOrWhiteSpace($Owner) -or
        [string]::IsNullOrWhiteSpace($Repo) -or
        [string]::IsNullOrWhiteSpace($Sample)) {
        throw "Each tenant must have owner, repo and sample values."
    }

    $BaseUrl = "https://api.github.com/repos/$Owner/$Repo/rulesets"
    Write-Host "`nRepository: $Owner/$Repo"

    $Existing = @(Invoke-RestMethod -Method Get -Uri $BaseUrl -Headers $Headers)
    $ExistingByName = @{}
    foreach ($Item in $Existing) {
        if (-not [string]::IsNullOrWhiteSpace($Item.name)) {
        $ExistingByName[$Item.name] = $Item.id
    }

    $Definitions = @(
        @{ Name = "branch-governance-main"; Branch = "main" }
        @{ Name = "branch-governance-uat"; Branch = "$Sample-uat" }
        @{ Name = "branch-governance-prod"; Branch = $Sample }
    )

    foreach ($Definition in $Definitions) {
        $Payload = New-RulesetPayload -Name $Definition.Name -Branch $Definition.Branch
        $Json = $Payload | ConvertTo-Json -Depth 20

        if ($ExistingByName.ContainsKey($Definition.Name)) {
            $Id = $ExistingByName[$Definition.Name]
            $Uri = "$BaseUrl/$Id"
            Invoke-RestMethod -Method Put -Uri $Uri -Headers $Headers -Body $Json -ContentType "application/json" | Out-Null
            Write-Host "Updated $($Definition.Name) -> $($Definition.Branch)"
        }
        else {
            Invoke-RestMethod -Method Post -Uri $BaseUrl -Headers $Headers -Body $Json -ContentType "application/json" | Out-Null
            Write-Host "Created $($Definition.Name) -> $($Definition.Branch)"
        }
    }
}

Write-Host "`nRuleset configuration completed."
