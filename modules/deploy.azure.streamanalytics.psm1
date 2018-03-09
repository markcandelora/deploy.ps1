

$functionTemplate = @{
	"name" = '[Name]';
	"type" = "Microsoft.StreamAnalytics/streamingjobs/functions";
	"location" = $null;
	"properties" = @{
		"type" = "Scalar";
		"properties" = @{
			"inputs" = '[FunctionInputs]';
			"output" = @{
				"dataType" = '[OutputType]';
			    };
			"binding" = @{
				"type" = "Microsoft.StreamAnalytics/JavascriptUdf";
				"mlProperties" = $null;
				"jsProperties" = @{
					"script" = '[JSCode]';
				    };
				"properties" = @{
					"script" = '[JSCode]';
                    };
                };
            };
        };
    };
$inputTemplate = @{
	"name" = '[Name]';
	"type" = "Microsoft.StreamAnalytics/streamingjobs/inputs";
	"properties" = @{
		"type" = '[connectionType.propertyType]';
		"dataSource" = @{
			"type" = '[connectionType.dataSourceType]';
			"properties" = '[properties]'
		    };
		"serialization" = @{
			"type" = '[serialization.type]';
			"properties" = @{
				"encoding" = '[serialization.encoding]'
                }
            }
        }
    };
$outputTemplate = @{
	"name" = '[name]';
	"properties" = @{
		"datasource" = @{
			"type" = '[connectionType.datasourceType]';
			"properties" = '[properties]'
		    };
		"serialization" = @{
			"type" = '[serialization.type]';
			"properties" = @{
				"fieldDelimiter" = '[serialization.fieldDelimiter]';
				"encoding" = '[serialization.encoding]';
				"format" = '[serialization.fieldDelimiter.format]'
                };
            };
        };
    };
$rootTemplate = @{
    "name" = '[job.Name]';
    "type" = "Microsoft.StreamAnalytics/StreamingJobs";
    "location" = '[job.Location]';
    "properties" = @{
        "sku" = @{
            "name" = "[job.sku]"
        };
        "outputErrorPolicy" = '[OutputErrorPolicy]';
        "eventsOutOfOrderPolicy" = '[EventsOutOfOrderPolicy]';
        "eventsOutOfOrderMaxDelayInSeconds" = '[EventsOutOfOrderMaxDelayInSeconds]';
        "eventsLateArrivalMaxDelayInSeconds" = '[EventsLateArrivalMaxDelayInSeconds]';
        "dataLocale" = '[DataLocale]';
        "functions" = '[job.Functions]';
        "inputs" = '[job.Inputs]';
        "transformation" = @{
            "name" = "Transformation";
            "properties" = @{
                "streamingUnits" = '[StreamingUnits]';
                "query" = '[job.Script]'
                };
            };
        "outputs" = '[job.Outputs]'
        };
    };

$inputTypes = @{
        ioTHub        = @{ "dataSourceType" = 'Microsoft.Devices/IotHubs'; "propertyType" = 'Stream'    };
        blobReference = @{ "dataSourceType" = 'Microsoft.Storage/Blob';    "propertyType" = 'Reference' };
        };
$outputTypes = @{
        sqlDatabase     = @{ "dataSourceType" = 'Microsoft.Sql/Server/Database' };
        blobStorage     = @{ "dataSourceType" = 'Microsoft.Storage/Blob'        };
        documentDb      = @{ "dataSourceType" = 'Microsoft.Storage/DocumentDB'  };
        serviceBusTopic = @{ "dataSourceType" = 'Microsoft.ServiceBus/Topic'    };
        function        = @{ "dataSourceType" = 'Microsoft.AzureFunction'       };
        };


Register-AzureProvider "Microsoft.StreamAnalytics";
Add-NameFormatType "StreamAnalytics";

function Deploy-StreamAnalytics($name, $sku, $projectPath, $parent) {
    $functionDeploymentTemplate = (Clone-Object $functionTemplate).Result;
    $inputDeploymentTemplate    = (Clone-Object $inputTemplate).Result;
    $outputDeploymentTemplate   = (Clone-Object $outputTemplate).Result;
    $rootDeploymentTemplate     = (Clone-Object $rootTemplate).Result;
    
    $job = @{
        Name = $name;
        Location = $parent.location;
        ResourceGroupName = $parent.name;
        Sku = $sku;
        };
    
    $projectFolder = Split-Path $projectPath -Parent;
    $project = [System.Xml.XmlDocument](Get-Content $projectPath);
    $files = $project.Project.ItemGroup.Configure;
    $script = Get-Content (Join-Path $projectFolder $project.Project.ItemGroup.Script.Include) -Raw;
    
    $functionFiles = $files | ? { $_.SubType -eq "JSFunctionConfig" };
    $job["functions"] = (Generate-Configs $functionDeploymentTemplate $functionFiles.Include).Collection;

    $inputFiles = $files | ? { $_.SubType -eq "Input" };
    $job["inputs"] = (Generate-Configs $inputDeploymentTemplate $inputFiles.Include $inputTypes).Collection;

    $outputFiles = $files | ? { $_.SubType -eq "Output" };
    $job["outputs"] = (Generate-Configs $outputDeploymentTemplate $outputFiles.Include $outputTypes).Collection;

    $jobFile = $files | ? { $_.SubType -eq "JobConfig" };
    $job["script"] = "$script";

    $jobConfig = (Generate-Configs $rootDeploymentTemplate $jobFile.Include).Collection | Select-Object -First 1;
    $jobConfigJson = $jobConfig | ConvertTo-Json -Depth 100;
    
    Write-LogInfo "Stopping job...";
    Stop-AzureRmStreamAnalyticsJob -ResourceGroupName $job.ResourceGroupName -Name $job.Name | Out-Null;
    Write-LogInfo "Deploying job...";
    Invoke-AzureRmResourceApi -Method "PUT" -ResourceGroupName $parent.name -Provider "Microsoft.StreamAnalytics/streamingjobs" -ResourceName $name -ApiVersion "2016-03-01" -Body $jobConfigJson -ContentType "application/json" | Out-Null;
    Write-LogInfo "Starting job...";
    $started = Start-AzureRmStreamAnalyticsJob -ResourceGroupName $job.ResourceGroupName -Name $job.Name -OutputStartMode "LastOutputEventTime";
    if (!$started) {
        $started = Start-AzureRmStreamAnalyticsJob -ResourceGroupName $job.ResourceGroupName -Name $job.Name -OutputStartMode "JobStartTime" -ErrorAction Stop;
    }
    
    if (!$started) {
        Write-LogWarning "Could not start Stream Analytics job.";
    } else {
        Write-LogInfo "Job started.";
    }
    Write-LogInfo "Deployment complete.";
}

function Generate-Configs($template, $paramFiles, $types) {
    $returnValue = @();
    foreach ($file in $paramFiles) {
        $filePath = Join-Path (Split-Path $projectPath -Parent) $file;
        $values = ConvertFrom-Json (Get-Content $filePath -Raw);
        Add-Member -InputObject $values -Name "job" -MemberType NoteProperty -Value $job;
    
        #find property param...
        $propertyParams = Get-Member -InputObject $values -MemberType NoteProperty | ? { $_.Name -like "*properties" };
        $propertyName = ($propertyParams | ? { $values."$($_.Name)" -ne $null }).Name;
        
        if ($propertyName) {
            $propertyType = $propertyName.Replace("Properties", "");
            Add-Member -InputObject $values -Name "properties" -MemberType NoteProperty -Value $values."$propertyName";
            Add-Member -InputObject $values -Name "connectionType" -MemberType NoteProperty -Value $types."$propertyType";
            Invoke-Expression -Command "Fill-Password$propertyType `$values.$propertyName";
        }

        $reference = (Clone-Object $template).Result;
        $reference = (Resolve-Values -Object $reference -Values $values).Result;
        $returnValue += $reference;
    }
    return @{ Collection = $returnValue };
}

Function Add-ProvisioningVaultReader([string]$vaultName) {
	Write-Trace -Enter
	
    if (-not $vaultName) {
        $vaultName = Get-AzureRmResource -ResourceGroupName $job.ResourceGroupName -ResourceType "Microsoft.KeyVault/vaults" | Select -First 1 -ExpandProperty "ResourceName";
    }

    # get current authenticated client (user or service principal)
	$account = (Get-AzureRMContext).Account
	
	# get object ID 
	if ($account.Type -eq 'user') 
	{
		# TODO: determine if there is a more robust correlation between ADUser and Account
		$objectId = (Get-AzureRMADUser | 
		                Where-Object { $_.UserPrincipalName.StartsWith($account.Id.Replace('@','_')) }).Id
	} 
	else 
	{
		$objectId = (Get-AzureRMADServicePrincipal -SPN $account.Id).Id
	}
	
	# add object ID as a KeyVault principal to read/write secrets
	Set-AzureRMKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $objectId -PermissionsToSecrets ('get','set','list') -ErrorAction Stop
	
	Write-Trace -Exit
	
	return $objectId
}

Function Remove-ProvisioningVaultReader([string] $vaultName, [Parameter(Mandatory)][Guid] $objectId) {

    if (-not $vaultName) {
        $vaultName = Get-AzureRmResource -ResourceGroupName $job.ResourceGroupName -ResourceType "Microsoft.KeyVault/vaults" | Select-Object -First 1 -ExpandProperty "ResourceName";
    }

	Remove-AzureRmKeyVaultAccessPolicy -VaultName $vaultName -ObjectId $objectId -ErrorAction SilentlyContinue
}

function Fill-PasswordFunction($properties) {
    $rootName = $properties.functionAppName;
    $function = Resolve-DeploymentReference -Dependency "ResourceGroup-$($parent.name)/AppService-$rootName";
    $functionName = $function.Name;
    
    $properties.functionAppName = $functionName;
    $properties.apiKey = $key;
}

function Fill-PasswordIoTHub($properties) {
    $rootName = $properties.IotHubNamespace;
    $hub = Resolve-DeploymentReference -Dependency "ResourceGroup-$($parent.name)/IotHub-$rootName";
    $key = $hub.GetAccessKey($properties.SharedAccessPolicyName);
    $hubName = $hub.Name;

    $properties.IotHubNamespace = $hubName;
    $properties.SharedAccessPolicyKey = $key;
    Add-Member -InputObject $properties -Name "endpoint" -MemberType NoteProperty -Value "messages/events";
}

function Fill-PasswordServiceBusTopic($properties) {
    $rootName = $properties.ServiceBusNamespace;
    $sb = Find-AzureRMResource -ResourceNameContains $rootName -ResourceGroupNameEquals $job.ResourceGroupName -ResourceType "Microsoft.ServiceBus/namespaces";
    $namespace = $sb.Name;
    
    $rawResult = Invoke-ArmRestApi -ResourcePath "providers/Microsoft.ServiceBus/namespaces/$namespace/AuthorizationRules/$($properties.SharedAccessPolicyName)/listkeys" -apiVersion "2017-04-01" -verb "Post";
    $jsonResult = ConvertFrom-Json $rawResult;
    $key = $jsonResult.primaryKey;

    $properties.sharedAccessPolicyKey = $key;
}

function Fill-PasswordBlobReference($properties) {
    Fill-PasswordBlobStorage @PSBoundParameters;
}

function Fill-PasswordBlobStorage($properties) {
    $storageAccountProps = $properties.StorageAccounts[0];
    $rootName = $storageAccountProps.AccountName;
    $storageAccount = Resolve-DeploymentReference -Dependency "ResourceGroup-$($parent.name)/StorageAccount-$rootName";
    $storageAccountName = $storageAccount.Name;
    $key = $storageAccount.GetAccessKey();
    
    $context = New-AzureStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $key;
    if (-not (Get-AzureStorageContainer -Name $properties.Container -Context $context -ErrorAction SilentlyContinue)) {
        New-AzureStorageContainer -Name $properties.Container -Context $context | Out-Null;
    }
    
    $storageAccountProps.AccountName = $storageAccountName;
    $storageAccountProps.AccountKey = $key;
}

function Fill-PasswordDocumentDb($properties) {
    $rootName = $properties.AccountId;
    $docdb = Resolve-DeploymentReference -Dependency "ResourceGroup-$($parent.name)/DocumentDb-$rootName";
    $key = $docdb.GetAccessKey();
    
    $properties.AccountId = $docdb.name;
    $properties.AccountKey = $key;
}

function Fill-PasswordSQLDatabase($properties) {
    $dbServer = Find-AzureRmResource -ResourceGroupNameEquals $job.ResourceGroupName -ResourceType "Microsoft.Sql/servers" -ExpandProperties;
    
    $vaultName = Get-AzureRmResource -ResourceGroupName $job.ResourceGroupName -ResourceType "Microsoft.KeyVault/vaults" | Select -First 1 -ExpandProperty "ResourceName";
    $objId = Add-ProvisioningVaultReader;
    $secret = Get-AzureKeyVaultSecret -VaultName $vaultName -Name $properties.Password;
    $connStringValues = @{};
    $connectionString = $secret.SecretValueText;
    $connectionString -split ";" | % { $i = $_.Split('='); $connStringValues[$i[0]] = $i[1] };
    Remove-ProvisioningVaultReader -ObjectId $objId;
    
    $properties.Server = $dbServer.Properties.FullyQualifiedDomainName;
    $properties.Password = $connStringValues['password'];
}

