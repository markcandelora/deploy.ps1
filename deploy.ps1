USING MODULE ".\modules\deploy.utility.psm1";
USING MODULE ".\modules\deploy.logging.psm1";

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

    static [void] EnsureModule([string]$path, [bool]$force) {
        Ensure-Module -Name $path -Force:$force;
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

function Ensure-Module($name, [switch]$force) {
    $moduleFile = Split-Path $name -Leaf;
    $moduleName = [System.IO.Path]::GetFileNameWithoutExtension($moduleFile);
    $module = Get-Module -Name $moduleName -ErrorAction SilentlyContinue;
    if ($module -and $force) {
        Remove-Module -Name ([System.IO.Path]::GetFileNameWithoutExtension($name));
        $module = $null;
    }

    if (!$module -or $force) {
        Microsoft.PowerShell.Utility\Write-Host "Loading module $moduleName";

        $warnPref = $global:WarningPreference;
        $WarningPreference = "SilentlyContinue";
        Invoke-Expression -Command "USING MODULE '$name';" -WarningAction SilentlyContinue;
        $global:WarningPreference = $warnPref;
    }
}

function Load-Modules() {
    #do not reload these...
    $skipReload = @("deploy.logging","deploy.utility");
    $modules = Get-ChildItem "$PSScriptRoot\modules" -Filter "*.psm1" | 
               % { [PSCustomObject]@{ Name = [System.IO.Path]::GetFileNameWithoutExtension($_.FullName); Path = $_.FullName; } } | 
               ? { $skipReload -notcontains $_.Name } |
               Sort-Object -Property "Name";
    $modules | Select-Object -ExpandProperty "Path" | % { Ensure-Module -Name $_ -Force };
}
Ensure-Module ".\modules\deploy.utility.psm1" -Force;
Ensure-Module ".\modules\deploy.logging.psm1" -Force;

Load-Modules;
$deployment = [Deployment]::new($configFile, $configParams);
$deployment.Start();
