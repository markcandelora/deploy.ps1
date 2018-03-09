
function Deploy-AppServiceCode($buildType, $projectPath, $resourceGroupName, $appServiceName) {
    if ($buildType -eq "msbuild") {
        Deploy-AppServiceCodeMsBuild @PSBoundParameters;
    } elseif ($buildType -eq "angularcli") {
        throw [NotImplementedException] "angularcli build option has not been implemented";
    } elseif ($buildType -eq "node") {
        throw [NotImplementedException] "node build option has not been implemented";
    }
}

function Deploy-AppServiceWebJob($name, $buildType, $projectPath, $jobType, $resourceGroupName, $appServiceName) {
    if ($buildType -eq "msbuild") {
        Deploy-AppServiceWebJobMBBuild @PSBoundParameters;
    } elseif ($buildType -eq "powershell") {
        throw [NotImplementedException] "powershell build option has not been implemented";
    } elseif ($buildType -eq "node") {
        throw [NotImplementedException] "node build option has not been implemented";
    }
}

function Deploy-AppServiceWebJobMBBuild($name, $projectPath, $jobType, $resourceGroupName, $appServiceName) {
    Write-LogInfo "Deploying $jobType web job $name";

    #Build Project & zip
    $projectDir = Split-Path $projectPath -Parent;
    $outPath = "bin\deploy";
    $outFiles = Join-Path -Path $projectDir -ChildPath "$outPath\*";
    $zipPath = Join-Path -Path $projectDir -ChildPath "$name.zip";
    Remove-Item -Path $outPath -Recurse -Force -ErrorAction SilentlyContinue;
    Write-LogInfo "Building project $projectPath";
    Invoke-MSBuild -ProjectPath $projectPath -Target "Build" -Params @( "/p:OutputPath=`"$outPath`"" );
    Compress-Archive -Path $outFiles -DestinationPath $zipPath -Force;

    #Check for web job existence...
    try {
        $job = Invoke-AzureScmApi -ResourceGroupName $resourceGroupName -AppServiceName $appServiceName -Uri "$($jobType)webjobs/$name" -Method "GET";
    } catch { <# Ignore errors... #> }

    #delete job if exists
    if ($job) {
        Write-LogInfo "Job exists, deleting...";
        $response = Invoke-AzureScmApi -ResourceGroupName $resourceGroupName -AppServiceName $appServiceName -Uri "$($jobType)webjobs/$name" -Method "DELETE";
    }

    #Deploy
    Write-LogInfo "Deploying $jobType webjob $name to $appServiceName";
    $headers = @{ "Content-Disposition" = "attachment; filename=$name.zip"; };
    $response = Invoke-AzureScmApi -ResourceGroupName $resourceGroupName -AppServiceName $appServiceName -Uri "$($jobType)webjobs/$name" -Headers $headers -Method "PUT" -InFile $zipPath -ContentType "application/zip";
}

function Deploy-AppServiceCodeMSBuild($projectPath, $resourceGroupName, $appServiceName) {
    $prof = Get-AppServiceDeploymentProfile @PSBoundParameters;
    $userName = $prof.userName;
    $password = $prof.userPWD;
    $deployUrl = $prof.publishUrl
    $params = @("/p:DeployOnBuild=True", "/p:AllowUntrustedCertificate=True",
                "/p:CreatePackageOnPublish=True", "/p:WebPublishMethod=MSDeploy",
                "/p:MSDeployPublishMethod=WMSVC", "/p:MSDeployServiceUrl=$deployUrl",
                "/p:UserName=$userName", "/p:Password=$password",
                "/p:DeployIisAppPath=$appServiceName", "/p:SkipExtraFilesOnServer=True");
    Invoke-MSBuild -ProjectPath $projectPath -Target "Build" -Params $params;
}
