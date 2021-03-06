Configuration ArcGISMissionServer
{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [System.Management.Automation.PSCredential]
        $ServiceCredential,

        [Parameter(Mandatory=$false)]
        [System.Boolean]
        $ServiceCredentialIsDomainAccount = $false,

        [Parameter(Mandatory=$false)]
        [System.Boolean]
        $ServiceCredentialIsMSA = $false,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [System.Management.Automation.PSCredential]
        $ServerPrimarySiteAdminCredential,
        
        [Parameter(Mandatory=$False)]
        [System.String]
        $PrimaryServerMachine,

        [Parameter(Mandatory=$False)]
        [System.String]
        $ConfigStoreLocation,

        [Parameter(Mandatory=$True)]
        [System.String]
        $ServerDirectoriesRootLocation,

        [Parameter(Mandatory=$False)]
        [System.Array]
        $ServerDirectories = $null,

        [Parameter(Mandatory=$False)]
        [System.String]
        $ServerLogsLocation = $null,

        [Parameter(Mandatory=$False)]
        [System.Object]
        $SslRootOrIntermediate,

        [Parameter(Mandatory=$False)]
        [ValidateSet("AzureFiles","AzureBlob")]
        [AllowNull()] 
        [System.String]
        $CloudStorageType,

        [Parameter(Mandatory=$False)]
        [System.String]
        $AzureFileShareName,

        [Parameter(Mandatory=$False)]
        [System.String]
        $CloudNamespace,

        [Parameter(Mandatory=$False)]
        [System.Management.Automation.PSCredential]
        $CloudStorageCredentials,

        [Parameter(Mandatory=$False)]
        [System.Array]
        $ContainerImagePaths,

        [Parameter(Mandatory=$False)]
        [System.Boolean]
        $DebugMode = $False
    )

    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DSCResource -ModuleName @{ModuleName="ArcGIS";ModuleVersion="3.1.1"}
    Import-DscResource -Name ArcGIS_MissionServer
    Import-DscResource -Name ArcGIS_MissionServerSettings
    Import-DscResource -Name ArcGIS_Server_TLS
    Import-DscResource -Name ArcGIS_Service_Account
    Import-DscResource -Name ArcGIS_WindowsService
    Import-DscResource -Name ArcGIS_xFirewall

    if(($null -ne $CloudStorageType) -and $CloudStorageCredentials) 
    {
        $AccountName = $CloudStorageCredentials.UserName
		$EndpointSuffix = ''
        $Pos = $CloudStorageCredentials.UserName.IndexOf('.blob.')
        if($Pos -gt -1) {
            $AccountName = $CloudStorageCredentials.UserName.Substring(0, $Pos)
			$EndpointSuffix = $CloudStorageCredentials.UserName.Substring($Pos + 6) # Remove the hostname and .blob. suffix to get the storage endpoint suffix
			$EndpointSuffix = ";EndpointSuffix=$($EndpointSuffix)"
        }

        if($CloudStorageType -ieq 'AzureFiles') {
            $AzureFilesEndpoint = if($Pos -gt -1){$CloudStorageCredentials.UserName.Replace('.blob.','.file.')}else{$CloudStorageCredentials.UserName}                   
            $AzureFileShareName = $AzureFileShareName.ToLower() # Azure file shares need to be lower case
            $ConfigStoreLocation  = "\\$($AzureFilesEndpoint)\$AzureFileShareName\$($CloudNamespace)\missionserver\config-store"
            $ServerDirectoriesRootLocation   = "\\$($AzureFilesEndpoint)\$AzureFileShareName\$($CloudNamespace)\missionserver\server-dirs" 
        }
        else {
            $ConfigStoreCloudStorageConnectionString = "NAMESPACE=$($CloudNamespace)missionserver$($EndpointSuffix);DefaultEndpointsProtocol=https;"
            $ConfigStoreCloudStorageAccountName = "AccountName=$AccountName"
            $ConfigStoreCloudStorageConnectionSecret = "AccountKey=$($CloudStorageCredentials.GetNetworkCredential().Password)"
        }
    }

    Node $AllNodes.NodeName
    {
        if($Node.Thumbprint){
            LocalConfigurationManager
            {
                CertificateId = $Node.Thumbprint
            }
        }

        $MachineFQDN = Get-FQDN $Node.NodeName
        $IsMultiMachineMissionServer = (($AllNodes | Measure-Object).Count -gt 1)
        $DependsOn = @()

        ArcGIS_xFirewall MissionServer_FirewallRules
        {
            Name                  = "ArcGISMissionServer"
            DisplayName           = "ArcGIS for Mission Server"
            DisplayGroup          = "ArcGIS for Mission Server"
            Ensure                = 'Present'
            Access                = "Allow"
            State                 = "Enabled"
            Profile               = ("Domain","Private","Public")
            LocalPort             = ("20443","20300","20301")
            Protocol              = "TCP"
            DependsOn       	   = $DependsOn
        }
        $DependsOn += '[ArcGIS_xFirewall]MissionServer_FirewallRules'

        ArcGIS_WindowsService ArcGIS_for_MissionServer_Service
        {
            Name            = 'ArcGIS Mission Server'
            Credential      = $ServiceCredential
            StartupType     = 'Automatic'
            State           = 'Running' 
            DependsOn       = $DependsOn
        }
        $DependsOn += '[ArcGIS_WindowsService]ArcGIS_for_MissionServer_Service'

        $DataDirs = @()
        if($null -ne $CloudStorageType){
            if(-not($CloudStorageType -ieq 'AzureFiles')){
                $DataDirs = @($ServerDirectoriesRootLocation)
                if($ServerDirectories -ne $null){
                    foreach($dir in $ServerDirectories){
                        $DataDirs += $dir.path
                    }
                }
            }
        }else{
            $DataDirs = @($ConfigStoreLocation,$ServerDirectoriesRootLocation) 
            if($ServerDirectories -ne $null){
                foreach($dir in $ServerDirectories){
                    $DataDirs += $dir.path
                }
            }
        }

        if($null -ne $ServerLogsLocation){
            $DataDirs += $ServerLogsLocation
        }

        ArcGIS_Service_Account MissionServer_Service_Account
        {
            Name            = 'ArcGIS Mission Server'
            RunAsAccount    = $ServiceCredential
            IsDomainAccount = $ServiceCredentialIsDomainAccount
            Ensure          = 'Present'
            DataDir         = $DataDirs
            DependsOn       = $DependsOn
        }
        $DependsOn += '[ArcGIS_Service_Account]MissionServer_Service_Account'

        if($AzureFilesEndpoint -and $CloudStorageCredentials -and ($CloudStorageType -ieq 'AzureFiles')) 
        {
            $filesStorageAccountName = $AzureFilesEndpoint.Substring(0, $AzureFilesEndpoint.IndexOf('.'))
            $storageAccountKey       = $CloudStorageCredentials.GetNetworkCredential().Password
    
            Script PersistStorageCredentials
            {
                TestScript = { 
                                $result = cmdkey "/list:$using:AzureFilesEndpoint"
                                $result | ForEach-Object{Write-verbose -Message "cmdkey: $_" -Verbose}
                                if($result -like '*none*')
                                {
                                    return $false
                                }
                                return $true
                        }
                SetScript = { 
                            $result = cmdkey "/add:$using:AzureFilesEndpoint" "/user:$using:filesStorageAccountName" "/pass:$using:storageAccountKey" 
                            $result | ForEach-Object{Write-verbose -Message "cmdkey: $_" -Verbose}
                        }
                GetScript            = { return @{} }                  
                DependsOn            = $Depends
                PsDscRunAsCredential = $ServiceCredential # This is critical, cmdkey must run as the service account to persist property
            }
            $DependsOn += '[Script]PersistStorageCredentials'
        } 

        if($Node.NodeName -ine $PrimaryServerMachine)
        {
            WaitForAll "WaitForAllServer$($PrimaryServerMachine)"{
                ResourceName = "[ArcGIS_MissionServer]MissionServer$($PrimaryServerMachine)"
                NodeName = $PrimaryServerMachine
                RetryIntervalSec = 60
                RetryCount = 100
                DependsOn = $Depends
            }
            $DependsOn += "[WaitForAll]WaitForAllServer$($PrimaryServerMachine)"
        }

        ArcGIS_MissionServer "MissionServer$($Node.NodeName)"
        {
            ServerHostName                          = $MachineFQDN
            Ensure                                  = 'Present'
            SiteAdministrator                       = $ServerPrimarySiteAdminCredential
            ConfigurationStoreLocation              = $ConfigStoreLocation
            ServerDirectoriesRootLocation           = $ServerDirectoriesRootLocation
            ServerDirectories                       = if($ServerDirectories -ne $null){ (ConvertTo-JSON $ServerDirectories -Depth 5) }else{ $null }
            LogLevel                                = if($IsDebugMode) { 'DEBUG' } else { 'WARNING' }
            ConfigStoreCloudStorageConnectionString = $ConfigStoreCloudStorageConnectionString
            ConfigStoreCloudStorageAccountName      = $ConfigStoreCloudStorageAccountName
            ConfigStoreCloudStorageConnectionSecret = $ConfigStoreCloudStorageConnectionSecret
            ServerLogsLocation                      = $ServerLogsLocation
            Join                                    = if($Node.NodeName -ine $PrimaryServerMachine) { $true } else { $false }
            PeerServerHostName                      = Get-FQDN $PrimaryServerMachine
            DependsOn                               = $DependsOn
        }
        $DependsOn += "[ArcGIS_MissionServer]MissionServer$($Node.NodeName)"

        if($Node.SSLCertificate){
            ArcGIS_Server_TLS "MissionServer_TLS_$($Node.NodeName)"
            {
                ServerHostName = $MachineFQDN
                Ensure = 'Present'
                SiteName = 'arcgis'
                SiteAdministrator = $ServerPrimarySiteAdminCredential                         
                CName =  $Node.SSLCertificate.CName
                CertificateFileLocation = $Node.SSLCertificate.Path
                CertificatePassword = $Node.SSLCertificate.Password
                EnableSSL = $True
                SslRootOrIntermediate = $SslRootOrIntermediate
                ServerType = "MissionServer"
                DependsOn = $DependsOn
            }
            $DependsOn += "[ArcGIS_Server_TLS]MissionServer_TLS_$($Node.NodeName)"
        }
    }
}