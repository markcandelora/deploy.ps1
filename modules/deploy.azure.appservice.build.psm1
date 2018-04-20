
function Deploy-AppServiceCode($buildType, $projectPath, $resourceGroupName, $appServiceName) {
    if ($buildType -eq "msbuild") {
        Deploy-AppServiceCodeMsBuild @PSBoundParameters;
    } elseif ($buildType -eq "angularcli") {
        throw [NotImplementedException] "angularcli build option has not been implemented";
    } elseif ($buildType -eq "node") {
        throw [NotImplementedException] "node build option has not been implemented";
    }
}

function Deploy-AppServiceWebJob($name, $buildType, $projectPath, $jobType, $schedule, $resourceGroupName, $appServiceName) {
    if ($buildType -eq "msbuild") {
        Deploy-AppServiceWebJobMBBuild @PSBoundParameters;
    } elseif ($buildType -eq "powershell") {
        throw [NotImplementedException] "powershell build option has not been implemented";
    } elseif ($buildType -eq "node") {
        throw [NotImplementedException] "node build option has not been implemented";
    }

    if ($jobType -eq "triggered" -and $schedule) {
        Write-LogInfo "Setting CRON schedule: $schedule";
        $body = ConvertTo-Json @{ schedule = $schedule } -Compress;
        $headers = @{  };
        Invoke-AzureScmApi -ResourceGroupName $resourceGroupName -AppServiceName $appServiceName -Uri "$($jobType)webjobs/$name/settings" -Headers $headers -Body $body -Method "PUT" -ContentType "application/json" | Out-Null;
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

    #Deploy
    Write-LogInfo "Deploying $jobType webjob $name to $appServiceName";
    $headers = @{ "Content-Disposition" = "attachment; filename=$name.zip"; };
    $response = Invoke-AzureScmApi -ResourceGroupName $resourceGroupName -AppServiceName $appServiceName -Uri "$($jobType)webjobs/$name" -Headers $headers -Method "PUT" -InFile $zipPath -ContentType "application/zip";

    Remove-Item $zipPath;
}

function Deploy-AppServiceCodeMSBuild($projectPath, $resourceGroupName, $appServiceName) {
    $prof = Get-AppServiceDeploymentProfile @PSBoundParameters;
    $userName = $prof.userName;
    $password = $prof.userPWD;
    $deployUrl = $prof.publishUrl
    $params = [Xml]"<Project ToolsVersion='4.0' xmlns='http://schemas.microsoft.com/developer/msbuild/2003'><PropertyGroup>
                <DeployOnBuild>True</DeployOnBuild>
                <AllowUntrustedCertificate>True</AllowUntrustedCertificate>
                <CreatePackageOnPublish>True</CreatePackageOnPublish>
                <WebPublishMethod>MSDeploy</WebPublishMethod>
                <PublishProvider>AzureWebSite</PublishProvider>
                <MSDeployPublishMethod>WMSVC</MSDeployPublishMethod>
                <MSDeployServiceUrl>$deployUrl</MSDeployServiceUrl>
                <DeployIisAppPath>$appServiceName</DeployIisAppPath>
                <UserName>$userName</UserName>
                <Password>$password</Password>
                <SkipExtraFilesOnServer>True</SkipExtraFilesOnServer>
               </PropertyGroup></Project>";
    $publishProfile = Join-Path -Path (Split-Path -Path $projectPath -Parent) -ChildPath "properties/PublishProfiles/deploy.pubxml";
    $params.Save($publishProfile);
    $cmdLineArgs = @( '/p:PublishProfile=deploy.pubxml' );
    Invoke-MSBuild -ProjectPath $projectPath -Target 'Build' -Params $cmdLineArgs -Verbosity "minimal";
}
