Register-AzureProvider "Microsoft.ApiManagement";
Add-NameFormatType "ApiManagement";
[DeploymentFunctions]::AddExtensionMethod("AddApiMgmtApi", { param($apiMgmt, $apiName, $apiPath, $swaggerPath, $apiHost)
                                                             $apim = Get-DeploymentItem -Type "ApiManagement" -Name $apiMgmt -Graph $this.DeploymentGraph;
                                                             if (!$apim.Apis) { $apim["Apis"] = @(); }
                                                             if (!$apiHost) { $apiHost = "https://{0}.azurewebsites.net" -f $this.CurrentDeploymentItem.Name; }
                                                             $returnValue = @{ ApiName = $apiName; ApiHost = $apiHost; ApiPath = $apiPath; SwaggerPath = $swaggerPath; };
                                                             $apim.Apis += $returnValue;
                                                             return $returnValue; });
Register-ReferenceIdentifier -Regex "(?<=\[.*)(?<=\`$this\.AddApiMgmtApi\()(?:((?<![``])['`"])((?:.(?!(?<![``])\1))*.?)\1(,\s?)?)*(?=\))(?=.*])" `
                             -Resolver { param($m, $currentItem, $graph)
                                         $params = $m[0] -split ',' | % { $_.Trim('"',"'") };
                                         return @{ Dependent = Get-DeploymentItem -Type "ApiManagement" -Name $params[0] -Graph $graph; Requisite = $currentItem; } };
function Deploy-ApiManagement($name, $sku, $adminEmail, $organization, $capacity, $enableCors, $policy, $policyFile, $products, $apis, $users, $parent) {
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

    if ($policy -or $policyFile) {
        $params = @{
            Context = New-AzureRmApiManagementContext -ResourceGroupName $parent.Name -ServiceName $name;
            Policy = if ($policy) { $policy } else { Resolve-ScriptPath -Path $policyFile -GetContent };
            };
        Write-LogInfo "Setting custom policy ...";
        $policy = Set-AzureRmApiManagementPolicy @params;    
    } elseif ($enableCors) {
        $params = @{
            Context = New-AzureRmApiManagementContext -ResourceGroupName $parent.Name -ServiceName $name;
            Policy = "<policies><inbound>
                        <cors><allowed-origins><origin>*</origin></allowed-origins>
                                <allowed-methods><method>*</method></allowed-methods>
                                <allowed-headers><header>*</header></allowed-headers></cors>
                      </inbound><backend><forward-request /></backend><outbound /><on-error /></policies>";
            };
        Write-LogInfo "Setting CORS policy ...";
        $policy = Set-AzureRmApiManagementPolicy @params;    
    }

    $products = Set-ApiManagementProducts -Products $products -ResourceGroupName $parent.Name -ApiManagementName $name;
    $apis = Set-ApiManagementApis -Apis $apis -ResourceGroupName $parent.Name -ApiManagementName $name;
    $users = Set-ApiManagementUsers -Users $users -ResourceGroupName $parent.Name -ApiManagementName $name;
    return @{ Users = $users; };
}

function Set-ApiManagementProducts($products, $resourceGroupName, $apiManagementName) {
    $ctx = New-AzureRmApiManagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $removals = Get-AzureRmApiManagementProduct -Context $ctx | ? { $products.ProductName -notcontains $_.Title; };
    foreach ($removal in $removals) {
        Write-LogInfo "Removing product $($removal.Title) and all associated subscriptions ...";
        Remove-AzureRmApiManagementProduct -Context $ctx -ProductId $removal.ProductId -DeleteSubscriptions;
    }

    foreach ($product in $products) {
        Set-ApiManagementProduct @product @PSBoundParameters;
    }
}

function Set-ApiManagementApis($apis, $resourceGroupName, $apiManagementName) {
    $ctx = New-AzureRmApiManagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $removals = Get-AzureRmApiManagementApi -Context $ctx | ? { $apis.ApiName -notcontains $_.Name; };
    foreach ($removal in $removals) {
        Write-LogInfo "Removing API $($removal.Name) ...";
        Remove-AzureRmApiManagementApi -Context $ctx -ApiId $removal.ApiId;
    }

    foreach ($api in $apis) {
        Set-ApiManagementApi @api @PSBoundParameters;
    }
}

function Set-ApiManagementUsers($users, $resourceGroupName, $apiManagementName) {
    $returnValue = @{};
    $ctx = New-AzureRmApiManagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    #$removals = Get-AzureRmApiManagementUser -Context $ctx | ? { $apis.UserName -notcontains $_.UserId; };
    #foreach ($removal in $removals) {
    #    Write-LogInfo "Removing User $($removal.Name) ...";
    #    Remove-AzureRmApiManagementUser -Context $ctx -ApiId $removal.ApiId;
    #}

    foreach ($user in $users) {
        $returnValue[$user.Email] = Set-ApiManagementUser @user @PSBoundParameters;
    }
    return $returnValue;
}

function Set-ApiManagementProduct($resourceGroupName, $apiManagementName, $productName, $subscriptionRequired, $approvalRequired, $policy, $policyFile) {
    $ctx = New-AzureRmApimanagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $product = Get-AzureRmApiManagementProduct -Context $ctx -Title $productName -ErrorAction SilentlyContinue;
    $params = @{  
        Context = $ctx;
        Title = $productName;
        SubscriptionRequired = $subscriptionRequired;
        ApprovalRequired = $approvalRequired;
        };
    if ($product) {
        Write-LogInfo "Updating product $productName ...";
        $product = Set-AzureRmApiManagementProduct @params -ProductId $product.ProductId;
    } else {
        Write-LogInfo "Creating new product $productName ...";
        $product = New-AzureRmApiManagementProduct @params;
    }

    if ($policy -or $policyFile) {
        $params = @{
            Context = $ctx;
            Policy = if ($policy) { $policy } else { Resolve-ScriptPath -Path $policyFile -GetContent };
            ProductId = $product.Id;
            };
        Write-LogInfo "Setting product policy ...";
        $policy = Set-AzureRmApiManagementPolicy @params;
    }
}

function Set-ApiManagementApi($resourceGroupName, $apiManagementName, $apiName, $apiHost, $apiPath, $swaggerPath) {
    $ctx = New-AzureRmApiManagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $api = Get-AzureRmApiManagementApi -Context $ctx -Name $apiName -ErrorAction SilentlyContinue;
    $swaggerUrl = (Join-Url $apiHost $swaggerPath);
    $params = @{  
        Context = $ctx;
        SpecificationFormat = [Microsoft.Azure.Commands.ApiManagement.ServiceManagement.Models.PsApiManagementApiFormat]::Swagger;
        SpecificationUrl = $swaggerUrl;
        Path = $apiPath;
        };
    if ($api) {
        Write-LogInfo "Importing update to API $apiName ...";
        $api = Import-AzureRmApiManagementApi @params -ApiId $api.ApiId;
    } else {
        Write-LogInfo "Importing new API $apiName ...";
        $api = Import-AzureRmApiManagementApi @params;
    }

    $params = @{
        Context = $ctx;
        ApiId = $api.ApiId;
        };
    $products = Get-AzureRmApiManagementProduct -Context $ctx;
    foreach ($product in $products) {
        $apiProd = Add-AzureRmApiManagementApiToProduct @params -ProductId $product.ProductId;
    }

    if ($policy -or $policyFile) {
        $params = @{
            Context = $ctx;
            Policy = if ($policy) { $policy } else { Resolve-ScriptPath -Path $policyFile -GetContent };
            ApiId = $api.ApiId;
            };
        Write-LogInfo "Setting API policy ...";
        $policy = Set-AzureRmApiManagementPolicy @params;
    }
}

function Set-ApiManagementUser($resourceGroupName, $apiManagementName, $email, $password, $firstName, $lastName, $subscriptions) {
    $returnValue = @{};
    $ctx = New-AzureRmApiManagementContext -ResourceGroupName $resourceGroupName -ServiceName $apiManagementName;
    $user = Get-AzureRmApiManagementUser -Context $ctx -ErrorAction SilentlyContinue | ? { $_.Email -eq $email };
    $params = @{  
        Context = $ctx;
        Password = $password
        Email = $email;
        FirstName = $firstName;
        LastName = $lastName;
        State = [Microsoft.Azure.Commands.ApiManagement.ServiceManagement.Models.PsApiManagementUserState]::Active;
        };
    if (!$user) {
        Write-LogInfo "Creating new user $email ...";
        $user = New-AzureRmApiManagementUser @params;
    } elseif ($user.FirstName -eq "Administrator") {
        Write-LogInfo "Cannot update administrator user $email ...";
    } else {
        Write-LogInfo "Updating user information for $email ...";
        Set-AzureRmApiManagementUser @params -UserId $user.UserId | Out-Null;
    }

    $params = @{
        Context = $ctx;
        UserId = $user.UserId;
        };
    $existingSubscriptions = Get-AzureRmApiManagementSubscription @params;
    $subsToKeep = $existingSubscriptions | ? { $subscriptions -contains $_.ProductId };
    $subsToDelete = $existingSubscriptions | ? { $subscriptions -notcontains $_.ProductId };
    $subsToAdd = $subscriptions | ? { $existingSubscriptions.ProductId -notcontains $_ };
    foreach ($subscription in $subsToDelete) {
        Remove-AzureRmApiManagementSubscription -Context $ctx -SubscriptionId $subscription.SubscriptionId | Out-Null;
    }
    foreach ($subscription in $subsToAdd) {
        $azureSub = New-AzureRmApiManagementSubscription @params -Name $subscription -ProductId $subscription -State Active;
        $returnValue[$azureSub.ProductId] = $azureSub;
    }
    foreach ($subscription in $subsToKeep) {
        $returnValue[$subscription.ProductId] = $subscription;
    }

    return $returnValue;
}



