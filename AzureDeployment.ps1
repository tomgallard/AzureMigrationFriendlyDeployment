Param(  
        $timeStampFormat = "g",
        $alwaysDeleteExistingDeployments = $true,
        $enableDeploymentUpgrade = $true,
        $selectedsubscription = "default",
        $subscriptionDataFile = ""
     )

function Initialize-AzureEnvironment($subscriptionName,$publishSettingsFilePath,$storageAccountName) {
    if((Test-Path $publishSettingsFilePath) -eq $false) {
        Write-Error "No file found at $publishSettingsFilePath"
        throw ("No file found at  $publishSettingsFilePath")
    }
    Import-AzurePublishSettingsFile -PublishSettingsFile $publishSettingsFilePath
	TeamCity-Log "Azure Publish settings file imported"
	    Set-AzureSubscription -SubscriptionName $subscriptionName  -CurrentStorageAccount $storageAccountName -ErrorAction Stop
    TeamCity-Log "Updated subscription with storage account"
}
function Publish-AzureProject($serviceName,$slot,$packageLocation,$cloudConfigLocation)
{
    Get-Location | Write-Host 
    if((Test-Path $packageLocation) -eq $false) {
        Write-Error "No file found at  $packageLocation "
        throw ("No file found at  $packageLocation")
    }
    if((Test-Path $cloudConfigLocation) -eq $false) {
        Write-Error "No file found at $cloudConfigLocation "
        throw ("No file found at  $cloudConfigLocation ")
    }
    TeamCity-Log "All file paths found - continuing"
    $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot -ErrorVariable a -ErrorAction silentlycontinue 
    TeamCity-Log "Retrieved Deployment"
    if ($a[0] -ne $null)
    {
        TeamCity-Log "$(Get-Date –f $timeStampFormat) - No deployment is detected. Creating a new deployment. "
    }
    #check for existing deployment and then either upgrade, delete + deploy, or cancel according to $alwaysDeleteExistingDeployments and $enableDeploymentUpgrade boolean variables
    if ($deployment.Name -ne $null)
    {
        TeamCity-Log  "Deployment exists in $servicename. Continuing. - alwaysDeleteExistingDeployments is $alwaysDeleteExistingDeployments"
        if ($alwaysDeleteExistingDeployments)
        {
                TeamCity-Log  "Always delete existing deployments is true"
                if($enableDeploymentUpgrade)
                {

                    TeamCity-Log  "EnableDeploymentUpgrade is true - upgrading "
                    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Deployment exists in $servicename.  Upgrading deployment."
                    UpgradeDeployment $serviceName $slot $packageLocation $cloudConfigLocation
                }
                else  #Delete then create new deployment
                    {
                        TeamCity-Log  "EnableDeploymentUpgrade is false - deleting and replacing "
                        TeamCity-Log "$(Get-Date –f $timeStampFormat) - Deployment exists in $servicename.  Deleting deployment."
                        DeleteDeployment $serviceName $slot
                        CreateNewDeployment $serviceName $slot $packageLocation $cloudConfigLocation
                }

        }
        else {
                TeamCity-Log  "Always delete existing deployments is false"
                TeamCity-Log "$(Get-Date –f $timeStampFormat) - ERROR: Deployment exists in $servicename.  Script execution cancelled."
                exit 1
        }
    } else {
            CreateNewDeployment $serviceName $slot $packageLocation $cloudConfigLocation
    }
}
function Get-BuildLabel() {
	return "Deployment via Teamcity- Build Number $env:build_number VCS Revision : $env:build_vcs_number";
}
function Get-BuildName() {
	return "Teamcity- Automated Deployment";
}
function TeamCity-Log($message,$status = "NORMAL") {
Write-Host "##teamcity[message text='$message' status='$status']"
}
function CreateNewDeployment($serviceName ,$slot, $packageLocation,$cloudConfigLocation)
{
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Creating New Deployment: In progress"
	$buildLabel= Get-BuildLabel
    $opstat = New-AzureDeployment -Slot $slot -Package $packageLocation -Configuration $cloudConfigLocation `
    -label  $buildLabel -ServiceName $serviceName -ErrorAction Stop -name Get-BuildName

    $completeDeployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot -ErrorAction Stop
    $completeDeploymentID = $completeDeployment.deploymentid

    write-progress -id 3 -activity "Creating New Deployment" -completed -Status "Complete"
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Creating New Deployment: Complete, Deployment ID: $completeDeploymentID"

    StartInstances $serviceName $slot
}

function UpgradeDeployment($serviceName ,$slot, $packageLocation,$cloudConfigLocation)
{
    write-progress -id 3 -activity "Upgrading Deployment" -Status "In progress"
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Upgrading Deployment: In progress"
	$buildLabel= Get-BuildLabel
    # perform Update-Deployment
    $setdeployment = Set-AzureDeployment -Upgrade -Slot $slot -Package $packageLocation -Configuration $cloudConfigLocation `
    -label  $buildLabel -ServiceName $serviceName -Force -ErrorAction Stop

    $completeDeployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot -ErrorAction Stop
    $completeDeploymentID = $completeDeployment.deploymentid

    write-progress -id 3 -activity "Upgrading Deployment" -completed -Status "Complete"
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Upgrading Deployment: Complete, Deployment ID: $completeDeploymentID"
}

function DeleteDeployment($serviceName ,$slot)
{

    write-progress -id 2 -activity "Deleting Deployment" -Status "In progress"
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Deleting Deployment: In progress"

    #WARNING - always deletes with force
    $removeDeployment = Remove-AzureDeployment -Slot $slot -ServiceName $serviceName -Force

    write-progress -id 2 -activity "Deleting Deployment: Complete" -completed -Status $removeDeployment
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Deleting Deployment: Complete"

}
function MoveAzureDeploymentAndConfig($ServiceName,$NewConfig,$NewStagingConfig)
{
	TeamCity-Log "Updating config file to production $NewConfig"
	Set-AzureDeployment -Config –ServiceName $ServiceName –Slot "Staging" –Configuration $NewConfig
	TeamCity-Log "Switching to production"
	Move-AzureDeployment -ServiceName $ServiceName
	TeamCity-Log "Switching old production over to staging config $NewStagingConfig"
	Set-AzureDeployment -Config –ServiceName $ServiceName –Slot "Staging" –Configuration $NewStagingConfig
}
$blobPath = "deploy_in_progress/deployment_info"
function CreateDeploymentBlob()
{
	
    CreateContainerIfNotExists "deployment-control"
    $dummyFile = New-Item dummyblob.txt -type file -force
	Set-AzureStorageBlobcontent -Blob "deploy-in-progress/deployment_info" -Container "deployment-control" -File $dummyFile -Force
    Remove-Item $dummyFile
	TeamCity-Log "Created deployment blob"
}
function CreateContainerIfNotExists($containerName) {
    #error if already exists, so just continue
    $containerExists = (Get-AzureStorageContainer | Where-Object -Property "Name" -eq -Value $containerName).Length -eq 1
    if(!$containerExists) {
	    New-AzureStorageContainer "deployment-control" -ErrorAction Continue
    }
}
function DeleteDeploymentBlob()
{
    CreateContainerIfNotExists "deployment-control"
    Remove-AzureStorageBlob -Blob "deploy-in-progress/deployment_info" -Container "deployment-control" 
	TeamCity-Log "Deleted deployment blob"
}
function StartInstances($serviceName ,$slot)
{
    write-progress -id 4 -activity "Starting Instances" -status "In progress"
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Starting Instances: In progress"

    $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot
    $runstatus = $deployment.Status

    if ($runstatus -ne 'Running') 
    {
        $run = Set-AzureDeployment -Slot $slot -ServiceName $serviceName -Status Running
    }
    $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot
    $oldStatusStr = @("") * $deployment.RoleInstanceList.Count

    while (-not(AllInstancesRunning($deployment.RoleInstanceList)))
    {
        $i = 1
        foreach ($roleInstance in $deployment.RoleInstanceList)
        {
            $instanceName = $roleInstance.InstanceName
            $instanceStatus = $roleInstance.InstanceStatus

            if ($oldStatusStr[$i - 1] -ne $roleInstance.InstanceStatus)
            {
                $oldStatusStr[$i - 1] = $roleInstance.InstanceStatus
                Write-Output "$(Get-Date –f $timeStampFormat) - Starting Instance '$instanceName': $instanceStatus"
            }

            write-progress -id (4 + $i) -activity "Starting Instance '$instanceName'" -status "$instanceStatus"
            $i = $i + 1
        }

        sleep -Seconds 1

        $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot
    }

    $i = 1
    foreach ($roleInstance in $deployment.RoleInstanceList)
    {
        $instanceName = $roleInstance.InstanceName
        $instanceStatus = $roleInstance.InstanceStatus

        if ($oldStatusStr[$i - 1] -ne $roleInstance.InstanceStatus)
        {
            $oldStatusStr[$i - 1] = $roleInstance.InstanceStatus
            TeamCity-Log "$(Get-Date –f $timeStampFormat) - Starting Instance '$instanceName': $instanceStatus"
        }

        $i = $i + 1
    }

    $deployment = Get-AzureDeployment -ServiceName $serviceName -Slot $slot
    $opstat = $deployment.Status 

    write-progress -id 4 -activity "Starting Instances" -completed -status $opstat
    TeamCity-Log "$(Get-Date –f $timeStampFormat) - Starting Instances: $opstat"
}

function AllInstancesRunning($roleInstanceList)
{
    foreach ($roleInstance in $roleInstanceList)
    {
        if ($roleInstance.InstanceStatus -ne "ReadyRole")
        {
            return $false
        }
    }

    return $true
}
function ReplicateProductionToStagingDb($server,$prodDb,$stagingDb,$username,$password)
{
    try {
        $stagingDbExists = (Invoke-sqlcmd "SELECT COUNT(*) FROM master.dbo.sysdatabases WHERE name = '$stagingDb'" -serverinstance $server -username $username -password $password)[0] -eq 1
        if($stagingDbExists) {
            Invoke-sqlcmd "DROP DATABASE $stagingDb" -serverinstance $server -username $username -password $password -ErrorAction Stop
        }
        Invoke-sqlcmd "CREATE DATABASE $stagingDb AS COPY OF $prodDb" -serverinstance $server -username $username -password $password  -ErrorAction Stop

    }
    catch {
        Write-Host($error)
        TeamCity-Log "$(Get-Date –f $timeStampFormat) - Error replicating database: $error"
    }
}
function BackupDatabase($server,$prodDb,$backupDb,$username,$password)
{
 try {
        $stagingDbExists = (Invoke-sqlcmd "SELECT COUNT(*) FROM master.dbo.sysdatabases WHERE name = '$backupDb'" -serverinstance $server -username $username -password $password)[0] -eq 1
        if($stagingDbExists) {
            Invoke-sqlcmd "DROP DATABASE $backupDb" -serverinstance $server -username $username -password $password -ErrorAction Stop
        }
        Invoke-sqlcmd "CREATE DATABASE $backupDb AS COPY OF $prodDb" -serverinstance $server -username $username -password $password  -ErrorAction Stop

    }
    catch {
        Write-Host($error)
        TeamCity-Log "$(Get-Date –f $timeStampFormat) - Error replicating database: $error"
    }
}
function EnsureDbReplicationFinished($server,$prodDb,$targetDb,$username,$password)
{	
	try {
	    Invoke-sqlcmd "SELECT * FROM sys.dm_database_copies" -serverinstance $server -username $username -password $password  -ErrorAction Stop
        $newDbId = (Invoke-SqlCmd "SELECT dbid FROM master..sysdatabases where name = '$targetDb'"  -serverinstance $server -username $username -password $password  -ErrorAction Stop)[0]
        $progress = 0
    
        #continue while not null
        while($progress -ne [DBNull]::Value) {
            $progress = (Invoke-SqlCmd "SELECT MIN(percent_complete) FROM sys.dm_database_copies WHERE database_id = $newDbId" `
                        -serverinstance $server -username $username -password $password  -ErrorAction Stop)[0]
            TeamCity-Log "$(Get-Date –f $timeStampFormat) - replicating prod db to staging progress : $progress %"
            Start-Sleep -s 5
        }
	}
	catch {
		Write-Host($error)
        TeamCity-Log "$(Get-Date –f $timeStampFormat) - Error replicating database: $error"
	}
}
#configure powershell with Azure 1.7 modules
Import-Module Azure
Push-Location
Import-Module “sqlps” -DisableNameChecking
Pop-Location