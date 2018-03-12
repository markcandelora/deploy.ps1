USING MODULE ".\modules\deploy.utility.psm1";

PARAM (
    [string]$configFile = "$PSScriptRoot\config.ps1",
    [Hashtable]$configParams = @{ Environment = "dev" },
    [string]$logLevel = "INFO"
    )

$ErrorActionPreference = "Stop";

class Deployment {
    [string] $configFile = $null;
    [Hashtable] $deploymentConfig = $null;
    [System.Collections.Generic.List[Hashtable]] $deploymentGraph = $null;
    [Hashtable] $currentDeploymentItem = $null;
        
    Deployment($configFile, $params) {
        $this.configFile = $configFile;
        $this.deploymentConfig = Invoke-Expression "&'$configFile' @params";
    }
    
    [void] Start() {
        $this.Start("INFO");
    }
    
    [void] Start($logLevel) {
        Start-Log -RootPath $PSScriptRoot -logName $this.deploymentConfig.Name -LogLevel $logLevel;
        $this.Deploy();
        Stop-Log;
    }

    [void] Deploy() {
        $nameFormat = $this.deploymentConfig.NameFormat;
        $this.deploymentGraph = (New-DependencyGraph $this.deploymentConfig.Items).Collection;
        Format-Names -Format $nameFormat -DeploymentItems $this.deploymentGraph;

        Push-Stack -Name $this.deploymentConfig.Name -Config $this.deploymentConfig -Path $this.configFile -Graph $this.deploymentGraph;

        $i = 0;
        $done = $false;
        while (! $done) {
            $deploymentItem = Get-ReadyDeploymentItem $this.deploymentGraph;

            if (!$deploymentItem) {
                throw [InvalidOperationException] "Deployment configuration contains circular references or other error preventing completion of deployment.";
            }

            Update-ProgressBar -Activity $this.deploymentConfig.Name -Status $deploymentItem.Id -CompletedItems $i -totalItems $this.deploymentGraph.Count;
            $this.StartStep($deploymentItem);
            Update-ProgressBar -Activity $this.deploymentConfig.Name -Status $deploymentItem.Id -CompletedItems (++$i) -totalItems $this.deploymentGraph.Count;
            $deploymentItem.Completed = $true;

            $done = ($this.deploymentGraph | ? { $_.Completed -ne $true }).Count -eq 0;
        }
        Pop-Stack | Out-Null;
    }

    [void] StartStep([Hashtable]$configItem) {
        $this.currentDeploymentItem = $configItem;
        Set-DeploymentItem $configItem;
        Write-LogInfo "Starting $($configItem.Type) $($configItem.Name)...";
        
        try {
            $type = $configItem.Type;
            $resolver = [DeploymentFunctions]::new($this.deploymentGraph, $configItem);
            $this.currentDeploymentItem = $resolver.ResolveProperties($configItem);
            $result = $this.MeasureCommand({ return Invoke-Expression -Command "return Deploy-$type @configItem;" });
            $this.currentDeploymentItem = Join-Hashtable $configItem $result.Result -AddMethodAsMember;
            Write-LogInfo "Completed $($configItem.Type) $($configItem.Name) in $($result.Runtime)";
            $this.currentDeploymentItem = $null;
        } catch {
            $err = $_;
            while ($err.Exception -is [System.Management.Automation.MethodInvocationException]) {
                $err = $err.Exception.InnerException.ErrorRecord;
            }
            Write-LogError -content "An error occurred during deployment step $($configItem.Type) $($configItem.Name)" -ErrorRecord $err;
            throw;
        }
    }

    [Hashtable] MeasureCommand([ScriptBlock]$expression) {
        $startTime = Get-Date;
        $result = $expression.Invoke();
        $endTime = Get-Date;
        return @{
            Result = $result | Select-Object -First 1;
            Runtime = $endTime - $startTime;
            };
    }

    static [void] EnsureModule($path) {
        $moduleFile = Split-Path $path -Leaf;
        $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($moduleFile);
        $module = Get-Module -Name $moduleName -ErrorAction SilentlyContinue;
        if (!$module) {
            Microsoft.PowerShell.Utility\Write-Host "Loading module $moduleName";

            $warnPref = $global:WarningPreference;
            $WarningPreference = "SilentlyContinue";
            Invoke-Expression -Command "USING MODULE '$path';" -WarningAction SilentlyContinue;
            $global:WarningPreference = $warnPref;
        }
    }
}

function Add-NameFormatType($type) {
    [Deployment]::EnsureModule("$PSScriptRoot\modules\deploy.utility.psm1");
    deploy.utility\Add-NameFormatType -Type $type;
}

function Register-ReferenceIdentifier($regex, $resolver) {
    [Deployment]::EnsureModule("$PSScriptRoot\modules\deploy.utility.psm1");
    deploy.utility\Register-ReferenceIdentifier @PSBoundParameters;
}

function Ensure-Module($name) {
    [Deployment]::EnsureModule($name);
}

function Load-Modules() {
    $modules = Get-ChildItem "$PSScriptRoot\modules" -Filter "*.psm1" | 
               % { [PSCustomObject]@{ Name = [System.IO.Path]::GetFileNameWithoutExtension($_.FullName); Path = $_.FullName; } } | 
               Sort-Object -Property "Name";
    $modules | Select-Object -ExpandProperty "Name" |
               % { Remove-Module $_ -Force -ErrorAction SilentlyContinue };
    $modules | Select-Object -ExpandProperty "Path" | % { [Deployment]::EnsureModule($_) };
}

Load-Modules;
$deployment = [Deployment]::new($configFile, $configParams);
$deployment.Start();

<#
& 'C:\Program Files (x86)\Microsoft Visual Studio\2017\Enterprise\MSBuild\15.0\Bin\MSBuild.exe' `
    '/p:TargetConnectionString="Data Source=deployblahasdf.database.windows.net;Initial Catalog=blaha;User ID=sqlAdmin;Password=Pass@word1"' `
    '/p:TargetDatabase="deployblahasdf.database.windows.net"' `
    '/p:TargetServer="blaha"' `
    '/p:TargetUsername="sqlAdmin"' `
    '/p:TargetPassword="Pass@word1"' `
    '/p:SqlPublishProfilePath="C:\git\_internal\Azure Deployment\testingCode\BlahE\deployblahasdf.blaha.publish.xml"' `
    '/p:GenerateSqlPackage="True"' `
    '/p:PublishToDatabase="True"' `
    '/t:Build;Publish' `
    '".\testingCode\BlahE\BlahE.sqlproj"';
#>

