
$ErrorActionPreference = "Stop";

$progressStack = [System.Collections.Generic.Stack[object]]::new();
$stackAdjustment = 0;
$logPath = $null;
$logStarted = $false;
$startTime = $null;
$endTime = $null;
$isInteractive = $true;
$logLevel = $null;
$logLevels = @{ "DEBUG" = 1;
                "INFO" = 2;
                "WARN" = 3;
                "ERROR" = 4; };

function Start-Log($rootPath, $logName, $logLevel = "INFO") {
    if (!$logStarted) {
        $script:stackAdjustment = (Get-PSCallStack).Length;
        $script:startTime = [DateTime]::Now;
        $script:isInteractive = Test-Interactive;
        $script:logPath = Join-Path -Path $rootPath -ChildPath "$logName-$($script:startTime.ToString("yyy-MM-ddTHH-mm-ss")).log";
        $script:logStarted = $true;
        Set-LogLevel $logLevel;
        if (!(Test-Path $rootPath)) {
            New-Item -Path $rootPath -ItemType Directory;
        } elseif (Test-Path $script:logPath) {
            Remove-Item $script:logPath;
        }
        Write-LogInternal -content "######################################" -prefix "#";
        Write-LogInternal -content " Azure Deployment $script:startTime" -prefix "#";
        Write-LogInternal -content "######################################" -prefix "#";
    }
}

function Stop-Log() {
    $script:endTime = [DateTime]::Now;
    Write-LogInternal -content "######################################" -prefix "#";
    Write-LogInternal -content " End Deployment $script:endTime" -prefix "#";
    Write-LogInternal -content " Total Runtime $($script:endTime - $script:startTime)" -prefix "#";
    Write-LogInternal -content "######################################" -prefix "#";
    $script:logStarted = $false;
}

function Write-LogInfo($content) {
    Write-Log -content $content -level "INFO";
}

function Write-LogDebug($content) {
    Write-Log -content $content -level "DEBUG";
}

function Write-LogWarning($content) {
    Write-Log -content $content -level "WARN";
}

function Write-LogWarn($content) {
    Write-Log -content $content -level "WARN";
}

function Write-LogError($content, $errorRecord) {
    Write-Log @PSBoundParameters -level "ERROR";
}

function Write-Log($content, $errorRecord, $level = "INFO") {
    $datePrefix = (Get-Date).ToString("yyy-MM-dd hh:mm:ss.fffff");
    $prefix = "[$datePrefix - $level] ";
    if ($content) {
        Write-LogInternal -prefix $prefix -content $content;
    }
    if ($errorRecord) {
        $errorMessage = "$($errorRecord.Exception.Message)`n$($errorRecord.ScriptStackTrace)";
        Write-LogInternal -prefix $prefix -content $errorMessage;
    }
}

function Write-LogInternal($prefix, $content) {
    $content = Add-CallStackPrefix -message $content;
    $content = Add-Prefix -prefix $prefix -message $content;
    
    if ($script:isInteractive) {
        [Console]::Out.WriteLine($content);
    }

    if ($script:logPath) {
        Out-File -FilePath $script:logPath -Append -NoClobber -InputObject $content;
    }
}

function Update-ProgressBar($activity, $status, $percent, [double]$completedItems, [double]$totalItems) {
    if ($script:isInteractive) {
        if (!$percent) {
            $percent = [Math]::Min(($completedItems / $totalItems) * 100, 100);
        }
        $completed = $percent -ge 100;
        $id = [Math]::Abs($activity.GetHashCode());
        if ($script:progressStack.Count -gt 0) {
            $parent = $script:progressStack.Peek();
        }
        if ($parent.Id -ne $id) {
            $script:progressStack.Push(@{ Id = $id; ParentId = $parent.Id; });
        }
        $self = $script:progressStack.Peek();
        if ($self.ParentId) {
            Write-Progress -Id $id -Activity $activity -Status $status -PercentComplete $percent -Completed:$completed -ParentId $self.ParentId;
        } else {
            Write-Progress -Id $id -Activity $activity -Status $status -PercentComplete $percent -Completed:$completed;
        }

        if ($completed) {
            $script:progressStack.Pop() | Out-Null;
        }
    }
}

function Get-LogLevel {
    return $script:logLevels.GetEnumerator() | ? { $_.Value -eq $script:logLevel; } | Select-Object -ExpandProperty "Name";
}

function Set-LogLevel($level) {
    if($script:logLevels.ContainsKey($level)) {
        $script:logLevel = $script:logLevels[$level];
    } else {
        throw "The specified log level '$level' is not valid please use one of $($script:logLevels.Keys)";
    }
}

function Add-CallStackPrefix($message) {
    $depth = [Math]::Max(0, (Get-PSCallStack).Length - ($script:stackAdjustment + 2));
    $prefix = "  " * $depth;
    return Add-Prefix $message $prefix;
}

function Add-Prefix($message, $prefix) {
    return $prefix + ($message -replace "`r`n", "`n" `
                               -replace "`r", "`n" `
                               -replace "`n", "`n$prefix");    
}

Set-Alias -Name "Write-Host" -Value Write-LogInfo;

Export-ModuleMember -Function Start-Log;
Export-ModuleMember -Function Stop-Log;
Export-ModuleMember -Function Get-LogLevel;
Export-ModuleMember -Function Set-LogLevel;
Export-ModuleMember -Function Write-LogDebug;
Export-ModuleMember -Function Write-LogInfo;
Export-ModuleMember -Function Write-LogWarn;
Export-ModuleMember -Function Write-LogError;
Export-ModuleMember -Function Write-Log;
Export-ModuleMember -Function Update-ProgressBar;
Export-ModuleMember -Alias "Write-Host";
