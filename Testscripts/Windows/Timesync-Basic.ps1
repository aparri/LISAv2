# Copyright (c) Microsoft Corporation. All rights reserved.
# Licensed under the Apache License.

<#
.Description
    Verify the time on the VM is in sync with the Hyper-V host.
#>

param([string] $TestParams, [object] $AllVMData)

# Main script body
function Main {
    param (
        $Ipv4,
        $VMPort,
        $VMUserName,
        $VMPassword,
        $RootDir
    )
    $retVal = $False
    $maxTimeDiff = "5"
    $testDelay = "0"

    $params = $TestParams.Split(";")
    foreach($p in $params) {
        $tokens = $p.Trim().Split("=")
        if ($tokens.Length -ne 2) {
            continue
        }

        $val = $tokens[1].Trim()
        switch($tokens[0].Trim().ToLower()) {
            "MaxTimeDiff" { $maxTimeDiff = $val }
            "TestDelay"   { $testDelay   = $val }
            default       { continue }
        }
    }

    # Change the working directory to where we should be
    if (-not (Test-Path $rootDir)) {
        Write-LogErr "The directory `"${rootDir}`" does not exist"
        return "FAIL"
    }
    Set-Location $rootDir

    $retVal = Optimize-TimeSync -Ipv4 $Ipv4 -Port $VMPort -Username $VMUserName `
                -Password $VMPassword
    if (-not $retVal)  {
        Write-LogErr "Failed to config time sync."
        return "FAIL"
    }

    # If the test delay was specified, sleep for a bit
    if ($testDelay -ne "0") {
        Write-LogInfo "Sleeping for ${testDelay} seconds"
        Start-Sleep -Seconds $testDelay
    }

    $diffInSeconds = Get-TimeSync -Ipv4 $Ipv4 -Port $VMPort `
         -Username $VMUserName -Password $VMPassword
    if ($diffInSeconds -and $diffInSeconds -lt $maxTimeDiff) {
        Write-LogInfo "Time is properly synced"
        return "PASS"
    } else {
        Write-LogErr "Time is out of sync!"
        return "FAIL"
    }
}

Main -Ipv4 $AllVMData.PublicIP -VMPort $AllVMData.SSHPort `
    -VMUserName $user -VMPassword $password -RootDir $WorkingDirectory
