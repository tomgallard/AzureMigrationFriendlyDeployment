Param(  
        $deploymentLabel = "Deployment to My Service",
        $timeStampFormat = "g",
        $alwaysDeleteExistingDeployments = $true,
        $enableDeploymentUpgrade = $true,
        $selectedsubscription = "default",
        $subscriptionDataFile = ""
     )
try
{

Write-Host "##teamcity[message text='Starting Azure Sandbox deployment']"
$ErrorActionPreference = "Stop"
$env:PSModulePath = $env:PSModulePath + ";C:\Program Files (x86)\Microsoft SDKs\Windows Azure\PowerShell\Azure"
Import-Module $PSScriptRoot\AzureDeployment.ps1
TeamCity-Log "Azure Deployment Script Loaded"
Initialize-AzureEnvironment -subscriptionName BizSpark -publishSettingsFilePath "c:\SSHKeys\mypublishsettings.publishsettings" -storageAccountName "yourstorageaccountname"
TeamCity-Log "Azure Environment Initialized"
CreateDeploymentBlob
TeamCity-Log "Replicating prod database to staging"
ReplicateProductionToStagingDb -server "yourazure.database.windows.net" -prodDb "proddbname" -stagingDb "stagindbname" -username "dbuser" -password "dbpassword"
EnsureDbReplicationFinished -server "yourazure.database.windows.net" -prodDb "proddbname" -stagingDb "stagindbname" -username "dbuser" -password "dbpassword"
TeamCity-Log "Publishing to staging"
try {
	Publish-AzureProject  -serviceName "yourservicename" -slot Staging `
	 -packageLocation "WindowsAzure1\bin\Release\app.publish\WindowsAzure1.ccproj.cspkg" -cloudConfigLocation "WindowsAzure1\bin\Release\app.publish\ServiceConfiguration.SandboxCloud-Staging.cscfg"
	TeamCity-Log "Switching to production"
	MoveAzureDeploymentAndConfig -ServiceName "yourservicename" -NewConfig "WindowsAzure1\ServiceConfiguration.SandboxCloud-Production.cscfg" -NewStagingConfig "WindowsAzure1\ServiceConfiguration.SandboxCloud-Staging.cscfg"
 }
 catch {
	Write-Host($error)
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Error publishing azure project : $error"
	exit 1
 }
 finally {
	DeleteDeploymentBlob
 }
 TeamCity-Log "Finished Azure Sandbox Deployment"
}
 catch
 {
    Write-Host "##teamcity[message text='Error executing script' status='ERROR']"
    $error | fl * -f
    exit 1
 }