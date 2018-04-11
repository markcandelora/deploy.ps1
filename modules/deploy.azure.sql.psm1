
Register-AzureProvider "Microsoft.Sql";
Add-NameFormatType "SqlServer";

$sqlServerActions = @{
    ExecSqlInMaster = { param($sql) Invoke-Sql -Server $this -Sql $sql; };
    };
$sqlDatabaseActions = @{
    ExecSql = { param($sql) Invoke-Sql -Database $this -Sql $sql; };
    };
    
function Deploy-SqlServer($name, $adminUserName, $adminPassword, $parent) {
    $params = @{ ResourceGroupName = $parent.Name;
                 ServerName = $name };
    $server = Get-AzureRmSqlServer @params -ErrorAction SilentlyContinue;

    $password = ConvertTo-SecureString -String $adminPassword -AsPlainText -Force;
    if (!$server) {
        $creds = [System.Management.Automation.PSCredential]::new($adminUserName, $password);
        Write-LogInfo "Creating new Sql Server - $name...";
        $server = New-AzureRmSqlServer @params -Location $parent.Location -SqlAdministratorCredentials $creds;
        New-AzureRmSqlServerFirewallRule @params -AllowAllAzureIPs | Out-Null;
    } else {
        if ($server.SqlAdministratorLogin -ne $adminUserName) {
            throw [ArgumentException]"AdminUserName '$adminUserName' does not match name for existing server $name";
        }
        Write-LogInfo "Updating Sql Server - $name...";
        $server = Set-AzureRmSqlServer @params -SqlAdministratorPassword $password;
    }

    $self = Get-DeploymentItem -Current;
    Deploy-SqlFirewallRule -Name "deploymentHost" -HostIP -Parent $self | Out-Null;

    return $sqlServerActions;
}

function Deploy-SqlFirewallRule($name, $ipStart, $ipEnd, [switch]$hostIP, $parent) {
    $params = @{ ResourceGroupName = $parent.Parent.Name;
                 ServerName = $parent.Name; };
    $rules = Get-AzureRmSqlServerFirewallRule @params;

    if ($hostIP) {
        $ipStart = Get-ExternalIP;
        $name += $ipStart;
    }
    if ($ipStart -and !$ipEnd) {
        $ipEnd = $ipStart;
    }

    $rule = $rules | ? { $_.StartIpAddress -eq $ipStart; } | Select-Object -First 1;
    if (!$rule) {
        Write-LogInfo "Creating new firewall rule $name : $ipStart - $ipEnd";
        New-AzureRmSqlServerFirewallRule @params -FirewallRuleName $name -StartIpAddress $ipStart -EndIpAddress $ipEnd | Out-Null;
    } else {
        Write-LogInfo "Firewall rule already exists $name : $ipStart - $ipEnd";
    }
}

function Deploy-SqlDatabase($name, $tier, $collation, $maxGigs, $backupTo, $restoreFrom, $code, $parent) {
    $baseparams = @{ ResourceGroupName = $parent.Parent.Name;
                     ServerName = $parent.Name; };
    $dbparams = Join-Hashtable @{ DatabaseName = $name } $baseparams;
    $db = Get-AzureRmSqlDatabase @dbparams -ErrorAction SilentlyContinue;

    $creationParams = (Clone-Object $dbparams).Result;
    if ($collation) { $creationParams["CollationName"] = $collation; }
    if ($tier) { $creationParams["RequestedServiceObjectiveName"] = $tier; }
    if ($maxGigs) {
        $maxSizeBytes = ($maxGigs * 1024 * 1024 * 1024);
        $creationParams["MaxSizeBytes"] = $maxSizeBytes;
    }

    if ($db -and $backupTo) {
        Deploy-SqlDatabaseBackup -DatabaseName $name -Server $parent @backupTo | Out-Null;
    }
    
    if ($restoreFrom) {
        Write-LogInfo "Restoring new Sql Database - $name...";
        $swapAndDrop = [bool]$db;
        $importParams = (Clone-Object $creationParams).Result;
        if ($swapAndDrop) {
            $oldName = "$($name)_old";
            $newName = "$($name)_import";
            $importParams["DatabaseName"] = $newName;
        }
        Deploy-SqlDatabaseRestore -Server $parent @importParams @restoreFrom | Out-Null;
        if ($swapAndDrop) {
            Rename-SqlDatabase -Server $parent -OldName $name     -NewName $oldName;
            Rename-SqlDatabase -Server $parent -OldName $newName  -NewName $name;
            while (!(Get-AzureRmSqlDatabase @baseparams -DatabaseName $oldName -ErrorAction SilentlyContinue)) { Start-Sleep -Seconds 5; }
            Remove-AzureRmSqlDatabase @baseparams -DatabaseName $oldName | Out-Null;
        }
        $db = Get-AzureRmSqlDatabase @dbparams;
    } elseif (!$db) {
        Write-LogInfo "Creating new Sql Database - $name...";
        $db = New-AzureRmSqlDatabase @creationParams;
    } else {
        $update = ($collation    -and $collation    -ne $db.CollationName              );
        $update = ($tier         -and $tier         -ne $db.CurrentServiceObjectiveName) -or $update;
        $update = ($maxSizeBytes -and $maxSizeBytes -ne $db.MaxSizeBytes               ) -or $update;
        if ($update) {
            Write-LogInfo "Updating Sql Database - $name...";
            $db = Set-AzureRmSqlDatabase @creationParams;
        } else {
            Write-LogInfo "Sql Database '$name' is up-to-date.";
        }
    }

    $adminConnString = [System.Data.SqlClient.SqlConnectionStringBuilder]::new();
    $adminConnString["Data Source"] = $parent.Name + ".database.windows.net";
    $adminConnString["Initial Catalog"] = $name;
    $adminConnString["User ID"] = $parent.AdminUserName;
    $adminConnString["Password"] = $parent.AdminPassword;

    if ($code) {
        $projectPath = $code.ProjectPath;
        $code.Remove("ProjectPath") | Out-Null;
        $build = @{ ConnectionString = $adminConnString.ConnectionString;
                    ProjectPath = $projectPath;
                    DeployParams = $code; };
        Deploy-SqlDatabaseCode @build;
    }
    $dbProps = @{ AdminConnectionString = $adminConnString.ConnectionString; };
    return Join-Hashtable $dbProps $sqlDatabaseActions;
}

function Deploy-SqlDatabaseRestore($databaseName, $server, $container, $maxSizeBytes, $requestedServiceObjectiveName, $blobPath) {
    $editions = @{ "F"[0] = "Free"; "B"[0] = "Basic"; "S"[0] = "Standard"; "P"[0] = "Premium"; };
    $blobToImport = $container.ListBlobs($blobPath) | Sort-Object -Property "LastModified" -Descending | Select-Object -First 1;
    $blobUri = $blobToImport.ICloudBlob.Uri.ToString();
    $params = @{
        ResourceGroupName = $server.Parent.Name;
        ServerName = $server.Name;
        DatabaseName = $databaseName;
        Edition = $editions[$requestedServiceObjectiveName[0]];
        ServiceObjectiveName = $requestedServiceObjectiveName;
        DatabaseMaxSizeBytes = $maxSizeBytes;
        StorageKeyType = "StorageAccessKey";
        StorageKey = $container.Parent.GetAccessKey();
        StorageUri = $blobUri;
        AdministratorLogin = $server.AdminUserName;
        AdministratorLoginPassword = ConvertTo-SecureString $server.AdminPassword -AsPlainText -Force;
        };
    Write-LogInfo "Starting import of SQL Database to '$databaseName' from '$blobUri'...";
    $info = New-AzureRmSqlDatabaseImport @params;
    while ($import.Status -ne "Succeeded") {
        Start-Sleep -Seconds 15;
        $import = Get-AzureRmSqlDatabaseImportExportStatus $info.OperationStatusLink;
    }
    $returnValue = Get-AzureRmSqlDatabase -ResourceGroupName $server.Parent.Name -ServerName $server.Name -DatabaseName $name;
    Write-LogInfo "Import complete.";

    return $returnValue;
}

function Deploy-SqlDatabaseBackup($databaseName, $server, $container, $blobPath) {
    $blobUri = $container.GetBlobUrl($blobPath);
    $params = @{
        ResourceGroupName = $server.Parent.Name;
        ServerName = $server.Name;
        DatabaseName = $databaseName;
        StorageKeyType = "StorageAccessKey";
        StorageKey = $container.Parent.GetAccessKey();
        StorageUri = $blobUri;
        AdministratorLogin = $server.AdminUserName;
        AdministratorLoginPassword = ConvertTo-SecureString $server.AdminPassword -AsPlainText -Force;
        };
    Write-LogInfo "Starting backup of SQL Database '$databaseName' to '$blobUri'...";
    $info = New-AzureRmSqlDatabaseExport  @params;
    while ($export.Status -ne "Succeeded") {
        Start-Sleep -Seconds 15;
        $export = Get-AzureRmSqlDatabaseImportExportStatus $info.OperationStatusLink;
    }
    Write-LogInfo "Backup complete";
}

function Rename-SqlDatabase($server, $oldName, $newName) {
    Write-LogInfo "Renaming database $oldName -> $newName ...";
    $server.ExecSqlInMaster("ALTER DATABASE [$oldName] MODIFY NAME = [$newName];");
}

function Deploy-SqlDatabaseCode($projectPath, $connectionString, $deployParams, $verbosity) {
    $deployTemplate = '<?xml version="1.0" encoding="utf-8"?>
        <Project ToolsVersion="15.0" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
        <PropertyGroup>
            <IncludeCompositeObjects>True</IncludeCompositeObjects>
            <ProfileVersionNumber>1</ProfileVersionNumber>
            {params}
        </PropertyGroup>
        </Project>';
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($connectionString);
    $deployParams["TargetConnectionString"] = $connectionString;
    $deployParams["TargetDatabaseName"] = $builder.InitialCatalog;
    $deployParams["DeployScriptFileName"] = [System.IO.Path]::GetFileNameWithoutExtension($projectPath) + ".sql";
    $xmlParams = $deployParams.GetEnumerator() | % { "<$($_.Name)>$([System.Xml.Linq.XText]::new("$($_.Value)"))</$($_.Name)>" };
    $publishProfile = $deployTemplate -replace "{params}", ($xmlParams -join "");

    $projectFolder = Split-Path $projectPath -Parent;
    $publishProfileName = "$($builder.DataSource.Split('.')[0]).$($builder.InitialCatalog).publish.xml";
    $publishProfilePath = Join-Path $projectFolder $publishProfileName;
    ([xml]$publishProfile).Save($publishProfilePath);
    $publishProfilePath = Get-Item $publishProfilePath | Select-Object -ExpandProperty "FullName";

    $buildParams = @(
        "/p:SqlPublishProfilePath=""$publishProfilePath""";
        "/p:TargetConnectionString=""$connectionString""";
        "/p:TargetDatabase=""$($builder.InitialCatalog)""";
        "/p:TargetServer=""$($builder.DataSource)""";
        "/p:TargetUsername=""$($builder.UserID)""";
        "/p:TargetPassword=""$($builder.Password)""";
        "/p:GenerateSqlPackage=True";
        "/p:PublishToDatabase=True";
        );
    Invoke-MsBuild -ProjectPath $projectPath -Target "Build;Publish" -Params $buildParams -Verbosity $verbosity;
    Remove-Item $publishProfilePath;
}

function Invoke-Sql($server, $database, $connectionString, $sql) {
    if ($server) {
        $adminConnString = [System.Data.SqlClient.SqlConnectionStringBuilder]::new();
        $adminConnString["Data Source"] = $server.Name + ".database.windows.net";
        $adminConnString["Initial Catalog"] = "master";
        $adminConnString["User ID"] = $server.AdminUserName;
        $adminConnString["Password"] = $server.AdminPassword;
        $connectionString = $adminConnString.ConnectionString;
    } elseif ($database) {
        $connectionString = $database.AdminConnectionString;        
    }

    $conn = [System.Data.SqlClient.SqlConnection]::new($connectionString);
    $conn.Open();
    try {
        $cmd = $conn.CreateCommand();
        $cmd.CommandType = "Text";
        $cmd.CommandText = $sql;
        $cmd.CommandTimeout = 0;
        $cmd.ExecuteNonQuery() | Out-Null;
    } finally {
        $conn.Dispose();
    }
}
