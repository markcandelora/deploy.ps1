Register-AzureProvider "Microsoft.Storage";
Add-NameFormatType "StorageAccount";

$ErrorActionPreference = "Stop";

$storageAccountActions = @{
    GetAccessKey = { return (Get-AzureRmStorageAccountKey -ResourceGroupName $this.Parent.Name -Name $this.Name)[0].Value; };
    GetConnectionString = { return "DefaultEndpointsProtocol=https;AccountName={0};AccountKey={1};" -f ($this.Name,$this.GetAccessKey()); };
    };
$storageContainerActions = @{
    CreateSASToken = { param($ttlHours) return New-StorageAccountContainerSASToken @this -TTLHours $ttlHours };
    GetBlobUrl = { param($blobPath) return Join-Url $this.Url.ToString() $blobPath; };
    ListBlobs = { param($filter) return $this.Connection | Get-AzureStorageBlob -Blob $filter; };
    };
$blobActions = @{};

function Deploy-StorageAccount($name, $location, $skuName, $kind, $accessTier, $parent) {
    $account = Get-AzureRmStorageAccount -ResourceGroupName $parent.Name -Name $name -ErrorAction SilentlyContinue;
    $params = $PSBoundParameters;
    $params.Remove("Parent") | Out-Null;
    $params["ResourceGroupName"] = $parent.Name;
    if (!$params.Location) {
        $params["location"] = $parent.Location;
    }

    if (!$account) {
        Write-LogInfo "Creating new storage account '$name'";
        $account = New-AzureRmStorageAccount @params;
        # put access token into keyvault
    } else {
        Write-LogInfo "Updating storage account '$name'";
        $params.Remove("kind") | Out-Null;
        $params.Remove("location") | Out-Null;
        $account = Set-AzureRmStorageAccount @params;
    }
    $accountData = @{
        Endpoints = $account.PrimaryEndpoints;
        }
    return Join-Hashtable $accountData $script:storageAccountActions;
}

function Deploy-BlobContainer($name, $publicAccess, $parent) {
    $resourceGroupName = $parent.Parent.Name;
    $storageAccountName = $parent.Name;

    $context = Get-StorageAccountContext -resourceGroupName $resourceGroupName -storageAccountName $storageAccountName;
    $container = Get-AzureStorageContainer -Context $context -Name $name -ErrorAction SilentlyContinue;

    if (!$container) {
        Write-LogInfo "Creating new storage container '$name'";
        $container = New-AzureStorageContainer -Context $context -Name $name;
    } else {
        Write-LogInfo "Container '$name' already exists";
    }

    Write-LogInfo "Setting container permissions";
    $permission = if ($publicAccess) { "Container" } else { "Off" };
    $container | Set-AzureStorageContainerAcl -Permission $permission;
    
    $containerValues = @{
        Url = $container.CloudBlobContainer.Uri;
        Connection = $container;
        };
    return Join-Hashtable $containerValues $script:storageContainerActions;
}

# function Deploy-StorageQueue($resourceGroupName, $storageAccountName, $context, $name) {
#     if (!$context) {
#         $context = Get-StorageAccountContext @PSBoundParameters;
#     }
#     $queue = Get-AzureStorageQueue -Context $context -Name $name;
#     $queue.CloudQueue.CreateIfNotExists() | Out-Null;
# }

# function Deploy-TableStore($resourceGroupName, $storageAccountName, $context, $name, $rows) {
#     if (!$context) {
#         $context = Get-StorageAccountContext @PSBoundParameters;
#     }
#     $table = Get-AzureStorageTable -Name $name -Context $context -ErrorAction SilentlyContinue;
#     if (!$table) {
#         $table = New-AzureStorageTable -Context $context -Name $name;
#     }
#     if ($rows) {
#         foreach ($row in $rows) {
#             Deploy-TableStoreRow -Table $table -RowData $row;
#         }
#     }
# }

function Deploy-Blob($blobPath, $blobType = "Block", $parent) {
    $containerName = $parent.Name;
    $storageAccountName = $parent.Parent.Name;
    $resourceGroupName = $parent.Parent.Parent.Name

    $localPath = Resolve-ScriptPath -path $blobPath;
    $localItem = Get-Item -Path $localPath;
    $isFolder = $localItem.PSIsContainer;

    if ($isFolder) {
        $files = $localPath | Get-ChildItem -File -Recurse | % { return @{ LocalPath = $_.FullName; RemotePath = $_.FullName.Replace($localItem.FullName, "").Replace("\","/").Trim("/") } };
    } else {
        $files = Get-Item -Path $localPath | % { return @{ LocalPath = $_.FullName; RemotePath = $_.Name } };
    }

    $context = Get-StorageAccountContext -storageAccountName $storageAccountName -resourceGroupName $resourceGroupName;
    foreach ($file in $files) {
        Write-LogInfo "Uploading $($file.RemotePath)";
        Set-AzureStorageBlobContent -Context $context -Container $containerName -File $file.LocalPath -Blob $file.RemotePath -BlobType $blobType -Force | Out-Null;
    }
}

# function Deploy-TableStoreRow($resourceGroupName, $storageAccountName, $table, $rowData) {
#     if ($table -is [string]) {
#         $context = Get-StorageAccountContext @PSBoundParameters;
#         $table = Get-AzureStorageTable -Name $name -Context $context -ErrorAction SilentlyContinue;
#     }
#     $partitionKey = $rowData.PartitionKey;
#     $rowKey = $rowData.RowKey;
#     $rowData.Remove("PartitionKey");
#     $rowData.Remove("RowKey");
#     Add-StorageTableRow -Table $table -PartitionKey $partitionKey -RowKey $rowKey -property $rowData | Out-Null;
# }

function Get-StorageAccountContext($resourceGroupName, $storageAccountName) {
    $accessKey = Get-AzureRmStorageAccountKey -ResourceGroupName $resourceGroupName -Name $storageAccountName;
    return New-AzureStoragecontext -StorageAccountName $storageAccountName -StorageAccountKey $accessKey[0].Value;
}

function New-StorageAccountContainerSASToken($name, $ttlHours, $parent) {
    return New-StorageAccountContainerSAS -ResourceGroupName $parent.Parent.Name -StorageAccountName $parent.Name -ContainerName $name -TTLHours $ttlHours;
}

function New-StorageAccountContainerSAS($resourceGroupName, $storageAccountName, $containerName, $ttlHours) {
    $storageContext = Get-StorageAccountContext @PSBoundParameters;
    $now = Get-Date;

    $returnValue = New-AzureStorageContainerSASToken -Name $containerName -Context $storageContext -Permission "rwd" -ExpiryTime $now.AddHours($ttlHours);
    return $returnValue;
}
