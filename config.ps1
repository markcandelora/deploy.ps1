param (
    [string]$environment
    )

$dev = @{
    SQLTier = "Basic";
    };
$prod = @{
    SQLTier = "Basic";
    };
$envParams = if ($environment -eq "dev") { $dev } else { $prod };

return @{
    Name = "TestDeployment";
    NameFormat = "deploy{name}asdf";
    Items = @(
        @{ Type = "ResourceGroup"; Name = "test"; Location = "East US"; Resources = @(
            @{ Type = "ApiManagement"; Name = "api"; Sku = "Developer"; Organization = "marks test"; AdminEmail = "markc@bluemetal.com"; EnableCors = $true;
               Products = @(@{ ProductName = "Unlimited"; });
               Users = @( @{ Email = "markc@bluemetal.com"; Subscriptions = @("Unlimited"); };
                          @{ Email = "mcandelo@gmail.com"; Password = "abcXYZ123!@#"; FirstName = "Mark"; LastName = "Candelora"; Subscriptions = @("Unlimited"); }; ); };
            # @{ Type = "KeyVault"; Name = "vault"; Sku = "Standard"; Secrets = @{ abc = "9n87sdf8b97io" }; };
            # @{ Type = "AppServicePlan"; Name = "svcplan2";
            #     Tier = "Free"; Location = "East US"; AppServices = @(
            #         @{ Type = "AppService"; Name = "blahA"; 
            #             Code = @{
            #                 BuildType = "MSBuild";
            #                 ProjectPath = ".\testingCode\BlahA\BlahA.csproj";
            #                 };
            #             WebJobs = @(
            #                 @{ Name = "aaa"; JobType = "triggered"; BuildType = "MSBuild"; ProjectPath = ".\testingCode\BlahB\BlahB.csproj"; }
            #                 );
            #             AppSettings = @{
            #                 "bbb" = '[$this.resolve("ResourceGroup-test/StorageAccount-store/BlobContainer-test").CreateSasToken(999)]';
            #                 };
            #             ApiManagement = '[$this.AddApiMgmtApi("api", "blaha", "blaha", "/swagger/blaha/swagger.json")]';
            #             };
            #         @{ Type = "AppService"; Name = "blahB"; 
            #             AppSettings = @{
            #                 "abc" = '[$this.GetKeyVaultSecret("abc").SecretValueText]';
            #                 "random" = '[$this.RandomString()]';
            #                 };
            #             ConnectionStrings = @{ 
            #                 #"connStr" = "[$this.resolve('ResourceGroup-test/Custom-sample1').Result]";
            #                 }
            #             };
            #         @{ Type = "FunctionApp"; Name = "blahC"
            #             Code = @{
            #                 BuildType = "MSBuild";
            #                 ProjectPath = ".\testingCode\BlahC\BlahC.csproj";
            #                 };
            #             StorageAccount = '[$this.Resolve("ResourceGroup-test/StorageAccount-store").GetConnectionString()]' 
            #             AppSettings = @{
            #                 "bbb" = '[$this.resolve("ResourceGroup-test/StorageAccount-store/BlobContainer-test").Url.ToString()]';
            #                 };
            #             ConnectionStrings = @{
            #                 "store" = @{ Value = '[$this.Resolve("ResourceGroup-test/StorageAccount-store").GetConnectionString()]'; Type = "Custom" };
            #                 }
            #             }
            #         )
            #     };
            # @{ Type = "StorageAccount"; Name = "store"; SkuName = "Standard_LRS"; Kind = "Storage";
            #     BlobContainers = @(
            #         @{ Type = "BlobContainer"; Name = "test"; 
            #             Blobs = @( 
            #                 @{ Type = "Blob"; Name = "config.ps1"; BlobPath = ".\modules" } 
            #                 )
            #             };
            #         @{ Type = "BlobContainer"; Name = "telemetry"; };
            #         @{ Type = "BlobContainer"; Name = "referencedata"; };
            #         )
            #     };
            # @{ Type = "IotHub"; Name = "iothub"; Sku = "F1"; Units = 1; };
            # @{ Type = "StreamAnalytics"; Name = "stream"; Sku = "Standard";
            #     ProjectPath = ".\testingCode\BlahD\BlahD.asaproj"; 
            #     Depends = @(
            #         '[$this.resolve("ResourceGroup-test/StorageAccount-store/BlobContainer-telemetry")]';
            #         '[$this.resolve("ResourceGroup-test/StorageAccount-store/BlobContainer-referencedata")]';
            #         '[$this.resolve("ResourceGroup-test/IotHub-iothub")]';
            #         ); };
            # @{ Type = "SqlServer"; Name = "blah"; AdminUserName = "sqlAdmin"; AdminPassword = "[$this.resolve("ResourceGroup-test/KeyVault-vault").AddSecret("blah-admin-pwd", $this.RandomString())]";
            #     Databases = @(
            #         @{ Type = "SqlDatabase"; Name = "blaha"; Tier = $envParams.SQLTier; MaxGigs = 2;
            #             Code = @{ ProjectPath = ".\testingCode\BlahE\BlahE.sqlproj";
            #                       BlockOnPossibleDataLoss = $false;
            #                       DropObjectsNotInSource = $true;
            #                 }; };
            #         ); };
            # @{ Type = "ServiceBus"; Name = "blahsb"; Sku = "Standard"; AuthRules = @{ Abc = "Send;Listen"; Def = "Listen" };
            #    Items = @( @{ Type = "ServiceBusTopic"; Name = "topica"; AuthRules = @{ topicaccess = "Listen"; }; };
            #               @{ Type = "ServiceBusQueue"; Name = "queuea"; AuthRules = @{ queueaccess = "Send" }; };
            #     ); };
            )};
        );
    };