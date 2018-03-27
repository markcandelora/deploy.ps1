USING NAMESPACE Microsoft.Azure.Commands.Management.IotHub.Models;
USING NAMESPACE Microsoft.Azure.Management.IotHub.Models;
USING NAMESPACE System.Collections.Generic;

Register-AzureProvider "Microsoft.Devices";
Add-NameFormatType "IotHub";

$iotHubActions = @{
    AddEventHubConsumerGroup = { param($name) Add-IotEventHubConsumerGroup -ResourceGroup $this.parent.name -IotHubName $this.name -ConsumerGroupName $name; return $name; };
    GetAccessKey = { param($policy) return Get-AzureRmIotHubKey -ResourceGroupName $this.parent.name -Name $this.name -KeyName $policy | Select-Object -ExpandProperty "PrimaryKey"; };
    };

function Deploy-IotHub($name, $sku, $units, $consumerGroups, $fileUpload, $cloudToDevice, $operationsMonitoring, $routes, $endpoints, $enableFallback, $parent) {
    $params = @{ ResourceGroupName = $parent.name;
                 Name = $name; };
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

    $params = @{ ResourceGroupName = $parent.name;
                 Name = $name; };

    if ($fileUpload) {
        Write-LogInfo "Updating file upload properties...";        
        Set-AzureRmIotHub @params @fileUpload | Out-Null;
    }

    if ($cloudToDevice) {
        Write-LogInfo "Updating cloud-to-device properties...";        
        Set-AzureRmIotHub @params -CloudToDevice $cloudToDevice | Out-Null;
    }

    if ($operationsMonitoring) {
        Write-LogInfo "Updating operations monitoring properties...";        
        Set-AzureRmIotHub @params -OperationsMonitoringProperties $operationsMonitoring | Out-Null;
    }

    if ($routes -or $endpoints) {
        Write-LogInfo "Updating routing properties...";
        Set-AzureRmIotHub @params -RoutingProperties (ConvertTo-Routing -Endpoints $endpoints -Routes $routes -FallbackEnabled $fallbackEnabled) | Out-Null;        
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

function ConvertTo-Routing($endpoints, $routes, $fallbackEnabled) {
    $returnValue = [PSRoutingProperties]@{
        Endpoints = [PSRoutingEndpoints]@{
            EventHubs        = ($endpoints | 
                                    ? { $_.EndpointType -eq "EventHub" } | 
                                    % { @{ ResourceGroup = $_.ResourceGroup; SubscriptionId = $_.SubscriptionId; ConnectionString = $_.ConnectionString; Name = $_.Name; } } | 
                                    ConvertTo-List -Type "PSRoutingEventHubProperties").Collection;
            ServiceBusQueues = ($endpoints | 
                                    ? { $_.EndpointType -eq "Queue" } | 
                                    % { @{ ResourceGroup = $_.ResourceGroup; SubscriptionId = $_.SubscriptionId; ConnectionString = $_.ConnectionString; Name = $_.Name; } } | 
                                    ConvertTo-List -Type "PSRoutingServiceBusQueueEndpointProperties").Collection;
            ServiceBusTopics = ($endpoints | 
                                    ? { $_.EndpointType -eq "Topic" } | 
                                    % { @{ ResourceGroup = $_.ResourceGroup; SubscriptionId = $_.SubscriptionId; ConnectionString = $_.ConnectionString; Name = $_.Name; } } | 
                                    ConvertTo-List -Type "PSRoutingServiceBusTopicEndpointProperties").Collection;
            };
        FallbackRoute = [PSFallbackRouteMetadata]@{ 
            Condition = "true";
            EndpointNames = [List[string]]@("events");
            IsEnabled = $fallbackEnabled;
            };
        Routes = ($routes | 
            % { @{ Condition = $_.Condition; EndpointNames = [List[string]]$_.EndpointNames; IsEnabled = $_.IsEnabled; Name = $_.Name; Source = $_.Source; } } |
            ConvertTo-List -Type "PSRouteMetadata").Collection;
        };

    return $returnValue;
}

function ConvertTo-List([Parameter(ValueFromPipeline)]$items, $type) {
    if ($input) {
        $items = $input;
    }
    if ($items) {
        $cmd = "@{ Collection = [List[$type]][$type[]]@(`$items | % { [$type]`$_ }) }";
        $returnValue = Invoke-Expression $cmd;
    } else {
        $returnValue = @{ Collection = $null; };
    }
    return $returnValue;
}
