Ensure-Module ".\modules\deploy.azure.psm1";

Register-AzureProvider "Microsoft.Web";
Add-NameFormatType "AppServicePlan";
Add-NameFormatType "AppService";

$ErrorActionPreference = "Stop";

$appServicePlanActions = @{
    
    };
$appServiceActions = @{
    GetPublishProfile = { return Get-AppServiceDeploymentProfile -ResourceGroup $this.Parent.Parent.Name -AppService $this.Name; };
    };

$functionTemplate = @{
    "name" = "[name]";
    "type" = "Microsoft.Web/sites";
    "apiVersion" = "2016-08-01";
    "location" = "[location]";
    "kind" = "functionapp";
    "properties" = @{ 
        "serverFarmId" = "[appServicePlanName]";
        "siteConfig" = @{
            "alwaysOn" = "[alwaysOn]";
            "appSettings" = @( );
            }
        };
    "resources" = @( @{  
        "apiVersion" = "2015-08-01";
        "name" = "appsettings";
        "type" = "config";
        "properties" = @{
            "AzureWebJobsStorage" = "[storageAccount]";
            "AzureWebJobsDashboard" = "[storageAccount]";
            "WEBSITE_CONTENTAZUREFILECONNECTIONSTRING" = "[storageAccount]";
            "WEBSITE_CONTENTSHARE" = "[name]"
            };
        "dependsOn" = @( "[name]" );
        }; @{
            "apiVersion" = "2015-08-01";
            "name" = "connectionstrings";
            "type" = "config";
            "properties" = @{ };
            "dependsOn" = @( "[name]" );
            }; )
    };

Add-NameFormatType "FunctionApp";

$functionActions = @{
    GetAccessToken = { return Invoke-AzureRmResourceApi -Method "GET" -ResourceGroupName $this.parent.parent.name -Provider "Microsoft.Web/Sites" -ResourceName (Join-Url $this.Name "/functions/admin/token") -ApiVersion "2016-08-01"; };
    GetKey = { param($type) return Invoke-RestMethod -Method "GET" -Uri "$($this.Url)/admin/host/$type" | ConvertFrom-Json; };
    GetMasterKey = { return $this.GetKey("systemkeys/_master").value; };
    GetDefaultKey = { return $this.GetKey("keys").keys[0].value; };
    GetFunctions = { return Invoke-AzureScmApi -Method "GET" -ResourceGroupName $this.parent.parent.name -AppServiceName $this.name -Uri "functions" | ConvertFrom-Json; };
    GetFunctionUrl = { param($functionName) return Join-Url $this.Url "api" $functionName };
    };

function Deploy-FunctionApp($name, $location, [switch]$alwaysOn, $storageAccount, [switch]$autoCreateStorageAccount, $appSettings, $connectionStrings, $code, $parent) {
    $PSBoundParameters["appServicePlanName"] = $parent.Name;
    if (!$location) {
        $PSBoundParameters["location"] = $parent.Parent.Location;
    }
    if (!$alwaysOn) {
        $PSBoundParameters["alwaysOn"] = $false;
    }
    $definition = (Clone-Object $functionTemplate).Result;
    $functionParams = $PSBoundParameters;
    $definition = (Resolve-Values -Object $definition -Values $functionParams).Result;
    if ($appSettings) {
        $templateSettings = $definition.Resources | ? { $_.name -eq "appsettings" };
        $templateSettings.properties = Join-Hashtable $templateSettings.properties $appSettings;
    }
    if ($connectionStrings) {
        $templateSettings = $definition.Resources | ? { $_.name -eq "connectionstrings" };
        $templateSettings.properties = Join-Hashtable $templateSettings.properties $connectionStrings;
    }

    Write-LogInfo "Creating/updating function app $name";
    Deploy-AzureResource -ResourceGroupName $parent.Parent.Name -Resource $definition;
    if ($code) {
        Write-LogInfo "Deploying function app code...";
        Deploy-AppServiceCode @code -ResourceGroupName $parent.Parent.Name -AppServiceName $name;
    }
    $functionApp = Get-AzureRmResource -ResourceGroupName $parent.parent.name -ResourceName $name;

    $functionValues = @{
        Url = "https://$($functionApp.defaultHostName)";
        };
    return Join-Hashtable $functionValues $functionActions;
}


function Deploy-AppServicePlan($name, $location, $tier, $parent) {
    $plan = Get-AzureRmAppServicePlan -ResourceGroupName $parent.Name -Name $name -ErrorAction SilentlyContinue;
    $params = $PSBoundParameters;
    $params["resourceGroupName"] = $parent.Name;
    if (!$params["location"]) {
        $params["location"] = $parent.Location;
    }
    $params.Remove("Parent") | Out-Null;
    
    if ($plan) {
        if ($plan.Sku.Tier -ne $tier) {
            Write-LogInfo "Updating app service plan $name ...";
            $params.Remove("location") | Out-Null;
            $plan = Set-AzureRmAppServicePlan @params;
        } else {
            Write-LogInfo "App service plan $name already up-to-date.";
        }
    } else {
        Write-LogInfo "Creating app service plan $name ...";
        $plan = New-AzureRmAppServicePlan @params;
    }
    return Join-Hashtable @{} $script:appServicePlanActions;
}

function Deploy-AppService($name, $tier, $appSettings, $connectionStrings, $code, $webJobs, $parent) {
    $app = Get-AzureRmWebApp -ResourceGroupName $parent.Parent.Name -Name $name -ErrorAction SilentlyContinue;
    $params = $PSBoundParameters;
    $params["location"] = $parent.Location;
    $params["resourceGroupName"] = $parent.Parent.Name;
    $params.Remove("parent") | Out-Null;

    if ($app) {
        $params = @{
            Name = $name;
            ResourceGroupName = $parent.Parent.Name;
            };
        if ($appSettings -and $appSettings.Count) { 
            #wierd workaround for app settings: https://github.com/Azure/azure-powershell/issues/340 (see last comment about values explicitly using ToString)
            $params["appSettings"] = $appSettings.GetEnumerator() | ConvertTo-Hashtable -KeySelector { $_.Name } -ValueSelector { "$($_.Value)" };
        }
        if ($connectionStrings -and $connectionStrings.Count) {
            $params["connectionStrings"] = $connectionStrings;
        }
        if ($params.AppSettings -or $params.ConnectionStrings) {
            $app = Set-AzureRmWebApp @params;
        }
    } else {
        $params = @{
            Name              = $name;
            ResourceGroupName = $parent.Parent.Name;
            Tier              = $tier;
            Location          = $parent.Location;
            };
        $app = New-AzureRmWebApp @params;

        if ($appSettings       -and $appSettings.Count      ) { $params["appSettings"] = $appSettings;             }
        if ($connectionStrings -and $connectionStrings.Count) { $params["connectionStrings"] = $connectionStrings; }
        if ($params.AppSettings -or $params.ConnectionStrings) {
            $params.Remove("location") | Out-Null;
            $app = Set-AzureRmWebApp @params;
        }
    }

    if ($code) {
        Deploy-AppServiceCode @code -ResourceGroupName $parent.Parent.Name -AppServiceName $name;
    }

    foreach ($webJob in $webJobs) {
        Deploy-AppServiceWebJob @webJob -ResourceGroupName $parent.Parent.Name -AppServiceName $name;
    }

    $appValues = @{ 
        HostName = $app.DefaultHostName; 
        AppSettings = $app.SiteConfig.AppSettings;
        ConnectionStrings = $app.SiteConfig.ConnectionStrings;
        };
    return Join-Hashtable $appValues $script:appServiceActions;
}

function Get-AppServiceDeploymentProfile($resourceGroupName, $appServiceName) {
    $filePath = [System.IO.Path]::GetTempFileName();
    $data = Get-AzureRmWebAppPublishingProfile -ResourceGroupName $resourceGroupName -Name $appServiceName -Format WebDeploy -OutputFile $filePath;
    $returnValue = ([XML]$data).PublishData.PublishProfile | Select-Object -First 1;
    Remove-Item $filePath;
    return $returnValue;
}

function Invoke-AzureScmApi([string]$method, [string]$resourceGroupName, [string]$appServiceName, [Uri]$uri, [Hashtable]$headers, $body, [string]$contentType, [string]$inFile) {
    $prof = Get-AppServiceDeploymentProfile @PSBoundParameters;
    $userName = $prof.userName;
    $password = $prof.userPWD;

    $PSBoundParameters.Remove("resourceGroupName") | Out-Null;
    $PSBoundParameters.Remove("appServiceName")    | Out-Null;
    
    $authHeader = "Basic {0}" -f [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(("{0}:{1}" -f $userName, $password)));
    if ($headers) {
        $PSBoundParameters["headers"]["Authorization"] = $authHeader;
    } else {
        $PSBoundParameters["headers"] = @{ "Authorization" = $authHeader; };
    }
    $PSBoundParameters["Uri"] = [Uri](Join-Url "https://$appServiceName.scm.azurewebsites.net/api/" $uri.ToString());

    Write-LogDebug "Invoking $method request to $($PSBoundParameters["uri"])";
    $returnValue = Invoke-RestMethod @PSBoundParameters;
    return $returnValue;
}