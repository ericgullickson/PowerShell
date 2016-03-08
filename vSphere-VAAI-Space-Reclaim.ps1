##########################################################################################################
#VMware PowerCLI must be installed on the machine this is running on. 
##########################################################################################################
#
#Written by Eric Gullickson - Capital Data
#egullickson@capital-data.com 
#
#v1.0 - Just wrote it for Dell Compellent
#v1.1 - Changed logic to support Dell Compellent, Dell EqualLogic, EMC VMAX, EMC VNX, HDS, NetApp, Pure. 
#v1.2 - Added XtremIO
#
#Requirements:
# VMware PowerCLI
# vSphere 5.5+
#
##########################################################################################################
#Enter the following parameters. Put all entries inside the quotes.
##########################################################################################################

$strVCenter = 'server.domain.tld'
$strVCUser = 'user@vsphere.local'
$strVCPass = 'somethingstrong'
$strLogFolder = 'C:\scripts\logs\'
$strLogFile = '-space-reclaim.txt'

#End of parameters
#
##########################################################################################################
#       DISCLAIMER
##########################################################################################################
# Use at your own risk. I am not liable for damages caused by this script.
##########################################################################################################
#
#Create log file and folder if non-existent
If (!(Test-Path -Path $strLogFolder)) { New-Item -ItemType Directory -Path $strLogFolder }
$strLogFile = $strLogFolder + (Get-Date -Format yyyy-MM-dd-%H-mm-ss) + $strLogFile

Add-Content $strLogFile 'Capital Data VMware VMFS Space Reclaim Script'
Add-Content $strLogFile '##########################################################################################################'
Add-Content $strLogFile ((Get-Date -Format o ) + ': Script Started')

#Important PowerCLI if not done and connect to vCenter.
Add-PsSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue
Add-PSSNapin -Name VMware.DeployAutomation -ErrorAction SilentlyContinue
Add-PSSnapin -Name VMware.ImageBuilder -ErrorAction SilentlyContinue

#Get rid of the errors that pop up because no one uses third part signed certificates. And work around slow connections.
Set-PowerCLIConfiguration -Scope Session -invalidcertificateaction 'ignore' -confirm:$false |out-null
Set-PowerCLIConfiguration -Scope Session -WebOperationTimeoutSeconds -1 -confirm:$false |out-null

#Connect to the vCenter to start doing some real work. 
Connect-VIServer -Server $strVCenter -username $strVCUser -password $strVCPass|out-null

#Add log content. 
Add-Content $strLogFile ((Get-Date -Format o ) + ': Connected to vCenter ' + $strVCenter)
Add-Content $strLogFile '##########################################################################################################'

#Gather VMFS Datastores and identify how many are VAAI capable. 
$objDatastores = Get-Datastore
Add-Content $strLogFile 'Found the following datastores:'
Add-Content $strLogFile $objDatastores
Add-Content $strLogFile '##########################################################################################################'

#Starting reclaim process on datastores
$intVolCount=0
$strArrayVendor = $null

#Loop through all the Datastores we found in vCenter. 
foreach ($objDatastore in $objDatastores)
{
    #Randomly select a ESXi host to do the work. 
    $objESX = $objDatastore | Get-VMhost | where-object {($_.version -like '5.5.*') -or ($_.version -like '6.0.*')} |Select-Object -last 1
    #If the datastore is NFS or VVOL's skip it and log it. 
    if ($objDatastore.Type -ne 'VMFS')
    {
        Add-Content $strLogFile ((Get-Date -Format o ) + ': This volume is not a VMFS volume it is a ' + $objDatastore.Type + ' and cannot be reclaimed. Skipping...')
        Add-Content $strLogFile $objDatastore
        Add-Content $strLogFile '##########################################################################################################'
    }
    else
    {
        $objLUN = $objDatastore.ExtensionData.Info.Vmfs.Extent.DiskName | select-object -last 1
        $objESXcli=Get-Esxcli -VMHost $objESX
        Add-Content $strLogFile ((Get-Date -Format o ) + ': The datastore named ' + $objDatastore + ' is being evaluated.')
        Add-Content $strLogFile ((Get-Date -Format o ) + ': The ESXi Host named ' + $objESX + ' will run the space reclaim operation')
        Add-Content $strLogFile ''

        #Base on the first 8 digits of the device ID we can tell what type of disk it is. This is an incomplete list of supported vendors. 
        switch -wildcard ($objLUN) 
            { 
                "naa.6000d310*" { $strArrayVendor = "Dell Compellent"; break} 
                "naa.514f0c56*" { $strArrayVendor = "EMC XtremIO"; break}
                "naa.60060160*" { $strArrayVendor = "EMC VNX"; break} 
                "naa.60060e80*" { $strArrayVendor = "Hitachi Data Systems"; break} 
                "naa.60060480*" { $strArrayVendor = "EMC VMAX"; break} 
                "naa.60a98000*" { $strArrayVendor = "NetApp"; break} 
                "naa.6090a038*" { $strArrayVendor = "Dell EqualLogic"; break} 
                "naa.624a9370*" { $strArrayVendor = "Pure Storage"; break}
                default {
                            Add-Content $strLogFile ((Get-Date -Format o ) + ': This datastore is NOT a VAAI compatible LUN. Skipping....')
                            Add-Content $strLogFile $objLUN
                            Add-Content $strLogFile '##########################################################################################################'
                }
            }

        #If the device ID matches a vendor in the switch statement. Then we log it and process the lun. 
        if ($strArrayVendor)
        {
            Add-Content $strLogFile ((Get-Date -Format o ) + ': This datastore is a ' + $strArrayVendor + ' backed Datastore.')
            Add-Content $strLogFile $objLUN
            Add-Content $strLogFile ''
            #Calculating optimal block count. If VMFS is 75% full or more the count must be 200 MB only. Ideal block count is 1% of free space of the VMFS in MB
            if ((1 - $objDatastore.FreeSpaceMB/$objDatastore.CapacityMB) -ge .75)
            {
                $intBlockCount = 200
                Add-Content $strLogFile 'The volume is 75% or more full so the block count will default to 200 MB. This will slow down the reclaim process'
                Add-Content $strLogFile 'It is recommended to either free up space on the volume or increase the capacity so it is less than 75% full'
                Add-Content $strLogFile ("The block count in MB will be " + $intBlockCount)
            }
            else
            {
                $intBlockCount = [math]::floor($objDatastore.FreeSpaceMB * .01)
                Add-Content $strLogFile ("The maximum allowed block count for this datastore is " + $intBlockCount)
            }
            $objESXcli.storage.vmfs.unmap($intBlockCount, $objDatastore.Name, $null) | Out-Null
            Start-Sleep -s 10

            $intVolCount=$intVolCount+1
            Add-Content $strLogFile ''
            Add-Content $strLogFile ((Get-Date -Format o ) + ': Datastore space reclaim is complete.')
            Add-Content $strLogFile '##########################################################################################################'
            Start-Sleep -s 5
        }
    }
}

#Disconnect vCenter.
Disconnect-VIServer -Server $strVCenter -confirm:$false


Add-Content $strLogFile ((Get-Date -Format o ) + ': Script Completed')
