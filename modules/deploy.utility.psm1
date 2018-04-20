
$ErrorActionPreference = "Stop";

$global:deployStack = [System.Collections.Generic.Stack[object]]::new();
$global:nameFormatTypes = [System.Collections.Generic.List[string]]::new();
$global:currentDeploymentItem = $null;

#region Stack Management
function Push-Stack($name, $config, $path, $graph) {
    $global:deployStack.Push([PSCustomObject][Hashtable]$PSBoundParameters);
}

function Pop-Stack() {
    $global:deployStack.Pop() | Out-Null;
}

function Peek-Stack() {
    return $global:deployStack.Peek();
}

function Get-StackItem([switch]$current, $level) {
    $returnValue = $null;
    if ($current) {
        $stackItem = $global:deployStack.Peek();
    } elseif ($level) {
        $stackItem = $global:deployStack[$level];
    } else {
        throw [ArgumentNullException]::new("Must supply level or current parameter", "level");
    }
    $returnValue = $stackItem | Select-Object -Property ("Config","Name","Path","Graph");
    return $returnValue;
}

function Set-DeploymentItem($item) {
    $global:currentDeploymentItem = $item;
}

function Get-DeploymentItem([switch]$current, $graph, $type, $name) {
    if ($current) {
        $returnValue = $global:currentDeploymentItem;
    } else {
        if (!$graph) {
            $graph = (Peek-Stack).Graph;
        }
        $returnValue = $graph | ? { $_.Id -like "*/$type-$name"; };
    }
    return $returnValue;
}

#endregion

#region Builds & Process Invocation
function Get-MsBuild {
    $vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe";
    $returnValue = & $vswhere "-latest" "-products" "*" "-requires" "Microsoft.Component.MSBuild" "-property" "installationPath";
    if ($returnValue) {
        $returnValue = Join-Path $returnValue 'MSBuild\15.0\Bin\MSBuild.exe'
        if (!(Test-Path $returnValue)) {
            throw [InvalidOperationException] "Could not find MSBuild";
        }
    }
    return $returnValue;
}

function Invoke-MsBuild($projectPath, $target, $params, $verbosity) {
    $msbuild = Get-MsBuild;
    $projectPath = Resolve-ScriptPath -Path $projectPath;
    $buildParams = [System.Collections.Generic.List[object]]::new($params);
    if ($verbosity) {
        $buildParams.Add("/v:$verbosity");
    }
    $buildParams.Add("/t:$target");
    $buildParams.Add("`"$projectPath`"");
    if ($verbosity) {
        $buildParams.Add("/v:$verbosity");
    }
    Write-LogDebug "$msbuild $([string]::Join(" ", $buildParams))";
    Exec-Process -Exe $msbuild -Params $buildParams.ToArray();
}

function Exec-Process($exe, $params, $stdOutLogLevel = "INFO") {
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($exe, $params);
    $startInfo.UseShellExecute = $false;
    $startInfo.RedirectStandardError = $true;
    $startInfo.RedirectStandardOutput = $true;
    $startInfo.CreateNoWindow = $true;
    $process = [System.Diagnostics.Process]::Start($startInfo);

    #see: https://stackoverflow.com/questions/10262231/obtaining-exitcode-using-start-process-and-waitforexit-instead-of-wait/23797762#23797762
    $process.Handle | Out-Null; #apparently required to properly retrieve the ExitCode below...

<# this code seems to crash powershell...
    $process.add_OutputDataReceived({ param($sender, $eventArgs) Write-Log $eventArgs.Data -Level $stdOutLogLevel; });
    $process.add_ErrorDataReceived({ param($sender, $eventArgs) Write-Log $eventArgs.Data -Level "ERROR"; });
    $process.BeginOutputReadLine();
    $process.BeginErrorReadLine();

    while (!$process.HasExited) { Start-Sleep -Milliseconds 500; }
    $process.WaitForExit();
    Start-Sleep -Milliseconds 5000;
#>

    $handler = { Write-Log $EventArgs.Data -Level $event.MessageData; };
    Register-ObjectEvent -InputObject $process -EventName "ErrorDataReceived" -Action $handler -MessageData "ERROR" | Out-Null;
    $process.BeginErrorReadLine();
    Write-Log $process.StandardOutput.ReadToEnd() -Level "INFO";

    while (!$process.HasExited) { Start-Sleep -Milliseconds 500; }
    Start-Sleep -Milliseconds 500;
    $process.WaitForExit();

    if ($process.ExitCode -gt 0) {
        throw [Exception] "Command $exe exited with code $($process.ExitCode)";
    }
}
#endregion

#region Misc functions...

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

function Lock-Object([object]$inputObject, [scriptblock]$scriptBlock) {
    [System.Threading.Monitor]::Enter($inputObject);
    . $scriptBlock;
    [System.Threading.Monitor]::Exit($inputObject);
}

function Get-ExternalIP() {
    if (!$returnValue) {
        $returnValue = Invoke-RestMethod 'http://ipinfo.io/json' | Select-Object -ExpandProperty 'ip';
    }
    if (!$returnValue) {
        $returnValue = (Invoke-WebRequest 'https://itomation.ca/mypublicip').Content.Trim();
    }
    if (!$returnValue) {
        $returnValue = (Invoke-WebRequest 'http://ifconfig.me/ip').Content.Trim();
    }
    return $returnValue;
}

function Resolve-ScriptPath($path, [switch]$getContent) {
    $returnValue = $null;
    $parentScriptDir = Split-Path -Path (Get-StackItem -Current | Select-Object -ExpandProperty "Path") -Parent;
    if (Test-Path (Join-Path -Path $parentScriptDir -ChildPath $path)) {
        $returnValue = Join-Path -Path $parentScriptDir -ChildPath $path;
    } elseif (Test-Path $path) {
        $returnValue = $path;
    } else {
        throw [System.ArgumentException] "$path does not exist in current directory, script directory, or as an absolute path.";
    }

    if ($getContent) {
        $returnValue = "$(Get-Content -Path $returnValue -Raw)";
    }

    return $returnValue;
}

function Test-Interactive {
    $returnValue = $true;

    $flag = !([Environment]::GetCommandLineArgs() | ? { $_ -like '-NonI*' });
    $debug = $host.DebuggerEnabled;
    if ([Environment]::UserInteractive -and $flag) {
        $returnValue = $true;
    } elseif ($debug) {
        $returnValue = $true;
    } else {
        $returnValue = $false;
    }

    return $returnValue;
}

function ConvertTo-Hashtable([Parameter(ValueFromPipeline=$true)]$inputObject, [ScriptBlock]$keySelector, [ScriptBlock]$valueSelector = { $_ }) {
    $returnValue = @{};
    if ($input) {
        $inputObject = $input;
    }
    if ($inputObject -is [Hashtable]) {
        $inputObject = $inputObject.GetEnumerable();
    }
    $inputObject | % {
        $var = [System.Collections.Generic.List[PSVariable]]::new([PSVariable[]]@([PSVariable]::new('_', $_)));
        $key = $keySelector.InvokeWithContext(@{}, $var)[0];
        $var = [System.Collections.Generic.List[PSVariable]]::new([PSVariable[]]@([PSVariable]::new('_', $_)));
        $value = $valueSelector.InvokeWithContext(@{}, $var)[0];
        $returnValue[$key] = $value;
        } | Out-Null;
    return $returnValue;
}

function Join-Url {
    $returnValue = "";
    if ($args.Length -gt 0) {
        $startsWithSlash = ($args | Select-Object -First 1).StartsWith("/");
        $endsWithSlash = ($args | Select-Object -Last 1).EndsWith("/");
        $returnValue = ($args | % { $_.Trim('/', '\') }) -join "/";
        if ($startsWithSlash) {
            $returnValue = "/" + $returnValue;
        }
        if ($endsWithSlash) {
            $returnValue += "/";
        }
    }
    return $returnValue;
}

function Join-Hashtable($source, $other, [switch]$addMethodAsMember) {
    $returnValue = $source;
    if ($other) {
        foreach ($item in $other.GetEnumerator()) {
            if ($addMethodAsMember -and $item.Value -is [ScriptBlock]) {
                Add-Member -MemberType ScriptMethod -Name $item.Name -Value $item.Value -InputObject $source;
            } else {
                $returnValue[$item.Name] = $item.Value;
            }
        }
    }
    return $returnValue;
}

function Resolve-Values($object, $values, [string]$startIdentifier = "[", [string]$endIdentifier = "]", [switch]$debug) {
    $returnValue = @{ Result = $object };
    if ($object -is [string]) {
        if ($object.StartsWith($startIdentifier) -and $object.EndsWith($endIdentifier)) {
            $debug -and (Write-LogDebug "Resolving $object ...") | Out-Null;
            $expression = '@{ Result = $values.' + $object.TrimStart($startIdentifier).TrimEnd($endIdentifier) + ' }';
            $returnValue = Invoke-Expression $expression;
            $debug -and (Write-LogDebug "...Result $($returnValue.Result)") | Out-Null;
        }
    } elseif ($object -is [Hashtable]) {
        $items = $object.GetEnumerator().Where({$true});
        foreach ($item in $items) {
            $debug -and (Write-LogDebug "Resolving property $($item.Name)") | Out-Null;
            $PSBoundParameters["Object"] = $item.Value;
            $object[$item.Name] = (Resolve-Values @PSBoundParameters).Result;
            $debug -and (Write-LogDebug "...Result $($item.Name) : $($object[$item.Name])") | Out-Null;
        }
    } elseif ($object -is [System.Collections.IEnumerable]) {
        for ($i = 0; $i -lt $object.Length; $i++) {
            $debug -and (Write-LogDebug "Resolving $($i) : $($object[$i])") | Out-Null;
            $PSBoundParameters["Object"] = $object[$i];
            $object[$i] = (Resolve-Values @PSBoundParameters).Result;
            $debug -and (Write-LogDebug "...Result $($item.Name) : $($object[$item.Name])") | Out-Null;
        }
    }

    return $returnValue;
}

function Clone-Object($object) {
    $returnValue = $null;
    if ($object -is [string]) {
        $returnValue = $object.Clone();
    } elseif ($object -is [Hashtable]) {
        $returnValue = $object.Clone();
        #Avoiding concurrent modification exception by iterating through input & setting clone
        foreach ($item in $object.GetEnumerator()) {
            $returnValue[$item.Name] = (Clone-Object $item.Value).Result;
        }
    } elseif ($object -is [System.Collections.IEnumerable]) {
        $returnValue = $object.Clone();
        for ($i = 0; $i -lt $returnValue.Length; $i++) {
            $returnValue[$i] = (Clone-Object $returnValue[$i]).Result;
        }
    } elseif ($object -is [PSCustomObject]) {
        $returnValue = [PSCustomObject]@{};
        $cloneMembers = @([System.Management.Automation.PSMemberTypes]::NoteProperty, 
                          [System.Management.Automation.PSMemberTypes]::Property);
        foreach ($member in $object.PSObject.Members) {
            if (!$returnValue.PSObject.Members["$($member.Name)"]) {
                if ($cloneMembers.Contains($member.MemberType)) {
                    $value = (Clone-Object $member.Value).Result;
                } else {
                    $value = $member.Value;
                }
                Add-Member -InputObject $returnValue -Name $member.Name -MemberType $member.MemberType -Value $member.Value | Out-Null;
            }
        }
    } elseif ($object.Clone) {
        $returnValue = $object.Clone();
    } else {
        $returnValue = $object;
    }

    return @{ "result" = $returnValue; };
}

function Get-RandomString($seed, $length = 32, [bool]$lowercase = $true, [bool]$uppercase = $true, [bool]$numbers = $true, [char[]]$symbols = "~!@#$%^&*()_+=-``[]{};':`",./<>?".ToCharArray()) {
    $charList = [System.Collections.Generic.List[char]]::new();
    if ($lowercase) { $charList.AddRange([char[]]([int][char]'a'..[int][char]'z' | % { [char]$_; })); }
    if ($uppercase) { $charList.AddRange([char[]]([int][char]'A'..[int][char]'Z' | % { [char]$_; })); }
    if ($numbers) { $charList.AddRange([char[]](0..9 | % { "$_"; })); }
    if ($symbols) { $charList.AddRange($symbols); }
    $returnValue = ($charList | Get-Random -SetSeed $seed -Count $length) -join "";
    return $returnValue;
}
#endregion

class DeploymentFunctions {
    static [Hashtable] $extensionMethods = @{ };
    [System.Collections.Generic.List[Hashtable]] $deploymentGraph = $null;
    [Hashtable] $currentDeploymentItem = $null;

    static [void] AddExtensionMethod([string]$name, [ScriptBlock]$function) {
        [DeploymentFunctions]::extensionMethods[$name] = $function;
    }

    DeploymentFunctions($graph, $currentItem) {
        $this.deploymentGraph = $graph;
        $this.currentDeploymentItem = $currentItem;
        foreach ($method in [DeploymentFunctions]::extensionMethods.GetEnumerator()) {
            $this | Add-Member -MemberType ScriptMethod -Name $method.Name -Value $method.Value;
        }
    }

    [Hashtable] Resolve($reference) { 
        return Resolve-DeploymentReferenceById -Dependency $reference -Graph $this.deploymentGraph -Item $this.currentDeploymentItem;
    }

    [string] Concat() { 
        return [string]::Join("", $args);
    }

    [string] RandomString() {
        return Get-RandomString -Seed $this.currentDeploymentItem.Id.GetHashCode();
    }
    [string] RandomString([int]$length) {
        return Get-RandomString @PSBoundParameters -Seed $this.currentDeploymentItem.Id.GetHashCode();
    }
    [string] RandomString([string]$seed) {
        return Get-RandomString -Seed ($seed + $this.currentDeploymentItem.Id).GetHashCode();
    }
    [string] RandomString([string]$seed, [int]$length) {
        $PSBoundParameters["seed"] = ($seed + $this.currentDeploymentItem.Id).GetHashCode();
        return Get-RandomString @PSBoundParameters;
    }
    [string] RandomString([bool]$lowercase, [bool]$uppercase, [bool]$numbers, [char[]]$symbols) {
        return Get-RandomString @PSBoundParameters -Seed $this.currentDeploymentItem.Id.GetHashCode();
    }
    [string] RandomString([int]$length, [bool]$lowercase, [bool]$uppercase, [bool]$numbers, [char[]]$symbols) {
        return Get-RandomString @PSBoundParameters -Seed $this.currentDeploymentItem.Id.GetHashCode();
    }
    [string] RandomString([string]$seed, [bool]$lowercase, [bool]$uppercase, [bool]$numbers, [char[]]$symbols) {
        $PSBoundParameters["seed"] = ($seed + $this.currentDeploymentItem.Id).GetHashCode();
        return Get-RandomString @PSBoundParameters;
    }
    [string] RandomString([string]$seed, [int]$length, [bool]$lowercase, [bool]$uppercase, [bool]$numbers, [char[]]$symbols) {
        $PSBoundParameters["seed"] = ($seed + $this.currentDeploymentItem.Id).GetHashCode();
        return Get-RandomString @PSBoundParameters;
    }

    [Object] ResolveProperties($config) {
        $returnValue = $null;
        if ($config -is [string]) {
            $returnValue = $this.ResolveProperty($config);
        } elseif ($config -is [Hashtable]) {
            $items = [System.Collections.Generic.List[System.Collections.DictionaryEntry]]::new();
            $config.GetEnumerator() | % { $items.Add($_); };
            foreach ($item in $items) {
                $isReference = (@("parent", "references", "referencedBy") -contains  $item.Name);
                $isChildItem = [bool]$item.Value.Id
                if ((!$isReference) -and (!$isChildItem)) {
                    $config[$item.Name] = $this.ResolveProperties($item.Value);
                }
            }
            $returnValue = $config;
        } elseif ($config -is [System.Collections.IEnumerable]) {
            for ($i = 0; $i -lt $config.Count; $i++) {
                $isChildItem = [bool]$config[$i].Id
                if (!$isChildItem) {
                    $config[$i] = $this.ResolveProperties($config[$i]);
                }
            }
            $returnValue = $config;
        } else {
            $returnValue = $config;
        }
        return $returnValue;
    }
    
    [object] ResolveProperty([string]$property) {
        $returnValue = $null;
        if ($property.StartsWith("[") -and $property.EndsWith("]")) {
            Write-LogDebug "Resolving dynamic property $property ...";
            $returnValue = Invoke-Expression -Command $property.TrimStart("[").TrimEnd("]");
            Write-LogDebug "... result: $returnValue";
        } else {
            $returnValue = $property;
        }
        return $returnValue;
    }
}

#region Name formatting
function Format-Name($format, $params) {
    $returnValue = $format;
    foreach ($param in $params.GetEnumerator()) {
        $returnValue = $returnValue -replace "{$($param.Name)}",$param.Value;
    }
    return $returnValue.ToLower();
}

function Add-NameFormatType($type) {
    $global:nameFormatTypes.Add($type);
}

function Format-Names($format, $deploymentItems) {
    foreach ($item in $deploymentItems) {
        if ($global:nameFormatTypes.Contains($item.Type)) {
            $item["Name"] = Format-Name -Format $format -Params $item;
        }
    }
}
#endregion

#region Dependencies & Dependency graph

$script:referenceIdentifiers = [System.Collections.Generic.List[Hashtable]]::new();
function Register-ReferenceIdentifier($regex, $resolver) {
    $script:referenceIdentifiers.Add([Hashtable]$PSBoundParameters);
}

function Resolve-DeploymentReference([string]$item, $graphItem, $graph) {
    $returnValue = [System.Collections.Generic.List[Hashtable]]::new();
    foreach ($identifier in $script:referenceIdentifiers) {
        if ($item -match $identifier.regex) {
            $returnValue.Add([Hashtable]$identifier.resolver.Invoke(@($matches, $graphItem, $graph))[0]);
        }
    }
    return @{ Collection = $returnValue };
}

# Regex taken from https://www.metaltoad.com/blog/regex-quoted-string-escapable-quotes
# matches: resolve('anything `"ignoring escaped quotes`" between quotes')
Register-ReferenceIdentifier -Regex "(?<=\[.*)(?<=\`$this\.resolve\()((?<![``])['`"])((?:.(?!(?<![``])\1))*.?)\1(?=\))(?=.*])" `
                             -Resolver { param($m, $item, $graph) return @{ Dependent = $item; Requisite = [DeploymentFunctions]::new($graph, $item).Resolve($m[2]); } };
function Find-DeploymentReferences($item, $graphItem, $graph) {
    $returnValue = [System.Collections.Generic.List[Hashtable]]::new();

    if ($item -is [string]) {
        # $resolveRegex = "(?<=\[.*)(?<=\`$this\.resolve\()((?<![``])['`"])((?:.(?!(?<![``])\1))*.?)\1(?=\))(?=.*])";
        # if ($item -match $resolveRegex) {
        #     $returnValue.Add($Matches[2]);
        # }
        $returnValue.AddRange((Resolve-DeploymentReference -Item $item -GraphItem $graphItem -Graph $graph).Collection);
    } elseif ($item -is [Hashtable]) {
        foreach ($childitem in $item.GetEnumerator()) {
            $isReference = (@("parent", "references", "referencedBy") -contains  $childitem.Name);
            $isChildItem = [bool]$childitem.Value.Id
            if ((!$isReference) -and (!$isChildItem)) {
                $returnValue.AddRange((Find-DeploymentReferences -Item $childitem.Value -GraphItem $graphItem -Graph $graph).Collection);
            }
        }
    } elseif ($item -is [System.Collections.IEnumerable]) {
        foreach ($childItem in $item) {
            $isChildItem = [bool]$childitem.Id
            if (!$isChildItem) {
                $returnValue.AddRange((Find-DeploymentReferences -Item $childitem -GraphItem $graphItem -Graph $graph).Collection);
            }
        }
    }

    return @{ "Collection" = $returnValue };
}

function Get-DeploymentItemId($item, $parent) {
    $returnValue = "$($item.Type)-$($item.Name)";
    if ($parent) {
        $returnValue = $parent.Id + "/" + $returnValue;
    }
    return $returnValue;
}

function Get-ChildDeploymentItems($item, [switch]$childCall) {
    $returnValue = [System.Collections.Generic.List[Hashtable]]::New();;
    if ($item -is [string]) {
        # fall through... we don't want to iterate over the string, but it is an enumerable object...
    } elseif ($item -is [Hashtable]) {
        if ($item.Name -and $item.Type -and $childCall) {
            $returnValue.Add($item);
        } else {
            foreach ($child in $item.Values) {
                $returnValue.AddRange((Get-ChildDeploymentItems $child -ChildCall).Collection);
            }
        }
    } elseif ($item -is [System.Collections.IEnumerable]) {
        foreach ($child in $item) {
            $returnValue.AddRange((Get-ChildDeploymentItems $child -ChildCall).Collection);
        }
    }
    return @{ "Collection" = $returnValue };
}

function Resolve-DeploymentReferenceById($dependency, $item, $graph) {
    $returnValue = $null;

    if (!$graph) {
        $graph = (Peek-Stack).Graph;
    }

    $returnValue = @($graph | ? { $_.Id -eq $dependency -or $_.Id -like "*/$dependency" });
    if ($returnValue.Length -ne 1) {
        throw [ArgumentException]"Dependency '$dependency' matched ${$returnValue.Length} items.";
    }

    return $returnValue;
}

function New-GraphItem([Hashtable]$item, [Hashtable]$parent) {
    $item["Id"] = Get-DeploymentItemId @PSBoundParameters;
    $item["Completed"] = $false;
    $item["Parent"] = $null;
    $item["References"] = [System.Collections.Generic.List[Hashtable]]::New();
    $item["ReferencedBy"] = [System.Collections.Generic.List[Hashtable]]::New();
    return $item;
}

function New-DependencyGraph($items, $parent) {
    $returnValue = [System.Collections.Generic.List[Hashtable]]::New();
    $items | % { $returnValue.Add((New-GraphItem -Item $_ -Parent $parent)); };
    foreach ($item in @($returnValue)) {    
        $children = Get-ChildDeploymentItems $item;
        if ($children.Collection) {
            $childGraph = New-DependencyGraph -Items $children.Collection -Parent $item;
            $returnValue.AddRange($childGraph.Collection);
        }
    }

    if ($parent) {
        foreach ($graphItem in $returnValue) {
            if (!$graphItem.Parent) {
                $graphItem.Parent = $parent;
                $graphItem.References.Add($parent);
                $parent.ReferencedBy.Add($graphItem);
            }
        }
    }

    foreach ($graphItem in $returnValue) {
        if (!$parent) { # only want to resolve dependencies at the root call
            $dependencies = Find-DeploymentReferences -Item $graphItem -GraphItem $graphItem -Graph $returnValue;
            foreach ($dependency in $dependencies.Collection) {
                if ($dependency.Requisite -and $dependency.Dependent) {
                    $dependency.Dependent.References.Add($dependency.Requisite);
                    $dependency.Requisite.ReferencedBy.Add($dependency.Dependent);
                } else {
                    throw "Deployment item $graphItem contains a reference that cannot be resolved.";
                }
            }
        }
    }
    return @{ "Collection" = $returnValue };
}

function Get-ReadyDeploymentItem($graph) {
    function Count-Dependencies($graphItem) {
        $returnValue = 0;
        foreach ($d in $graphItem.References) {
            if (! $d.Completed) {
                $returnValue++;
            }
        }
        return $returnValue;
    }
    return $graph | ? { $_.Completed -eq $false } | 
                    ? { (Count-Dependencies $_) -eq 0 } | 
                    Select-Object -First 1;
}
#endregion

#region General deployment functions
function Deploy-Script($configPath, $name) {
    $filePath = Resolve-ScriptPath -Path $configPath;
    $config = Invoke-Expression -Command "&'$filePath'";
    Run-Deploy -config $config -deploymentName $config.Name;
}

function Deploy-Manual($message, $steps) {
    if (!(Test-Interactive)) {
        throw [System.InvalidOperationException] "Cannot use manual steps in a non-interactive context";
    }
    if ($message) {
        [Console]::Beep(800, 500);
        Write-LogInfo -content $message;
        Write-LogInfo -content "Press enter to continue...";
        [Console]::ReadKey() | Out-Null;
    }
    if ($steps) {
        foreach ($step in $steps.GetEnumerator()) {
            Deploy-Manual @step;
        }
    }
}

function Deploy-Custom($command) {
    $result = Invoke-Expression -Command $command;
    return @{ Result = $result };
}
#endregion


Export-ModuleMember -Function Clone-Object;
Export-ModuleMember -Function Resolve-Values;
Export-ModuleMember -Function Test-Interactive;
Export-ModuleMember -Function Get-StackItem;
Export-ModuleMember -Function Peek-Stack;
Export-ModuleMember -Function Pop-Stack;
Export-ModuleMember -Function Push-Stack;
Export-ModuleMember -Function Get-DeploymentItem;
Export-ModuleMember -Function Set-DeploymentItem;
Export-ModuleMember -Function Get-ExternalIP;
Export-ModuleMember -Function Resolve-ScriptPath;
Export-ModuleMember -Function Join-Url;
Export-ModuleMember -Function Join-Hashtable;
Export-ModuleMember -Function ConvertTo-Hashtable;
Export-ModuleMember -Function Exec-Process;
Export-ModuleMember -Function Invoke-MsBuild;
Export-ModuleMember -Function Get-MsBuild;
Export-ModuleMember -Function New-DependencyGraph;
Export-ModuleMember -Function Resolve-DeploymentReference;
Export-ModuleMember -Function Register-ReferenceIdentifier;
Export-ModuleMember -Function Get-DeploymentItemId;
Export-ModuleMember -Function Get-ReadyDeploymentItem;
Export-ModuleMember -Function Format-Names;
Export-ModuleMember -Function Add-NameFormatType;
Export-ModuleMember -Function Resolve-DynamicProperties;
Export-ModuleMember -Function Deploy-Custom;
Export-ModuleMember -Function Deploy-Script;
Export-ModuleMember -Function Deploy-Manual;
