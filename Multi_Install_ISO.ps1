#Import Vmware PowerCli tools.
#This will work on all ISO BOOTS setups

#If Invalid Cert error happens.
#Get-PowerCliConfiguration
#Set-PowerCliConfiguration -InvalidCertificateAction Ignore
#Connect to VCenter now.
#https://be-virtual.net/powercli-10-0-0-error-invalid-server-certificate/

[VMware.Vim.VirtualMachineGuestOsIdentifier].GetEnumValues()

#Install-Module -Name PsJsonCredential
$admin = Import-PSCredentialFromJson -Path C:\Users\mikedopp\OneDrive\Secure\nadmin.json


Get-Module "ListAvailable VM*"| Import-Module | Out-Null
Import-Module ActiveDirectory
Connect-VIServer wdc-vcenter.mediconnect.net -Credential $admin
Connect-CISServer wdc-vcenter.mediconnect.net -Credential $admin

#Import-Module VMware.VimAutomation.Core
#Import-Module VMware.VimAutomation.Cis.Core
#Connect-VIServer edc-vcenter.mediconnect.net -Credential $admin
#alternatively you can connect-viserver to HostServerName
#Connect-CISServer edc-vcenter.mediconnect.net -Credential $admin



#Install-Module -Name VMware.PowerCLI -Scope CurrentUser

#this is just incase the variables have not been mapped.
New-PSDrive -name V -PSProvider FileSystem -Root '\\filesvr\it$\PSAutoM' -Credential "mediconnect\mikedoppsu"
$vmlist = Import-CSV $wd\PowerCli_Associated_Files\buildtest.csv
$wd = get-item -path ".\" -verbose #magic sauce...
#$vmlist = Get-Content -raw -path "$wd\PowerCli_Associated_Files\jsonTemp\WinTest.json" | ConvertFrom-Json
#$vmlist = Import-CSV “D:\Documents\PAD_SJ_DevOps\devops_powershell\MikeD\PowerCli_Associated_Files\buildtest.csv”
#$vmlist = Get-Content -raw -path "C:\Users\mikedopp\OneDrive\Git\PAD_SJ_DevOps\devops_powershell\MikeD\PowerCli_Associated_Files\WinTest.json" | ConvertFrom-Json

$secure = ConvertTo-SecureString -String $vmlist.cred_pass -AsPlainText -Force
$cred = New-Object -typename PSCredential -ArgumentList @($vmlist.cred_user, $secure)

#$vmlist = Get-ChildItem -Path (Read-Host -Prompt 'Get path') | ConvertFrom-Json

    foreach ($item in $vmlist) {
        # Map variables
        $template = $item.template
        $datastore = $item.datastore
        $OSDiskSize = $item.OSDiskSize
        $vmhost = $item.vmhost
        $ISO = $item.ISO
        $vmname = $item.vmname
        $ip = $item.ip
        $subnet = $item.subnet
        $gateway = $item.gateway
        $primary = $item.primary
        $netadapter = $item.netadapter
        $datacenter = $item.datacenter
        $destfolder = $item.folder
        $vlan = $item.vlan
        $OSRamSize = $item.OSRamSize
        $cpucount = $item.NumCPU
        $domain = $item.domain
        $note = $item.note
        $path = $item.path #not used yet
        $cred_User = $item.Cred_User
        $cred_pass = $item.Cred_Pass
        $SecondDiskSize = $item.SecondDiskSize
        $SecondDiskDS = $item.SecondDiskDS
        $GuestIDOS = $item.GuestIDOS
        $spec = $item.spec
        $type = $item.NetType

        #$secure = ConvertTo-SecureString -String $cred_pass -AsPlainText -Force
        #$cred = New-Object -typename PSCredential -ArgumentList @($cred_User, $secure)
        #'OSCustomizationSpec'              = $spec
        #'OSCustomizationSpec'= $spec

        #***Mapped Variables***#
        #GuestID's
        # windows8Server64Guest = 2012R2
        # windows9Server64Guest = 2016
***Variables Index***
$vc = Read-Host "Enter vCenter Server hostname or IP address"
$name = Read-Host "Enter the Server Name"
$ipaddress = Read-Host "Enter IP Address"
$subnet = Read-Host "Enter Subnet, i.e. 255.255.255.0"
$gateway = Read-Host "Enter Gateway"
$dns1 = Read-Host "Enter primary DNS server"
$dns2 = Read-Host "Enter secondary DNS server"
$zonename = Read-Host "Enter Zone name for DNS"
$dnsserver = Read-Host "Enter hostname for DNS Server that will be used to update DNS"
$clustername = Read-Host "Enter the cluster name for $vc"
$template = Read-Host "Enter the template to be used to clone VM from"
$customization = Read-Host "Enter the customization to be used within the template"
$NewDatastore = Read-Host "Enter the datastore to be used in $vc"
$networkname = Read-Host "Enter the network name to be used for the primary virtual nic for $name"
$ADDescription = Read-Host "Enter AD Description of $name"
$targetOU = Read-Host "Enter target OU to move Computer object to, I.E 'OU=Computers,DC=blah,DC=blah' "
Write-Output "Enter AD credentials that allow the Virtual Machine to be joined to the domain"
$mycredential = Get-Credential
$to = Read-Host "Enter the recipients of the new virtual machine email notification"
$from = Read-Host "Enter the sender of the new virtual machine email notification"
$smtpserver = Read-Host "Enter the SMTP Server hostname"

## Create AD Group for AD Administrators for the Virtual Machine
$administrator = "_Administrators"
$group = $name + $administrator
$path = Read-Host "Enter target OU to create the administrator groups for $name, I.E 'OU=Users,DC=blah,DC=blah'"

$adgroupvars = @{

    Name          = $group
    GroupScope    = Global
    Description   = "Members with Local Administrator Rights on $name"
    GroupCategory = Security
    Path          = $path
}

New-ADGroup @adgroupvars



$vmnetwork = @{

    OSCustomizationSpec = $customization
    IpMode              = UseStaticIP
    IpAddress           = $ipaddress
    SubnetMask          = $subnet
    DefaultGateway      = $gateway
    DNS                 = $dns1, $dns2
    Position            = 1
}


## Add DNS Record
Add-DnsServerResourceRecordA -Name $name -IPv4Address $ipaddress -ZoneName $zonename -ComputerName $dnsserver -CreatePtr

## Wait until computer is on the domain, and then move it to the right OU
do {
	  	Write-Host "." -nonewline -ForegroundColor Red
	  	Start-Sleep 5
} until (Get-ADComputer -Filter {Name -eq $name})

Get-ADComputer $name | Move-ADobject -targetpath $targetOU

## Set AD Description
Set-ADComputer -Identity $Name -Description $ADDescription

## Send Completion Email
Send-MailMessage -To $to -From $from -Subject "New VM $name Created" -SmtpServer $smtpserver




        $NewVMParams = @{
            'VMHost'            = $Vmhost
            'Name'              = $Vmname
            'Datastore'         = $DataStore
            'DiskGB'            = $OSDiskSize
            'DiskStorageFormat' = 'Thin'
            'MemoryGB'          = $OSRamSize
            'GuestId'           = $GuestIDOS
            'Version'           = 'v13'
            'NumCpu'            = $cpucount
            'Notes'             = $Note
            'Location'          = $destfolder
            'NetworkName'       = $vlan
           }
        $VMname = New-VM @NewVMParams

       #Mounting ISO to CD Rom
        $NewCDDriveParams = @{
            'VM'             = $VMname
            'IsoPath'        = $ISO
            'StartConnected' = $true
        }
        New-CDDrive @NewCDDriveParams
    #Detecting network driver and Setting to VMXNET3
        $FindNet = Get-VM $vmname | Get-NetworkAdapter -Name "Network adapter 1"
        Set-Networkadapter -NetworkAdapter $FindNet -Type Vmxnet3 -Confirm:$false


        #Adding Second Disk (D DRIVE)
        $NewHardDiskParams = @{
            'VM'         = $VMName
            'CapacityGB' = $SecondDiskSize
            'Datastore'  = $SecondDiskDS
        }
        New-HardDisk @NewHardDiskParams



        Start-VM -VM $VMname
        #$GuestIDOS = "Win2012R2"
        #$vmname = "vw-vM112R2Ag02"
        #Add Tagging to New VM. For easier searching in Vsphere
        #Tags and categories need to be created before assigned.
        #QuickNDirty. This so could be cleaned up.
        $ErrorActionPreference = 'Continue'
        If ($GuestIDOS -eq "windows7Server64Guest") {
            Get-VM -Name $VMName | New-TagAssignment -Tag 'Win2008R2'
        } elseif ($GuestIDOS -eq 'windows8Server64Guest') {
            Get-VM -Name $VMName | New-TagAssignment -Tag 'Win2012R2'
        } elseif ($GuestIDOS -eq 'windows9Server64Guest') {
            Get-VM -Name $VMName | New-TagAssignment -Tag 'Win2016'
        } else {
            "Not sure what the $GuestIDOS is"
        }
        #Get-VM $vmname | Get-VMGuest | Where-Object {$_.GuestFamily -eq "windowsguest"} Update-Tools -NoReboot -RunAsync | Out-Null
    }
