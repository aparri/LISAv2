##############################################################################################
# AzureController.psm1
# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.
# Operations :
#
<#
.SYNOPSIS
	PS modules for LISAv2 test automation
	This module drives the test on Azure

.PARAMETER
	<Parameters>

.INPUTS


.NOTES
	Creation Date:
	Purpose/Change:

.EXAMPLE


#>
###############################################################################################
using Module ".\TestController.psm1"
using Module "..\TestProviders\AzureProvider.psm1"

Class AzureController : TestController
{
	[string] $ARMImageName
	[string] $StorageAccount

	AzureController() {
		$this.TestProvider = New-Object -TypeName "AzureProvider"
		$this.TestPlatform = "Azure"
	}

	[void] ParseAndValidateParameters([Hashtable]$ParamTable) {
		$this.ARMImageName = $ParamTable["ARMImageName"]

		if ($ParamTable["StorageAccount"] -imatch "^NewStorage_") {
			Throw "LISAv2 only supports specified storage account by '-StorageAccount' or candidate parameters values as below. `n
			Please use '-StorageAccount ""Auto_Complete_RG=XXXResourceGroupName""' or `n
			'-StorageAccount ""Existing_Storage_Standard""' or `n
			'-StorageAccount ""Existing_Storage_Premium""'"
		}
		else {
			$this.StorageAccount = $ParamTable["StorageAccount"]
		}

		$parameterErrors = ([TestController]$this).ParseAndValidateParameters($ParamTable)

		$this.TestProvider.TipSessionId = $this.CustomParams["TipSessionId"]
		$this.TestProvider.TipCluster = $this.CustomParams["TipCluster"]
		$this.TestProvider.PlatformFaultDomainCount = $this.CustomParams["PlatformFaultDomainCount"]
		$this.TestProvider.PlatformUpdateDomainCount = $this.CustomParams["PlatformUpdateDomainCount"]
		$this.TestProvider.EnableTelemetry = $ParamTable["EnableTelemetry"]
		if ($this.CustomParams["EnableNSG"] -and $this.CustomParams["EnableNSG"] -eq "true") {
			$this.TestProvider.EnableNSG = $true
		}
		if ( !$this.ARMImageName -and !$this.OsVHD ) {
			$parameterErrors += "-ARMImageName '<Publisher> <Offer> <Sku> <Version>', or -OsVHD <'VHD_Name.vhd'> is required."
		}
		if (!$this.OsVHD) {
			if (($this.ARMImageName.Trim().Split(" ").Count -ne 4) -and ($this.ARMImageName -ne "")) {
				$parameterErrors += ("Invalid value for the provided ARMImageName parameter: <'$($this.ARMImageName)'>." + `
									 "The ARM image should be in the format: '<Publisher> <Offer> <Sku> <Version>'.")
			}
		}
		if (!$this.ARMImageName) {
			if ($this.OsVHD -and [System.IO.Path]::GetExtension($this.OsVHD) -ne ".vhd" -and !$this.OsVHD.Contains("vhd")) {
				$parameterErrors += "-OsVHD $($this.OsVHD) does not have .vhd extension required by Platform Azure."
			}
		}
		if (!$this.TestLocation) {
			$parameterErrors += "-TestLocation <AzureRegion> is required."
		}
		if ($parameterErrors.Count -gt 0) {
			$parameterErrors | ForEach-Object { Write-LogErr $_ }
			throw "Failed to validate the test parameters provided. Please fix above issues and retry."
		} else {
			Write-LogInfo "Test parameters for Azure have been validated successfully. Continue running the test."
		}
	}

	[void] PrepareTestEnvironment($XMLSecretFile) {
		if ($XMLSecretFile -and (Test-Path $XMLSecretFile)) {
			# Connect AzureAccount and Set Azure Context
			Add-AzureAccountFromSecretsFile -CustomSecretsFilePath $XMLSecretFile
			# Place prepare storage accounts before invoke Base.PrepareTestEnvironment($XMLSecretFile)
			if ($this.StorageAccount -imatch "^Auto_Complete_RG=.+") {
				$storageAccountRG = $this.StorageAccount.Trim('= ').Split('=').Trim()[1]
				# Prepare storage accounts (create new storage accounts if needed), and update AzureSecretFile with new set of StorageAccounts
				# and update content of .XML\RegionAndStorageAccounts.xml
				PrepareAutoCompleteStorageAccounts -storageAccountsRGName $storageAccountRG -XMLSecretFile $XMLSecretFile
			}
		}
		# Invoke Base.PrepareTestEnvironment($XMLSecretFile)
		([TestController]$this).PrepareTestEnvironment($XMLSecretFile)
		$RegionAndStorageMapFile = Resolve-Path ".\XML\RegionAndStorageAccounts.xml"
		if (Test-Path $RegionAndStorageMapFile) {
			$RegionAndStorageMap = [xml](Get-Content $RegionAndStorageMapFile)
		} else {
			throw "File $RegionAndStorageMapFile does not exist"
		}
		$azureConfig = $this.GlobalConfig.Global.Azure
		# $this.XMLSecrets will be assigned after Base.PrepareTestEnvironment($XMLSecretFile)
		if ($this.XMLSecrets) {
			$secrets = $this.XMLSecrets.secrets
			$azureConfig.Subscription.SubscriptionID = $secrets.SubscriptionID
			$azureConfig.TestCredentials.LinuxUsername = $secrets.linuxTestUsername
			$azureConfig.TestCredentials.LinuxPassword = if ($secrets.linuxTestPassword) { $secrets.linuxTestPassword } else { "" }
			$azureConfig.TestCredentials.sshPrivateKey = Get-SSHKey -XMLSecretFile $XMLSecretFile
			$azureConfig.ResultsDatabase.server = if ($secrets.DatabaseServer) { $secrets.DatabaseServer } else { "" }
			$azureConfig.ResultsDatabase.user = if ($secrets.DatabaseUser) { $secrets.DatabaseUser } else { "" }
			$azureConfig.ResultsDatabase.password = if ($secrets.DatabasePassword) { $secrets.DatabasePassword } else { "" }
			$azureConfig.ResultsDatabase.dbname = if ($secrets.DatabaseName) { $secrets.DatabaseName } else { "" }
		}
		$this.VmUsername = $azureConfig.TestCredentials.LinuxUsername
		$this.VmPassword = $azureConfig.TestCredentials.LinuxPassword
		$this.SSHPrivateKey = $azureConfig.TestCredentials.sshPrivateKey

		if (!$this.sshPrivateKey -and !$this.VmPassword) {
			Write-LogErr "Please set sshPrivateKey or linuxTestPassword."
		}
		if ($this.sshPrivateKey -and $this.VmPassword) {
			Write-LogDbg "Use private key, reset password into empty."
			$this.VmPassword = ""
		}
		# global variables: StorageAccount, TestLocation
		if ( $this.StorageAccount -imatch "^ExistingStorage_Standard" ) {
			$azureConfig.Subscription.ARMStorageAccount = $RegionAndStorageMap.AllRegions.$($this.TestLocation).StandardStorage
			Write-LogInfo "Selecting existing standard storage account in $($this.TestLocation) - $($azureConfig.Subscription.ARMStorageAccount)"
		}
		elseif ( $this.StorageAccount -imatch "^ExistingStorage_Premium" ) {
			$azureConfig.Subscription.ARMStorageAccount = $RegionAndStorageMap.AllRegions.$($this.TestLocation).PremiumStorage
			Write-LogInfo "Selecting existing premium storage account in $($this.TestLocation) - $($azureConfig.Subscription.ARMStorageAccount)"
		}
		elseif ($this.StorageAccount -and ($this.StorageAccount -inotmatch "^Auto_Complete_RG=.+")) {
			 # $this.StorageAccount should be some exact name of Storage Account
			$sc = Get-AzStorageAccount | Where-Object {$_.StorageAccountName -eq $this.StorageAccount}
			if (!$sc) {
				Throw "Provided storage account $($this.StorageAccount) does not exist, abort testing."
			}
			if($sc.Location -ne $this.TestLocation) {
				Throw "Provided storage account $($this.StorageAccount) location $($sc.Location) is different from test location $($this.TestLocation), abort testing."
			}
			$azureConfig.Subscription.ARMStorageAccount = $this.StorageAccount.Trim()
			Write-LogInfo "Selecting custom storage account : $($azureConfig.Subscription.ARMStorageAccount) as per your test region."
		}
		else { # else means $this.StorageAccount is empty, or $this.StorageAccount is like 'Auto_Complete_RG=Xxx'
			$azureConfig.Subscription.ARMStorageAccount = $RegionAndStorageMap.AllRegions.$($this.TestLocation).StandardStorage
			Write-LogInfo "Auto selecting storage account : $($azureConfig.Subscription.ARMStorageAccount) as per your test region."
		}

		if ($this.ResultDBTable) {
			$azureConfig.ResultsDatabase.dbtable = ($this.ResultDBTable).Trim()
			Write-LogInfo "ResultDBTable : $($this.ResultDBTable) added to GlobalConfig.Global.HyperV.ResultsDatabase.dbtable"
		}
		if ($this.ResultDBTestTag) {
			$azureConfig.ResultsDatabase.testTag = ($this.ResultDBTestTag).Trim()
			Write-LogInfo "ResultDBTestTag: $($this.ResultDBTestTag) added to GlobalConfig.Global.HyperV.ResultsDatabase.testTag"
		}

		Write-LogInfo "------------------------------------------------------------------"

		$SelectedSubscription = Set-AzContext -SubscriptionId $azureConfig.Subscription.SubscriptionID
		$subIDSplitted = ($SelectedSubscription.Subscription.SubscriptionId).Split("-")
		Write-LogInfo "SubscriptionName       : $($SelectedSubscription.Subscription.Name)"
		Write-LogInfo "SubscriptionId         : $($subIDSplitted[0])-xxxx-xxxx-xxxx-$($subIDSplitted[4])"
		Write-LogInfo "User                   : $($SelectedSubscription.Account.Id)"
		Write-LogInfo "ServiceEndpoint        : $($SelectedSubscription.Environment.ActiveDirectoryServiceEndpointResourceId)"
		Write-LogInfo "CurrentStorageAccount  : $($azureConfig.Subscription.ARMStorageAccount)"

		Write-LogInfo "------------------------------------------------------------------"

		Write-LogInfo "Setting global variables"
		$this.SetGlobalVariables()
	}

	[void] SetGlobalVariables() {
		([TestController]$this).SetGlobalVariables()

		# Used in CAPTURE-VHD-BEFORE-TEST.ps1 and some cases
		Set-Variable -Name ARMImageName -Value $this.ARMImageName -Scope Global -Force
	}

	[void] PrepareTestImage() {
		#If Base OS VHD is present in another storage account, then copy to test storage account first.
		if ($this.OsVHD) {
			$ARMStorageAccount = $this.GlobalConfig.Global.Azure.Subscription.ARMStorageAccount
			if ($ARMStorageAccount -imatch "^NewStorage_") {
				Throw "LISAv2 only supports copying VHDs to existing storage account.`n
				Please use <ARMStorageAccount>Auto_Complete_RG=XXXResourceGroupName<ARMStorageAccount> or `n
				<ARMStorageAccount>Existing_Storage_Standard<ARMStorageAccount> `n
				<ARMStorageAccount>Existing_Storage_Premium<ARMStorageAccount>"
			}
			$useSASURL = $false
			if (($this.OsVHD -imatch 'sp=') -and ($this.OsVHD -imatch 'sig=')) {
				$useSASURL = $true
			}

			if (!$useSASURL -and ($this.OsVHD -inotmatch "/")) {
				$this.OsVHD = 'http://{0}.blob.core.windows.net/vhds/{1}' -f $ARMStorageAccount, $this.OsVHD
			}

			#Check if the test storage account is same as VHD's original storage account.
			$givenVHDStorageAccount = $this.OsVHD.Replace("https://","").Replace("http://","").Split(".")[0]
			$sourceContainer =  $this.OsVHD.Split("/")[$this.OsVHD.Split("/").Count - 2]
			$vhdName = $this.OsVHD.Split("?")[0].split('/')[-1]

			if ($givenVHDStorageAccount -ne $ARMStorageAccount) {
				Write-LogInfo "Your test VHD is not in target storage account ($ARMStorageAccount)."
				Write-LogInfo "Your VHD will be copied to $ARMStorageAccount now."

				#Copy the VHD to current storage account.
				#Check if the OsVHD is a SasUrl
				if ($useSASURL) {
					$copyStatus = Copy-VHDToAnotherStorageAccount -SasUrl $this.OsVHD -destinationStorageAccount $ARMStorageAccount -destinationStorageContainer "vhds" -vhdName $vhdName
					$this.OsVHD = 'http://{0}.blob.core.windows.net/vhds/{1}' -f $ARMStorageAccount, $vhdName
				} else {
					$copyStatus = Copy-VHDToAnotherStorageAccount -sourceStorageAccount $givenVHDStorageAccount -sourceStorageContainer $sourceContainer -destinationStorageAccount $ARMStorageAccount -destinationStorageContainer "vhds" -vhdName $vhdName
				}
				if (!$copyStatus) {
					Throw "Failed to copy the VHD to $ARMStorageAccount"
				}
			} else {
				$sc = Get-AzStorageAccount | Where-Object {$_.StorageAccountName -eq $ARMStorageAccount}
				$storageKey = (Get-AzStorageAccountKey -ResourceGroupName $sc.ResourceGroupName -Name $ARMStorageAccount)[0].Value
				$context = New-AzStorageContext -StorageAccountName $ARMStorageAccount -StorageAccountKey $storageKey
				$blob = Get-AzStorageBlob -Blob $vhdName -Container $sourceContainer -Context $context -ErrorAction Ignore
				if (!$blob) {
					Throw "Provided VHD not existed, abort testing."
				}
			}
			Set-Variable -Name BaseOsVHD -Value $this.OsVHD -Scope Global
			Write-LogInfo "New Base VHD name - $($this.OsVHD)"
		}
	}
}
