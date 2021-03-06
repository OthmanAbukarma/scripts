 $HPOV = Read-host "Enter the OneView Server name /IP"
 $HPOVUsr = Read-Host "Enter your OneView User name"
 Write-host "Enter OneView password at the prompt" -ForegroundColor Yellow
 Connect-HPOVMgmt -Hostname $HPOV -UserName $HPOVUsr
 $VC = Read-Host "Enter vCenter name/ip to connect to" 
 Connect-viserver $VC
  
 Get-HPOVStoragePool
 Write-host "For the next two questions refer to the data on screen" -ForegroundColor Yellow
 $Pool = Read-host "Enter the name of the Storage Pool to use for the new volume" 
 $System = Read-Host "Enter the name of the Storage System that Pool is on" 
 $cap = Read-host "Enter the size of the volume in GB" 
 $name = Read-Host "Enter the name of the new volume" 
 $ID = Read-Host "Enter the Lun ID for the new volume" 
 $cluster = Read-Host "Enter VMware cluster to add datastore"
  
 $policy = Get-HPOVStorageSystem -Name $system | Show-HPOVStorageSystemPerformancePolicy -Name "VMware ESX 5"
 $SP = Get-HPOVStoragePool -Name $Pool -StorageSystem $System
 #create volume
 Write-Host " Creating new volume named $name with $cap gb of storage" -ForegroundColor Cyan
 New-HPOVStorageVolume -Name $name -StoragePool $SP -Capacity $cap -ProvisioningType Thin -PerformancePolicy $policy -Shared | Wait-HPOVTaskComplete
 

$vol =  Get-HPOVStorageVolume -Name $name

Write-host " Connecting the new volume $name to the HPC Server profiles" -ForegroundColor Cyan
$blades1 = Get-HPOVServerProfile -Name *HPC*
$blades2 = Get-HPOVServerProfile -Name *Tenant*
Foreach ($svr in $blades1) {
    New-HPOVServerProfileAttachVolume -ServerProfile $svr -Volume $vol -LunID $ID -LunIdType Manual | Wait-HPOVTaskComplete
    }

Foreach ($svr in $blades2) {
    New-HPOVServerProfileAttachVolume -ServerProfile $svr -Volume $vol -LunID $ID -LunIdType Manual | Wait-HPOVTaskComplete
    }
#scan all the host in the cluster to new storage volume

Sleep 20
Write-host " connecting to $cluster and scanning for new storage" -ForegroundColor Yellow
Get-Cluster $cluster | Get-VMHost | Get-VMHostStorage -RescanAllHba -RescanVmfs

#function to find free LUNs found at http://vcloud-lab.com/entries/powercli/find-free-or-unassigned-storage-lun-disks-on-vmware-esxi-server
# removed some of the notes to save space
function Get-FreeEsxiLUNs {   
    #EXAMPLE
    #Get-FreeEsxiLUNs -Esxihost Esxi001.vcloud-lab.com
    #Shows free unassigned storage Luns disks on Esxi host name Esxi001.vcloud-lab.com
    ###############################

    [CmdletBinding()]
    param(
        [Parameter(Position=0, Mandatory=$true)]
        [System.String]$Esxihost
    )    
    Begin {
        if (-not(Get-Module vmware.vimautomation.core)) {
            Import-Module vmware.vimautomation.core
        }
        #Connect-VIServer | Out-Null
    }
    Process {
        $VMhost = Get-VMhost $EsxiHost
        $AllLUNs = $VMhost | Get-ScsiLun -LunType disk
        $Datastores = $VMhost | Get-Datastore
        foreach ($lun in $AllLUNs) {
            $Datastore = $Datastores | Where-Object {$_.extensiondata.info.vmfs.extent.Diskname -Match $lun.CanonicalName}
            if ($Datastore.Name -eq $null) {
                $lun | Select-Object CanonicalName, CapacityGB, Vendor        
            } 
        }
    }
    End {}
}

$free = Get-FreeEsxiLUNs -Esxihost (Get-cluster $cluster |get-vmhost | Get-random) | Where-Object {$_.Vendor -eq "Nimble"} |select CanonicalName
$path = $free -replace "@{CanonicalName=","" -replace "}",""


#create new Datastore
Write-host " Creating new Datastore named $name in cluster $cluster" -ForegroundColor Cyan
Get-VMHost | Get-Random | New-Datastore -name $name -Path $path -Vmfs -FileSystemVersion 6

#rescan vhost for new Datastore
Get-VMHost  | Get-VMHostStorage -RescanAllHba -Refresh

#Create Datastore Tag and Storage policy for vCloud Director
Write-Host "Creating Datastore Tag and Storage Policy for vCloud Director" -ForegroundColor Yellow
$tag = New-Tag -Name $name -Category Datastore 
$rule = New-SpbmRule -AnyOfTags $tag
$ruleset = New-SpbmRuleSet -AllOfRules $rule
$policy = New-SpbmStoragePolicy -Name $name -AnyOfRuleSets $ruleset
Get-Datastore -Server $VC -Name $name | New-TagAssignment -Tag $tag




Write-Host "Volume $name has been created and attached to vmware cluster $cluster" -ForegroundColor Green
Write-host "Disconnecting from OneView and vCenter" -ForegroundColor Green
Disconnect-HPOVMgmt
Disconnect-VIServer -Server * -Confirm:$false
