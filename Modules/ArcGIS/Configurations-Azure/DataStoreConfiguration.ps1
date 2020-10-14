﻿Configuration DataStoreConfiguration
{
	param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [System.Management.Automation.PSCredential]
        $ServiceCredential

        ,[Parameter(Mandatory=$false)]
        [System.String]
        $ServiceCredentialIsDomainAccount = 'false'

        ,[Parameter(Mandatory=$true)]
        [ValidateNotNullorEmpty()]
        [System.Management.Automation.PSCredential]
        $SiteAdministratorCredential

        ,[Parameter(Mandatory=$false)]
        [System.String]
        $UseCloudStorage 

        ,[Parameter(Mandatory=$false)]
        [System.String]
        $UseAzureFiles 

        ,[Parameter(Mandatory=$false)]
        [System.Management.Automation.PSCredential]
        $StorageAccountCredential
        
        ,[Parameter(Mandatory=$true)]
        [System.String]
        $DataStoreMachineNames

        ,[Parameter(Mandatory=$true)]
        [System.String]
        $ServerMachineNames

        ,[Parameter(Mandatory=$true)]
        [System.String]
        $FileShareMachineName

        ,[Parameter(Mandatory=$false)]
        [System.String]
        $DataStoreTypes = 'Relational'

        ,[Parameter(Mandatory=$false)]
        [System.Boolean]
        $IsTileCacheDataStoreClustered = $False

        ,[Parameter(Mandatory=$true)]
        [System.String]
        $ExternalDNSHostName    

        ,[Parameter(Mandatory=$false)]
        [System.Int32]
        $OSDiskSize = 0

        ,[Parameter(Mandatory=$false)]
        [System.String]
        $EnableDataDisk  

         ,[Parameter(Mandatory=$false)]
        [System.String]
        $FileShareName = 'fileshare' 
        
        ,[Parameter(Mandatory=$false)]
        [System.String]
        $DebugMode
    )
        
    Import-DscResource -ModuleName PSDesiredStateConfiguration 
    Import-DSCResource -ModuleName ArcGIS
	Import-DscResource -Name ArcGIS_DataStore
    Import-DscResource -Name ArcGIS_Service_Account
    Import-DscResource -name ArcGIS_WindowsService
    Import-DscResource -Name ArcGIS_xFirewall
    Import-DscResource -Name ArcGIS_xDisk
    Import-DscResource -Name ArcGIS_Disk
    
    $DataStoreHostNames = ($DataStoreMachineNames -split ',')
    $DataStoreHostName = $DataStoreHostNames | Select-Object -First 1
    $ServerHostNames = ($ServerMachineNames -split ',')
    $ServerMachineName = $ServerHostNames | Select-Object -First 1
    $FolderName = $ExternalDNSHostName.Substring(0, $ExternalDNSHostName.IndexOf('.')).ToLower()
    $DataStoreBackupLocation = "\\$($FileShareMachineName)\$FileShareName\$FolderName\datastore\dbbackups"            
    $IsStandBy = ($env:ComputerName -ine $DataStoreHostName)
    $PeerMachineName = $null
    if($DataStoreHostNames.Length -gt 1) {
      $PeerMachineName = $DataStoreHostNames | Select-Object -Last 1
    }
    $IsDebugMode = $DebugMode -ieq 'true'
    $IsServiceCredentialDomainAccount = $ServiceCredentialIsDomainAccount -ieq 'true'
    $IsDataStoreWithStandby = ($DataStoreHostName -ine $PeerMachineName) -and ($PeerMachineName)
    $DataStoreContentDirectory = "$($env:SystemDrive)\\arcgis\\datastore\\content"

    if(($UseCloudStorage -ieq 'True') -and $StorageAccountCredential) 
    {
        if($UseAzureFiles -ieq 'True') {
            $AzureFilesEndpoint = $StorageAccountCredential.UserName.Replace('.blob.','.file.')                        
            $FileShareName = $FileShareName.ToLower() # Azure file shares need to be lower case   
            $FolderName = $ExternalDNSHostName.Substring(0, $ExternalDNSHostName.IndexOf('.'))
            $DataStoreBackupLocation = "\\$($AzureFilesEndpoint)\$FileShareName\$FolderName\datastore\dbbackups" 
        }
    }

	Node localhost
	{
        $DataStoreDependsOn = @()
        LocalConfigurationManager
        {
			ActionAfterReboot = 'ContinueConfiguration'            
            ConfigurationMode = 'ApplyOnly'    
            RebootNodeIfNeeded = $true
        }
        
        if($OSDiskSize -gt 0) 
        {
            ArcGIS_Disk OSDiskSize
            {
                DriveLetter = ($env:SystemDrive -replace ":" )
                SizeInGB    = $OSDiskSize
            }
        }
        
        if($EnableDataDisk -ieq 'true')
        {
            ArcGIS_xDisk DataDisk
            {
                DiskNumber  =  2
                DriveLetter = 'F'
            }
        }

        $HasValidServiceCredential = ($ServiceCredential -and ($ServiceCredential.GetNetworkCredential().Password -ine 'Placeholder'))
        if($HasValidServiceCredential) 
        {
            if(-Not($IsServiceCredentialDomainAccount)){
                User ArcGIS_RunAsAccount
                {
                    UserName       = $ServiceCredential.UserName
                    Password       = $ServiceCredential
                    FullName       = 'ArcGIS Service Account'
                    Ensure         = 'Present'
                    PasswordChangeRequired = $false
                    PasswordNeverExpires = $true
                }
                $DataStoreDependsOn += @('[User]ArcGIS_RunAsAccount')
            }

            ArcGIS_WindowsService ArcGIS_DataStore_Service
            {
                Name            = 'ArcGIS Data Store'
                Credential      = $ServiceCredential
                StartupType     = 'Automatic'
                State           = 'Running' 
                DependsOn       = $DataStoreDependsOn
            }
            $DataStoreDependsOn += @('[ArcGIS_WindowsService]ArcGIS_DataStore_Service')
                
            ArcGIS_Service_Account DataStore_Service_Account
		    {
			    Name            = 'ArcGIS Data Store'
			    RunAsAccount    = $ServiceCredential
			    Ensure          = 'Present'
			    DependsOn       = $DataStoreDependsOn
                DataDir         = $DataStoreContentDirectory  
                IsDomainAccount = $IsServiceCredentialDomainAccount
            }
            $DataStoreDependsOn += @('[ArcGIS_Service_Account]DataStore_Service_Account')

            ArcGIS_xFirewall DataStore_FirewallRules
		    {
                Name                  = "ArcGISDataStore" 
                DisplayName           = "ArcGIS Data Store" 
                DisplayGroup          = "ArcGIS Data Store" 
                Ensure                = 'Present' 
                Access                = "Allow" 
                State                 = "Enabled" 
                Profile               = ("Domain","Private","Public")
                LocalPort             = ("2443", "9876")                        
                Protocol              = "TCP" 
            } 
            $DataStoreDependsOn += @('[ArcGIS_xFirewall]DataStore_FirewallRules')

            if($IsDataStoreWithStandby) 
            {
                ArcGIS_xFirewall DataStore_FirewallRules_OutBound
			    {
				    Name                  = "ArcGISDataStore-Out" 
				    DisplayName           = "ArcGIS Data Store Out" 
				    DisplayGroup          = "ArcGIS Data Store" 
				    Ensure                = 'Present'
				    Access                = "Allow" 
				    State                 = "Enabled" 
				    Profile               = ("Domain","Private","Public")
				    LocalPort             = ("9876")       
				    Direction             = "Outbound"                        
				    Protocol              = "TCP" 
                }   
                $DataStoreDependsOn += @('[ArcGIS_xFirewall]DataStore_FirewallRules_OutBound')
            }       
            
            if($DataStoreTypes.split(",") -iContains "TileCache"){
                ArcGIS_xFirewall TileCache_DataStore_FirewallRules
                {
                    Name                  = "ArcGISTileCacheDataStore" 
                    DisplayName           = "ArcGIS Tile Cache Data Store" 
                    DisplayGroup          = "ArcGIS Tile Cache Data Store" 
                    Ensure                = 'Present' 
                    Access                = "Allow" 
                    State                 = "Enabled" 
                    Profile               = ("Domain","Private","Public")
                    LocalPort             = ("29079-29082")
                    Protocol              = "TCP" 
                }
                $DataStoreDependsOn += @('[ArcGIS_xFirewall]TileCache_DataStore_FirewallRules')

                ArcGIS_xFirewall TileCache_FirewallRules_OutBound
                {
                    Name                  = "ArcGISTileCacheDataStore-Out" 
                    DisplayName           = "ArcGIS TileCache Data Store Out" 
                    DisplayGroup          = "ArcGIS TileCache Data Store" 
                    Ensure                = 'Present'
                    Access                = "Allow" 
                    State                 = "Enabled" 
                    Profile               = ("Domain","Private","Public")
                    LocalPort             = ("29079-29082")
                    Direction             = "Outbound"                        
                    Protocol              = "TCP" 
                } 
                $DataStoreDependsOn += @('[ArcGIS_xFirewall]TileCache_FirewallRules_OutBound')

                if($IsDataStoreWithStandby) {
                    ArcGIS_xFirewall MultiMachine_TileCache_DataStore_FirewallRules
                    {
                        Name                  = "ArcGISMultiMachineTileCacheDataStore" 
                        DisplayName           = "ArcGIS Multi Machine Tile Cache Data Store" 
                        DisplayGroup          = "ArcGIS TileCache Data Store" 
                        Ensure                = 'Present' 
                        Access                = "Allow" 
                        State                 = "Enabled" 
                        Profile               = ("Domain","Private","Public")
                        LocalPort             = ("4369","29083-29090")
                        Protocol              = "TCP" 
                    }
                    $DataStoreDependsOn += @('[ArcGIS_xFirewall]MultiMachine_TileCache_DataStore_FirewallRules')

                    ArcGIS_xFirewall MultiMachine_TileCache_FirewallRules_OutBound
                    {
                        Name                  = "ArcGISMultiMachineTileCacheDataStore-Out" 
                        DisplayName           = "ArcGIS Multi Machine TileCache Data Store Out" 
                        DisplayGroup          = "ArcGIS TileCache Data Store" 
                        Ensure                = 'Present'
                        Access                = "Allow" 
                        State                 = "Enabled" 
                        Profile               = ("Domain","Private","Public")
                        LocalPort             = ("4369","29083-29090")
                        Direction             = "Outbound"                        
                        Protocol              = "TCP" 
                    } 
                    $DataStoreDependsOn += @('[ArcGIS_xFirewall]MultiMachine_TileCache_FirewallRules_OutBound')
                }
            }

            ArcGIS_DataStore DataStore
		    {
			    Ensure                     = 'Present'
			    SiteAdministrator          = $SiteAdministratorCredential
			    ServerHostName             = $ServerMachineName
			    ContentDirectory           = $DataStoreContentDirectory
			    IsStandby                  = $IsStandBy
                #DatabaseBackupsDirectory   = $DataStoreBackupLocation
                #FileShareRoot              = "\\$($FileShareMachineName)\$($FileShareName)"
                RunAsAccount               = $ServiceCredential 
                DataStoreTypes             = $DataStoreTypes.split(",")
                IsEnvAzure                 = $true
                IsTileCacheDataStoreClustered = $IsTileCacheDataStoreClustered
			    DependsOn                  = $DataStoreDependsOn
		    } 

		    foreach($ServiceToStop in @('ArcGIS Server', 'Portal for ArcGIS', 'ArcGISGeoEvent', 'ArcGISGeoEventGateway', 'ArcGIS Notebook Server'))
		    {
			    if(Get-Service $ServiceToStop -ErrorAction Ignore) 
			    {
				    ArcGIS_WindowsService "$($ServiceToStop.Replace(' ','_'))_Service"
				    {
					    Name			= $ServiceToStop
					    Credential		= $ServiceCredential
					    StartupType		= 'Manual'
					    State			= 'Stopped'
					    DependsOn		= if(-Not($IsServiceCredentialDomainAccount)){ @('[User]ArcGIS_RunAsAccount')}else{ @()}
				    }
			    }
		    }
        }
	}
}