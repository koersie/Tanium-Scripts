<#
	.SYNOPSIS
		Installs the Tanium client and optionally waits for a Tanium policy tag to land.

	.PARAMETER TaniumPolicy
		Name of the policy tag to wait for after install. If omitted or empty, no policy check is done.
		If the tag does not land it will write a warning.

	.PARAMETER WaitForPolicyTimeout
		Maximum number of seconds to wait for the policy tag. Only used when TaniumPolicy is set.

	.PARAMETER Servers
		Tanium server(s) to connect to. Accepts an array or a single comma-separated string.

	.PARAMETER ServerPort
		Tanium server port. Default is 17472.

	.PARAMETER VerbosityLevel
		Client log verbosity level: 1, 41 or 91. Default is 1.

	.PARAMETER InstallerPath
		Path to the Tanium Client installer. Default is SetupClient.exe in the script folder.

	.PARAMETER LogPath
		Path of the transcript. Default is C:\Windows\Logs\TaniumInstall.log.

	.EXAMPLE
		.\Install-Tanium.ps1
		Runs with all default values (no policy check).

	.EXAMPLE
		.\Install-Tanium.ps1 -Servers "tanium1.corp.local,tanium2.corp.local" -TaniumPolicy citrix_image -WaitForPolicyTimeout 600

	.NOTES
        Author      : Matthijs Koers
        Requires    : Administrator rights, SetupClient.exe
        Log file    : C:\Windows\Logs\TaniumInstall.log (remove before sealing the image if unwanted)
        Exit codes  : 0 = installed, 3010 = installed (reboot required), 1 = install failed
                      A policy tag that does not land only writes a warning; it does not change the exit code
#>
[CmdletBinding()]
param(
	[string]$TaniumPolicy = '',

	[ValidateRange(1, 86400)]
	[int]$WaitForPolicyTimeout = 300,

	# Accepts "a,b" as one string or a real array; both end up comma-joined
	[ValidateNotNullOrEmpty()]
	[string[]]$Servers = @('server1.domain.local', 'server2.domain.local'),

	[ValidateRange(1, 65535)]
	[int]$ServerPort = 17472,

	[ValidateSet(1, 41, 91)]
	[int]$VerbosityLevel = 1,

	[string]$InstallerPath = "$PSScriptRoot\SetupClient.exe",

	[string]$LogPath = "$env:windir\Logs\TaniumInstall.log"
)

# Constants (not meant to be passed in)
$TagsRegistryPath = 'HKLM:\SOFTWARE\WOW6432Node\Tanium\Tanium Client\Sensor Data\Tags'
$ServerList = $Servers -join ','

#Start logfile
Start-Transcript -Path $LogPath

try{
	#Install
	$InstallProcess = Start-Process -FilePath $InstallerPath -ArgumentList "/ServerAddress=$ServerList /ServerPort=$ServerPort /LogVerbosityLevel=$VerbosityLevel /S" -NoNewWindow -PassThru -Wait

	#Process results
	If ($InstallProcess.ExitCode -ne 0 -and $InstallProcess.ExitCode -ne 3010) {
		throw "Install failed with exitcode $($InstallProcess.ExitCode)"
	}

	#Wait for policy to land
	if($TaniumPolicy){
		# Same test is used in the loop and the final check
		$PolicyLanded = { $null -ne (Get-ItemProperty -Path $TagsRegistryPath -ErrorAction SilentlyContinue).$TaniumPolicy }

		[int]$i = 0
		While(-not (& $PolicyLanded) -and ($i -lt $WaitForPolicyTimeout)){
			Start-Sleep -Seconds 1
			$i++
		}
		If(& $PolicyLanded){
			Write-Output "Tanium policy: $TaniumPolicy has landed."
		} Else{
			Write-Output "WARNING: Tanium policy $TaniumPolicy has not landed within the set time limit of $WaitForPolicyTimeout seconds."
		}
	}

	Stop-Transcript
	Exit $InstallProcess.ExitCode
} catch{
	Write-Output $_.Exception.Message
	Stop-Transcript
	Exit 1
}
