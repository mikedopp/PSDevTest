param([String]$buildcsv="")
Import-Module VMware.PowerCLI
## include common functions
$thisPath = Split-Path -Path $MyInvocation.MyCommand.Definition -Parent
. ($thisPath + '.\common_vm_build_functions.ps1')
cd $thisPath

$datestr = (get-date).ToString('MMddyyyy')
$active_vcenter = ""
$has_vcenter_conn = 0

If ($buildcsv.Length -eq 0)
{
    Write-Output "Did not specify a build.csv, exiting."
    exit 1
}

If (Test-Path $buildcsv) { }
Else
{
    Write-Output "File $($buildcsv) does not exist!"
    exit 1
}

$vmlist = Import-CSV $buildcsv
$firstrow = $vmlist[0]
if(Get-Member -inputobject $firstrow -name "vc" -Membertype Properties) { $active_vcenter = $firstrow.vc }

$currentVCenter = ($global:defaultviserver).Name
$currentVCenter


If ($active_vcenter -eq "WDC")
{
    Write-Output "Building on WDC"
	If ($currentVCenter)
	{
		If([string]$currentVCenter -eq "wdc-vcenter.mediconnect.net")
		{
			Write-Output " - Already connected."
		}
		Else
		{
			Disconnect-VIServer -Server * -Force -confirm:$false
			$currentVCenter = $null
		}
	}
	If ($currentVCenter) { }
	Else
	{
    . ($thisPath + '.\vcenter_connect_wdc_new.ps1')
	}
}
Elseif ($active_vcenter -eq "EDC")
{
    Write-Output "Building on EDC"
#    . ($thisPath + '.\vcenter_connect_edc_vcenter.ps1')
}
Elseif ($active_vcenter -eq "VXR")
{
    Write-Output "Building on VXR"
#    . ($thisPath + '.\vcenter_connect_wdc_vxrack.ps1')
}
Else
{
    Write-Output "VCenter Unknown: $($active_vcenter)"
    exit 1
}

## thing to be populated with VM build instructions
$vmhashlist = @()
$vmhashes = @{}
$building_complete = $false
$testdrive = $false

## ok let's start worrying ourselves with the job of building
Foreach ($csvrow in $vmlist)
{
    #Write-Output $csvrow
    $ht = HashtableFromCSVRow $csvrow
    $vmname = $null
    If ($ht.ContainsKey("Name") -eq $true) { $vmname = $ht.Name }
    If ($vmname) { } Else { If ($ht.ContainsKey("vmname") -eq $true) { $vmname = $ht.vmname } }
    If ($vmname)
    {
        $ht = VMWorkDeterminePath $ht
        $ht.itercount = 0
        $vmhashlist += $vmname
        $vmhashes.($vmname) = $ht
    }
}

Write-Host "=-=-=-=-= Begin Building Loop =-=-=-=-="
While ($building_complete -eq $false)
{
    $doing_things = $false
	$pause_for_effect = $null
    Foreach ($vmname in $vmhashlist)
    {
        If ($vmhashes.ContainsKey($vmname) -eq $true)
        {
            
            $our_path = $null
            $build_bailout = $null
            $build_init_complete = $null
            $build_vmtools_complete = $null
            $build_adwork_complete = $null
			$wait_til = $null
            If ($vmhashes.($vmname).ContainsKey("Pathing") -eq $true) { $our_path = $vmhashes.($vmname).Pathing }
            If ($vmhashes.($vmname).ContainsKey("build_bailout") -eq $true) { $build_bailout = $vmhashes.($vmname).build_bailout }
            If ($vmhashes.($vmname).ContainsKey("build_init_complete") -eq $true) { $build_init_complete = $vmhashes.($vmname).build_init_complete }
            If ($vmhashes.($vmname).ContainsKey("build_vmtools_complete") -eq $true) { $build_vmtools_complete = $vmhashes.($vmname).build_vmtools_complete }
            If ($vmhashes.($vmname).ContainsKey("build_guestwork_complete") -eq $true) { $build_guestwork_complete = $vmhashes.($vmname).build_guestwork_complete }
            If ($vmhashes.($vmname).ContainsKey("build_adwork_complete") -eq $true) { $build_adwork_complete = $vmhashes.($vmname).build_adwork_complete }
			If ($vmhashes.($vmname).ContainsKey("build_wait_til") -eq $true) { $wait_til = $vmhashes.($vmname).build_wait_til }
            Write-Host " - LOOP For Server $($vmname) |$($build_init_complete)|"
			If (((Get-Date) -ge $wait_til) -eq $true)
			{
				$wait_til = $null
				$vmhashes.($vmname).build_wait_til = $null
			}
			If ($wait_til)
			{
				If ($pause_for_effect)
				{
					If ($wait_til -lt $pause_for_effect)
					{
						$pause_for_effect = $wait_til
					}
				}
				Else
				{
					$pause_for_effect = $wait_til
				}
			}

            ## Initial Build
            If ($build_bailout -eq $true) { }
            Else
            {
                $ready_vmtools = $false
                $ready_guestwork = $false
                $ready_adwork = $false
                If ($build_init_complete)
                {
                    If ($build_vmtools_complete)
					{
                        If ($build_guestwork_complete)
                        {
                            If ($build_adwork_complete)
                            {
                            }
                            Else
                            {
                                $ready_adwork = $true
                            }
                        }
                        Else
                        {
                            $ready_guestwork = $true
                        }
					}
					Else
					{
						$ready_vmtools = $true
					}
					If ($wait_til)
					{
						$ready_vmtools = $false
						$ready_guestwork = $false
						$ready_adwork = $false
					}
                }
                If ($build_init_complete) {  }
                Else
                {
                    If ($our_path)
                    {
                        If ($our_path -eq "build_ISO") { $vmhashes.($vmname) = VMBuildFromISO $active_vcenter $vmhashes.($vmname) $testdrive }
                        ElseIf ($our_path -eq "build_Template") { $vmhashes.($vmname) = VMBuildFromTemplate $active_vcenter $vmhashes.($vmname) $testdrive }
                        Else { $vmhashes.($vmname).build_bailout = $true }
                        $doing_things = $true
                        #ElseIf ($our_path -eq "build_Template") { $vmhashes.($vmname) = VMBuildFudgeADWorkForCAC $active_vcenter $vmhashes.($vmname) $false }
                    }
                    Else
                    {
                        Write-Output "ERR: Unable to determine pathing."
                    }
                    #Write-Output "BuildType -> $($vmhashes.($vmname).Pathing)"
					Write-Output "BuildState: $($vmhashes.($vmname).BuildState)"
                    $vmhashes.($vmname) = Write-BuildMessages $vmhashes.($vmname)
                    #Write-Host $vmhashes.($vmname).build_init_complete
                }
                

                ## VMWare Tools Upgrade
                If ($ready_vmtools -eq $true)
                {
					Write-Host "Ready VMTools"
                    $vmhashes.($vmname) = VMUpdateVMTools $active_vcenter $vmhashes.($vmname) $testdrive
                    Write-Output "BuildState: $($vmhashes.($vmname).BuildState)"
                    $vmhashes.($vmname) = Write-BuildMessages $vmhashes.($vmname)
                    $doing_things = $true
                }

                ## Do some VMGuest Work
                If ($ready_guestwork -eq $true)
                {
					Write-Host "Ready Guestwork"
                    $vmhashes.($vmname) = VMBuildFromISOGuestWork $active_vcenter $vmhashes.($vmname) $testdrive
                    Write-Output "BuildState: $($vmhashes.($vmname).BuildState)"
                    $vmhashes.($vmname) = Write-BuildMessages $vmhashes.($vmname)
                    $doing_things = $true
                }
                
                ## Active Directory Work
                If ($ready_adwork -eq $true)
                {
					Write-Host "Ready ADWork"
                    $vmhashes.($vmname) = VMBuildDoADWork $active_vcenter $vmhashes.($vmname)
                    Write-Output "BuildState: $($vmhashes.($vmname).BuildState)"
                    $vmhashes.($vmname) = Write-BuildMessages $vmhashes.($vmname)
                    $doing_things = $true
                }
                $vmhashes.($vmname).itercount += 1
                If ($vmhashes.($vmname).itercount -gt 5)
                {
                    $vmhashes.($vmname).build_bailout = $true
                }
            }
        }
    }
	If ($pause_for_effect)
	{
		If($doing_things -eq $false)
		{
			# we should wait, and aren't doing anything, so sleep until the pause is over
			$sleep_val = ($pause_for_effect - (Get-Date)).TotalSeconds
			If($sleep_val -gt 0)
			{
				Start-Sleep $sleep_val
			}
			$doing_things = $true
		}
	}
    If ($doing_things -eq $true) { } Else { $building_complete = $true }
}
