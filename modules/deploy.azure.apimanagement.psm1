Register-AzureProvider "Microsoft.ApiManagement";
Add-NameFormatType "ApiManagement";
[DeploymentFunctions]::AddExtensionMethod("AddApiMgmtApi", { param($apiMgmt, $apiName, $apiPath, $swaggerPath)
                                                             $apim = Get-ApiManagement -Graph $this.DeploymentGraph -Name $apiName;
                                                             $apim.Apis.Add(@{ ApiName = $apiName; ApiHost = $this.CurrentDeploymentItem.HostName; ApiPath = $apiPath; SwaggerPath = $swaggerPath; }); });
Register-ReferenceIdentifier -Regex "(?<=\[.*)(?<=\`$this\.AddApiMgmtApi\()(((?<![``])['`"])((?:.(?!(?<![``])\1))*.?)\1(,\s?)?){4}(?=\))(?=.*])" `
                             -Resolver { param($m, $currentItem, $graph)
                                         $params = $m[0] -split ',' | % { $_.Trim('"',"'") };
                                         return @{ Dependent = Get-DeploymentItem -Type "ApiManagement" -Name $params[0]; Requisite = $currentItem; } };
function Deploy-ApiManagement($name, $sku, $adminEmail, $organization, $capacity, $products, $apis, $parent) {
    $params = @{ ResourceGroupName = $parent.Name;
                 Name = $name; }
    $apim = Get-AzureRmApiManagement @params -ErrorAction SilentlyContinue;
    if ($apim) {
        Write-LogInfo "Api management $name already created";
    } else {
        Write-LogInfo "Creating api management $name ...";
        $params = [Hashtable]$PSBoundParameters;
        $params.Remove("parent") | Out-Null;
        $params["ResourceGroupName"] = $parent.Name;
        $params["Location"] = if ($location) { $location } else { $parent.Location };
        $apim = New-AzureRmApiManagement @params;
    }

    foreach ($product in $products) {
        Ensure-ApiManagementProdut -ResourceGroupName @product $parent.Name -ApiManagementName $name;
    }

    foreach ($api in $apis) {
        Update-ApiManagementApi @api -ResourceGroupName $parent.Name -ApiManagementName $name;
    }
}

function Update-ApiManagementApi($resourceGroupName, $apiManagementName, $apiName, $apiHost, $apiPath, $swaggerPath) {
    $ctx = New-AzureRmApimanagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $api = Get-AzureRmApiManagementApi -Context $ctx -Name $apiName -ErrorAction SilentlyContinue;
    $params = @{  
        Context = $ctx;
        SpecificationFormat = [Microsoft.Azure.Commands.ApiManagement.ServiceManagement.Models.PsApiManagementApiFormat]::Swagger;
        SpecificationUrl = $swaggerUrl;
        Path = $apiPath;
        };
    $swaggerUrl = (Join-Url $apiHost $swaggerPath);
    if ($api) {
        Write-LogInfo "Importing update to API $apiName ...";
        $api = Import-AzureRmApiManagementApi @params -ApiId $api.Id;
    } else {
        Write-LogInfo "Importing new API $apiName ...";
        $api = Import-AzureRmApiManagementApi @params;
    }
}

function Ensure-ApiManagementProdut($resourceGroupName, $apiManagementName, $productName, $subscriptionRequired, $approvalRequired) {
    $ctx = New-AzureRmApimanagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $product = Get-AzureRmApiManagementProduct -Context $ctx -Name $apiName -ErrorAction SilentlyContinue;
    $params = @{  
        Context = $ctx;
        Title = $productName;
        SubscriptionRequired = $subscriptionRequired;
        ApprovalRequired = $approvalRequired;
        };
    if ($product) {
        Write-LogInfo "Updating product $productName ...";
        $product = Set-AzureRmApiManagementProduct @params -ProductId $product.Id;
    } else {
        Write-LogInfo "Creating new product $productName ...";
        $product = New-AzureRmApiManagementProduct @params;
    }
}