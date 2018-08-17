add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy

Import-Module ActiveDirectory

# Import-PSCredential and Export-PSCredential from http://poshcode.org/471
function Export-PSCredential {
        param ( $Credential = (Get-Credential), $Path = "credentials.enc.xml" )
       
        # Test for valid credential object
        if ( !$Credential -or ( $Credential -isnot [system.Management.Automation.PSCredential] ) ) {
                Throw "You must specify a credential object to export to disk."
        }
       
        # Create temporary object to be serialized to disk
        $export = "" | Select-Object Username, EncryptedPassword
       
        # Give object a type name which can be identified later
        $export.PSObject.TypeNames.Insert(0,'ExportedPSCredential')
       
        $export.Username = $Credential.Username
 
        # Encrypt SecureString password using Data Protection API
        # Only the current user account can decrypt this cipher
        $export.EncryptedPassword = $Credential.Password | ConvertFrom-SecureString
 
        # Export using the Export-Clixml cmdlet
        $export | Export-Clixml $Path
        Write-Host -foregroundcolor Green "Credentials saved to: " -noNewLine
 
        # Return FileInfo object referring to saved credentials
        Get-Item $Path
}


function Import-PSCredential {
        param ( $Path = "credentials.enc.xml" )
 
        # Import credential file
        $import = Import-Clixml $Path
       
        # Test for valid import
        if ( $import.PSObject.TypeNames -notcontains 'Deserialized.ExportedPSCredential' ) {
                Throw "Input is not a valid ExportedPSCredential object, exiting."
        }
        $Username = $import.Username
       
        # Decrypt the password and store as a SecureString object for safekeeping
        $SecurePass = $import.EncryptedPassword | ConvertTo-SecureString
       
        # Build the new credential object
        $Credential = New-Object System.Management.Automation.PSCredential $Username, $SecurePass
        Write-Output $Credential
}


# borrowing os customization checking from http://blogs.vmware.com/PowerCLI/2012/08/waiting-for-os-customization-to-complete.html
$STATUS_VM_NOT_STARTED = "VmNotStarted"
$STATUS_CUSTOMIZATION_NOT_STARTED = "CustomizationNotStarted"
$STATUS_STARTED = "CustomizationStarted"
$STATUS_SUCCEEDED = "CustomizationSucceeded"
$STATUS_FAILED = "CustomizationFailed"

# constants for vm_states
$VM_STATE_INITIAL = 0
$VM_STATE_SUCCESS = 1
$VM_STATE_FAILURE = 2

# constants for event types      
$EVENT_TYPE_CUSTOMIZATION_STARTED = "VMware.Vim.CustomizationStartedEvent" 
$EVENT_TYPE_CUSTOMIZATION_SUCCEEDED = "VMware.Vim.CustomizationSucceeded" 
$EVENT_TYPE_CUSTOMIZATION_FAILED = "VMware.Vim.CustomizationFailed" 
$EVENT_TYPE_VM_START = "VMware.Vim.VmStartingEvent"
      
# seconds to sleep before next loop iteration 
$WAIT_INTERVAL_SECONDS = 15
$WAIT_MAXIMUM_ITERATIONS = 40

Function HashtableFromCSVRow
{
Param(
    [Parameter(Mandatory=$True)][PSCustomObject]$csvrow
    )
    $ht = @{}
    $proplist = Get-Member -inputobject $csvrow -Membertype Properties
    Foreach ($propname in $proplist)
    {
        If (($propname.name).EndsWith("Pass") -eq $true)
        {
            $ht.($propname.name) = ConvertTo-SecureString -String $csvrow.($propname.name) -AsPlainText -Force
        }
        Else
        {
            #Write-Output $propname.name
            If ($csvrow.($propname.name) -eq "TRUE")
            {
                $ht.($propname.name) = $true
            }
            ElseIf ($csvrow.($propname.name) -eq "FALSE")
            {
                $ht.($propname.name) = $FALSE
            }
            Else
            {
                $ht.($propname.name) = $csvrow.($propname.name)
            }
        }
    }
    $ht
}

Function VMWorkDeterminePath
{
    Param(
[Parameter(Mandatory=$True)][hashtable]$item,
[bool]$testdrive=$true
)
    ## initialize some values here
    $item.Pathing = "Unknown"
    $item.BuildState = "Unknown"
    $item.BuildMessages = @()
    If ($item.ContainsKey("GuestIDOS") -eq $true)
    {
        $guestos = $item.GuestIDOS
        If ($guestos)
        {
            If (([string]$guestos).Length -gt 0)
            {
                $item.Pathing = "build_ISO"
            }
        }
    }
    If ($item.ContainsKey("TemplateName") -eq $true)
    {
        $templatemoniker = $item.TemplateName
        If ($templatemoniker)
        {
            If (([string]$templatemoniker).Length -gt 0)
            {
                $item.Pathing = "build_Template"
            }
        }
    }
    $item
}


Function Write-BuildMessages
{
    Param(
[Parameter(Mandatory=$True)][hashtable]$item
    )
    Foreach ($message in $item.BuildMessages)
    {
        Write-Host $message
    }
    $item.BuildMessages = @()
    $item
}


Function VMWorkGetVMHost
{
    Param(
[Parameter(Mandatory=$True)][hashtable]$item,
[bool]$testdrive=$true
    )
	$datacenter = $null
	$singleClusterHostName = $null
	If ($item.ContainsKey("vmhost") -eq $true) { $singleClusterHostName = $item.vmhost }
	If ($item.ContainsKey("ClusterName") -eq $true)
	{
		$datacenter = Get-Datacenter -Cluster $item.ClusterName
		$vmHosts = Get-VMHost -Location $item.ClusterName
		Foreach ($vmHost in $vmHosts)
		{
			If ($singleClusterHostName) { } Else { $singleClusterHostName = $vmHost }
		}
	}
	If ($singleClusterHostName)
	{
		If ($item.ContainsKey("vmhost") -eq $true)
		{
			If ([string]($item.vmhost).Length -eq 0)
			{
				$item.vmhost = $singleClusterHostName
			}
		}
		Else
		{
			$item.vmhost = $singleClusterHostName
		}
	}
	$item
}


Function VMWorkGetDatastore
{
    Param(
[Parameter(Mandatory=$True)][hashtable]$item,
[bool]$testdrive=$true
    )
    $datastore_name = ""
    If ($item.ContainsKey("datastore") -eq $true) { $datastore_name = $item.datastore }
    #Write-Host "OK Find Datastore - start"
    If ($datastore_name -eq "")
    {
		#Write-Host "OK Find Datastore"
        # get a list of available datastores for our cluster?
        $GBneeded = [float]250.0
        # Brad method
        If ($item.ContainsKey("Cdrive") -eq $true)
        {
            $GBneeded = [float]$item.Cdrive + 150.0
            Foreach ($letter in $alphabet)
            {
                $drivefield = "$($letter)drive"
                If ($item.ContainsKey($drivefield) -eq $true)
                {
                    $GBneeded += [fload]$item.$drivefield
                }
            }
        }
        ElseIf ($item.ContainsKey("OSDiskSize") -eq $true)
        {
            $GBneeded = [float]$item.OSDiskSize + 150.0
            If ($item.ContainsKey("SecondDisksize") -eq $true) { $GBneeded += [float]$item.SecondDisksize }
        }
		#Write-Host "OK Find Datastore, sized needed $($GBneeded)"
        $datacenter = $null
        $singleClusterHostName = $null
        If ($item.ContainsKey("ClusterName") -eq $true)
        {
            $datacenter = Get-Datacenter -Cluster $item.ClusterName
			$vmHosts = Get-VMHost -Location $item.ClusterName
			Foreach ($vmHost in $vmHosts)
			{
                If ($singleClusterHostName) { } Else { $singleClusterHostName = $vmHost }
			}
        }
		If ($singleClusterHostName)
		{
			If ($item.ContainsKey("vmhost") -eq $true)
			{
				If ([string]($item.vmhost).Length -eq 0)
				{
					$item.vmhost = $singleClusterHostName
				}
			}
			Else
			{
				$item.vmhost = $singleClusterHostName
			}
		}
        If ($datacenter) { }
        Else
        {
            If ($item.ContainsKey("DataCenter") -eq $true)
            {
                $datacenter = Get-Datacenter -Name $item.DataCenter
                $vmHosts = Get-VMHost -Location $item.DataCenter
                Foreach ($vmHost in $vmHosts)
                {
                    If ($singleClusterHostName) { } Else { $singleClusterHostName = $vmHost }
                }
            }
        }
        #$stores = Get-Datastore -Datacenter $datacenter -VMHost $singleClusterHostName | Sort-Object FreeSpaceGB -descending
        $stores = Get-Datastore -VMHost $singleClusterHostName | Sort-Object FreeSpaceGB -descending
        Foreach ($store in $stores)
        {
            If ($datastore_name -eq "")
            {
                If ($store.State -eq "Available")
                {
                    If ($store.CapacityGB -gt 1000.0)
                    {
                        If ($store.FreeSpaceGB -gt $GBneeded)
                        {
                            If ($item.ClusterName -eq 'VW2.0_NewCage')
                            {
                                If ($store.Name -eq 'VMFS5_G600_00ad_LUN03 (TEMP)')
                                {
                                }
                                Else
                                {
                                    if ($store.Name -eq 'VMFS5_G600_008b_LUN02')
                                    {
                                        $datastore_name = $store.Name
                                    }
                                    Elseif ($store.Name -eq 'VMFS5_G600_008a_LUN01')
                                    {
                                        $datastore_name = $store.Name
                                    }
                                    Else
                                    {
                                        $datastore_name = $store.Name
                                    }
                                }
                            }
                            Else
                            {
                                $datastore_name = $store.Name
                            }
                        }
                    }
                }
            }
        }
        If ($datastore_name -eq "") { } Else { $item.datastore = $datastore_name }
    }
	#Write-Host "OK Find Datastore - end"
    #$datastore_name
	$item
}


Function VMWorkWindowsGuestExpandDrives
{
    Param(
[Parameter(Mandatory=$True)][hashtable]$item,
[bool]$testdrive=$true
    )
    $vmname = $null
    $nagiostoken = $null
    $octotrust = $null
    $saltmaster = $null
    If ($item.ContainsKey("vmname") -eq $true) { $vmname = $item.vmname }
    If ($item.ContainsKey("nagiostoken") -eq $true) { $nagiostoken = $item.nagiostoken }
    If ($item.ContainsKey("OctoThumbprint") -eq $true) { $octotrust = $item.OctoThumbprint }
    If ($item.ContainsKey("SaltMaster") -eq $true) { $saltmaster = $item.SaltMaster }
    If ($nagiostoken) { If (([string]$nagiostoken).Length -eq 0) { $nagiostoken = $null } }
    If ($octotrust) { If (([string]$octotrust).Length -eq 0) { $octotrust = $null } }
    If ($saltmaster) { If (([string]$saltmaster).Length -eq 0) { $saltmaster = $null } }

    If ($vmname)
    {
        $domjcount = 0
		$thisVM = Get-VM -Name $vmname
		
		$driveletters = @()
        
        # look for drive letters
        Foreach ($letter in $alphabet)
        {
            $drivefield = "$($letter)drive"
            If ($item.ContainsKey($drivefield) -eq $true)
            {
                If ([int]$item.$drivefield -gt 0)
                {
                    $driveletters += $letter
                }
            }
        }

        # check for VM creds
        $item = VMInstantiateGuestCredentials $item

		# check for NAGIOS token
		If ($nagiostoken) { } Else { $nagiostoken = $defaultnagiostoken }

        # check for Octo Thumbprint
        If ($octotrust) { } Else { $octotrust = $defaultoctotrust }

        # check for Salt Master
        If ($saltmaster) { } Else { $saltmaster = $SaltMaster }
        
		#####Need to pass argument for drive letter.  This is where iteration of drives is valuable.  This brings the disk online from being off, and then formats and mounts it as a drive.
		
		$drivestring = "@(""C"""
		ForEach ($driveletter in $driveletters)
		{
			$drivestring += ",""$($driveletter)"""
		}
		$drivestring += ")"
		$item.BuildMessages += "  - Need to Extend drives"
		$DriveAdditionScript = "`$driveLetters = $($drivestring)
		`$drivect = 0
		Foreach (`$driveletter in `$driveLetters)
		{
			If (`$drivect -gt 0)
			{
				`$disk = get-disk
				Foreach (`$tdisk in `$disk)
				{
					If (`$tdisk.Number -eq `$drivect)
					{
						`$tdisk | set-disk -IsOffline:`$false
						`$tdisk | set-disk -IsReadOnly:`$false
						`$tdisk | Initialize-Disk -PartitionStyle MBR
						`$part = `$tdisk | New-Partition -UseMaximumSize -DriveLetter `$driveLetter
						`$volume = `$part | get-volume
						`$volume | format-volume -FileSystem NTFS -Confirm:`$false
						`$volume | select * 
					}
				}
			}
			`$drivect += 1
		}
        "
        If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $DriveAdditionScript -VM $vmname -GuestCredential $item.guestcred }
        

        #####This expands a drive to the max size allowed.  This is appropriate for the C drive.
        $DriveExpansionScript = '$part = get-partition -DriveLetter C
$size = $part | Get-PartitionSupportedSize
$part | Resize-Partition -Size $size.SizeMax
Get-Partition -DriveLetter C'
        If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $DriveExpansionScript -VM $vmname -GuestCredential $item.guestcred }
		
		## Let's pave the way for new stuff to occur
        $PaveTheWayScript = "`$installdir = ""C:\Installs""
md -Force `$installdir
Remove-Item -Recurse -Force ""`$(`$installdir)\$domjsource"" -Confirm:`$false
Remove-Item -Recurse -Force ""`$(`$installdir)\$domjsource1"" -Confirm:`$false
Remove-Item -Recurse -Force ""`$(`$installdir)\$domjsource2"" -Confirm:`$false
Remove-Item -Recurse -Force ""`$(`$installdir)\$domjsource3"" -Confirm:`$false
Remove-Item -Recurse -Force ""`$(`$installdir)\$domjsource4"" -Confirm:`$false
"

		If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $PaveTheWayScript -VM $vmname -GuestCredential $item.guestcred }

        #####Salt Install Bit
        #####Create variable for file name and pasing it to the script. 
		#$installsPrep = 'md -Force C:\Installs'
		#If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $installsPrep -VM $vmname -GuestCredential $item.guestcred }
        If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $saltsource -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
		If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $octsource -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
		If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $ncpasource -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
		If (Test-Path $domjsource)
		{
			If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $domjsource -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
			$domjcount += 1
		}
		If (Test-Path $domjsource1)
		{
			If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $domjsource1 -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
			$domjcount += 1
		}
		If (Test-Path $domjsource2)
		{
			If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $domjsource2 -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
			$domjcount += 1
		}
		If (Test-Path $domjsource3)
		{
			If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $domjsource3 -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
			$domjcount += 1
		}
		If (Test-Path $domjsource4)
		{
			If ($item.guestcred) { $cpres = Copy-VMGuestFile -Source $domjsource4 -Destination "C:\Installs" -VM $vmname -LocalToGuest -GuestCredential $item.guestcred }
		}
		
		#####Turn off firewall, enable PS Remoting
		$firewallScript = "NetSh Advfirewall set allprofiles state off"
		If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $firewallScript -VM $vmname -GuestCredential $item.guestcred }
		$item.BuildMessages += "  - Firewall disabled."
		$psremoteScript = "Enable-PSRemoting -Force -SkipNetworkProfileCheck -Confirm:`$false"
		If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $psremoteScript -VM $vmname -GuestCredential $item.guestcred }
        $item.BuildMessages += "  - PS Remoting enabled."
        $targetdomain = ""
        If ($item.ContainsKey("Domain") -eq $true) { $targetdomain = $item.Domain }
        $SaltScript = "`$installdir = ""C:\Installs""
md -Force `$installdir
`$minionname = (`$env:computername).ToLower()
`$domainname = ""$($targetdomain)"".ToLower()
If (`$domainname.length -gt 0)
{
	`$minionname += "".""
	`$minionname += `$domainname
}
`$installfile = ""$($saltsource)""
`$argumentlist = ""/S /master=$($saltmaster) /minion-name=`$minionname""

function Elevate-Process
{
	param ([string]`$exe = `$(Throw ""Pleave provide the name and path of an executable""),[string]`$arguments)
	`$startinfo = new-object System.Diagnostics.ProcessStartInfo 
	`$startinfo.FileName = `$exe
	`$startinfo.Arguments = `$arguments 
	`$startinfo.verb = ""RunAs"" 
	`$process = [System.Diagnostics.Process]::Start(`$startinfo)
}

If (Test-Path `$installfile)
{
	If (Test-Path C:\salt\conf\pki\minion\minion_master.pub)
	{
		Write-Host ""Salt-Minion is already communicating with a master.""
	}
	Else
	{
		if(Get-Service -Name ""Salt-Minion"" -ErrorAction SilentlyContinue)
		{
			`$thisSVC = Get-Service -Name ""Salt-Minion""
			If (`$thisSVC.Status -eq ""Running"")
			{
				Write-Host ""Stopping Salt Minion... "" -ForegroundColor Green
				Stop-Service -Name ""Salt-Minion""
			}
			Write-Host ""Salt-Minion Service found... Stopping..."" -ForegroundColor Green
		}
	}
	
	unblock-file `$installfile -Confirm:`$false

	if (`$? -eq `$true)
	{
		Write-Host ""File unblocked"" -ForegroundColor Green
	}

	Write-Host ""Starting Installation"" -ForegroundColor Green
	Elevate-Process -Exe `$installfile -arguments `$argumentlist
	Sleep 60

	While (!(Get-Service -Name ""Salt-Minion"" -ErrorAction SilentlyContinue))
	{
		Write-Host ""Salt-Minion not available"" -ForegroundColor Yellow
		Write-Host ""Sleeping 5"" -ForegroundColor Yellow
		Sleep -s 5

		if(Get-Service -Name ""Salt-Minion"" -ErrorAction SilentlyContinue)
		{
			Write-Host ""Starting Salt Minion... "" -ForegroundColor Green
			Start-Service -Name ""Salt-Minion""
			Write-Host ""Salt-Minion Service found... Starting..."" -ForegroundColor Green
			break
		}
	}
}"

        If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $SaltScript -VM $vmname -GuestCredential $item.guestcred }
        $item.BuildMessages += "  - Salt Installed."
    }

	If ($domjcount -ge 4)
	{
        $DomJoinScript = "`$installdir = ""C:\Installs""
md -Force `$installdir
cd $installdir
Invoke-Expression C:\Installs\mycreds.ps1"

        If ($item.guestcred) { $invres = Invoke-VMScript -ScriptText $DomJoinScript -VM $vmname -GuestCredential $item.guestcred }
        
        $item.BuildMessages += "  - $($vmname): Domain Joined."
	}
    $item.BuildState = "Did special Guest Work"
    $item.build_wait_til = ((Get-Date) + (New-TimeSpan -Seconds 120.0))
    $item
}

Function ADWorkComputer
{
    Param(
[Parameter(Mandatory=$True)][hashtable]$item,
[bool]$testdrive=$true
)
    $go_for_administratorsgroup = 1
    $go_for_updatedns = 1
    $go_for_updateadou = 1
    $go_for_updateaddescription = 1
    $go_for_sendingemail = 1

    Write-Host "ADWorkComputer 1"
    
    If ($item.ContainsKey("ADAdminGroupOU") -eq $false)
    {
        $go_for_administratorsgroup = 0
    }
    Else
    {
        If ([string]($item.ADAdminGroupOU).Length -eq 0)
        {
            $go_for_administratorsgroup = 0
        }
    }
    If ($item.ContainsKey("IPAddress") -eq $false)
    {
        $go_for_updatedns = 0
    }
    Else
    {
        If ([string]($item.IPAddress).Length -eq 0)
        {
            $go_for_updatedns = 0
        }
    }
    If ($item.ContainsKey("DNSZone") -eq $false)
    {
        $go_for_updatedns = 0
    }
    Else
    {
        If ([string]($item.DNSZone).Length -eq 0)
        {
            $go_for_updatedns = 0
        }
    }
    If ($item.ContainsKey("DNSServer") -eq $false)
    {
        $go_for_updatedns = 0
    }
    Else
    {
        If ([string]($item.DNSServer).Length -eq 0)
        {
            $go_for_updatedns = 0
        }
    }
    If ($item.ContainsKey("ADTargetOU") -eq $false)
    {
        $go_for_updateadou = 0
    }
    Else
    {
        If ([string]($item.ADTargetOU).Length -eq 0)
        {
            $go_for_updateadou = 0
        }
    }
    If ($item.ContainsKey("ADDescription") -eq $false)
    {
        $go_for_updateaddescription = 0
    }
    Else
    {
        If ([string]($item.ADDescription).Length -eq 0)
        {
            $go_for_updateaddescription = 0
        }
    }
    If ($item.ContainsKey("SMTPTo") -eq $false)
    {
        $go_for_sendingemail = 0
    }
    Else
    {
        If ([string]($item.SMTPTo).Length -eq 0)
        {
            $go_for_sendingemail = 0
        }
    }
    If ($item.ContainsKey("SMTPFrom") -eq $false)
    {
        $go_for_sendingemail = 0
    }
    Else
    {
        If ([string]($item.SMTPFrom).Length -eq 0)
        {
            $go_for_sendingemail = 0
        }
    }
    If ($item.ContainsKey("SMTPServer") -eq $false)
    {
        $go_for_sendingemail = 0
    }
    Else
    {
        If ([string]($item.SMTPServer).Length -eq 0)
        {
            $go_for_sendingemail = 0
        }
    }

    #Write-Host $go_for_updatedns
    Write-Host $go_for_updateadou
    #Write-Host $go_for_updateaddescription
    If ($go_for_administratorsgroup -eq 1)
    {
        ## Create AD Group for AD Administrators for the Virtual Machine
        $administrator = "_Administrators"
        $group = $($item.Name) + $administrator
        #$path = Read-Host "Enter target OU to create the administrator groups for $($item.Name), I.E 'OU=Users,DC=blah,DC=blah'"

        $adgroupvars = @{

            Name          = $group
            GroupScope    = "Global"
            Description   = "Members with Local Administrator Rights on $($item.Name)"
            GroupCategory = "Security"
            Path          = $($item.ADAdminGroupOU)
        }

        If ($testdrive -eq $false)
        {
            New-ADGroup @adgroupvars
        }
        Else
        {
            Write-Host "ADWork -> New AD Administrators Group $($group)"
        }
    }

    If ($go_for_updatedns -eq 1)
    {
        ## Add DNS Record
        If ($testdrive -eq $false)
        {
            Add-DnsServerResourceRecordA -Name $($item.Name) -IPv4Address $($item.IPAddress) -ZoneName $($item.DNSZone) -ComputerName $($item.DNSServer) -CreatePtr
        }
        Else
        {
            Write-Host "ADWork -> Add DNS Record $($item.Name)"
        }
    }

    ## Wait until computer is on the domain, and then move it to the right OU
    If ($go_for_updateadou -eq 1)
    {
        If ($testdrive -eq $false)
        {
            #Write-Host "$($item.Name)"
            #Do
            #{
            #    Write-Host "." -nonewline -ForegroundColor Red
            #    Start-Sleep 5
            #}
            #Until (Get-ADComputer -Path "OU=Computers,DC=mediconnect,DC=net" -Filter {Name -eq $($item.Name)})

            Get-ADComputer -Identity "$($item.Name)" | Move-ADobject -targetpath $($item.ADTargetOU)
        }
        Else
        {
            Write-Host "ADWork -> Move Machine to OU $($item.ADTargetOU)"
        }
    }

    ## Set AD Description
    If ($go_for_updateaddescription -eq 1)
    {
        If ($testdrive -eq $false)
        {
            Set-ADComputer -Identity $($item.Name) -Description $($item.ADDescription)
        }
        Else
        {
            Write-Host "ADWork -> Update Object Description $($item.ADDescription)"
        }
    }

    ## Send Completion Email
    If ($go_for_sendingemail -eq 1)
    {
        If ($testdrive -eq $false)
        {
            Send-MailMessage -To $($item.SMTPTo) -From $($item.SMTPFrom) -Subject "New VM $($item.Name) Created" -SmtpServer $($item.SMTPServer)
        }
        Else
        {
            Write-Host "ADWork -> Send Email"
        }
    }
}


Function VMBuildDoADWork
{
    Param(
        [Parameter(Mandatory=$True)][string]$vcenteraddr,
        [Parameter(Mandatory=$True)][hashtable]$item,
        [bool]$testdrive=$true
        )

    $go_for_domainwork = $false
    If ($item.ContainsKey("domain_joined") -eq $true)
    {
        If ($item.domain_joined -eq $true) { $go_for_domainwork = $true}
    }
    If ($go_for_domainwork -eq $true)
    {
        $adht = @{}
        #$adht.ADAdminGroupOU = "OU=LightHouse,OU=Servers_Prod,DC=mediconnect,DC=net"
        #$adht.ADTargetOU = "OU=CAC,OU=PROD,OU=HighTrust,DC=mediconnect,DC=net"

        $adht.Name = $null
        $adht.ADAdminGroupOU = $null
        $adht.IPAddress = $null
        $adht.DNSZone = $null
        $adht.DNSServer = $null
        $adht.ADTargetOU = $null
        $adht.ADDescription = $null
        $adht.SMTPTo = $null
        $adht.SMTPFrom = $null
        $adht.SMTPServer = $null
        
        If ($item.ContainsKey("Name") -eq $true) { $adht.Name = $item.Name }
        If ($item.ContainsKey("ADAdminGroupOU") -eq $true) { $adht.ADAdminGroupOU = $item.ADAdminGroupOU }
        If ($item.ContainsKey("IPAddress") -eq $true) { $adht.IPAddress = $item.IPAddress }
        If ($item.ContainsKey("Domain") -eq $true) { $adht.DNSZone = $item.Domain }
        If ($item.ContainsKey("DNSServer") -eq $true) { $adht.DNSServer = $item.DNSServer }
        If ($item.ContainsKey("ADTargetOU") -eq $true) { $adht.ADTargetOU = $item.ADTargetOU }
        If ($item.ContainsKey("ADDescription") -eq $true) { $adht.ADDescription = $item.ADDescription }
        If ($item.ContainsKey("SMTPTo") -eq $true) { $adht.SMTPTo = $item.SMTPTo }
        If ($item.ContainsKey("SMTPFrom") -eq $true) { $adht.SMTPFrom = $item.SMTPFrom }
        If ($item.ContainsKey("SMTPServer") -eq $true) { $adht.SMTPServer = $item.SMTPServer }
        
        $adres = ADWorkComputer $adht $testdrive
        $item.BuildState = "Ran AD Work"
		$item.build_wait_til = ((Get-Date) + (New-TimeSpan -Seconds 45.0))
    }
    Else
    {
        $item.BuildState = "VM Not Domain Joined, skipped domain work"
    }
	$item.build_adwork_complete = $true
    $item
}


Function VMUpdateVMTools
{
Param(
    [Parameter(Mandatory=$True)][string]$vcenteraddr,
    [Parameter(Mandatory=$True)][hashtable]$item,
    [bool]$testdrive=$true
    )
    If ($vcenteraddr -eq $item.vc)
    {
        If ($testdrive -eq $false)
        {
            #Get-VM $vmname | Get-VMGuest | Where-Object {$_.GuestFamily -eq "windowsguest"} Update-Tools -NoReboot -RunAsync | Out-Null
			###$updres = Update-Tools $vmname -RunAsync | Out-Null
        }
        $item.BuildState = "Updated VMWare Tools"
		$item.build_wait_til = ((Get-Date) + (New-TimeSpan -Seconds 0.5))
    }
    Else
    {
        $item.BuildState = "Skipped Updating VMWare Tools, VCenter does not match"
    }
	$item.build_vmtools_complete = $true
    $item
}


Function VMInstantiateGuestCredentials
{
    Param(
        [Parameter(Mandatory=$True)][hashtable]$item
        )
    If ($item.ContainsKey("proc_guestcred") -eq $true) { }
    Else
    {
        #$ok_guestcreds = $false
        If ($item.ContainsKey("guestcred") -eq $true) { }
        Else
        {
            $item.guestcred = $null
            # check for VM creds, BNewb way
            If ($item.ContainsKey("VMLocalCreds") -eq $true)
            {
                $userprofile = (Get-Item env:\USERPROFILE).Value
                $credspath = $userprofile+"\Documents\creds"
                $cmdres = md -f $credspath -ErrorAction SilentlyContinue -Confirm:$false
                If ($item.VMLocalCreds -ne "")
                {
                    $myvmlocalcredspath = $credspath+"\"+$item.VMLocalCreds+".clixml"
                    If (Test-Path $myvmlocalcredspath)
                    {
                        $item.guestcred = Import-PSCredential $myvmlocalcredspath
                    }
                    else
                    {
                        Write-Host "Need Guest VM Credentials $($item.VMLocalCreds)" -ForegroundColor Red -BackgroundColor Gray
                        $item.guestcred = Get-Credential
                        $finfo = Export-PSCredential $item.guestcred $myinfobloxcredspath
                    }
                }
            }
            Else
            {
                ## Doppy Way
                If ($item.ContainsKey("cred_user") -eq $true)
                {
                    If ($item.ContainsKey("cred_pass") -eq $true)
                    {
                        $item.guestcred = New-Object -typename PSCredential -ArgumentList @($item.cred_user, $item.cred_pass)
                    }
                }
            }
        }
        $item.proc_guestcred = $true
    }
    $item
}


Function VMGuestRename
{
    Param(
        [Parameter(Mandatory=$True)][string]$vcenteraddr,
        [Parameter(Mandatory=$True)][hashtable]$item,
        [bool]$testdrive=$true
        )
    
    If ($vcenteraddr -eq $item.vc)
    {
        $ok_guestcreds = $false
        $item = VMInstantiateGuestCredentials $item
        If ($item.ContainsKey("guestcred") -eq $true) { $ok_guestcreds = $true }
        $GUIFail = "Win2016"
        If ($item.ContainsKey("Rename_Source") -eq $true) { $GUIFail = $item.Rename_Source }
        $serverName = $item.vmname
        $RenameME = @"
Rename-Computer -NewName $serverName -Force -Restart
"@
        $RenameMe = $renameme.Replace($GUIFail, $ServerName)
        If ($testdrive -eq $false)
        {
            If ($ok_guestcreds -eq $true)
            {
                If ($testdrive -ne $true) { $invres = Invoke-VMScript -VM $item.vmname -ScriptText $ReNameMe -GuestCredential $item.guestcred -ScriptType Powershell }
            }
            Else { $item.BuildMessages += "Would rename $($ServerName), but no guest credentials" }
        }
        Else { }
        $item.BuildMessages += "Asked Guest to Rename to $($ServerName)"
    }
    $item
}


Function VMGuestReconfigureNIC
{
    Param(
        [Parameter(Mandatory=$True)][string]$vcenteraddr,
        [Parameter(Mandatory=$True)][hashtable]$item,
        [bool]$testdrive=$true
        )
    
    If ($vcenteraddr -eq $item.vc)
    {
        $ok_guestcreds = $false
        $item = VMInstantiateGuestCredentials $item
        If ($item.ContainsKey("guestcred") -eq $true) { $ok_guestcreds = $true }
        $GUIFail = "Win2016"
        If ($item.ContainsKey("Rename_Source") -eq $true) { $GUIFail = $item.Rename_Source }
        $serverName = $item.vmname
        $scriptBlock1 = @"
Get-Netadapter -Name $netadapter | New-NetIPAddress -AddressFamily IPv4 -IPAddress $IPAddress -PrefixLength 23 -Type Unicast -DefaultGateway $Gateway
#Set-VirtualPortGroup -Name $vlan
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet0' -ServerAddresses $primary
Disable-NetAdapterBinding -Name "Ethernet0" -ComponentID ms_tcpip6
Disable-NetAdapterBinding -Name "Ethernet0" -DisplayName "QoS Packet Scheduler"
"@
        $ipaddress = $item.IpAddress
        $scriptBlock1 = $scriptBlock1.Replace('#netadapter#', $netadapter).Replace('#Ipaddress#', $IPAddress).Replace('#Gateway#', $Gateway)
        $scriptBlock2 =@"
Set-NetworkAdapter -NetworkAdapter "Network adapter 1" -NetworkName $vlan -Confirm:$false
"@

        If ($testdrive -eq $false)
        {
            If ($ok_guestcreds -eq $true)
            {
                If ($testdrive -ne $true) { $invres = Invoke-VMScript -VM $item.vmname -ScriptText $scriptBlock1 -GuestCredential $item.guestcred -ScriptType Powershell }
                If ($testdrive -ne $true) { $invres = Invoke-VMScript -VM $item.vmname -ScriptText $scriptBlock2 -GuestCredential $item.guestcred -ScriptType Powershell }
            }
            Else { $item.BuildMessages += "Would Reconfigure NIC $($ServerName), but no guest credentials" }
        }
        Else { }
        $item.BuildMessages += "Asked Guest to Reconfigure NIC $($ServerName)"
    }
    $item
}

Function VMBuildFromISOGuestWork
{
Param(
    [Parameter(Mandatory=$True)][string]$vcenteraddr,
    [Parameter(Mandatory=$True)][hashtable]$item,
    [bool]$testdrive=$true
    )

    If ($item.Pathing -eq "build_ISO")
    {
        $item = VMGuestRename $vcenteraddr $item $testdrive
        $item = VMGuestReconfigureNIC $vcenteraddr $item $testdrive
        $item.build_wait_til = ((Get-Date) + (New-TimeSpan -Seconds 45.0))
    }
    $item = VMWorkWindowsGuestExpandDrives $item $testdrive
    ## in theory we should be able to push salt
    $item.build_guestwork_complete = $true
    $item
}

Function VMBuildFromISO
{
Param(
    [Parameter(Mandatory=$True)][string]$vcenteraddr,
    [Parameter(Mandatory=$True)][hashtable]$item,
    [bool]$testdrive=$true
    )
    $go_for_newvm = 1
    $created_new_vm = 0
    #$go_for_cddrive = 1
    #$go_for_nicwork = 1
    #$go_for_hddwork = 1
    #$go_for_adstuff = 1

    #$go_for_updatedns = 1
    #$go_for_updateaddescription = 1
    #$go_for_sendingemail = 1

    # Map variables
    ## needed to tell if we're trying to build in the right vcenter
    $vc = $null

    ## for new vm name
    $vmhost = $null
    $vmname = $null
    $datastore = $null
    $OSDiskSize = $null
    $OSRamSize = $null
    $GuestIDOS = $null
    $cpucount = $null
    $destfolder = $null
    $vlan = $null
    $note = ""

    ## for attaching CD drive with ISO
    $ISO = $null

    ## for second disk
    $SecondDiskSize = $null
    $SecondDiskDS = $null

    ## OK WHAT ARE THESE
    #$template = $null
    #$ip = $null
    #$subnet = $null
    #$gateway = $null
    #$primary = $null
    #$netadapter = $null
    #$datacenter = $null
    #$domain = $null
    #$path = $null
    #$cred_User = $null
    #$cred_pass = $null
    #$spec = $null
    #$type = $null

    ## these be the 'read-host' vars
    #$name = $null
    #$ipaddress = $null
    #$subnet = $null
    #$gateway = $null
    #$dns1 = $null
    #$dns2 = $null
    #$zonename = $null
    #$dnsserver = $null
    #$clustername = $null
    #$customization = $null
    #$NewDatastore = $null
    #$networkname = $null
    #$ADDescription = $null
    #$targetOU = $null
    #$mycredential = $null
    #$to = $null
    #$from = $null
    #$smtpserver = $null

    # pre-existing vars
    If ($item.ContainsKey("vc") -eq $true) { $vc = $item.vc }
    If ($item.ContainsKey("vmname") -eq $true) { $vmname = $item.vmname }
    If ($item.ContainsKey("vmhost") -eq $true) { $vmhost = $item.vmhost }
    If ($item.ContainsKey("datastore") -eq $true) { $datastore = $item.datastore }
    If ($item.ContainsKey("OSDiskSize") -eq $true) { $OSDiskSize = $item.OSDiskSize }
	If ($item.ContainsKey("Cdrive") -eq $true) { $OSDiskSize = $item.Cdrive }
    If ($item.ContainsKey("OSRamSize") -eq $true) { $OSRamSize = $item.OSRamSize }
	If ($item.ContainsKey("RAM") -eq $true) { $OSRamSize = $item.RAM }
    If ($item.ContainsKey("GuestIDOS") -eq $true) { $GuestIDOS = $item.GuestIDOS }
	If ($item.ContainsKey("NumCPU") -eq $true) { $cpucount = $item.NumCPU }
    If ($item.ContainsKey("CPUcount") -eq $true) { $cpucount = $item.CPUcount }
    If ($item.ContainsKey("folder") -eq $true) { $destfolder = $item.folder }
    If ($item.ContainsKey("vlan") -eq $true) { $vlan = $item.vlan }
    If ($item.ContainsKey("note") -eq $true) { $note = $item.note }
    If ($item.ContainsKey("ISO") -eq $true) { $ISO = $item.ISO }
    If ($item.ContainsKey("SecondDiskSize") -eq $true) { $SecondDiskSize = $item.SecondDiskSize }
	If ($item.ContainsKey("Edrive") -eq $true) { $SecondDiskSize = $item.Edrive }
    If ($item.ContainsKey("SecondDiskDS") -eq $true) { $SecondDiskDS = $item.SecondDiskDS }
    #If ($item.ContainsKey("template") -eq $true) { $template = $item.template }
    #If ($item.ContainsKey("datacenter") -eq $true) { $datacenter = $item.datacenter }
    #If ($item.ContainsKey("ip") -eq $true) { $ip = $item.ip }
    #If ($item.ContainsKey("subnet") -eq $true) { $subnet = $item.subnet }
    #If ($item.ContainsKey("gateway") -eq $true) { $gateway = $item.gateway }
    #If ($item.ContainsKey("primary") -eq $true) { $primary = $item.primary }
    #If ($item.ContainsKey("netadapter") -eq $true) { $netadapter = $item.netadapter }
    
    #If ($item.ContainsKey("domain") -eq $true) { $domain = $item.domain }
    
    #If ($item.ContainsKey("path") -eq $true) { $path = $item.path }
    #If ($item.ContainsKey("Cred_User") -eq $true) { $cred_User = $item.Cred_User }
    #If ($item.ContainsKey("Cred_Pass") -eq $true) { $cred_pass = $item.Cred_Pass }
    #If ($item.ContainsKey("spec") -eq $true) { $spec = $item.spec }
    If ($item.ContainsKey("NetType") -eq $true) { $type = $item.NetType }
    # weird vars
    
    #If ($item.ContainsKey("name") -eq $true) { $name = $item.name }
    #If ($item.ContainsKey("ipaddress") -eq $true) { $ipaddress = $item.ipaddress }
    #If ($item.ContainsKey("dns1") -eq $true) { $dns1 = $item.dns1 }
    #If ($item.ContainsKey("dns2") -eq $true) { $dns2 = $item.dns2 }
    #If ($item.ContainsKey("zonename") -eq $true) { $zonename = $item.zonename }
    #If ($item.ContainsKey("dnsserver") -eq $true) { $dnsserver = $item.dnsserver }
    #If ($item.ContainsKey("clustername") -eq $true) { $clustername = $item.clustername }
    #If ($item.ContainsKey("template") -eq $true) { $template = $item.template }
    #If ($item.ContainsKey("customization") -eq $true) { $customization = $item.customization }
    #If ($item.ContainsKey("NewDatastore") -eq $true) { $NewDatastore = $item.NewDatastore }
    #If ($item.ContainsKey("networkname") -eq $true) { $networkname = $item.networkname }
    #If ($item.ContainsKey("ADDescription") -eq $true) { $ADDescription = $item.ADDescription }
    #If ($item.ContainsKey("targetOU") -eq $true) { $targetOU = $item.targetOU }
    #If ($item.ContainsKey("mycredential") -eq $true) { $mycredential = $item.mycredential }
    #If ($item.ContainsKey("to") -eq $true) { $to = $item.to }
    #If ($item.ContainsKey("from") -eq $true) { $from = $item.from }
    #If ($item.ContainsKey("smtpserver") -eq $true) { $smtpserver = $item.smtpserver }

    If ($vc)
    {
        If ($vcenteraddr -eq $vc)
        {
            If ($vmname)
			{
				If ($vmname.Length -eq 0) { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, No VM Name" }
				Else
				{
					$thisVM = Get-View -Viewtype virtualmachine -Filter @{'name'=$vmname}
					$vmCount = $thisVM | measure
					If ($vmCount.Count -ne 0)
					{
						$go_for_newvm = 0; $item.BuildMessages += "VM Build Skipping, VM Name $($vmname) Already Exists"
						$item.build_init_complete = $true
					}
				}
			}
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, No VM Name" }
			
			
            If ($vmhost)
            {
                If ($vmhost.Length -eq 0)
                {
                    $item = VMWorkGetVMHost $item
                    If ($item.ContainsKey("vmhost") -eq $true) { $vmhost = $item.vmhost }
                }
            }
            Else
            {
				$item = VMWorkGetVMHost $item
                If ($item.ContainsKey("vmhost") -eq $true) { $vmhost = $item.vmhost }
            }
            
            If ($vmhost) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, VMHost Information Missing" }
            
            If ($datastore)
            {
                If ($datastore.Length -eq 0)
                {
                    $item = VMWorkGetDatastore $item
					#Write-Host "GET DATASTORE YOU BALLS a"
                    #Write-Host VMWorkGetDatastore $item
                    If ($item.ContainsKey("datastore") -eq $true) { $datastore = $item.datastore }
                }
            }
            Else
            {
                #$item = VMWorkGetDatastore $item
				#Write-Host "GET DATASTORE YOU BALLS b"
				$item = VMWorkGetDatastore $item
                If ($item.ContainsKey("datastore") -eq $true) { $datastore = $item.datastore }
            }
			
            If ($datastore) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, Datastore Information Missing" }
            
            If ($OSDiskSize) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, OSDiskSize Information Missing" }
            
            If ($OSRamSize) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, OSRamSize Information Missing" }
            
            If ($GuestIDOS) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, GuestIDOS Information Missing" }
            
            If ($cpucount) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, CPUCount Information Missing" }
            
            If ($destfolder) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, DestFolder Information Missing" }
            
            If ($vlan) { }
            Else { $go_for_newvm = 0; $item.BuildMessages += "VM Build Erroring, VLan Information Missing" }
        }
        Else
        {
            $item.BuildMessages += "  VCenter: $($vmname) has $($vc), we are logged in to $($vcenteraddr)"
            $go_for_newvm = 0
        }
    }
    Else
    {
        $item.BuildMessages += "  VCenter: Missing Information"
        $go_for_newvm = 0
    }

    If ($go_for_newvm -eq 1)
    {
        #Write-Host "OK OK OK 3"
        $NewVMParams = @{
            'VMHost'            = $vmhost
            'Name'              = $vmname
            'Datastore'         = $datastore
            'DiskGB'            = $OSDiskSize
            'DiskStorageFormat' = 'Thin'
            'MemoryGB'          = $OSRamSize
            'GuestId'           = $GuestIDOS
            'Version'           = 'v13'
            'NumCpu'            = $cpucount
            'Notes'             = $note
            'Location'          = $destfolder
            'NetworkName'       = $vlan
            }
        If ($testdrive -eq $false)
        {
            $VMname = New-VM @NewVMParams
            $item.BuildMessages += "  New-VM: $($vmname)"
        }
        Else
        {
            $item.BuildMessages += "  New-VM: $($vmname)"
            $item.BuildMessages += "   Test Drive: True"
        }
        $item.BuildMessages += "    DataStore: $($datastore)"
        $item.BuildMessages += "    CPU Count: $($cpucount)"
        $item.BuildMessages += "          RAM: $($OSRamSize) GB"
        $item.BuildMessages += "      OS Disk: $($OSDiskSize) GB"
        $created_new_vm = 1
    }

    If ($created_new_vm -eq 1)
    {
        if ($ISO)
        {
            #Mounting ISO to CD Rom
            $NewCDDriveParams = @{
                'VM'             = $vmname
                'IsoPath'        = $ISO
                'StartConnected' = $true
            }
            If ($testdrive -eq $false)
            {
                $cdres = New-CDDrive @NewCDDriveParams
            }
            Else
            {
                Write-Host "VM Work -> CD Mount $($ISO)"
            }
            $item.BuildMessages += "     ISO Path: $($ISO)"
        }

        #Detecting network driver and Setting to VMXNET3
        If ($testdrive -eq $false)
        {
            $FindNet = Get-VM $vmname | Get-NetworkAdapter -Name "Network adapter 1"
            $netres = Set-Networkadapter -NetworkAdapter $FindNet -Type Vmxnet3 -Confirm:$false
        }
        Else
        {
            Write-Host "VM Work -> Update VM NIC Settings"
        }

        if ($SecondDiskSize)
        {
			If ($SecondDiskDS) { } Else { $SecondDiskDS = $item.datastore }
            If ($SecondDiskDS)
            {
                #Adding Second Disk (D DRIVE)
                $NewHardDiskParams = @{
                    'VM'         = $vmname
                    'CapacityGB' = $SecondDiskSize
                    'Datastore'  = $SecondDiskDS
                }
                If ($testdrive -eq $false)
                {
                    $disadd = New-HardDisk @NewHardDiskParams
                }
                Else
                {
                    Write-Host "VM Work -> Second Disk $($SecondDiskSize) GB"
                }
                $item.BuildMessages += "      Ex Disk: $($SecondDiskSize) GB"
            }
        }

        If ($testdrive -eq $false)
        {
            $startres = Start-VM -VM $vmname
            #$GuestIDOS = "Win2012R2"
            #$vmname = "vw-vM112R2Ag02"
            #Add Tagging to New VM. For easier searching in Vsphere
            #Tags and categories need to be created before assigned.
            #QuickNDirty. This so could be cleaned up.
            #$ErrorActionPreference = 'Continue'
            #If ($GuestIDOS -eq "windows7Server64Guest") {
            #    Get-VM -Name $VMName | New-TagAssignment -Tag 'Win2008R2'
            #} elseif ($GuestIDOS -eq 'windows8Server64Guest') {
            #    Get-VM -Name $VMName | New-TagAssignment -Tag 'Win2012R2'
            #} elseif ($GuestIDOS -eq 'windows9Server64Guest') {
            #    Get-VM -Name $VMName | New-TagAssignment -Tag 'Win2016'
            #} else {
            #    "Not sure what the $GuestIDOS is"
            #}
        }
		$item.build_wait_til = ((Get-Date) + (New-TimeSpan -Seconds 240.0))
        $item.build_init_complete = $true
    }
    #$adht = @{}
    #$adht.ADAdminGroupOU = $path
    #$adht.IPAddress = $ip
    #$adht.DNSZone = $zonename
    #$adht.DNSServer = $dnsserver
    #$adht.ADTargetOU = $path
    #$adht.ADDescription = $ADDescription
    #$adht.SMTPTo = $SMTPTo
    #$adht.SMTPFrom = $SMTPFrom
    #$adht.SMTPServer = $SMTPServer
    
    $item.BuildState = "$vmname -> End of ISO Build"
    ## ADWorkComputer $adht $testdrive
    $item
}


## ok the Brad Newbold way
Function VMBuildFromTemplate
{
    Param(
        [Parameter(Mandatory=$True)][string]$vcenteraddr,
        [Parameter(Mandatory=$True)][hashtable]$item,
        [bool]$testdrive=$true
        )
    ## Fun with CSVs for VM Folders and Network Information
    $networks_csv_path = $null
    $folders_csv_path = $null
    $has_networks = 0
    $has_folders = 0
    # Initial Values here
    If ($item.ContainsKey("networks_csv") -eq $true) { $networks_csv_path = $item.networks_csv }
    If ($item.ContainsKey("folders_csv") -eq $true) { $folders_csv_path = $item.folders_csv }
    #$DeployVMs = Import-Csv new_vms.csv
    $VMNetworks = $null
    $VMFolders = $null
    If ($networks_csv_path) { $VMNetworks = Import-Csv $networks_csv_path }
    If ($folders_csv_path) { $VMFolders = Import-Csv $folders_csv_path }
    If ($VMNetworks) { $has_networks = 1 }
    If ($VMFolders) { $has_folders = 1 }
    #$freshVMs = @()
    #$readyVMs = @()
    #$phase2VMs = @()

    # location of salt install file
    $saltsource = "C:\Installs\Salt-Minion-2017.7.5-AMD64-Setup.exe"
    $sepsource = "C:\Installs\SEP_VHRQID\Win64bit - 12.1.6318.6100 - English\setup.exe"
    $octsource = "C:\Installs\Octopus.Tentacle.3.2.20-x64.msi"
    $nppsource = "C:\Installs\npp.6.9.1.Installer.exe"
    $ncpasource = "C:\Installs\ncpa-1.8.1.exe"
    $domjsource = "mycreds.ps1"
    $domjsource1 = "ExportedDomain.txt"
    $domjsource2 = "ExportedUsername.txt"
    $domjsource3 = "ExportedPassword.txt"
    $domjsource4 = "ExportedOU.txt"

    # NAGIOS and Octopus Variables
    $defaultsaltmaster = "172.27.1.120"
    $defaultnagiostoken = "b41a83a4237b040de07bc5ecea550675"
    # MCG
    $defaultoctotrust = "649FD2A55BCD99B2FE3E1972F1A53FBDE8042463"
    # VWQR
    #$octotrust = "C3FD2256A7FBD57AA789AB2E076E7E726FC83683"

    # Alphabet, because why not
    $alphabet = @("D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z")

    # credentials pre-loaded!
    # TODO: move to encrypted file outside of script, so script requires no interaction

    #Write-Host "Need VM Domain Credentials"
    #$domainCredential = Get-Credential
    $need_infoblox = 0

    $need_localcreds = 0

    $userprofile = (Get-Item env:\USERPROFILE).Value
    $credspath = $userprofile+"\Documents\creds"
    $cmdres = md -f $credspath

    #$item.IpAddress
    #$item.Network
    #$item

    If ($item.ContainsKey("IpAddress") -eq $false)
    {
        $item.IpAddress = ""
    }
    If ($item.ContainsKey("Network") -eq $false)
    {
        $item.Network = ""
    }
    If ($item.ContainsKey("VMLocalCreds") -eq $false)
    {
        $item.VMLocalCreds = ""
    }
    If ($item.ContainsKey("Datastore") -eq $false)
    {
        $item.Datastore = ""
    }
    If ($item.ContainsKey("Name") -eq $false)
    {
        $item.Name = ""
    }
    If ($item.ContainsKey("Domain") -eq $false)
    {
        $item.Domain = ""
    }
    If ($item.ContainsKey("TemplateName") -eq $false)
    {
        $item.TemplateName = ""
    }
    If ($item.ContainsKey("OSCustomization") -eq $false)
    {
        $item.OSCustomization = ""
    }
    If ($item.ContainsKey("ClusterName") -eq $false)
    {
        $item.ClusterName = ""
    }
    If ($item.ContainsKey("SpecVMNet") -eq $false)
    {
        $item.SpecVMNet = ""
    }
    If ($item.ContainsKey("CPUcount") -eq $false)
    {
        $item.CPUcount = ""
    }
    If ($item.ContainsKey("RAM") -eq $false)
    {
        $item.RAM = ""
    }

    

    If (($item.IpAddress -eq "") -and ($item.Network -ne ""))
    {
        $need_infoblox = 1
    }
    # check for VM creds
    If ($item.ContainsKey("VMLocalCreds") -eq $true)
    {
        Write-Host "VMWare Local Cred use"
        If ($item.VMLocalCreds -ne "")
        {
            $myvmlocalcredspath = $credspath+"\"+$item.VMLocalCreds+".clixml"
            If (Test-Path $myvmlocalcredspath)
            {

            }
            Else
            {
                Write-Host "Need $($item.VMLocalCreds) Credentials" -ForegroundColor Red -BackgroundColor Gray
                $vmlocalcred = Get-Credential
                $finfo = Export-PSCredential $vmlocalcred $myvmlocalcredspath
            }
        }
        Else
        {
            $need_localcreds = 1
        }
    }
    Else
    {
        $need_localcreds = 1
    }

    If ($need_infoblox -eq 1)
    {
        $credabbrev = "infobloxapi"
        $myinfobloxcredspath = $credspath+"\"+$credabbrev+".clixml"
        If (Test-Path $myinfobloxcredspath)
        {
            Write-Host "Reading Infoblox Credentials ..." -ForegroundColor Red -BackgroundColor Gray
            $ibcred = Import-PSCredential $myinfobloxcredspath
        }
        else
        {
            Write-Host "Need Infoblox Credentials" -ForegroundColor Red -BackgroundColor Gray
            $ibcred = Get-Credential
            $finfo = Export-PSCredential $ibcred $myinfobloxcredspath
        }
    }

    #this marks the start of event log query, thought it would be good to put it here to allow scalability of the query.
    $startTime = Get-Date
    $require_cooldown = 0

	# configure_network is initially set to 0, which means nothing happens
	$configure_network = 0
	$datastore_name = $item.Datastore
    $ipaddr = $item.IpAddress
	$netname = $item.Network
    $dns1 = ""
    $dns2 = ""
    $ipgateway = ""
    $ipsubnet = ""
	$bailout = 0
	$valid_template = 0
	$valid_customization = 0
	$valid_cluster = 0
	$valid_network = 0
	
	Foreach ($vmnet in $VMNetworks)
	{
		If ($netname -eq $vmnet.Network)
		{
			$dns1 = $vmnet.DNS1
			$dns2 = $vmnet.DNS2
			$ipgateway = $vmnet.Gateway
			$ipsubnet = $vmnet.Subnet
			$configure_network = 1
		}
	}
	$new_vm_fail = 0
    
    # should probably verify if the OSCustomization is valid, and kindly print a message if it isn't
	Try
	{
		$VWSpec = Get-OSCustomizationSpec -Name $item.OSCustomization -ErrorAction Stop
		$valid_customization = 1
		$nicCustomizations = Get-OSCustomizationNicMapping -OSCustomizationSpec $item.OSCustomization
		$nicCount = $nicCustomizations | measure
		While ($nicCount.Count -gt 0)
		{
			Get-OSCustomizationNicMapping -OSCustomizationSpec $item.OSCustomization | Remove-OSCustomizationNicMapping -Confirm:$false
			$nicCustomizations = Get-OSCustomizationNicMapping -OSCustomizationSpec $item.OSCustomization
			$nicCount = $nicCustomizations | measure
		}
	}
	Catch
	{
		$bailout = 1
	}
    
    # should probably verify if the TemplateName is valid, and kindly print a message if it isn't
	Try
	{
		$vmTemplate = Get-Template -Name $item.TemplateName -ErrorAction Stop
		$valid_template = 1
	}
	Catch
	{
		$bailout = 1
	}
    
    # should probably verify if the ClusterName is valid, and kindly print a message if it isn't
	Try
	{
		$Cluster = Get-Cluster -name $item.ClusterName -ErrorAction Stop
		$valid_cluster = 1
	}
	Catch
	{
		$bailout = 1
	}
    
	If ($bailout -eq 0)
	{
		# here is where a new VM would be created if one with a matching name isn't found
		#$thisVM = Get-VM -Name $item.Name
		$thisVM = Get-View -Viewtype virtualmachine -Filter @{'name'=$item.Name}
		$vmCount = $thisVM | measure
		If ($vmCount.Count -eq 0)
		{
			# this is here in case we're actually turning up a new machine!
			If ($configure_network -eq 1)
			{
				If ($ipaddr -eq "")
				{
					# get $ipaddr from InfoBlocks
					Try
					{
						$ipaddr = IB-GetOneIP $ibcred $infobloxurl $netname -ErrorAction Stop
						IB-AddHost $ibcred $infobloxurl $ipaddr ($item.Name+"."+$item.Domain) -ErrorAction Stop
						$valid_network = 1
					}
					Catch
					{
						$bailout = 1
						$configure_network = 0
					}
				}
			}
			Else
			{
				$valid_network = 1
			}
			
			$singleClusterHostName = ""
			$vmHosts = Get-VMHost -Location $item.ClusterName
			Foreach ($vmHost in $vmHosts)
			{
				If ($singleClusterHostName -eq "")
				{
					$singleClusterHostName = $vmHost
				}
				#Write-Host $vmHost.Name
			}
			
			If ($datastore_name -eq "")
			{
				# get a list of available datastores for our cluster?
				$GBneeded = [float]$item.Cdrive + [float]$item.Edrive + 150.0
				$datacenter = Get-Datacenter -Cluster $item.ClusterName
				#$stores = Get-Datastore -Datacenter $datacenter -VMHost $singleClusterHostName | Sort-Object FreeSpaceGB -descending
				$stores = Get-Datastore -VMHost $singleClusterHostName | Sort-Object FreeSpaceGB -descending
				Foreach ($store in $stores)
				{
					If ($datastore_name -eq "")
					{
						If ($store.State -eq "Available")
						{
							If ($store.CapacityGB -gt 1000.0)
							{
								If ($store.FreeSpaceGB -gt $GBneeded)
								{
									If ($item.ClusterName -eq 'VW2.0_NewCage')
									{
										If ($store.Name -eq 'VMFS5_G600_00ad_LUN03 (TEMP)')
										{
										}
										Else
										{
											if ($store.Name -eq 'VMFS5_G600_008b_LUN02')
											{
												$datastore_name = $store.Name
											}
											Elseif ($store.Name -eq 'VMFS5_G600_008a_LUN01')
											{
												$datastore_name = $store.Name
											}
											Else
											{
												$datastore_name = $store.Name
											}
										}
									}
									Else
									{
										$datastore_name = $store.Name
									}
								}
							}
						}
					}
				}
			}
			
			If ($datastore_name -ne "")
			{
				Write-Host "[VM:$($item.Name)] Selected $($datastore_name)"
				$DataStore = Get-Datastore -Name $datastore_name
				$DataStore
				If ($ipaddr -ne "")
				{
					$require_cooldown = 1
					#Get-OSCustomizationSpec $VWSpec | New-OSCustomizationNicMapping -IpMode UseStaticIP -IpAddress $ipaddr -Dns $dns1,$dns2 -DefaultGateway $ipgateway -SubnetMask $ipsubnet
					If ($configure_network -eq 1)
					{
						### Write-Output "Configure Network Un!"
						$vmres = New-OSCustomizationNicMapping -OSCustomizationSpec $item.OSCustomization -Position 1 -IpMode UseStaticIP -IpAddress $ipaddr -Dns $dns1,$dns2 -DefaultGateway $ipgateway -SubnetMask $ipsubnet
					}
					$vmres = New-VM -Name $item.Name -ResourcePool $Cluster -Template $vmTemplate -OSCustomizationSpec $VWSpec.Name -Datastore $DataStore -ErrorAction Stop
					If ($configure_network -eq 1)
					{
						### Write-Output "Configure Network Deux!"
						#Get-OSCustomizationSpec $VWSpec | Get-OSCustomizationNicMapping | Remove-OSCustomizationNicMapping -Confirm:$false
						$vmres = Get-OSCustomizationNicMapping -OSCustomizationSpec $item.OSCustomization | Remove-OSCustomizationNicMapping -ErrorAction SilentlyContinue -Confirm:$false
					}
					Start-Sleep $WAIT_INTERVAL_SECONDS
					$shinyVM = Get-VM -Name $item.Name
					$shinyCT = $shinyVM | measure
					If ($shinyCT.Count -eq 0)
					{
						$new_vm_fail = 1
					}
					Else
					{
						$loopHDD = 1
						While ($loopHDD -eq 1)
						{
							$vmHDs = Get-HardDisk $shinyVM.Name
							$hddCount = $vmHDs | measure
							If ($hddCount.Count -gt 0)
							{
								$loopHDD = 0
							}
							Else
							{
								Write-Host "Disk Count is $($hddCount.Count)"
								Start-Sleep $WAIT_INTERVAL_SECONDS
							}
						}
					}
					if ($new_vm_fail -eq 0)
					{
						$freshVMs += $item.Name
					}
				}
				Else
				{
					$new_vm_fail = 1
				}
			}
			Else
			{
				Write-Host "[VM:$($item.Name)] Unable to select a $($datastore)"
				$new_vm_fail = 1
			}
		}
    
		If ($new_vm_fail -eq 0)
		{
			# bulk of configuration work follows
			$thisVM = Get-VM -Name $item.Name
			$vmView = Get-View -Viewtype virtualmachine -Filter @{'name'=$item.Name}
			$vmCount = $thisVM | measure
			If ($vmCount.Count -eq 1) {
				Write-Host "VM" $item.Name "Exists"
				If ($thisVM.PowerState -eq "PoweredOff") {
					Write-Host "  - Is Powered Off, so we can make changes!"
					
					# first ram and CPU
					$vmRAM = $thisVM.MemoryGB
					$vmCPU = $thisVM.NumCpu
					$vmCoresPerSocket = $thisVM.ExtensionData.Config.Hardware.NumCoresPerSocket
					
					$newCPUcores = [int]$item.CPUcount
					$newCPUcount = [int]$item.CPUcount
					$newRAMcount = [float]$item.RAM
					
					# ok set CPU and Memory if they are not set correctly
					If ($newCPUcount -gt 0) {
						If ($thisVM.NumCpu -ne $newCPUcount) {
							Set-VM -VM $thisVM -NumCpu $newCPUcores -Confirm:$false
						}
					}
					If ($newCPUcores -gt 1)
					{
						If ($vmCoresPerSocket -ne $newCPUcores)
						{
							$spec = New-Object –Type VMware.Vim.VirtualMAchineConfigSpec –Property @{"NumCoresPerSocket" = $newCPUcores}
							$thisVM.ExtensionData.ReconfigVM_Task($spec)
						}
					}
					If ($newRAMcount -gt 0) {
						If ($thisVM.MemoryGB -ne $newRAMcount) {
							Set-VM -VM $thisVM -MemoryGB $newRAMcount -Confirm:$false
						}
					}
					
					# NIC configuration
					$vmNICs = Get-NetworkAdapter -VM $thisVM
					$nicCount = $vmNICs | measure
					# any more than one could be problematic, if it's more than one, let's just leave this alone
					If ($nicCount.Count -eq 1) {
						# yes, just one, but I'd keep the loop in case I eventually add logic to handle multiple NICs, then the object names will fit like a glove
						Foreach ($nic in $vmNICs)
						{
							$targetnet = ""
                            If ($item.ContainsKey("SpecVMNet") -eq $true)
							{
								If ($item.SpecVMNet -eq "")
								{
									Foreach ($vmnet in $VMNetworks)
									{
										If ($item.Network -eq $vmnet.Network)
										{
											$targetnet = $vmnet.VMNet
										}
									}
								}
								Else
								{
									$targetnet = $item.SpecVMNet
								}
							}
							Else
							{
								Foreach ($vmnet in $VMNetworks)
								{
									If ($item.Network -eq $vmnet.Network)
									{
										$targetnet = $vmnet.VMNet
									}
								}
							}
							# really just to connect to the target network, but might as well explicitly connect the NIC
							If ($targetnet -ne "")
							{
								Set-NetworkAdapter -NetworkAdapter $nic -StartConnected:$true -NetworkName $targetnet -Confirm:$false
							}
						}
					}
					
					# HDD work
					# TODO: maybe add some customization for drives beyond 1 and 2
					$vmHDs = Get-HardDisk $item.Name
					$hddCount = $vmHDs | measure
					$targetHDMax = 2
					Write-Host "  - Num Hard Disks" $hddCount.Count
					$driveletters = @()
					#Write-Host "  - Sanity Check : $($item.Object.Properties)"
					#$objMembers = $item | Get-Member
					Foreach ($letter in $alphabet)
					{
                        $drivefield = "$($letter)drive"
                        If ($item.ContainsKey($drivefield) -eq $true)
                        {
                            If ([int]$item.$drivefield -gt 0)
                            {
                                $driveletters += $letter
                                $targetHDMax += 1
                            }
                        }
					}

					Foreach ($hdd in $vmHDs)
					{
						Write-Host "  - HDD Work"
						Write-Host "  - " $hdd.ToString()
						Write-Host "  - Capacity" $hdd.CapacityGB "GB"
						$Info = $vmView.Config.Hardware.Device | where {$_.GetType().Name -eq "VirtualDisk"} | where {$_.DeviceInfo.Label -eq $hdd.Name}
						Write-Host "  - SCSI Controller" $Info.ControllerKey
						Write-Host "  - SCSI ID" $Info.UnitNumber
						$drivenumber = $Info.UnitNumber
						#Write-Host $hdd.DiskType
						#Write-Host $hdd.Persistence
						If ($drivenumber -ne "")
						{
							If ($drivenumber -eq 0)
							{
								Write-Host "  - Check C drive" $item.Cdrive "versus" $hdd.CapacityGB
								#If ([int]$item.Cdrive -gt [int]$hdd.CapacityGB)
								try
								{
									$newKBcap = [int]$item.Cdrive * 1048576
									Write-Host "  - Need to Grow C drive"
									Set-Harddisk -Harddisk $hdd -CapacityKB $newKBcap -confirm:$false
								}
								catch { }
							}
							Else
							{
								If ($hdd.Name.StartsWith("Hard disk ") -eq $true)
								{
									try
									{
										##$drivenumber = $hdd.Name.SubString(10) -as [int]
										$driveletter = $driveletters[$drivenumber - 1]
										$drivefield = "$($driveletter)drive"
										If ([float]$item.$drivefield -gt $hdd.CapacityGB)
										{
											Write-Host "  - Need to Grow $($driveletter) drive"
											$newKBcap = [int]$item.$drivefield * 1048576
											Set-Harddisk -Harddisk $hdd -CapacityKB $newKBcap -confirm:$false
										}
									}
									catch { }
								}
							}
						}
					}
					
					# if there was no E drive and the config asks for one
					If ($hddCount.Count -eq 1)
					{
						Write-Host "  Drive Count -eq 1: $($driveletters)"
						ForEach ($driveletter in $driveletters)
						{
							$drivefield = "$($driveletter)drive"
							Write-Host "  Drive : $($drivefield) - $([int]$item.$drivefield)"
							If ([int]$item.$drivefield -gt 0)
							{
								Write-Host "  - Need to Add $($driveletter) drive"
								$newKBcap = [int]$item.$drivefield * 1048576
								$hdd = New-HardDisk -Persistence Persistent -DiskType Flat -CapacityKB $newKBcap -StorageFormat Thin -Datastore $DataStore -VM $thisVM -Confirm:$false
							}
						}
					}
					
					# ok configured, let's boot the VM
					Start-VM -VM $thisVM
					$item.build_wait_til = ((Get-Date) + (New-TimeSpan -Seconds 240.0))
				}
				Else
				{
					Write-Host "  - Is already powered on, assuming picking up VM creation"
				}
			}
		}
        $item.build_init_complete = $true
	}
	Else
	{
		Write-Host "Bailed Out of Creating VM $($item.name)"
		If ($valid_template -ne 1)
		{
			Write-Host "    Error Using Selected Template: $($item.TemplateName)"
		}
		If ($valid_customization -ne 1)
		{
			Write-Host "    Error Using Selected VM Customization: $($item.OSCustomization)"
		}
		If ($valid_cluster -ne 1)
		{
			Write-Host "    Error Using Selected VM Cluster: $($item.ClusterName)"
		}
		If ($valid_network -ne 1)
		{
			Write-Host "    Error Using Selected Network: $($item.Network)"
		}
    }
    $item
}
