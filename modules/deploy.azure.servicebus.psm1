Register-AzureProvider "Microsoft.ServiceBus";
Add-NameFormatType "ServiceBus";

function Deploy-ServiceBus($name, $location, $sku, $authRules, $parent) {
    $params = @{ ResourceGroup = $parent.Name;
                 NamespaceName = $name };
    $sb = Get-AzureRmServiceBusNamespace @params -ErrorAction SilentlyContinue;
    $location = if ($location) { $location } else { $parent.Location };
    if ($sb) {
        $update = $update -or $location -ne $sb.Location;
        $update = $update -or $sku -ne $sb.Sku.Name;
        if ($update) {
            Write-LogInfo "Updating service bus $name ...";
            $sb = Set-AzureRmServiceBusNamespace @params -Location $location -SkuName $sku;
        } else {
            Write-LogInfo "Service Bus $name is up-to-date.";
        }
    } else {
        Write-LogInfo "Creating new Service Bus $name ...";
        $sb = New-AzureRmServiceBusNamespace @params -Location $location -SkuName $sku;
    }

    $existingRules = Get-AzureRmServiceBusNamespaceAuthorizationRule @params;
    $newRules = @();
    foreach ($rule in $authRules.GetEnumerator()) {
        $newRules += Ensure-ServiceBusNamespaceAuthorizationRule @params -AuthRuleName $rule.Name -Rights $rule.Value -AllAuthRules $existingRules;
    }

    $accessKeys = $newRules | 
                    % { Get-AzureRmServiceBusNamespaceKey -ResourceGroup $parent.Name -NamespaceName $name -AuthorizationRuleName $_.Name; } | 
                    ConvertTo-Hashtable -KeySelector { $_.KeyName };
    $sbProps = @{ Url = $sb.ServiceBusEndpoint; Access = $accessKeys; };
    return $sbProps;
}

function Deploy-ServiceBusTopic($name, $enablePartitioning, $autoDeleteOnIdle, $defaultMessageTimeToLive, $duplicateDetectionHistoryTimeWindow, 
                                $enableBatchedOperations, $enableExpress, $maxSizeInMegabytes, $requiresDuplicateDetection, $supportOrdering, 
                                $sizeInBytes, $authRules, $parent) {
    return Deploy-ServiceBusItem -Type "Topic" -ItemParameters $PSBoundParameters;
}

function Deploy-ServiceBusQueue($name, $enablePartitioning, $autoDeleteOnIdle, $defaultMessageTimeToLive, $duplicateDetectionHistoryTimeWindow, 
                                $enableBatchedOperations, $deadletteringOnExpiredMessages, $enableExpress, $isAnonymousAccessible, $maxDeliveryCount, 
                                $maxSizeInMegabytes, $messageCount, $requiresDuplicateDetection, $requiresSession, $sizeInBytes, $authRules, $parent) {
    return Deploy-ServiceBusItem -Type "Queue" -ItemParameters $PSBoundParameters;
}

function Deploy-ServiceBusItem($type, $itemParameters) {
    $params = @{
        ResourceGroupName = $itemParameters.Parent.Parent.Name;
        Provider = "Microsoft.ServiceBus/namespaces";
        ResourceName = (Join-Url $itemParameters.Parent.Name "$($type)s" $itemParameters.Name);
        ApiVersion = "2015-08-01";
        };
    $item = Invoke-AzureRmResourceApi @params -Method "GET" -Ignore404;
    $properties = [Hashtable]$itemParameters;
    $properties.Remove("name") | Out-Null;
    $properties.Remove("authRules") | Out-Null;
    $properties.Remove("parent") | Out-Null;
    $itemDef = @{
        Name = $name;
        Properties = $properties;
        };

    Write-LogInfo "Creating or updating service bus $type $($itemParameters.Name) ...";
    $item = Invoke-AzureRmResourceApi @params -Method "PUT" -Body (ConvertTo-Json $itemDef) -ContentType 'application/json';

    $params = @{
        ResourceGroup = $itemParameters.Parent.Parent.Name;
        NamespaceName = $itemParameters.Parent.Name;
        "$($type)Name" = $itemParameters.Name;
        };
    $existingRules = Invoke-Expression "Get-AzureRmServiceBus$($type)AuthorizationRule @params";
    $newRules = @();
    foreach ($rule in $authRules.GetEnumerator()) {
        $newRules += Ensure-ServiceBusAuthorizationRuleGeneric @params -ItemType $type -SubItemName $itemParameters.Name -AuthRuleName $rule.Name -Rights $rule.Value -AllAuthRules $existingRules;
    }

    $accessKeys = $newRules | 
                    % { Invoke-Expression "Get-AzureRmServiceBus$($type)Key -ResourceGroup `$itemParameters.Parent.Parent.Name -NamespaceName `$itemParameters.Parent.Name -$($type)Name `$itemParameters.Name -AuthorizationRuleName `$_.Name"; } |
                    ConvertTo-Hashtable -KeySelector { $_.KeyName };
    $itemProps = @{ Access = $accessKeys; };
    return $itemProps;
}

function Ensure-ServiceBusNamespaceAuthorizationRule($resourceGroup, $namespaceName, $authRuleName, $rights, $allAuthRules) {
    Ensure-ServiceBusAuthorizationRuleGeneric @PSBoundParameters -ItemType "Namespace";
}

function Ensure-ServiceBusAuthorizationRuleGeneric($resourceGroup, $namespaceName, $subItemName, $itemType, $authRuleName, $rights, $allAuthRules) {
    $cmdText = '
        $params = @{ ResourceGroup = $resourceGroup; 
                    NamespaceName = $namespaceName;
                    {subItemName}
                    AuthorizationRuleName = $authRuleName};
        if ($allAuthRules) {
            $returnValue = $allAuthRules | ? { $_.Name -eq $authRuleName } | Select-Object -First 1;
        } else {
            $returnValue = Get-AzureRmServiceBus{itemType}AuthorizationRule @params -ErrorAction SilentlyContinue;
        }

        $params["Rights"] = $rights -split ";";
        if ($returnValue) {
            $rights -split ";" | % { $update = ([bool]$update) -or !([bool]($returnValue.Rights -eq $_)) };
            if ($update) {
                Write-LogInfo "Updating Authorization Rule $authRuleName ...";
                $returnValue = Set-AzureRmServiceBus{itemType}AuthorizationRule @params -AuthRuleObj $returnValue;
            } else {
                Write-LogInfo "Authorization Rule $authRuleName up-to-date";
            }
        } else {
            Write-LogInfo "Creating new Authorization Rule $authRuleName ...";
            $returnValue = New-AzureRmServiceBus{itemType}AuthorizationRule @params;
        }
        return $returnValue;';
    $paramItem = if ($subItemName) { "{itemType}Name = '$subItemName';" } else { "" };
    $cmdText = $cmdText.Replace("{subItemName}", $paramItem);
    $cmdText = $cmdText.Replace("{itemType}", $itemType);
    
    Invoke-Expression $cmdText;
}
