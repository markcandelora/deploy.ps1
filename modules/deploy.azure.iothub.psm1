Ensure-Module ".\deploy.azure.psm1";
Register-AzureProvider "Microsoft.Devices";
Add-NameFormatType "IotHub";

$iotHubActions = @{
    AddEventHubConsumerGroup = { param($name) Add-IotEventHubConsumerGroup -ResourceGroup $this.parent.name -IotHubName $this.name -ConsumerGroupName $name; return $name; };
    GetAccessKey = { param($policy) return Get-AzureRmIotHubKey -ResourceGroupName $this.parent.name -Name $this.name -KeyName $policy | Select-Object -ExpandProperty "PrimaryKey"; };
    };

function Deploy-IotHub($name, $sku, $units, $consumerGroups, $fileUpload, $cloudToDevice, $operationsMonitoring, $parent) {
    $params = @{
        ResourceGroupName = $parent.name;
        Name = $name
        };
    $iotHub = Get-AzureRmIotHub @params -ErrorAction SilentlyContinue;
    $params["SkuName"] = $sku;
    $params["Units"] = $units;
    if ($iotHub) {
        Write-LogInfo "IotHub exists, updating $name ...";
        $iotHub = Set-AzureRmIotHub @params;
    } else {
        Write-LogInfo "Creating new IotHub $name ...";
        $params["Location"] = $parent.Location;
        $iotHub = New-AzureRmIotHub @params;
    }

    if ($fileUpload) {
        Write-LogInfo "Updating file upload properties...";        
        $iotHub | Set-AzureRmIotHub @fileUpload | Out-Null;
    }

    if ($cloudToDevice) {
        Write-LogInfo "Updating cloud-to-device properties...";        
        $iotHub | Set-AzureRmIotHub -CloudToDevice $cloudToDevice | Out-Null;
    }

    if ($operationsMonitoring) {
        Write-LogInfo "Updating operations monitoring properties...";        
        $iotHub | Set-AzureRmIotHub -OperationsMonitoringProperties $operationsMonitoring | Out-Null;
    }

    foreach ($group in $consumerGroups) {
        Add-IotEventHubConsumerGroup -ResourceGroupName $parent.name -IotHubName $name -ConsumerGroupName $group | Out-Null;
    }

    $iotProperties = @{
        Url = "https://$($iotHub.properties.hostName)"
        };
    return Join-Hashtable $iotProperties $iotHubActions;
}

function Get-IotEventHubConsumerGroup($resourceGroupName, $iotHubName) {
    $resource = Join-Uri $iotHubName "EventhubEndPoints/events/ConsumerGroups";
    $consumerGroups = Invoke-AzureRmResourceApi -Method "GET" -ResourceGroupName $resourceGroupName -Provider "Microsoft.Devices/IotHubs" -ResourceName $resource -ApiVersion "2017-07-01" | ConvertFrom-Json;
    return @{ Collection = $consumerGroups.Value };
}

function Add-IotEventHubConsumerGroup($resourceGroupName, $iotHubName, $consumerGroupName) {
    $consumerGroups = Get-IotEventHubConsumerGroup @PSBoundParameters;
    if ($consumerGroups.Value -and $consumerGroups.Value.Contains()) {
        Write-LogInfo "Iot hub consumer group $consumerGroupName already exists.";
    } else {
        Write-LogInfo "Creating Iot hub consumer group $consumerGroupName ...";
        $resource = Join-Uri $iotHubName "EventhubEndPoints/events/ConsumerGroups" $consumerGroupName;
        $consumerGroups = Invoke-AzureRmResourceApi -Method "GET" -ResourceGroupName $resourceGroupName -Provider "Microsoft.Devices/IotHubs" -ResourceName $resource -ApiVersion "2017-07-01" | ConvertFrom-Json;
    }
}
