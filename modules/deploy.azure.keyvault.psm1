Register-AzureProvider "Microsoft.KeyVault";
Add-NameFormatType "KeyVault";
[DeploymentFunctions]::AddExtensionMethod("GetKeyVaultKey"   , { param($name)         $kv = Get-DefaultKeyVault $this.CurrentDeploymentItem; return Get-AzureKeyVaultKey    -VaultName $kv.Name -Name $name; });
[DeploymentFunctions]::AddExtensionMethod("GetKeyVaultSecret", { param($name)         $kv = Get-DefaultKeyVault $this.CurrentDeploymentItem; return Get-AzureKeyVaultSecret -VaultName $kv.Name -Name $name; });
[DeploymentFunctions]::AddExtensionMethod("SetKeyVaultKey"   , { param($name, $type)  $kv = Get-DefaultKeyVault $this.CurrentDeploymentItem; return Ensure-KeyVaultKey      -VaultName $kv.Name -Name $name -Type $type; });
[DeploymentFunctions]::AddExtensionMethod("SetKeyVaultSecret", { param($name, $value) $kv = Get-DefaultKeyVault $this.CurrentDeploymentItem; return Ensure-KeyVaultSecret   -VaultName $kv.Name -Name $name -Value $value; });

("GetKeyVaultKey", "GetKeyVaultSecret", "SetKeyVaultKey", "SetKeyVaultSecret") |
    % { Register-ReferenceIdentifier -Regex "(?<=\[.*)(?<=\`$this\.$_\()((?<![``])['`"])((?:.(?!(?<![``])\1))*.?)\1(?=\))(?=.*])" `
                                     -Resolver { param($m, $currentItem, $graph) return @{ Dependent = $currentItem; Requisite = Get-DefaultKeyVault $currentItem; } } };

$script:VaultActions = @{
    GetKey = { param($name) return Get-AzureKeyVaultKey -VaultName $this.Name -Name $name; };
    GetSecret = { param($name) return Get-AzureKeyVaultSecret -VaultName $this.Name -Name $name; };
    AddSecret = { param($name, $value) return Ensure-KeyVaultSecret -VaultName $this.Name -Name $name -Value $value; };
    AddKey = { param($name, $type) return Ensure-KeyVaultKey -VaultName $this.Name -Name $name -Type $type; };
    };

function Deploy-KeyVault($name, $location, $sku, $secrets, $parent) {
    $location = if ($location) { $location } else { $parent.Location };
    $params = @{
        ResourceGroupName = $parent.Name;
        VaultName = $name;
        };
    $vault = Get-AzureRmKeyVault @params -ErrorAction SilentlyContinue;
    if ($vault) {
        Write-LogInfo "Key vault $name already exists.";
    } else {
        Write-LogInfo "Creating new key vault $name ...";
        $vault = New-AzureRmKeyVault @params -Location $location -Sku $sku -EnabledForDeployment -EnabledForTemplateDeployment -EnabledForDiskEncryption -EnableSoftDelete;
    }

    if ($secrets) {
        $newSecrets = $secrets.GetEnumerator() |
                        % { Ensure-KeyVaultSecret @params -Name $_.Name -Value $_.Value; } |
                        ConvertTo-Hashtable -KeySelector { $_.Name };
    }

    if ($keys) {
        $newKeys = $keys.GetEnumerator() |
                        % { Ensure-KeyVaultKey @params -Name $_.Name -Type $_.Value; } |
                        ConvertTo-Hashtable -KeySelector { $_.Name };
    }

    $vaultProps = @{ Url = $vault.VaultUri.ToString(); Keys = $keys; Secrets = $secrets; };
    return Join-Hashtable $vaultProps $vaultActions -AddMethodAsMember;
}

function Ensure-KeyVaultSecret($vaultName, $name, $value) {
    $secureValue = ConvertTo-SecureString $value -AsPlainText -Force;
    $returnValue = Get-AzureKeyVaultSecret -VaultName $vaultName -Name $name -ErrorAction SilentlyContinue;
    if ($returnValue -and $returnValue.SecretValueText -ne $value) {
        Write-LogInfo "Updating keyvault secret $name ...";
        $returnValue = Set-AzureKeyVaultSecret -VaultName $vaultName -Name $name -SecretValue $secureValue -ContentType 'plain/text';
    } elseif (!$returnValue) {
        Write-LogInfo "Creating new keyvault secret $name ...";
        $returnValue = Set-AzureKeyVaultSecret -VaultName $vaultName -Name $name -SecretValue $secureValue -ContentType 'plain/text';
    } else {
        Write-LogInfo "Keyvault secret $name up-to-date.";
    }
    return $returnValue;
}

function Ensure-KeyVaultKey($vaultName, $name, $type) {
    $secureValue = ConvertTo-SecureString $value -AsPlainText -Force;
    $returnValue = Get-AzureKeyVaultKey -VaultName $vaultName -Name $name -ErrorAction SilentlyContinue;
    if (!$returnValue) {
        Write-LogInfo "Creating new keyvault secret $name ...";
        $returnValue = New-AzureKeyVaultKey -VaultName $vaultName -Name $name -SecretValue $secureValue -ContentType 'plain/text';
    } else {
        Write-LogInfo "Keyvault secret $name up-to-date.";
    }
    return $returnValue;
}

function Get-DefaultKeyVault($deploymentItem) {
    while ($deploymentItem.Type -ne 'ResourceGroup') {
        $deploymentItem = $deploymentItem.Parent;
    }
    $returnValue = $deploymentItem.Resources | ? { $_.Type -eq 'KeyVault' } | Select-Object -First 1;
    return $returnValue;
}
