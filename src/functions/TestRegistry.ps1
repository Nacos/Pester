﻿function New-TestRegistry {
    param(
        [Switch]
        $PassThru,

        [string]
        $Path
    )

    if ($Path -notmatch '\S') {
        $directory = New-RandomTempRegistry
    }
    else {
        if (-not (& $SafeCommands['Test-Path'] -Path $Path)) {
            # the pester registry root path HKCU:\Pester is created once
            # and then stays in place, in TestDrive we use system Temp folder,
            # but no such folder exists for registry so we create our own.
            # removing the folder after test run would be possible but we potentially
            # running into conflict with other instance of Pester that is running
            # so keeping it in place is a small price to pay for being able to run
            # parallel pester sessions easily.
            # Also don't use -Force parameter here
            # because that deletes the folder and creates a race condition see
            # https://github.com/pester/Pester/issues/1181
            $null = & $SafeCommands['New-Item'] -Path $Path
        }

        $directory = & $SafeCommands['Get-Item'] $Path
    }

    $DriveName = "TestRegistry"
    #setup the test drive
    if ( -not (& $SafeCommands['Test-Path'] "${DriveName}:\") ) {
        try {
            $null = & $SafeCommands['New-PSDrive'] -Name $DriveName -PSProvider Registry -Root $directory -Scope Global -Description "Pester test registry" -ErrorAction Stop
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'DriveAlreadyExists*') {
                # it can happen that Test-Path reports false even though the drive
                # exists. I don't know why but I see it in "Context Teardown fails"
                # it would be possible to use Get-PsDrive directly for the test but it
                # is about 10ms slower and we do it in every Describe and It so it would
                # quickly add up

                # so if that happens just ignore the error, the goal of this function is to
                # create the testdrive and the testdrive already exists, so all is good.
            }
            else {
                & $SafeCommands['Write-Error'] $_ -ErrorAction 'Stop'
            }
        }
    }

    $directory.PSPath
}

function Clear-TestRegistry {
    param(
        [String[]]$Exclude,
        [string]$TestRegistryPath
    )

    # if the setup fails before we mark test registry added
    # we would be trying to teardown something that does not
    # exist and fail in Get-TestRegistryPath
    if (-not (& $SafeCommands['Test-Path'] "TestRegistry:\")) {
        return
    }

    $path = $TestRegistryPath

    if ($null -ne $path -and (& $SafeCommands['Test-Path'] -Path $Path)) {
        #Get-ChildItem -Exclude did not seem to work with full paths
        & $SafeCommands['Get-ChildItem'] -Recurse -Path $Path |
            & $SafeCommands['Sort-Object'] -Descending  -Property 'PSPath' |
            & $SafeCommands['Where-Object'] { $Exclude -NotContains $_.PSPath } |
            & $SafeCommands['Remove-Item'] -Force -Recurse
    }
}

function Get-TestRegistryChildItem ([string]$TestRegistryPath) {
    & $SafeCommands['Get-ChildItem'] -Recurse -Path $TestRegistryPath |
        & $SafeCommands['Select-Object'] -ExpandProperty PSPath
}

function New-RandomTempRegistry {
    do {
        $tempPath = Get-TempRegistry
        $Path = & $SafeCommands['Join-Path'] -Path $tempPath -ChildPath ([Guid]::NewGuid())
    } until (-not (& $SafeCommands['Test-Path'] -Path $Path -PathType Container))

    try {
        try {
            & $SafeCommands['New-Item'] -Path $Path -ErrorAction Stop
        }
        catch [System.IO.IOException] {
                # when running in parallel this occasionally triggers
                # IOException: No more data is available
                # let's just retry the operation
                & $SafeCommands['Write-Warning'] "IO exception during creating path $path"
                & $SafeCommands['New-Item'] -Path $Path -ErrorAction Stop
        }
    }
    catch [Exception] {
        throw ([Exception]"Was not able to registry key for TestRegistry at '$Path'", ($_.Exception))
    }
}

function Remove-TestRegistry ($TestRegistryPath) {
    $DriveName = "TestRegistry"
    $Drive = & $SafeCommands['Get-PSDrive'] -Name $DriveName -ErrorAction Ignore
    if ($null -eq $Drive) {
        # the drive does not exist, someone must have removed it instead of us,
        # most likely a test that tests pester itself, so we just hope that the
        # one who removed this removed also the contents of it correctly
        return
    }

    $path = $TestRegistryPath

    if ($pwd -like "$DriveName*" ) {
        #will staying in the test drive cause issues?
        #TODO: review this
        & $SafeCommands['Write-Warning'] -Message "Your current path is set to ${pwd}:. You should leave ${DriveName}:\ before leaving Describe."
    }

    if ( $Drive ) {
        $Drive | & $SafeCommands['Remove-PSDrive'] -Force #This should fail explicitly as it impacts future pester runs
    }

    if (& $SafeCommands['Test-Path'] -Path $path -PathType Container) {
        & $SafeCommands['Remove-Item'] -Path $path -Force -Recurse
    }

    if (& $SafeCommands['Get-Variable'] -Name $DriveName -Scope Global -ErrorAction Ignore) {
        & $SafeCommands['Remove-Variable'] -Scope Global -Name $DriveName -Force
    }
}


function Get-TestRegistryPlugin {
    New-PluginObject -Name "TestRegistry" -Start {
        if (& $script:SafeCommands['Test-Path'] TestRegistry:\) {
            & $SafeCommands['Remove-Item'] (& $SafeCommands['Get-PSDrive'] TestRegistry -ErrorAction Stop).Root -Force -Recurse -Confirm:$false -ErrorAction Ignore
            & $SafeCommands['Remove-PSDrive'] TestRegistry
        }
    } -EachBlockSetupStart {
        param($Context)

        if ($Context.Block.IsRoot) {
            # this is top-level block setup test drive
            $path = New-TestRegistry
            $Context.Block.PluginData.Add('TestRegistry', @{
                    TestRegistryAdded   = $true
                    TestRegistryContent = $null
                    TestRegistryPath    = $path
                })
        }
        else {
            $testRegistryPath = $Context.Block.Parent.PluginData.TestRegistry.TestRegistryPath
            $Context.Block.PluginData.Add('TestRegistry', @{
                    TestRegistryAdded   = $false
                    TestRegistryContent = Get-TestRegistryChildItem -TestRegistryPath $testRegistryPath
                    TestRegistryPath    = $testRegistryPath
                })
        }
    } -EachBlockTearDownEnd {

        if ($Context.Block.IsRoot) {
            # this is top-level block remove test drive
            Remove-TestRegistry -TestRegistryPath $Context.Block.PluginData.TestRegistry.TestRegistryPath
        }
        else {
            Clear-TestRegistry -TestRegistryPath $Context.Block.PluginData.TestRegistry.TestRegistryPath -Exclude ( $Context.Block.PluginData.TestRegistry.TestRegistryContent )
        }
    }
}
