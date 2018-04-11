Ensure-Module "AzureRm";
Ensure-Module "Azure";

$ErrorActionPreference = "Stop";

$global:armTemplate = @{
    "`$schema" = "https://schema.management.azure.com/schemas/2015-01-01/deploymentTemplate.json#";
    "contentVersion" = "1.0.0.0";
    "parameters" = @{ };
    "variables" = @{ };
    "resources" = [System.Collections.ArrayList]::new();
    "outputs" = @{ };
    }
  

function Login-DebugUser() {
    $ErrorActionPreference = "Stop";
    $pwdFile = Join-Path -Path $PSScriptRoot -ChildPath "azure.cred";
    if (Test-Path $pwdFile) {
        $login = Import-clixml -Path $pwdFile;
    } else {
        $login = @{
            Creds = Get-Credential -Message "Login to Azure subscription";
            TenantId = Read-Host Prompt "Enter tenantId";
            SubscriptionId = Read-Host Prompt "Enter SubscriptionId";
            };
        $login | Export-Clixml -Path $pwdFile;
    }
    Login-AzureRmAccount -Credential $login.Creds -TenantId $login.TenantId | Out-Null;
    Select-AzureRmSubscription -SubscriptionId $login.SubscriptionId | Out-Null;

    "Login successful:" | Format-List;
    Get-AzureRmResourceGroup | Format-Table ResourceGroupName,Location;
}

function Deploy-LoginAzure($user, $password, [switch]$serviceAccount, $tenantId, $subscriptionId) {
    if (!(Get-AzureRmContext).Account) {
        $subscription = Get-AzureRmSubscription -SubscriptionId $subscriptionId -ErrorAction SilentlyContinue -WarningAction SilentlyContinue;
        if (!$subscription) {
            $creds = [System.Management.Automation.PSCredential]::new($user, $password);
            Login-AzureRmAccount -Credential $creds -TenantId $tenantId -ServicePrincipal:($servicePrincipal.IsPresent) | Out-Null;
            Select-AzureRmSubscription -SubscriptionId $subscriptionId | Out-Null;
        }
    }
}

function Deploy-ResourceGroup($name, $location, $tags) {
    $rg = Get-AzureRmResourceGroup -Name $name -ErrorAction SilentlyContinue;
    $params = $PSBoundParameters;
    if ($tags) {
        $params["tag"] = $tags;
    }

    if ($rg) {
        if ($tags) {
            Set-AzureRmResourceGroup -Name $name -Tag $tags | Out-Null;
        }
    } else {
        New-AzureRmResourceGroup @params | Out-Null;
    }
}

function Register-AzureProvider($namespace) {
    if (!$global:providers) {
        $global:providers = Get-AzureRmResourceProvider;
    }
    $provider = $global:providers | ? { $_.ProviderNamespace -eq $namespace } | Select-Object -First 1;
    if ($provider -eq $null -or $provider.RegistrationState -eq "NotRegistered") {
        Register-AzureRmResourceProvider -ProviderNamespace $namespace;
        $global:providers = Get-AzureRmResourceProvider;
    }
}

function Invoke-AzureRmResourceApi([string]$method, [string]$resourceGroupName, [string]$provider, [string]$resourceName, [string]$apiVersion, [Hashtable]$headers, $body, [string]$contentType, [string]$inFile, [switch]$ignore404) {
    $returnValue = $null;
    $subscriptionId = (Get-AzureRmContext).Subscription.Id;
    $url = (Join-Url "subscriptions" $subscriptionId "resourceGroups" $resourceGroupName "providers" $provider $resourceName) + "?api-version=$apiVersion";
    $returnValue = Invoke-AzureRmApi @PSBoundParameters -Uri $url;
    return $returnValue;
}

function Invoke-AzureRmApi([string]$method, [Uri]$uri, [Hashtable]$headers, $body, [string]$contentType, [string]$inFile, [switch]$ignore404) {
    $returnValue = $null;
    $uri = [Uri]::new($url, [UriKind]::RelativeOrAbsolute);
    if (!$uri.IsAbsoluteUri) {
        $PSBoundParameters["uri"] = Join-Url "https://management.azure.com" $url;
    }
    $token = Get-AccessToken "https://management.core.windows.net/";
    if ($headers) {
        $PSBoundParameters["headers"]["Authorization"] = "Bearer $token"; ;
    } else {
        $PSBoundParameters["headers"] = @{ "Authorization" = "Bearer $token"; };
    }
    $PSBoundParameters.Remove("ignore404") | Out-Null;

    Write-LogDebug "Invoking $method request to $($PSBoundParameters["uri"])";
    try {
        $returnValue = Invoke-RestMethod @PSBoundParameters -TimeoutSec 0;
    } catch [System.Net.WebException] {
        if (!$_.Exception.Response) {
            throw;
        } elseif ($_.Exception.Response.StatusCode -eq 404) {
            if (!$ignore404) {
                throw;
            }
        } elseif ($_.Exception.Response.ContentLength -gt 0) {
            $data = $_.Exception.Response.GetResponseStream().GetBuffer();
            $message = [System.Text.Encoding]::ASCII.GetString($data);
            throw $message;
        } else {
            throw;
        }
    }
    return $returnValue;
}

function Get-AccessToken($resource) {
    $returnValue = "";
    
    Get-AzureRmResourceGroup | Out-Null;

    $resource = [Uri]::new($resource).GetLeftPart([UriPartial]::Authority);
    $context = Get-AzureRmContext;
    $cacheItems = $context.TokenCache.ReadItems();
    $returnValue = $cacheItems | ? { $_.TenantId -eq $context.Tenant.Id -and $_.Resource -like "$resource*" } | Select-Object -First 1 -ExpandProperty "AccessToken";
    if (!$returnValue) {
        throw [InvalidOperationException] "Access token not found for tenant $($context.Tenant.Id) and resource $resource";
    }
    return $returnValue;
}

function Deploy-AzureResource([Hashtable]$resource, [string]$resourceGroupName) {
    $templateFile = [System.IO.Path]::GetTempFileName();
    $template = (Clone-Object $global:armTemplate).Result;
    $template.resources.Add($resource);
    $template | ConvertTo-Json -Depth 30 -Compress | Out-File -FilePath $templateFile;

    $deploymentName = "{0}-{1:yyyMMddtHHmmss}" -f $resource.Name,(Get-Date);
    $deployment = New-AzureRmResourceGroupDeployment -Name $deploymentName -ResourceGroupName $resourceGroupName -Mode Incremental -TemplateFile $templateFile;
    Remove-Item -Path $templateFile;
}

if (!(Get-AzureRmContext).Account) {
    [Console]::WriteLine('Cannot continue without authenticating to Azure.  Please run Login-DebugUser for debugging & local execution or Login-AzureRmAccount for execution as a service account.');
}
