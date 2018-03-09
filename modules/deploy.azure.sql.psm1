
Register-AzureProvider "Microsoft.Sql";
Add-NameFormatType "SqlServer";

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

function Deploy-SqlDatabase($name, $tier, $collation, $maxGigs, $code, $parent) {
    $params = @{ ResourceGroupName = $parent.Parent.Name;
                 ServerName = $parent.Name;
                 DatabaseName = $name };
    $db = Get-AzureRmSqlDatabase @params -ErrorAction SilentlyContinue;

    if ($collation) { $params["CollationName"] = $collation; }
    if ($tier) { $params["RequestedServiceObjectiveName"] = $tier; }
    if ($maxGigs) {
        $maxSizeBytes = ($maxGigs * 1024 * 1024 * 1024);
        $params["MaxSizeBytes"] = $maxSizeBytes;
    }
    
    if (!$db) {
        Write-LogInfo "Creating new Sql Database - $name...";
        $db = New-AzureRmSqlDatabase @params;
    } else {
        $update = ($collation    -and $collation    -ne $db.CollationName              );
        $update = ($tier         -and $tier         -ne $db.CurrentServiceObjectiveName) -or $update;
        $update = ($maxSizeBytes -and $maxSizeBytes -ne $db.MaxSizeBytes               ) -or $update;
        if ($update) {
            Write-LogInfo "Updating Sql Database - $name...";
            $db = Set-AzureRmSqlDatabase @params;
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
    return @{ AdminConnectionString = $adminConnString.ConnectionString; };
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
    # $deployParams["TargetConnectionString"] = $connectionString;
    # $deployParams["TargetDatabase"] = $builder.InitialCatalog;
    # $deployParams["TargetDatabaseName"] = $builder.InitialCatalog;
    $deployParams["DeployScriptFileName"] = [System.IO.Path]::GetFileNameWithoutExtension($projectPath) + ".sql";
    $xmlParams = $deployParams.GetEnumerator() | % { "<$($_.Name)>$([System.Xml.Linq.XText]::new("$($_.Value)"))</$($_.Name)>" };
    $publishProfile = $deployTemplate -replace "{params}", ($xmlParams -join "");

    $projectFolder = Split-Path $projectPath -Parent;
    $publishProfileName = "$($builder.DataSource.Split('.')[0]).$($builder.InitialCatalog).publish.xml";
    $publishProfilePath = Join-Path $projectFolder $publishProfileName;
    ([xml]$publishProfile).Save($publishProfilePath);
    $publishProfilePath = Get-Item $publishProfilePath | Select-Object -ExpandProperty "FullName";

    # $params = $deployParams.GetEnumerator() | % { "/p:$($_.Name)=`"$($_.Value)`"" };
    # Invoke-MsBuild -ProjectPath $projectPath -Target "Publish" -Params $params -Verbosity $verbosity;

    $buildParams = @(
        "/p:SqlPublishProfilePath=`"$publishProfilePath`"";
        "/p:TargetConnectionString=`"$connectionString`"";
        "/p:TargetDatabase=`"$($builder.InitialCatalog)`"";
        );
    Invoke-MsBuild -ProjectPath $projectPath -Target "Clean;Build;Publish" -Params $buildParams -Verbosity $verbosity;
    Remove-Item $publishProfilePath;
}

function Invoke-Sql($connectionString, $sql) {
    $conn = [System.Data.SqlClient.SqlConnection]::new($connectionString);
    $conn.Open();
    try {
        $cmd = $conn.CreateCommand();
        $cmd.CommandType = "Text";
        $cmd.CommandText = $sql;
        $cmd.ExecuteNonQuery() | Out-Null;
    } finally {
        $conn.Dispose();
    }
}