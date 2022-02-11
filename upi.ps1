#!/usr/bin/pwsh

. .\upi-variables.ps1

$ErrorActionPreference = "Stop"

# Connect to vCenter
Connect-VIServer -Server $vcenter -Credential (Import-Clixml $vcentercredpath)

Write-Output "Downloading the most recent $($version) installer"

$releaseApiUri = "https://api.github.com/repos/openshift/okd/releases"
$progressPreference = 'silentlyContinue'
$webrequest = Invoke-WebRequest -uri $releaseApiUri
$progressPreference = 'Continue'
$releases = ConvertFrom-Json $webrequest.Content -AsHashtable
$publishedDate = (Get-Date).AddDays(-365)
$currentRelease = $null

foreach($r in $releases) {
	if($r['name'] -like "*$($version)*") {
		if ($publishedDate -lt $r['published_at'] ) {
			$publishedDate = $r['published_at']
			$currentRelease = $r
		}
	}
}

foreach($asset in $currentRelease['assets']) {
	if($asset['name'] -like "openshift-install-linux*") {
		$installerUrl = $asset['browser_download_url']
	}
}



# If openshift-install doesn't exist on the path, download it and extract
if (-Not (Test-Path -Path "openshift-install")) {

    $progressPreference = 'silentlyContinue'
    Invoke-WebRequest -uri $installerUrl -OutFile "installer.tar.gz"
    tar -xvf "installer.tar.gz"
    $progressPreference = 'Continue'
}

Write-Output "Downloading FCOS OVA"

# If the OVA doesn't exist on the path, determine the url from openshift-install and download it.
if (-Not (Test-Path -Path "template-$($Version).ova")) {
    Start-Process -Wait -Path ./openshift-install -ArgumentList @("coreos", "print-stream-json") -RedirectStandardOutput coreos.json

    $coreosData = Get-Content -Path ./coreos.json | ConvertFrom-Json -AsHashtable
    $ovaUri = $coreosData.architectures.x86_64.artifacts.vmware.formats.ova.disk.location
    $progressPreference = 'silentlyContinue'
    Invoke-WebRequest -uri $ovaUri -OutFile "template-$($Version).ova"
    $progressPreference = 'Continue'
}

# Without having to add additional powershell modules yaml is difficult to deal
# with. There is a supplied install-config.json which is converted to a powershell
# object
$config = Get-Content -InputObject $installconfig | ConvertFrom-Json

# Set the install-config.json from upi-variables
$config.metadata.name = $clustername
$config.baseDomain = $basedomain
$config.sshKey = [string](Get-Content -Path $sshkeypath -Raw:$true)
$config.platform.vsphere.vcenter = $vcenter
$config.platform.vsphere.username = $username
$config.platform.vsphere.password = $password
$config.platform.vsphere.datacenter = $datacenter
$config.platform.vsphere.defaultDatastore = $datastore
$config.platform.vsphere.cluster = $cluster
$config.platform.vsphere.network = $portgroup
$config.platform.vsphere.apiVIP = $apivip
$config.platform.vsphere.ingressVIP = $ingressvip

$config.pullSecret = $pullsecret -replace "`n", "" -replace " ", ""

# Write out the install-config.yaml (really json)
$config | ConvertTo-Json -Depth 8 | Out-File -FilePath install-config.yaml -Force:$true

# openshift-install create manifests
start-process -Wait -FilePath ./openshift-install -argumentlist @("create", "manifests")
# openshift-install create ignition-configs
start-process -Wait -FilePath ./openshift-install -argumentlist @("create", "ignition-configs")

# Convert the installer metadata to a powershell object
$metadata = Get-Content -Path ./metadata.json | ConvertFrom-Json

# Since we are using MachineSets for the workers make sure we set the
# template name to what is expected to be generated by the installer.
$templateName = "$($metadata.infraID)-rhcos"

# If the folder already exists
$folder = Get-Folder -Name $metadata.infraID -ErrorAction continue

# Otherwise create the folder within the datacenter as defined in the upi-variables
if (-Not $?) {
	(get-view (Get-Datacenter -Name $datacenter).ExtensionData.vmfolder).CreateFolder($metadata.infraID)
    $folder = Get-Folder -Name $metadata.infraID
}

# If the fcos virtual machine already exists
$template = Get-VM -Name $templateName -ErrorAction continue

# Otherwise import the ova to a random host on the vSphere cluster
if (-Not $?) {
    $vmhost = Get-Random -InputObject (Get-VMHost -Location (Get-Cluster $cluster))
    $ovfConfig = Get-OvfConfiguration -Ovf "template-$($Version).ova"
    $ovfConfig.NetworkMapping.VM_Network.Value = $portgroup
    $template = Import-Vapp -Source "template-$($Version).ova" -Name $templateName -OvfConfiguration $ovfConfig -VMHost $vmhost -Datastore $Datastore -InventoryLocation $folder -Force:$true

    $templateVIObj = Get-View -VIObject $template.Name
    $templateVIObj.UpgradeVM($hardwareVersion)

    $template | Set-VM -MemoryGB 16 -NumCpu 4 -CoresPerSocket 4 -Confirm:$false
    $template | Get-HardDisk | Select-Object -First 1 | Set-HardDisk -CapacityGB 128 -Confirm:$false
    $template | New-AdvancedSetting -name "guestinfo.ignition.config.data.encoding" -value "base64" -confirm:$false -Force
    $snapshot = New-Snapshot -VM $template -Name "linked-clone" -Description "linked-clone" -Memory -Quiesce

}

# Take the $virtualmachines defined in upi-variables and convert to a powershell object
$vmHash = ConvertFrom-Json -InputObject $virtualmachines -AsHashtable

Write-Progress -id 222 -Activity "Creating virtual machines" -PercentComplete 0

$vmStep = (100 / $vmHash.virtualmachines.Count)
$vmCount = 1
foreach ($key in $vmHash.virtualmachines.Keys) {
    $node = $vmHash.virtualmachines[$key]

    $name = "$($metadata.infraID)-$($key)"

    $rp = Get-Cluster -Name $node.cluster -Server $node.server
    $datastore = Get-Datastore -Name $node.datastore -Server $node.server

    # Get the content of the ignition file per machine type (bootstrap, master, worker)
    $bytes = Get-Content -Path "./$($node.type).ign" -AsByteStream
    $ignition = [Convert]::ToBase64String($bytes)

    # Clone the virtual machine from the imported template
    $vm = New-VM -VM $template -Name $name -ResourcePool $rp -Datastore $datastore -Location $folder -LinkedClone -ReferenceSnapshot $snapshot

    $vm | New-AdvancedSetting -name "guestinfo.ignition.config.data" -value $ignition -confirm:$false -Force
    $vm | New-AdvancedSetting -name "guestinfo.hostname" -value $name -Confirm:$false -Force

    # in OKD the OVA is not up-to-date
    # causing very long startup times to pivot
    # start the bootstrap instance 5 minutes ahead of
    # the masters.
    if ($node.type -eq "master") {
        Start-ThreadJob -ThrottleLimit 5 -InputObject $vm {
            Start-Sleep -Seconds 300
            $input | Start-VM
        }
    }
    else {
        $vm | Start-VM
    }
    Write-Progress -id 222 -Activity "Creating virtual machines" -PercentComplete ($vmStep * $vmCount)
    $vmCount++
}
Write-Progress -id 222 -Activity "Completed virtual machines" -PercentComplete 100 -Completed

Clear-Host

# Instead of restarting openshift-install to wait for bootstrap, monitor
# the bootstrap configmap in the kube-system namespace

# Extract the Client Certificate Data from auth/kubeconfig
$match = Select-String "client-certificate-data: (.*)" -Path ./auth/kubeconfig
[Byte[]]$bytes = [Convert]::FromBase64String($match.Matches.Groups[1].Value)
$clientCertData = [System.Text.Encoding]::ASCII.GetString($bytes)

# Extract the Client Key Data from auth/kubeconfig
$match = Select-String "client-key-data: (.*)" -Path ./auth/kubeconfig
$bytes = [Convert]::FromBase64String($match.Matches.Groups[1].Value)
$clientKeyData = [System.Text.Encoding]::ASCII.GetString($bytes)

# Create a X509Certificate2 object for Invoke-WebRequest
$cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPem($clientCertData, $clientKeyData)

# Extract the kubernetes endpoint uri
$match = Select-String "server: (.*)" -Path ./auth/kubeconfig
$kubeurl = $match.Matches.Groups[1].Value

$apiTimeout = (20*60)
$apiCount = 1
$apiSleep = 30
Write-Progress -Id 444 -Status "1% Complete" -Activity "API" -PercentComplete 1
:api while ($true) {
    Start-Sleep -Seconds $apiSleep
    try {
        $webrequest = Invoke-WebRequest -Uri "$($kubeurl)/version" -SkipCertificateCheck
        $version = (ConvertFrom-Json $webrequest.Content).gitVersion

	if ($version -ne "" ) {
		Write-Debug "API Version: $($version)"
    		Write-Progress -Id 444 -Status "Completed" -Activity "API" -PercentComplete 100
		break api
	}
    }
    catch {}

    $percentage = ((($apiCount*$apiSleep)/$apiTimeout)*100)
    if ($percentage -le 100) {
       Write-Progress -Id 444 -Status "$percentage% Complete" -Activity "API" -PercentComplete $percentage
    }
    $apiCount++
}


$bootstrapTimeout = (30*60)
$bootstrapCount = 1
$bootstrapSleep = 30
Write-Progress -Id 333 -Status "1% Complete" -Activity "Bootstrap" -PercentComplete 1
:bootstrap while ($true) {
    Start-Sleep -Seconds $bootstrapSleep

    try {
        $webrequest = Invoke-WebRequest -Certificate $cert -Uri "$($kubeurl)/api/v1/namespaces/kube-system/configmaps/bootstrap" -SkipCertificateCheck

        $bootstrapStatus = (ConvertFrom-Json $webrequest.Content).data.status

        if ($bootstrapStatus -eq "complete") {
            Get-VM "$($metadata.infraID)-bootstrap" | Stop-VM -Confirm:$false | Remove-VM -Confirm:$false
    	    Write-Progress -Id 333 -Status "Completed" -Activity "Bootstrap" -PercentComplete 100
            break bootstrap
        }
    }
    catch {}

    $percentage = ((($bootstrapCount*$bootstrapSleep)/$bootstrapTimeout)*100)
    if ($percentage -le 100) {
       Write-Progress -Id 333 -Status "$percentage% Complete" -Activity "Bootstrap" -PercentComplete $percentage
    } else {
      Write-Output "Warning: Bootstrap taking longer than usual." -NoNewLine -ForegroundColor Yellow
    }

    $bootstrapCount++
}

$progressMsg = ""
Write-Progress -Id 111 -Status "1% Complete" -Activity "Install" -PercentComplete 1
:installcomplete while($true) {
    Start-Sleep -Seconds 30
    try {
        $webrequest = Invoke-WebRequest -Certificate $cert -Uri "$($kubeurl)/apis/config.openshift.io/v1/clusterversions" -SkipCertificateCheck

        $clusterversions = ConvertFrom-Json $webrequest.Content -AsHashtable

        # just like the installer check the status conditions of the clusterversions config
        foreach ($condition in $clusterversions['items'][0]['status']['conditions']) {
            switch ($condition['type']) {
                "Progressing" {
                    if ($condition['status'] -eq "True") {

                        $matchper = ($condition['message'] | Select-String "^Working.*\(([0-9]{1,3})\%.*\)")
                        $matchmsg = ($condition['message'] | Select-String -AllMatches -Pattern "^(Working.*)\:.*")

                        $progressMsg = $matchmsg.Matches.Groups[1].Value
			$progressPercent = $matchper.Matches.Groups[1].Value

                        Write-Progress -Id 111 -Status "$progressPercent% Complete - $($progressMsg)" -Activity "Install" -PercentComplete $progressPercent
                        continue
                    }
                }
                "Available" {
                    if ($condition['status'] -eq "True") {
                        Write-Progress -Id 111 -Activity "Install" -Status "Completed" -PercentComplete 100
                        break installcomplete
                    }
                    continue
                }
                Default {continue}
            }
        }
    }
    catch {}
}

Get-Job | Remove-Job
