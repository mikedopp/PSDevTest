#######################################################################################################
#              Warez Warez Warez                                                                      #
#                                                                                                     #
#                                                                                                     #
#                                                                                                     #
#                                                                                                     #
#######################################################################################################
#Deployment Functions
#Requirments
#Powercli
#PowerShell
#LocalDirectoryToInstall (in this case the Build ISO or location D:\)

#Powershell Module for Destoying Vcenter. **Sarcasm**

<# List of Variables used
        # Map variables
        $template = $item.template
        $OSName = $item.OSName
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
#>






#Adding the Vm too the domain. the param script doesnt like outside creds for some reason.
Function AddDom {
    $DomScript = @'
$cred_pass = "NOPE"
$cred_User = "mediconnect.net\mikedoppsu"
$secure = ConvertTo-SecureString -String $cred_pass -AsPlainText -Force
$nadmin = New-Object -typename PSCredential -ArgumentList @($cred_User, $secure)
$DomainAdd = "mediconnect.net"
Add-Computer -credential $nadmin -domainName $DomainAdd -Force -Restart
'@
    #$DomScript = $DomScript.Replace('#domain#', $domain)
    Invoke-VMScript -VM $VMname -ScriptText $DomScript -GuestCredential $cred -ScriptType Powershell
}

#Move ISO's To datastore on vcenter
#Needs Work. Mostly Variable work.
<#
Function StoreISOVM{
PSdrive
cd vmstore:
\ViaWest\VMFS5_G600_008b_LUN02\
Copy-DatastoreItem -Item D:\<blah>.iso -Destination .\
}
#>

#Mount ISo to Vm
#$vmname = "w1d01-lhbp02"
#N3eds to be cleaned up.
<#
Function MountCDISO{
get-vm $vmname |Get-CDDrive|Where-Object {$_.IsoPath -or $_.HostDevice -or $_.RemoteDevice}| Set-CDDrive -NoMedia -Confirm:$false
Get-VM $vmname |Get-CDDrive| Set-CDdrive -IsoPath "[VMFS5_G600_008b_LUN02] ISO\wsusoffline-w100-x64.iso" -Connected:$true
Invoke-VMScript -VM $vmname -ScriptText "D:\cmd\Doupdate.cmd" -GuestCredential $cred -ScriptType bat
get-vm $vmname |Get-CDDrive|Where-Object {$_.IsoPath -or $_.HostDevice -or $_.RemoteDevice}| Set-CDDrive -NoMedia -Confirm:$false
}
#>

#Add Users to local Domain access to Server.
$ADadmin = Import-PSCredentialFromJson -Path ~\ADadmin.json
Function AddAdmin {
    $ForStuff = @'

             foreach ($item in $Adadmin) {

    Invoke-Command -ScriptBlock{Add-LocalGroupMember -Group $admin -Member ($domain +\+ $ADUG)}  -Credential $admin -ComputerName $vmname
}
'@
    Invoke-VMScript -VM $VMname -ScriptText $ForStuff -GuestCredential $cred -ScriptType Powershell
}




#Cause this is an issue. Shaking my head.
Function SetTime {
    Invoke-VmScript -Vm $vmname -ScriptText "Set-TimeZone -Name 'Mountain Standard Time'" -GuestCredential $cred -ScriptType Powershell
}

#Take Generic windows name to its new name like vw-george-prod01
Function GUIFAIL {
    $GUIFail = $OsName
    $serverName = $vmname
    $RenameME = @"
Rename-Computer -NewName $serverName -Force -Restart
"@
    $RenameMe = $renameme.Replace($GUIFail, $ServerName)
    Invoke-VMScript -VM $vmname -ScriptText $ReNameMe -GuestCredential $cred -ScriptType Powershell
}

#brads favorite varaiable install stuffage. Sorry.
    Function VCPP {
       $InstallVCPP = @'
    Set-Location D:\
$Install = "install"
$VCinstall = "\vcinstall\"
$2008 = "2008\"
$2010 = "2010\"
$2012 = "2012\"
$2013 = "2013\"
$2015 = "2015\vc_redist."
$VCRed = "vcredist_x"

#install Visual C++
Start-Process -FilePath ( $Install + $VCinstall + $2008 + $VCRed + "86.exe") -ArgumentList "/qb"
Start-Process -FilePath ( $Install + $VCinstall + $2008 + $VCRed + "64.exe") -ArgumentList "/qb"
Start-Process -FilePath ( $Install + $VCinstall + $2008 + $VCRed + "86sp1.exe") -ArgumentList "/qb"
Start-Process -FilePath ( $Install + $VCinstall + $2008 + $VCRed + "64sp1.exe") -ArgumentList "/qb"
Start-Process -FilePath ( $Install + $VCinstall + $2010 + $VCRed + "86.exe") -ArgumentList "/passive /norestart"
Start-Process -FilePath ( $Install + $VCinstall + $2010 + $VCRed + "64.exe") -ArgumentList "/passive /norestart"
Start-Process -FilePath ( $Install + $VCinstall + $2012 + $VCRed + "86.exe") -ArgumentList "/passive /norestart"
Start-Process -FilePath ( $Install + $VCinstall + $2012 + $VCRed + "64.exe") -ArgumentList "/passive /norestart"
Start-Process -FilePath ( $Install + $VCinstall + $2013 + $VCRed + "64.exe") -ArgumentList "/install /passive /norestart"
Start-Process -FilePath ( $Install + $VCinstall + $2015 + "x64.exe") -ArgumentList "/install /passive /norestart"
Start-Process -FilePath ( $Install + $VCinstall + $2015 + "x86.exe") -ArgumentList "/install /passive /norestart"
write-host "Visual C++ sucks" -BackgroundColor Green -ForegroundColor Blue
'@

    Invoke-VMScript -VM $VMname -ScriptText $InstallVCPP -GuestCredential $cred -ScriptType Powershell
}

Function VCPP{
    $InstallVCPP = @'
    $FileList = get-childitem -path "C:\BuildFolder\Mount\Win2016\install\VCinstall" -recurse -filter ".exe*" -and "*vcredist_x*"
foreach ($FL_Item in $FileList) {
        start-process $fl_item
    write-host "Visual C++ sucks" -BackgroundColor Green -ForegroundColor Blue
'@
    Invoke-VMScript -VM $VMname -ScriptText $InstallVCPP -GuestCredential $cred -ScriptType Powershell
}


$InstallVCPP =
    $FileList = get-childitem -path "C:\BuildFolder\Mount\Win2016\install\VCinstall\" -recurse -filter ".exe*"
foreach ($FL_Item in $FileList) {
    start-process $fl_item
    write-host "Visual C++ sucks" -BackgroundColor Green -ForegroundColor Blue
}

Function VCPP {
    $VCppInstallScript = {
        $RootPath = "C:\BuildFolder\Mount\Win2016\install\VCinstall"

        $ServerVersion = (Get-WmiObject -ClassName 'Win32_OperatingSystem').Caption -replace '[^\d]'
        $Architecture = if ($env:PROCESSOR_ARCHITECTURE -match '64') {
            'x64'
        }
        else {
            'x86'
        }
        $InstallPath = [PSCustomObject]@{
            2008  = "2008\"
            2010  = "2010\"
            2012  = "2012\"
            2013  = "2013\"
            2015  = "2015\vc_redist."
            VCRed = "vcredist_"
        }

        #install Visual C++
        $Process = switch ($ServerVersion) {
            '2015' {
                Start-Process -FilePath "$RootPath$($InstallPath.$ServerVersion)$Architecture.exe" -ArgumentList "/install /passive /norestart" -PassThru
                break
            }
            '2008' {
                Start-Process -FilePath "$RootPath$($InstallPath.$ServerVersion)$VCRed$Architecture.exe" -ArgumentList "/qb" -PassThru
                Start-Process -FilePath "$RootPath$($InstallPath.$ServerVersion)$VCRed${Architecture}sp1.exe" -ArgumentList "/qb" -PassThru
                break
            }
            '2013' {
                Start-Process -FilePath "$RootPath$($InstallPath.$ServerVersion)$VCRed$Architecture.exe" -ArgumentList "/install /passive /norestart" -PassThru
            }
            default {
                Start-Process -FilePath "$RootPath$($InstallPath.$ServerVersion)$VCRed$Architecture.exe" -ArgumentList "/passive /norestart" -PassThru
            }
        }

        if ($Process.ExitCode -ne 0) {
            Write-Host "Install failed for the following product:" -ForegroundColor Red
            Write-Host @($Process).Where{$_.ExitCode -ne 0}.ProcessName -ForegroundColor Red
            Write-Host "Exit Code(s) were $($Process.ExitCode -join '; ')"
        }
        else {
            write-host "Visual C++ sucks" -BackgroundColor Green -ForegroundColor Blue
        }
    }

    #Invoke-VMScript -VM $VMname -ScriptText $InstallVCPP -GuestCredential $cred -ScriptType Powershell
}






#This only works for Windows 2008R2 and above. Cuz Powershell 3
Function EDrive {
    $Script = @'
Stop-Service -Name ShellHWDetection
Get-Disk |
Where-Object {$_.partitionstyle -eq 'raw'} |
Initialize-Disk -PartitionStyle MBR -PassThru |
New-Partition -AssignDriveLetter -UseMaximumSize |
Format-Volume -FileSystem NTFS -NewFileSystemLabel '--' -Confirm:$false
Start-Service -Name ShellHWDetection
Write-Host 'The script completed successfully' -ForegroundColor Green -BackgroundColor Red
'@

    Invoke-VMScript -VM $VMname -ScriptText $script  -GuestCredential $cred -ScriptType Powershell
}

#windows 7 DriveFormatting and such
Function 7Edrive {
    $7DriveE = @"
        $NewDiskNumber = 1
        $NewDiskLabel = "Drive2"
        $diskpart_command = $Null
        $diskpart_command = @'
            SELECT DISK $NewDiskNumber
            ATTRIBUTES DISK CLEAR READONLY
            ONLINE DISK
            CONVERT MBR
            CREATE PARTITION PRIMARY ALIGN=64
            ASSIGN LETTER=E
            SELECT VOLUME=3
            FORMAT FS=NTFS QUICK LABEL=$NewDiskLabel NOWAIT
            LIST VOLUME
            '@
    $diskpart_command | diskpart
"@

    Invoke-VMScript -VM $vmname -ScriptText $7DriveE  -GuestCredential $cred -ScriptType Powershell
}


# I  hate adding IP's and stuff. So this will do that and remove the ipv6 and QOS crap. Fixes the network adapter for Vmxnet3
Function NetFix {
    $NetScript = @"
 Get-Netadapter -Name $netadapter | New-NetIPAddress -AddressFamily IPv4 -IPAddress $IP -PrefixLength 23 -Type Unicast -DefaultGateway $Gateway
Set-DnsClientServerAddress -InterfaceAlias 'Ethernet0' -ServerAddresses $primary
Disable-NetAdapterBinding -Name 'Ethernet0' -ComponentID ms_tcpip6
Disable-NetAdapterBinding -Name 'Ethernet0' -DisplayName 'QoS Packet Scheduler'
Disable-NetAdapterManagement -Name "Ethernet0" -NoRestart
"@
    $NetScript = $NetScript.Replace('#netadapter#', $netadapter).Replace('#Ipaddress#', $IP).Replace('#Gateway#', $Gateway)
    Invoke-VMScript -VM $vmname -ScriptText $NetScript -GuestCredential $cred -ScriptType Powershell
}

#This fixes the network adapter to be a Vmxnet3 instead of the other crappy stuffs
Function FixNetadapt {
    $FindNet = Get-VM $vmname | Get-NetworkAdapter -Name "Network adapter 1"
    Set-Networkadapter -NetworkAdapter $FindNet -Type Vmxnet3 -Confirm:$false
}

# if only installing on one server use $VM = "<nameOfServer>"

#Function uses the mounted ISO when building the new server. Unfortunately these are hard coded.
#Shamefull Programming. :(
Function DoFix {
    $DoFix = @"
Install-WindowsFeature –name NET-Framework-Core –source D:\sources\sxs\
Install-WindowsFeature -name Web-Server -IncludeManagementTools
Robocopy.exe D:\install\desktopinfo\ C:\'Program Files (x86)'\DesktopInfo /CopyALL
REG IMPORT C:\'Program Files (x86)'\desktopinfo\addtorunlocalmachine.REG
Robocopy.exe "D:\install\ProcessExplorer\" "${env:ProgramFiles(x86)}\ProcessExplorer" /CopyALL
Robocopy.exe "D:install\Utils\" "${env:ProgramFiles(x86)}\Utils" /CopyALL
Robocopy.exe "D:\Install\UTILS\WUMT\" "${env:ProgramFiles(x86)}\UTILS\WUMT" /CopyALL
Start-Process -FilePath "D:\Install\Utils\'HashTab v4.0.0 Setup.exe'" -ArgumentList  "/S"
#import Registry Hacks.
REG IMPORT "D:\install\2012HAPPINESS.reg"
start-process -FilePath C:\'Program Files (x86)'\desktopinfo\desktopinfo.exe

Write-Host 'Added Registry Updates, DesktopInfo, and Various Utils. Your Welcome'
"@
    Invoke-VMScript -VM $vmname -ScriptText $DoFix -GuestCredential $cred -ScriptType Powershell
}

#so Visual C likes to leave crap on the root of C. This is a bandaid to cleanup such crappy stuff
Function CleanUpCrap {
    $CleanUp = @'
#Clean Up Visual C++ Files
Remove-Item C:\eula*.txt, C:\install.res.*.dll , C:\VC_RED.* , C:\vcredist.bmp , c:\m*.dll , c:\*.ini, C:\install.exe
'@
    Invoke-VMScript -VM $VMname -ScriptText $CleanUp -GuestCredential $cred -ScriptType Powershell
}

#Kinda for updating VmTools on the newest vm if the new vmtools isnt already installed.
Function vmupdate {
    Get-VM $vmname | Get-VMGuest | Where-Object {$_.GuestFamily -eq "windowsguest"} `
        | Update-Tools -NoReboot -RunAsync | Out-Null
}

#Move you VM to a better folder in vcenter. Part of cleaning up your act.
Function MoveVM {move-vm -Destination $destfolder -vm $vmname}

