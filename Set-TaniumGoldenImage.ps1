<#
    .SYNOPSIS
        Prepares the Tanium Client for capture in a golden image.

    .DESCRIPTION
        Based on the Tanium documentation "Preparing the Tanium Client on a virtual
        desktop infrastructure (VDI) instance":
        https://help.tanium.com/bundle/ug_client_cloud/page/client/os_imaging_virtual.html

        Locates TaniumClient.exe, stops all Tanium services, removes the ComputerId,
        LastGoodServerName and RegistrationCount settings, and applies the standard
        client settings, verifying each change.

        If Tamper Protection is enabled, only SYSTEM can stop the Tanium services.
        When the script is not running as SYSTEM, it re-launches itself through a
        temporary scheduled task running as SYSTEM, waits for it to finish, prints
        the log and removes the task. The task's exit code is passed back to the caller.

        The services are intentionally NOT restarted. Do not start the client or
        reboot the machine before capturing the image, otherwise the client
        re-registers and generates a new ComputerId.

        Options applied:
        - CX.index.FirstScanDistributeOverTimeMinutes = 1140
        - RandomSensorDelayInSeconds                  = 20
        - MaxAgeMultiplier                            = 2
        - MinDistributeOverTimeInSeconds              = 60
        - SaveClientStateIntervalInSeconds            = 1800

    .EXAMPLE
        .\Set-TaniumGoldenImage.ps1

        Run from an elevated PowerShell session. The script elevates itself to
        SYSTEM through a temporary scheduled task where needed.

    .INPUTS
        None.

    .OUTPUTS
        None. Progress is written to the console and to a transcript.

    .NOTES
        Author      : Matthijs Koers
        Requires    : Administrator rights, script saved as a .ps1 file readable by SYSTEM
        Log file    : C:\Windows\Logs\TaniumConfig.log (remove before sealing the image if unwanted)
        Exit codes  : 0 = all options applied and verified, 1 = one or more steps failed
        Services    : All services matching 'Tanium*' are stopped

    .LINK
        https://help.tanium.com/bundle/ug_client_cloud/page/client/os_imaging_virtual.html
#>

#Requires -RunAsAdministrator

#region Variables
    [string]$TaniumExecutable  = 'TaniumClient.exe'
    [string]$TaniumServiceName = 'Tanium*'
    [string]$TaskName          = 'TaniumConfig-TempSystemTask'
    [string]$LogFile           = Join-Path $env:windir '\Logs\TaniumConfig.log'
    [array]$PossibleExecutablePaths = "C:\Program Files (x86)\Tanium\Tanium Client",
                                    "C:\Program Files\Tanium\Tanium Client"

    $OptionsToSet = [ordered]@{
        'CX.index.FirstScanDistributeOverTimeMinutes' = 1140
        'RandomSensorDelayInSeconds'                  = 20
        'MaxAgeMultiplier'                            = 2
        'MinDistributeOverTimeInSeconds'              = 60
        'SaveClientStateIntervalInSeconds'            = 1800
    }

    # Options to remove
    [array]$OptionsToRemove = 'ComputerId',
                              'LastGoodServerName',
                              'RegistrationCount'
#endregion

#region Re-launch as SYSTEM (needed when Tamper Protection is enabled)
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        if (-not $PSCommandPath) { throw "Script must be run from a .ps1 file so it can be re-launched as SYSTEM." }

        Write-Output "Not running as SYSTEM. Creating temporary scheduled task '$TaskName'..."
        Remove-Item -Path $LogFile -Force -ErrorAction SilentlyContinue

        $Action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        $Principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $Settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

        try {
            Register-ScheduledTask -TaskName $TaskName -Action $Action -Principal $Principal -Settings $Settings -Force | Out-Null
            Start-ScheduledTask -TaskName $TaskName

            Start-Sleep -Seconds 3
            $Timeout = (Get-Date).AddMinutes(15)
            while ((Get-ScheduledTask -TaskName $TaskName).State -eq 'Running' -and (Get-Date) -lt $Timeout) {
                Start-Sleep -Seconds 2
            }
            $TaskResult = (Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult
        }
        finally {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
            Write-Output "Scheduled task '$TaskName' removed."
        }

        # Read the log with a shared handle and retry, as the SYSTEM process may still hold the file open
        if (Test-Path $LogFile) {
            $MaxAttempts = 10
            for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
                $Stream = $null
                $Reader = $null
                try {
                    $Stream = [System.IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
                    $Reader = [System.IO.StreamReader]::new($Stream)
                    $Reader.ReadToEnd()
                    break
                }
                catch [System.IO.IOException] {
                    if ($Attempt -eq $MaxAttempts) {
                        Write-Warning "Could not read '$LogFile' after $MaxAttempts attempts: $($_.Exception.Message)"
                    }
                    else {
                        Start-Sleep -Seconds 1
                    }
                }
                finally {
                    if ($Reader) { $Reader.Dispose() }
                    if ($Stream) { $Stream.Dispose() }
                }
            }
        }
        
        exit $TaskResult
    }
#endregion

Start-Transcript -Path $LogFile -Force | Out-Null

#region Functions
    function Set-TaniumClientOption {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Option,
            [Parameter(Mandatory)][string]$Value,
            [string]$Executable = $script:Executable
        )

        if (-not $Executable -or -not (Test-Path -Path $Executable -PathType Leaf)) {
            throw "TaniumClient.exe not found. Set `$Executable or pass -Executable."
        }

        $SetOutput = & $Executable config set $Option $Value 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Setting '$Option' failed (exit code $LASTEXITCODE): $SetOutput"
            return $false
        }

        $ListOutput = & $Executable config list $Option 2>&1
        $Pattern    = '{0}.*{1}' -f [regex]::Escape($Option), [regex]::Escape($Value)

        if ($ListOutput | Select-String -Pattern $Pattern) {
            Write-Verbose "Option '$Option' successfully set to '$Value'."
            return $true
        }

        Write-Warning "Option '$Option' was not confirmed as '$Value'. Current output: $ListOutput"
        return $false
    }

    function Remove-TaniumClientOption {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)][string]$Option,
            [string]$Executable = $script:Executable
        )

        if (-not $Executable -or -not (Test-Path -Path $Executable -PathType Leaf)) {
            throw "TaniumClient.exe not found. Set `$Executable or pass -Executable."
        }

        $RemoveOutput = & $Executable config remove $Option 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Removing '$Option' failed (exit code $LASTEXITCODE): $RemoveOutput"
            return $false
        }

        $ListOutput = & $Executable config list $Option 2>&1
        $Pattern    = '(?m)^\s*{0}\b' -f [regex]::Escape($Option)

        if ($ListOutput | Select-String -Pattern $Pattern) {
            Write-Warning "Option '$Option' still appears in the config: $ListOutput"
            return $false
        }

        Write-Verbose "Option '$Option' successfully removed."
        return $true
    }
#endregion

#region Find executable
    $Executable = $null
    foreach ($Path in $PossibleExecutablePaths) {
        $Candidate = Join-Path -Path $Path -ChildPath $TaniumExecutable
        if (Test-Path -Path $Candidate -PathType Leaf) {
            $Executable = $Candidate
            break
        }
    }

    if (-not $Executable) {
        Stop-Transcript | Out-Null
        throw "$TaniumExecutable was not found in any of the possible paths."
    }
    Write-Output "Found: $Executable"
#endregion

#region Apply configuration
    $Failed = @()

    # Stop all Tanium services. They are intentionally NOT restarted (golden image).
    foreach ($Service in @(Get-Service -Name $TaniumServiceName -ErrorAction SilentlyContinue |
                        Where-Object Status -ne 'Stopped')) {
        Write-Output "Stopping service '$($Service.Name)'..."
        try {
            Stop-Service -Name $Service.Name -Force -ErrorAction Stop
            $Service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(60))
        }
        catch {
            Write-Warning "Could not stop '$($Service.Name)': $_"
            $Failed += "Stop service $($Service.Name)"
        }
    }

    foreach ($Option in $OptionsToRemove) {
        if (-not (Remove-TaniumClientOption -Option $Option -Verbose)) {
            $Failed += "$Option (remove)"
        }
    }

    foreach ($Entry in $OptionsToSet.GetEnumerator()) {
        if (-not (Set-TaniumClientOption -Option $Entry.Key -Value $Entry.Value -Verbose)) {
            $Failed += $Entry.Key
        }
    }
#endregion

#region Result
    Stop-Transcript | Out-Null

    if ($Failed.Count -gt 0) {
        Write-Error "The following items failed: $($Failed -join ', ')"
        exit 1
    }

    Write-Output "Golden image prep complete. Services are stopped; do not start them before capturing the image."
    exit 0
#endregion
