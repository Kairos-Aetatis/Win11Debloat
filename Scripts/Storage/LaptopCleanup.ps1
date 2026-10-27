# Organizes loose documents and moves duplicates, long-unopened files, videos,
# images, and large files to an archive folder. Nothing in here is deleted.
# A manifest under Logs/LaptopCleanup records every move so it can be undone.
# Preinstalled apps are removed only when they are known bloat or OEM software
# and Windows has no record of them being opened.

function Test-IsWindowsPlatform {
    # Windows PowerShell 5.1 does not define $IsWindows. PowerShell 6+ does.
    if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
        return [bool]$IsWindows
    }

    return $true
}

function Test-CleanupPathEquals {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }

    $leftFull = [System.IO.Path]::GetFullPath($Left).TrimEnd('\', '/')
    $rightFull = [System.IO.Path]::GetFullPath($Right).TrimEnd('\', '/')
    return $leftFull.Equals($rightFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-CleanupPathUnder {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
    return $pathFull.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-CleanupPathIsExcluded {
    param(
        [string]$Path,
        [string[]]$ExcludeRoots
    )

    foreach ($root in @($ExcludeRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        if (Test-CleanupPathUnder -Path $Path -Root $root) {
            return $true
        }
    }

    return $false
}

function Test-LaptopStorageHomeSafe {
    param(
        [string]$StorageHome,
        [string[]]$ScanRoots
    )

    if ([string]::IsNullOrWhiteSpace($StorageHome)) {
        return $true
    }

    foreach ($root in @($ScanRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }

        # The archive must not be the folder being cleaned, or a parent of one.
        # An archive inside a cleaned folder is allowed and is excluded from the scan.
        if (Test-CleanupPathEquals -Left $root -Right $StorageHome) {
            return $false
        }
        if (Test-CleanupPathUnder -Path $root -Root $StorageHome) {
            return $false
        }
    }

    return $true
}

function Test-StorageHomeUsable {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        return ($null -ne $item -and $item.PSIsContainer)
    }

    $parent = Split-Path -Parent $Path
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return $false
    }

    return Test-Path -LiteralPath $parent -PathType Container
}

function Get-CleanupSkipDirectoryNames {
    return @(
        'node_modules', '.git', '.svn', '.hg', 'AppData', 'Application Data',
        'Windows', 'Program Files', 'Program Files (x86)', 'ProgramData',
        '$Recycle.Bin', 'System Volume Information', 'Win11Debloat',
        '.gemini'
    )
}

function Test-CleanupPathIsGemini {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $current = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $leaf = Split-Path -Leaf $current
        if ($leaf.Equals('.gemini', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent.TrimEnd('\', '/').Equals($current, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $current = $parent.TrimEnd('\', '/')
    }

    return $false
}

# .gemini holds Gemini settings and sign-in files. A path that points at it
# is turned into the Documents folder above it so those files stay put.
function Resolve-LaptopCleanupRoot {
    param(
        [string]$Requested
    )

    $resolved = [pscustomobject]@{
        Path = $null
        Warning = $null
    }
    if ([string]::IsNullOrWhiteSpace($Requested)) {
        return $resolved
    }

    $full = [System.IO.Path]::GetFullPath($Requested)
    if (-not (Test-CleanupPathIsGemini -Path $full)) {
        $resolved.Path = $full
        return $resolved
    }

    $current = $full.TrimEnd('\', '/')
    while (-not (Split-Path -Leaf $current).Equals('.gemini', [System.StringComparison]::OrdinalIgnoreCase)) {
        $current = (Split-Path -Parent $current).TrimEnd('\', '/')
    }

    $parent = Split-Path -Parent $current
    $resolved.Path = $parent
    $resolved.Warning = ".gemini holds Gemini app data, including sign-in files, so it was left in place. Documents in '$parent' will be cleaned instead."
    return $resolved
}

function Test-CleanupSkipDirectory {
    param(
        [string]$Name
    )

    foreach ($skip in (Get-CleanupSkipDirectoryNames)) {
        if ($Name.Equals($skip, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-CleanupSkipFileName {
    param(
        [string]$Name,
        [string]$Extension
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $true
    }

    if ($Name.StartsWith('~$', [System.StringComparison]::Ordinal)) {
        return $true
    }

    $lowerName = $Name.ToLowerInvariant()
    switch ($lowerName) {
        'desktop.ini' { return $true }
        'thumbs.db' { return $true }
        'ehthumbs.db' { return $true }
        '.ds_store' { return $true }
        'ntuser.dat' { return $true }
    }

    switch ($Extension) {
        '.lnk' { return $true }
        '.tmp' { return $true }
        '.partial' { return $true }
        '.crdownload' { return $true }
        '.download' { return $true }
    }

    return $false
}

function Test-CleanupCloudPlaceholder {
    param(
        [int]$Attributes
    )

    # OneDrive online-only files. Moving them would force a full download.
    $recallOnOpen = 0x40000
    $recallOnDataAccess = 0x400000
    return (($Attributes -band ($recallOnOpen -bor $recallOnDataAccess)) -ne 0)
}

function Get-CleanupFiles {
    param(
        [string[]]$ScanRoots,
        [string[]]$ExcludeRoots
    )

    $files = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[string]

    foreach ($root in @($ScanRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) {
            continue
        }
        if (Test-CleanupPathIsExcluded -Path $root -ExcludeRoots $ExcludeRoots) {
            continue
        }
        $pending.Add([System.IO.Path]::GetFullPath($root))
    }

    $index = 0
    while ($index -lt $pending.Count) {
        $dir = $pending[$index]
        $index++

        try {
            $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop)
        }
        catch {
            continue
        }

        foreach ($child in $children) {
            $childPath = $child.FullName
            if (Test-CleanupPathIsExcluded -Path $childPath -ExcludeRoots $ExcludeRoots) {
                continue
            }

            $attributes = 0
            try {
                $attributes = [int]$child.Attributes
            }
            catch {
                $attributes = 0
            }

            $isReparse = (($attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)
            if ($isReparse) {
                continue
            }
            $linkProperty = $child.PSObject.Properties['LinkType']
            if ($linkProperty -and $linkProperty.Value) {
                continue
            }

            if ($child.PSIsContainer) {
                if (Test-CleanupSkipDirectory -Name $child.Name) {
                    continue
                }
                $pending.Add($childPath)
                continue
            }

            $extension = ''
            if ($child.Extension) {
                $extension = $child.Extension.ToLowerInvariant()
            }
            if (Test-CleanupSkipFileName -Name $child.Name -Extension $extension) {
                continue
            }
            if (Test-CleanupCloudPlaceholder -Attributes $attributes) {
                continue
            }
            if ([int64]$child.Length -le 0) {
                continue
            }

            # Capture timestamps before anything reads the file contents. Hashing
            # updates LastAccessTime on volumes that still track it.
            $files.Add([pscustomobject]@{
                FullName = $childPath
                Name = [string]$child.Name
                DirectoryName = [string]$child.DirectoryName
                Length = [int64]$child.Length
                Extension = $extension
                LastWriteTimeUtc = $child.LastWriteTimeUtc
                LastAccessTimeUtc = $child.LastAccessTimeUtc
            })
        }
    }

    return $files.ToArray()
}

function Get-CleanupLastTouchedUtc {
    param(
        $File
    )

    $latest = [datetime]$File.LastWriteTimeUtc
    $access = [datetime]$File.LastAccessTimeUtc
    if ($access -gt $latest) {
        $latest = $access
    }

    return $latest
}

function Get-DocumentCategory {
    param(
        [string]$Extension
    )

    switch ($Extension) {
        '.pdf' { return 'PDFs' }
        '.doc' { return 'Word' }
        '.docx' { return 'Word' }
        '.rtf' { return 'Word' }
        '.odt' { return 'Word' }
        '.xls' { return 'Spreadsheets' }
        '.xlsx' { return 'Spreadsheets' }
        '.xlsm' { return 'Spreadsheets' }
        '.csv' { return 'Spreadsheets' }
        '.ods' { return 'Spreadsheets' }
        '.ppt' { return 'Presentations' }
        '.pptx' { return 'Presentations' }
        '.odp' { return 'Presentations' }
        '.txt' { return 'Text' }
        '.md' { return 'Text' }
        '.tex' { return 'Text' }
        default { return $null }
    }
}

function Test-CleanupImageExtension {
    param([string]$Extension)

    switch ($Extension) {
        '.jpg' { return $true }
        '.jpeg' { return $true }
        '.png' { return $true }
        '.gif' { return $true }
        '.bmp' { return $true }
        '.tif' { return $true }
        '.tiff' { return $true }
        '.heic' { return $true }
        '.heif' { return $true }
        '.webp' { return $true }
        '.raw' { return $true }
        '.cr2' { return $true }
        '.nef' { return $true }
        '.arw' { return $true }
        '.dng' { return $true }
        default { return $false }
    }
}

function Test-CleanupVideoExtension {
    param([string]$Extension)

    switch ($Extension) {
        '.mp4' { return $true }
        '.mkv' { return $true }
        '.mov' { return $true }
        '.avi' { return $true }
        '.wmv' { return $true }
        '.webm' { return $true }
        '.m4v' { return $true }
        '.mpg' { return $true }
        '.mpeg' { return $true }
        '.flv' { return $true }
        '.ts' { return $true }
        '.mts' { return $true }
        default { return $false }
    }
}

function Test-CleanupPathHasSegment {
    param(
        [string]$Path,
        [string]$Segment
    )

    $parts = $Path -split '[\\/]'
    foreach ($part in $parts) {
        if ($part.Equals($Segment, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Get-DuplicateKeeperScore {
    param(
        $File,
        [string[]]$LibraryRoots
    )

    $score = [double]0
    foreach ($root in @($LibraryRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        if (Test-CleanupPathUnder -Path $File.FullName -Root $root) {
            # Keep the copy that already lives in Documents, Pictures, or Videos.
            $score += 100
            break
        }
    }

    if ((Test-CleanupPathHasSegment -Path $File.FullName -Segment 'Downloads') -or
        (Test-CleanupPathHasSegment -Path $File.FullName -Segment 'Desktop')) {
        $score -= 40
    }

    # Newer copies win ties, without outweighing the library preference above.
    $score += ([double]$File.LastWriteTimeUtc.Ticks / 1000000000000000)
    return $score
}

function Get-DuplicateKeeper {
    param(
        [object[]]$Files,
        [string[]]$LibraryRoots
    )

    $best = $null
    $bestScore = [double]0
    foreach ($file in @($Files)) {
        $score = Get-DuplicateKeeperScore -File $file -LibraryRoots $LibraryRoots
        $take = $false
        if ($null -eq $best) {
            $take = $true
        }
        elseif ($score -gt $bestScore) {
            $take = $true
        }
        elseif ($score -eq $bestScore -and $file.FullName.Length -lt $best.FullName.Length) {
            $take = $true
        }
        elseif ($score -eq $bestScore -and $file.FullName.Length -eq $best.FullName.Length -and
            ($file.FullName.CompareTo([string]$best.FullName) -lt 0)) {
            $take = $true
        }

        if ($take) {
            $best = $file
            $bestScore = $score
        }
    }

    return $best
}

function Get-CleanupRelativePath {
    param(
        [string]$FullName,
        [string[]]$ScanRoots
    )

    $bestRoot = $null
    $bestLength = -1
    foreach ($root in @($ScanRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) {
            continue
        }
        if (-not (Test-CleanupPathUnder -Path $FullName -Root $root)) {
            continue
        }
        $fullRoot = [System.IO.Path]::GetFullPath($root).TrimEnd('\', '/')
        if ($fullRoot.Length -gt $bestLength) {
            $bestRoot = $fullRoot
            $bestLength = $fullRoot.Length
        }
    }

    if ($null -eq $bestRoot) {
        return [System.IO.Path]::GetFileName($FullName)
    }

    $fullNamePath = [System.IO.Path]::GetFullPath($FullName)
    $prefix = $bestRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($fullNamePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $fullNamePath.Substring($prefix.Length)
    }

    return [System.IO.Path]::GetFileName($FullName)
}

function Get-UniqueCleanupDestination {
    param(
        [string]$Path,
        [hashtable]$Reserved
    )

    $candidate = $Path
    $index = 2
    while ($Reserved.ContainsKey($candidate.ToLowerInvariant()) -or (Test-Path -LiteralPath $candidate)) {
        $directory = Split-Path -Parent $Path
        $base = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        $extension = [System.IO.Path]::GetExtension($Path)
        $candidate = Join-Path $directory ("{0} ({1}){2}" -f $base, $index, $extension)
        $index++
        if ($index -gt 10000) {
            throw "Could not find a free name for $Path"
        }
    }

    $Reserved[$candidate.ToLowerInvariant()] = $true
    return $candidate
}

function Test-CleanupLooseFile {
    param(
        [string]$DirectoryName,
        [string[]]$LooseDocRoots
    )

    foreach ($root in @($LooseDocRoots)) {
        if (Test-CleanupPathEquals -Left $DirectoryName -Right $root) {
            return $true
        }
    }

    return $false
}

# Builds the move list. This does not change the disk.
function Get-LaptopCleanupPlan {
    param(
        [string[]]$ScanRoots,
        [string[]]$LooseDocRoots,
        [string[]]$LibraryRoots,
        [string]$OrganizedRoot,
        [string]$StorageHome,
        [string[]]$ExcludeRoots,
        [int]$StaleDays = 365,
        [int64]$LargeFileBytes = 104857600,
        [datetime]$Now = ([datetime]::UtcNow),
        [int]$DuplicateMinBytes = 4096,
        [int]$StaleMinBytes = 4096
    )

    $files = @(Get-CleanupFiles -ScanRoots $ScanRoots -ExcludeRoots $ExcludeRoots)
    $bySize = @{}
    foreach ($file in $files) {
        if ($file.Length -lt $DuplicateMinBytes) {
            continue
        }
        $key = [string]$file.Length
        if (-not $bySize.ContainsKey($key)) {
            $bySize[$key] = New-Object System.Collections.Generic.List[object]
        }
        $bySize[$key].Add($file)
    }

    $hashByPath = @{}
    foreach ($group in $bySize.Values) {
        if ($group.Count -lt 2) {
            continue
        }
        foreach ($file in $group) {
            try {
                $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
                $hashByPath[$file.FullName] = $hash
            }
            catch {
                continue
            }
        }
    }

    $byHash = @{}
    foreach ($file in $files) {
        if (-not $hashByPath.ContainsKey($file.FullName)) {
            continue
        }
        $hash = $hashByPath[$file.FullName]
        if (-not $byHash.ContainsKey($hash)) {
            $byHash[$hash] = New-Object System.Collections.Generic.List[object]
        }
        $byHash[$hash].Add($file)
    }

    $duplicateExtras = @{}
    foreach ($hash in @($byHash.Keys)) {
        $group = $byHash[$hash]
        if ($group.Count -lt 2) {
            continue
        }
        $keeper = Get-DuplicateKeeper -Files $group.ToArray() -LibraryRoots $LibraryRoots
        foreach ($file in $group) {
            if ($file.FullName -ne $keeper.FullName) {
                $duplicateExtras[$file.FullName] = $hash
            }
        }
    }

    $assignments = @{}
    foreach ($file in $files) {
        $reason = $null
        if ($StorageHome -and $duplicateExtras.ContainsKey($file.FullName)) {
            $reason = 'duplicate'
        }
        elseif ($StorageHome -and (Test-CleanupVideoExtension -Extension $file.Extension)) {
            $reason = 'video'
        }
        elseif ($StorageHome -and (Test-CleanupImageExtension -Extension $file.Extension)) {
            $reason = 'image'
        }
        elseif ($StorageHome -and $file.Length -ge $LargeFileBytes) {
            $reason = 'large'
        }
        else {
            $lastTouched = Get-CleanupLastTouchedUtc -File $file
            $ageDays = ($Now.ToUniversalTime() - $lastTouched.ToUniversalTime()).TotalDays
            $category = Get-DocumentCategory -Extension $file.Extension
            $isLooseDoc = ($null -ne $category) -and (Test-CleanupLooseFile -DirectoryName $file.DirectoryName -LooseDocRoots $LooseDocRoots)
            if ($StorageHome -and $file.Length -ge $StaleMinBytes -and $ageDays -ge $StaleDays) {
                $reason = 'stale'
            }
            elseif ($isLooseDoc -and $OrganizedRoot -and $file.Length -lt $LargeFileBytes) {
                $reason = 'organize-doc'
            }
        }

        if ($reason) {
            $assignments[$file.FullName] = $reason
        }
    }

    $reserved = @{}
    $moves = New-Object System.Collections.Generic.List[object]
    foreach ($file in $files) {
        if (-not $assignments.ContainsKey($file.FullName)) {
            continue
        }

        $reason = $assignments[$file.FullName]
        $relative = Get-CleanupRelativePath -FullName $file.FullName -ScanRoots $ScanRoots
        $destination = $null
        switch ($reason) {
            'duplicate' {
                $hash = $duplicateExtras[$file.FullName]
                $prefix = $hash.Substring(0, [Math]::Min(8, $hash.Length))
                $destination = Join-Path (Join-Path (Join-Path $StorageHome 'Duplicates') $prefix) $file.Name
            }
            'video' {
                $destination = Join-Path (Join-Path $StorageHome 'Videos') $relative
            }
            'image' {
                $destination = Join-Path (Join-Path $StorageHome 'Pictures') $relative
            }
            'large' {
                $destination = Join-Path (Join-Path $StorageHome 'Large') $relative
            }
            'stale' {
                $year = (Get-CleanupLastTouchedUtc -File $file).Year
                $destination = Join-Path (Join-Path (Join-Path $StorageHome 'Unopened') ([string]$year)) $relative
            }
            'organize-doc' {
                $category = Get-DocumentCategory -Extension $file.Extension
                $destination = Join-Path (Join-Path $OrganizedRoot $category) $file.Name
            }
        }

        if ([string]::IsNullOrWhiteSpace($destination)) {
            continue
        }
        if (Test-CleanupPathEquals -Left $file.FullName -Right $destination) {
            continue
        }

        $destination = Get-UniqueCleanupDestination -Path $destination -Reserved $reserved
        $moves.Add([pscustomobject]@{
            Source = $file.FullName
            Destination = $destination
            Reason = $reason
            Bytes = $file.Length
            Status = 'planned'
        })
    }

    return [pscustomobject]@{
        Moves = $moves.ToArray()
    }
}

function Move-LaptopCleanupFile {
    param(
        [string]$Source,
        [string]$Destination
    )

    $parent = Split-Path -Parent $Destination
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $sourceRoot = [System.IO.Path]::GetPathRoot($Source)
    $destinationRoot = [System.IO.Path]::GetPathRoot($Destination)
    $sameVolume = $sourceRoot.Equals($destinationRoot, [System.StringComparison]::OrdinalIgnoreCase)
    if ($sameVolume) {
        Move-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
        return
    }

    # Across drives, copy first and only remove the original after the size matches.
    Copy-Item -LiteralPath $Source -Destination $Destination -ErrorAction Stop
    $sourceLength = (Get-Item -LiteralPath $Source -Force).Length
    $destinationLength = (Get-Item -LiteralPath $Destination -Force).Length
    if ($sourceLength -ne $destinationLength) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw "Copied file size did not match, so the original was left in place."
    }

    Remove-Item -LiteralPath $Source -Force -ErrorAction Stop
}

function Write-LaptopCleanupJson {
    param(
        $Object,
        [string]$Path
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $json = $Object | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json)
}

function Read-LaptopCleanupJson {
    param(
        [string]$Path
    )

    $json = [System.IO.File]::ReadAllText($Path)
    return $json | ConvertFrom-Json
}

function Get-LaptopCleanupLogRoot {
    if ($script:DefaultLogPath) {
        return Join-Path (Split-Path -Parent $script:DefaultLogPath) 'LaptopCleanup'
    }

    return Join-Path (Join-Path $PSScriptRoot 'Logs') 'LaptopCleanup'
}

function Invoke-LaptopFileMoves {
    param(
        [object[]]$Moves,
        [string]$ManifestPath
    )

    $moveObjects = New-Object System.Collections.Generic.List[object]
    foreach ($move in @($Moves)) {
        $moveObjects.Add($move)
    }

    $manifest = [pscustomobject]@{
        version = 1
        created = [datetime]::UtcNow.ToString('o')
        moves = $moveObjects.ToArray()
        appsRemoved = @()
    }
    Write-LaptopCleanupJson -Object $manifest -Path $ManifestPath

    $index = 0
    $total = $moveObjects.Count
    foreach ($move in $moveObjects) {
        if ($script:CancelRequested) {
            break
        }

        $index++
        if ($script:ApplySubStepCallback) {
            & $script:ApplySubStepCallback "Moving files ($index/$total)" $index $total
        }

        if (-not (Test-Path -LiteralPath $move.Source)) {
            $move.Status = 'skipped'
            Write-LaptopCleanupJson -Object $manifest -Path $ManifestPath
            continue
        }

        if (Test-Path -LiteralPath $move.Destination) {
            $move.Destination = Get-UniqueCleanupDestination -Path $move.Destination -Reserved @{}
        }

        Write-Host ("{0}: {1}" -f $move.Reason, $move.Source)
        try {
            Move-LaptopCleanupFile -Source $move.Source -Destination $move.Destination
            $move.Status = 'moved'
        }
        catch {
            $move.Status = 'failed'
            Write-Host "Could not move $($move.Source). $($_.Exception.Message)" -ForegroundColor Yellow
        }

        # Rewrite after each file so an interrupted cleanup can still be undone.
        $manifest.moves = $moveObjects.ToArray()
        Write-LaptopCleanupJson -Object $manifest -Path $ManifestPath
    }

    return $manifest
}

function Restore-LaptopFileMoves {
    param(
        [string]$ManifestPath
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Write-Host "Cleanup manifest was not found: $ManifestPath" -ForegroundColor Yellow
        return
    }

    $manifest = Read-LaptopCleanupJson -Path $ManifestPath
    $moves = @($manifest.moves)
    $restored = 0
    foreach ($move in $moves) {
        if ($move.status -ne 'moved' -and $move.Status -ne 'moved') {
            continue
        }

        $source = [string]$move.source
        if ([string]::IsNullOrWhiteSpace($source)) {
            $source = [string]$move.Source
        }
        $destination = [string]$move.destination
        if ([string]::IsNullOrWhiteSpace($destination)) {
            $destination = [string]$move.Destination
        }

        if (-not (Test-Path -LiteralPath $destination)) {
            Write-Host "Already gone, left unrestored: $destination" -ForegroundColor Yellow
            continue
        }
        if (Test-Path -LiteralPath $source) {
            Write-Host "Original path is occupied, left the archived copy in place: $source" -ForegroundColor Yellow
            continue
        }

        try {
            Move-LaptopCleanupFile -Source $destination -Destination $source
            $restored++
            Write-Host "Restored $source"
        }
        catch {
            Write-Host "Could not restore $source. $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    Write-Host "Restored $restored file(s)."
}

function Get-LatestLaptopCleanupManifestPath {
    $root = Get-LaptopCleanupLogRoot
    $latestPointer = Join-Path $root 'latest.txt'
    if (Test-Path -LiteralPath $latestPointer) {
        $pointed = ([System.IO.File]::ReadAllText($latestPointer)).Trim()
        if (-not [string]::IsNullOrWhiteSpace($pointed) -and (Test-Path -LiteralPath $pointed)) {
            return $pointed
        }
    }

    if (-not (Test-Path -LiteralPath $root)) {
        return $null
    }

    $files = @(Get-ChildItem -LiteralPath $root -Filter 'manifest-*.json' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($files.Count -eq 0) {
        return $null
    }

    return $files[0].FullName
}

function Get-SafeBloatAppIds {
    param(
        [string]$AppsFilePath
    )

    if (-not (Test-Path -LiteralPath $AppsFilePath)) {
        return @()
    }

    $json = [System.IO.File]::ReadAllText($AppsFilePath) | ConvertFrom-Json
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($app in @($json.Apps)) {
        $selected = $false
        if ($app.PSObject.Properties['SelectedByDefault']) {
            $selected = [bool]$app.SelectedByDefault
        }
        if (-not $selected) {
            continue
        }

        $recommendation = ''
        if ($app.PSObject.Properties['Recommendation'] -and $app.Recommendation) {
            $recommendation = [string]$app.Recommendation
        }
        if ($recommendation -and $recommendation -ne 'safe') {
            continue
        }

        $rawIds = $app.AppId
        $idList = @()
        if ($rawIds -is [System.Array]) {
            $idList = $rawIds
        }
        else {
            $idList = @($rawIds)
        }

        foreach ($id in $idList) {
            $text = ([string]$id).Trim()
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $ids.Add($text)
            }
        }
    }

    return $ids.ToArray()
}

function Test-AppIdMatchesPackage {
    param(
        [string]$PackageName,
        [string]$AppId
    )

    if ([string]::IsNullOrWhiteSpace($PackageName) -or [string]::IsNullOrWhiteSpace($AppId)) {
        return $false
    }

    if ($PackageName.Equals($AppId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return ($PackageName.IndexOf($AppId, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Get-LaptopAppProtectedPatterns {
    return @(
        'Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', 'Microsoft.Windows.Photos',
        'Microsoft.WindowsCalculator', 'Microsoft.WindowsNotepad', 'Microsoft.Paint',
        'Microsoft.ScreenSketch', 'Microsoft.WindowsTerminal', 'Microsoft.SecHealthUI',
        'Microsoft.Windows.SecHealthUI', 'ShellExperienceHost', 'StartMenuExperienceHost',
        'Microsoft.AAD.BrokerPlugin', 'Microsoft.AccountsControl', 'Microsoft.LockApp',
        'Microsoft.Win32WebViewHost', 'Microsoft.Windows.CloudExperienceHost',
        'Microsoft.Windows.Search', 'Microsoft.MicrosoftEdge', 'Microsoft.Edge',
        'Microsoft.GetHelp', 'Microsoft.Xbox.TCUI', 'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.YourPhone', 'Microsoft.UI.Xaml',
        'Microsoft.NET.', 'Microsoft.VCLibs', 'Microsoft.WindowsAppRuntime',
        'Windows.CBS', 'MicrosoftWindows.Client', 'NVIDIA', 'Nvidia', 'Realtek',
        'Intel', 'AMD', 'Dolby', '.NET.Native', 'VCLibs'
    )
}

function Test-NameContainsPattern {
    param(
        [string]$Name,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            continue
        }
        if ($Name.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Get-OemThirdPartyNamePatterns {
    # Package or publisher fragments for OEM software that is not already in Apps.json.
    # Drivers and audio stacks are intentionally absent; those stay installed.
    return @(
        'McAfee', 'WebAdvisor', 'WildTangent', 'SupportAssist', 'DigitalDelivery',
        'HPJumpStart', 'myHP', 'ExpressVPN', 'EclipseManager', 'ActiproSoftware',
        'CyberLink', 'Booking.com', 'WildGames', 'LenovoWelcome', 'DellCustomerConnect'
    )
}

function Test-PackageLaunched {
    param(
        [string]$Name,
        [string[]]$LaunchedTokens
    )

    foreach ($token in @($LaunchedTokens)) {
        if ([string]::IsNullOrWhiteSpace($token)) {
            continue
        }
        if ($token.IndexOf($Name, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Test-PackageProvisioned {
    param(
        [string]$Name,
        [string[]]$ProvisionedNames
    )

    foreach ($provisioned in @($ProvisionedNames)) {
        if ([string]::IsNullOrWhiteSpace($provisioned)) {
            continue
        }
        if ($provisioned.Equals($Name, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        if ($provisioned.StartsWith($Name + '_', [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

# Decides which installed packages are safe to remove.
# Safe-catalog apps are the project's existing default bloat list.
# Third-party packages are removed only when they shipped with the PC, match a
# known OEM name, and have no Windows launch record.
function Select-LaptopAppsToRemove {
    param(
        [string[]]$SafeAppIds,
        [object[]]$InstalledPackages,
        [string[]]$ProvisionedNames,
        [string[]]$LaunchedTokens,
        [bool]$HaveLaunchData,
        [string[]]$ProtectedPatterns,
        [string[]]$OemNamePatterns
    )

    $selected = New-Object System.Collections.Generic.List[object]
    $seen = @{}

    foreach ($package in @($InstalledPackages)) {
        if ($null -eq $package) {
            continue
        }

        $name = [string]$package.Name
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        if ($seen.ContainsKey($name.ToLowerInvariant())) {
            continue
        }
        $seen[$name.ToLowerInvariant()] = $true

        if ($package.IsFramework) {
            continue
        }
        if (Test-NameContainsPattern -Name $name -Patterns $ProtectedPatterns) {
            continue
        }

        $launched = $false
        if ($HaveLaunchData) {
            $launched = Test-PackageLaunched -Name $name -LaunchedTokens $LaunchedTokens
        }
        if ($launched) {
            continue
        }

        $provisioned = Test-PackageProvisioned -Name $name -ProvisionedNames $ProvisionedNames
        $matchesSafe = $false
        foreach ($appId in @($SafeAppIds)) {
            if (Test-AppIdMatchesPackage -PackageName $name -AppId $appId) {
                $matchesSafe = $true
                break
            }
        }

        if ($matchesSafe) {
            # Without launch history, only remove copies that shipped with the image.
            if ($HaveLaunchData -or $provisioned) {
                $selected.Add([pscustomobject]@{
                    Name = $name
                    Reason = 'unused-preinstalled'
                })
            }
            continue
        }

        $publisher = [string]$package.Publisher
        $oemMatch = (Test-NameContainsPattern -Name $name -Patterns $OemNamePatterns) -or
            (Test-NameContainsPattern -Name $publisher -Patterns $OemNamePatterns)
        if ($oemMatch -and $provisioned -and $HaveLaunchData) {
            $selected.Add([pscustomobject]@{
                Name = $name
                Reason = 'third-party-auto'
            })
        }
    }

    return $selected.ToArray()
}

function Get-OemWin32Catalog {
    # Longer names come first so "McAfee LiveSafe" does not fall through to "McAfee".
    return @(
        [pscustomobject]@{ Pattern = 'McAfee LiveSafe'; WingetIds = @('McAfee.LiveSafe') },
        [pscustomobject]@{ Pattern = 'McAfee WebAdvisor'; WingetIds = @('McAfee.WPS') },
        [pscustomobject]@{ Pattern = 'WebAdvisor'; WingetIds = @('McAfee.WPS') },
        [pscustomobject]@{ Pattern = 'McAfee'; WingetIds = @('McAfee.McAfee', 'McAfee.WPS', 'McAfee.LiveSafe') },
        [pscustomobject]@{ Pattern = 'Dell Digital Delivery'; WingetIds = @('Dell.DellDigitalDelivery') },
        [pscustomobject]@{ Pattern = 'HP Support Assistant'; WingetIds = @('HP.HPSupportAssistant') },
        [pscustomobject]@{ Pattern = 'SupportAssist'; WingetIds = @('Dell.SupportAssist') },
        [pscustomobject]@{ Pattern = 'WildTangent'; WingetIds = @('WildTangent.WildTangentGames') },
        [pscustomobject]@{ Pattern = 'Lenovo Now'; WingetIds = @('Lenovo.LenovoNow') },
        [pscustomobject]@{ Pattern = 'ExpressVPN'; WingetIds = @('ExpressVPN.ExpressVPN') },
        [pscustomobject]@{ Pattern = 'Booking.com'; WingetIds = @() }
    )
}

function Select-OemPreinstalledWin32 {
    param(
        [object[]]$Entries,
        [datetime]$WindowsInstallDate,
        [object[]]$Catalog,
        [int]$WindowDays = 14
    )

    # Names that share an OEM install date but are runtimes or drivers, not junk apps.
    $exclude = 'Visual C\+\+|Redistributable|\.NET|Runtime|Driver|NVIDIA|\bIntel\b|\bAMD\b|Realtek|Hotfix|Security Update|Update for'
    $selected = New-Object System.Collections.Generic.List[object]

    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }

        $displayName = [string]$entry.DisplayName
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            continue
        }
        if ($displayName -match $exclude) {
            continue
        }
        if ($null -eq $entry.InstallDate) {
            continue
        }

        $installDate = [datetime]$entry.InstallDate
        $delta = [Math]::Abs(($installDate.Date - $WindowsInstallDate.Date).TotalDays)
        if ($delta -gt $WindowDays) {
            continue
        }

        $match = $null
        foreach ($item in @($Catalog)) {
            if ($displayName.IndexOf([string]$item.Pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                $match = $item
                break
            }
        }
        if ($null -eq $match) {
            continue
        }

        $wingetIds = @($match.WingetIds | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $action = 'report'
        if ($wingetIds.Count -gt 0) {
            $action = 'uninstall'
        }

        $selected.Add([pscustomobject]@{
            DisplayName = $displayName
            WingetIds = $wingetIds
            Action = $action
        })
    }

    return $selected.ToArray()
}

function Get-LaptopCleanupSummary {
    param(
        [object[]]$Moves,
        [object[]]$Apps,
        [object[]]$Win32,
        [string]$StorageHome,
        [string]$OrganizedRoot,
        [string[]]$Warnings
    )

    $groups = @{}
    foreach ($move in @($Moves)) {
        if ($null -eq $move) {
            continue
        }
        $reason = [string]$move.Reason
        if (-not $groups.ContainsKey($reason)) {
            $groups[$reason] = 0
        }
        $groups[$reason] = $groups[$reason] + 1
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Laptop cleanup will:')

    $docCount = 0
    if ($groups.ContainsKey('organize-doc')) {
        $docCount = $groups['organize-doc']
    }
    if ($docCount -gt 0) {
        $lines.Add(("- Sort {0} document(s) into {1}" -f $docCount, $OrganizedRoot))
    }

    $remoteBits = New-Object System.Collections.Generic.List[string]
    $remoteLabels = @(
        [pscustomobject]@{ Key = 'duplicate'; Singular = 'duplicate copy'; Plural = 'duplicate copies' },
        [pscustomobject]@{ Key = 'stale'; Singular = 'long-unopened file'; Plural = 'long-unopened files' },
        [pscustomobject]@{ Key = 'video'; Singular = 'video'; Plural = 'videos' },
        [pscustomobject]@{ Key = 'image'; Singular = 'image'; Plural = 'images' },
        [pscustomobject]@{ Key = 'large'; Singular = 'large file'; Plural = 'large files' }
    )
    foreach ($label in $remoteLabels) {
        if (-not $groups.ContainsKey($label.Key) -or $groups[$label.Key] -le 0) {
            continue
        }
        $count = $groups[$label.Key]
        $word = $label.Plural
        if ($count -eq 1) {
            $word = $label.Singular
        }
        $remoteBits.Add(("{0} {1}" -f $count, $word))
    }
    if ($remoteBits.Count -gt 0) {
        $lines.Add(("- Move {0} to {1}" -f ($remoteBits -join ', '), $StorageHome))
    }

    $appNames = New-Object System.Collections.Generic.List[string]
    foreach ($app in @($Apps)) {
        if ($app -and $app.Name) {
            $appNames.Add([string]$app.Name)
        }
    }
    foreach ($app in @($Win32)) {
        if ($app -and $app.Action -eq 'uninstall' -and $app.DisplayName) {
            $appNames.Add([string]$app.DisplayName)
        }
    }
    if ($appNames.Count -gt 0) {
        $shown = @($appNames | Select-Object -First 8)
        $suffix = ''
        if ($appNames.Count -gt $shown.Count) {
            $suffix = " and $($appNames.Count - $shown.Count) more"
        }
        $lines.Add(("- Remove {0} unused preinstalled app(s): {1}{2}" -f $appNames.Count, ($shown -join ', '), $suffix))
    }

    foreach ($warning in @($Warnings)) {
        if (-not [string]::IsNullOrWhiteSpace($warning)) {
            $lines.Add([string]$warning)
        }
    }

    $lines.Add('Files are moved, not deleted. Put them back later with -UndoLaptopCleanup.')
    return ($lines -join [Environment]::NewLine)
}

function Resolve-LaptopStorageHome {
    param(
        [string]$Requested
    )

    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        return [System.IO.Path]::GetFullPath($Requested)
    }

    if (-not (Test-IsWindowsPlatform)) {
        return $null
    }

    $systemDrive = $env:SystemDrive
    $best = $null
    try {
        $disks = @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop)
    }
    catch {
        $disks = @()
    }

    foreach ($disk in $disks) {
        $driveType = 0
        try { $driveType = [int]$disk.DriveType } catch { $driveType = 0 }
        # 3 = local disk, 4 = network drive. Skip the Windows drive.
        if ($driveType -ne 3 -and $driveType -ne 4) {
            continue
        }
        if ($disk.DeviceID -eq $systemDrive) {
            continue
        }
        $freeSpace = [int64]0
        try { $freeSpace = [int64]$disk.FreeSpace } catch { $freeSpace = 0 }
        if ($freeSpace -lt 5GB) {
            continue
        }
        if ($null -eq $best -or $freeSpace -gt [int64]$best.FreeSpace) {
            $best = $disk
        }
    }

    if ($null -ne $best) {
        return Join-Path ($best.DeviceID + '\') 'LaptopArchive'
    }

    foreach ($oneDrive in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)) {
        if (-not [string]::IsNullOrWhiteSpace($oneDrive) -and (Test-Path -LiteralPath $oneDrive -PathType Container)) {
            return Join-Path $oneDrive 'LaptopArchive'
        }
    }

    return $null
}

function Add-UniqueCleanupPath {
    param(
        $List,
        [string]$Folder,
        [bool]$MustExist = $false
    )

    if ([string]::IsNullOrWhiteSpace($Folder)) {
        return
    }
    if ($MustExist -and -not (Test-Path -LiteralPath $Folder -PathType Container)) {
        return
    }
    if (Test-CleanupPathIsGemini -Path $Folder) {
        return
    }

    $full = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\', '/')
    foreach ($existing in $List) {
        if ($existing.Equals($full, [System.StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }
    $List.Add($full)
}

function Get-LaptopCleanupFolders {
    param(
        [string]$CleanupRoot
    )

    $profilePath = $env:USERPROFILE
    $targetOtherUser = $false
    if ($script:Params -and $script:Params.ContainsKey('User') -and -not [string]::IsNullOrWhiteSpace([string]$script:Params['User'])) {
        $targetOtherUser = $true
        $profilePath = GetUserDirectory -userName $script:Params['User']
    }

    $desktop = $null
    $documents = $null
    $downloads = $null
    $pictures = $null
    $videos = $null
    $music = $null

    if (-not $targetOtherUser -and (Test-IsWindowsPlatform)) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $pictures = [Environment]::GetFolderPath('MyPictures')
        $videos = [Environment]::GetFolderPath('MyVideos')
        $music = [Environment]::GetFolderPath('MyMusic')
        try {
            $shell = New-Object -ComObject Shell.Application
            $downloads = $shell.NameSpace('shell:Downloads').Self.Path
        }
        catch {
            $downloads = Join-Path $profilePath 'Downloads'
        }
    }
    else {
        $desktop = Join-Path $profilePath 'Desktop'
        $documents = Join-Path $profilePath 'Documents'
        $downloads = Join-Path $profilePath 'Downloads'
        $pictures = Join-Path $profilePath 'Pictures'
        $videos = Join-Path $profilePath 'Videos'
        $music = Join-Path $profilePath 'Music'
    }

    $desktopDocuments = $null
    if (-not [string]::IsNullOrWhiteSpace($desktop)) {
        $desktopDocuments = Join-Path $desktop 'Documents'
    }

    # An explicit folder wins. Otherwise a Documents folder that lives on the
    # Desktop is the library when the normal Documents folder is missing.
    $organizeParent = $documents
    if (-not [string]::IsNullOrWhiteSpace($CleanupRoot)) {
        $organizeParent = $CleanupRoot
    }
    elseif ([string]::IsNullOrWhiteSpace($documents) -and -not [string]::IsNullOrWhiteSpace($desktopDocuments)) {
        $organizeParent = $desktopDocuments
    }

    $scan = New-Object System.Collections.Generic.List[string]
    foreach ($folder in @($desktop, $documents, $downloads, $pictures, $videos, $music, $CleanupRoot, $desktopDocuments)) {
        if ([string]::IsNullOrWhiteSpace($folder) -or -not (Test-Path -LiteralPath $folder -PathType Container)) {
            continue
        }
        # Desktop\Documents is already covered by the Desktop walk. Scanning it
        # again would plan the same file twice.
        $alreadyCovered = $false
        $fullFolder = [System.IO.Path]::GetFullPath($folder)
        foreach ($existing in $scan) {
            if ((Test-CleanupPathUnder -Path $fullFolder -Root $existing) -and -not (Test-CleanupPathEquals -Left $fullFolder -Right $existing)) {
                $alreadyCovered = $true
                break
            }
        }
        if ($alreadyCovered) {
            continue
        }
        Add-UniqueCleanupPath -List $scan -Folder $folder -MustExist $true
    }

    $loose = New-Object System.Collections.Generic.List[string]
    foreach ($folder in @($desktop, $documents, $desktopDocuments, $downloads, $CleanupRoot)) {
        Add-UniqueCleanupPath -List $loose -Folder $folder -MustExist $true
    }

    $library = New-Object System.Collections.Generic.List[string]
    foreach ($folder in @($documents, $desktopDocuments, $pictures, $videos, $CleanupRoot)) {
        Add-UniqueCleanupPath -List $library -Folder $folder -MustExist $false
    }

    $organized = $null
    if (-not [string]::IsNullOrWhiteSpace($organizeParent) -and -not (Test-CleanupPathIsGemini -Path $organizeParent)) {
        $organized = Join-Path ([System.IO.Path]::GetFullPath($organizeParent)) 'Organized'
    }

    return [pscustomobject]@{
        ScanRoots = $scan.ToArray()
        LooseDocRoots = $loose.ToArray()
        LibraryRoots = $library.ToArray()
        OrganizedRoot = $organized
        ProfilePath = $profilePath
    }
}

function Get-WindowsInstallDate {
    $props = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $unix = [int64]$props.InstallDate
    $epoch = [datetime]::SpecifyKind([datetime]'1970-01-01', [DateTimeKind]::Utc)
    return $epoch.AddSeconds($unix).ToLocalTime()
}

function Get-InstalledUninstallEntries {
    $results = New-Object System.Collections.Generic.List[object]
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    foreach ($path in $paths) {
        $items = @(Get-ItemProperty -Path $path -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            if ($null -eq $item) {
                continue
            }
            $name = [string]$item.DisplayName
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }
            if ($item.SystemComponent -eq 1) {
                continue
            }
            if ($item.ParentKeyName) {
                continue
            }

            $installDate = $null
            $rawDate = [string]$item.InstallDate
            if ($rawDate -match '^\d{8}$') {
                try {
                    $installDate = [datetime]::ParseExact($rawDate, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture)
                }
                catch {
                    $installDate = $null
                }
            }

            $results.Add([pscustomobject]@{
                DisplayName = $name
                InstallDate = $installDate
            })
        }
    }

    return $results.ToArray()
}

function Get-LaptopLaunchHistory {
    $tokens = New-Object System.Collections.Generic.List[string]
    $haveData = $false
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search\RecentApps',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FeatureUsage\AppSwitched'
    )

    foreach ($key in $keys) {
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }
        $haveData = $true

        if ($key -like '*\AppSwitched') {
            $props = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
            if ($props) {
                foreach ($property in $props.PSObject.Properties) {
                    if ($property.Name -like 'PS*') {
                        continue
                    }
                    $tokens.Add([string]$property.Name)
                }
            }
            continue
        }

        $apps = @(Get-ChildItem -LiteralPath $key -ErrorAction SilentlyContinue)
        foreach ($app in $apps) {
            $props = Get-ItemProperty -LiteralPath $app.PSPath -ErrorAction SilentlyContinue
            if ($null -eq $props) {
                continue
            }
            $launchCount = 0
            if ($props.LaunchCount) {
                try { $launchCount = [int]$props.LaunchCount } catch { $launchCount = 0 }
            }
            if ($launchCount -le 0) {
                continue
            }
            if ($props.AppId) {
                $tokens.Add([string]$props.AppId)
            }
            if ($props.AppPath) {
                $tokens.Add([string]$props.AppPath)
            }
        }
    }

    return [pscustomobject]@{
        HaveData = $haveData
        Tokens = $tokens.ToArray()
    }
}

function Get-LaptopAppsToRemove {
    if (-not (Test-IsWindowsPlatform)) {
        return @()
    }
    if (-not (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue)) {
        return @()
    }

    $safeIds = @()
    if ($script:AppsListFilePath) {
        $safeIds = @(Get-SafeBloatAppIds -AppsFilePath $script:AppsListFilePath)
    }

    $installed = New-Object System.Collections.Generic.List[object]
    try {
        $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    }
    catch {
        $packages = @()
    }
    foreach ($package in $packages) {
        if ($null -eq $package -or [string]::IsNullOrWhiteSpace([string]$package.Name)) {
            continue
        }
        $isFramework = $false
        if ($package.IsFramework) {
            $isFramework = $true
        }
        if ($package.PSObject.Properties['IsResourcePackage'] -and $package.IsResourcePackage) {
            $isFramework = $true
        }
        $installed.Add([pscustomobject]@{
            Name = [string]$package.Name
            Publisher = [string]$package.Publisher
            IsFramework = $isFramework
        })
    }

    $provisioned = New-Object System.Collections.Generic.List[string]
    if (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
        try {
            $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)
        }
        catch {
            $provisionedPackages = @()
        }
        foreach ($package in $provisionedPackages) {
            if ($package.DisplayName) {
                $provisioned.Add([string]$package.DisplayName)
            }
            if ($package.PackageName) {
                $provisioned.Add([string]$package.PackageName)
            }
        }
    }

    $history = Get-LaptopLaunchHistory
    return @(Select-LaptopAppsToRemove `
        -SafeAppIds $safeIds `
        -InstalledPackages $installed.ToArray() `
        -ProvisionedNames $provisioned.ToArray() `
        -LaunchedTokens $history.Tokens `
        -HaveLaunchData ([bool]$history.HaveData) `
        -ProtectedPatterns (Get-LaptopAppProtectedPatterns) `
        -OemNamePatterns (Get-OemThirdPartyNamePatterns))
}

function Get-LaptopOemWin32ToRemove {
    if (-not (Test-IsWindowsPlatform)) {
        return @()
    }

    try {
        $windowsInstall = Get-WindowsInstallDate
        $entries = @(Get-InstalledUninstallEntries)
    }
    catch {
        Write-Host "Could not read installed desktop apps. $($_.Exception.Message)" -ForegroundColor Yellow
        return @()
    }

    return @(Select-OemPreinstalledWin32 -Entries $entries -WindowsInstallDate $windowsInstall -Catalog (Get-OemWin32Catalog))
}

function Uninstall-LaptopWinGetApp {
    param(
        [string]$Id
    )

    if (-not $script:WingetInstalled) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Id)) {
        return $false
    }

    $listOutput = Invoke-NonBlocking -ScriptBlock {
        param($packageId)
        winget list --id $packageId --exact --accept-source-agreements --disable-interactivity
    } -ArgumentList $Id

    $listText = ($listOutput | Out-String)
    $idPattern = '(?im)(^|\s)' + [regex]::Escape($Id) + '(\s|$)'
    if ($listText -notmatch $idPattern) {
        return $false
    }

    Write-Host "Removing preinstalled desktop app $Id..."
    $uninstallOutput = Invoke-NonBlocking -ScriptBlock {
        param($packageId)
        winget uninstall --id $packageId --exact --accept-source-agreements --disable-interactivity
    } -ArgumentList $Id

    $uninstallText = ($uninstallOutput | Out-String)
    if ($uninstallText -match 'Uninstall failed|No installed package|No package found') {
        Write-Host "WinGet could not remove $Id" -ForegroundColor Yellow
        return $false
    }

    return $true
}

function Confirm-LaptopCleanup {
    param(
        [string]$Summary,
        [int]$ActionCount
    )

    if ($ActionCount -le 0) {
        return $false
    }
    if ($WhatIfPreference) {
        Write-Host "WhatIf is set, so nothing will be moved or uninstalled."
        return $false
    }
    if ($script:Params -and ($script:Params.ContainsKey('Silent') -or $script:Params.ContainsKey('ApplyLaptopCleanup'))) {
        return $true
    }
    if ($script:GuiWindow -and (Get-Command Show-MessageBox -ErrorAction SilentlyContinue)) {
        try {
            $result = Show-MessageBox -Message $Summary -Title 'Clean up this laptop?' -Button 'YesNo' -Icon 'Warning' -Width 640
            return ($result -eq 'Yes')
        }
        catch {
            Write-Host "Laptop cleanup was skipped because it could not ask for confirmation." -ForegroundColor Yellow
            return $false
        }
    }

    Write-Host ""
    $answer = Read-Host "Apply this cleanup? (y/n)"
    return ($answer -match '^(y|yes)$')
}

function Invoke-LaptopCleanup {
    if ($script:Params -and $script:Params.ContainsKey('Sysprep')) {
        Write-Host "Laptop cleanup is skipped in Sysprep mode. It cleans a user profile, not the default profile." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $cleanupRoot = $null
    $cleanupWarning = $null
    if ($script:Params -and $script:Params.ContainsKey('CleanupRoot') -and -not [string]::IsNullOrWhiteSpace([string]$script:Params['CleanupRoot'])) {
        $resolvedRoot = Resolve-LaptopCleanupRoot -Requested ([string]$script:Params['CleanupRoot'])
        $cleanupRoot = $resolvedRoot.Path
        $cleanupWarning = $resolvedRoot.Warning
        if ($cleanupRoot -and -not (Test-Path -LiteralPath $cleanupRoot -PathType Container)) {
            $cleanupWarning = "Cleanup folder '$cleanupRoot' was not found."
            $cleanupRoot = $null
        }
    }

    $folders = Get-LaptopCleanupFolders -CleanupRoot $cleanupRoot
    if (@($folders.ScanRoots).Count -eq 0) {
        Write-Host "No personal folders were found to clean." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    $staleDays = 365
    if ($script:Params -and $script:Params.ContainsKey('StaleDays')) {
        $staleDays = [int]$script:Params['StaleDays']
    }
    $largeMb = 100
    if ($script:Params -and $script:Params.ContainsKey('LargeFileMB')) {
        $largeMb = [int]$script:Params['LargeFileMB']
    }

    $requestedHome = $null
    if ($script:Params -and $script:Params.ContainsKey('StorageHome')) {
        $requestedHome = [string]$script:Params['StorageHome']
    }
    $storageHome = Resolve-LaptopStorageHome -Requested $requestedHome
    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($cleanupWarning)) {
        $warnings.Add($cleanupWarning)
    }

    if ($storageHome -and (Test-CleanupPathIsGemini -Path $storageHome)) {
        $warnings.Add('.gemini holds Gemini app data, including sign-in files, so it was not used as the archive.')
        $storageHome = $null
    }
    if ($storageHome -and -not (Test-LaptopStorageHomeSafe -StorageHome $storageHome -ScanRoots $folders.ScanRoots)) {
        $warnings.Add("Archive location '$storageHome' contains a folder that would be cleaned, so it was not used.")
        $storageHome = $null
    }
    if ($storageHome -and -not (Test-StorageHomeUsable -Path $storageHome)) {
        $warnings.Add("Archive location '$storageHome' is not available. Choose a drive, network folder, or OneDrive path with -StorageHome.")
        $storageHome = $null
    }
    if (-not $storageHome) {
        $warnings.Add('No archive location was found. Duplicates, long-unopened files, videos, images, and large files stay where they are. Pass -StorageHome with another drive, a network folder, or an OneDrive path.')
    }

    $exclude = New-Object System.Collections.Generic.List[string]
    if ($storageHome) {
        $exclude.Add($storageHome)
    }
    if ($script:DefaultLogPath) {
        $scriptRoot = Split-Path -Parent (Split-Path -Parent $script:DefaultLogPath)
        if (-not [string]::IsNullOrWhiteSpace($scriptRoot)) {
            $exclude.Add($scriptRoot)
        }
    }

    Write-Host "> Cleaning up documents, media, duplicates, and unused preinstalled apps..."
    Write-Host "Scanning personal folders..."
    $plan = Get-LaptopCleanupPlan `
        -ScanRoots $folders.ScanRoots `
        -LooseDocRoots $folders.LooseDocRoots `
        -LibraryRoots $folders.LibraryRoots `
        -OrganizedRoot $folders.OrganizedRoot `
        -StorageHome $storageHome `
        -ExcludeRoots $exclude.ToArray() `
        -StaleDays $staleDays `
        -LargeFileBytes ([int64]$largeMb * 1MB)

    $apps = @(Get-LaptopAppsToRemove)
    $win32 = @(Get-LaptopOemWin32ToRemove)
    $summary = Get-LaptopCleanupSummary `
        -Moves $plan.Moves `
        -Apps $apps `
        -Win32 $win32 `
        -StorageHome $storageHome `
        -OrganizedRoot $folders.OrganizedRoot `
        -Warnings $warnings.ToArray()

    Write-Host $summary
    Write-Host ""

    foreach ($reported in @($win32 | Where-Object { $_ -and $_.Action -eq 'report' })) {
        Write-Host "Found preinstalled $($reported.DisplayName). It was left installed because it has no confirmed WinGet package."
    }

    $uninstallApps = @($win32 | Where-Object { $_ -and $_.Action -eq 'uninstall' })
    $actionCount = @($plan.Moves).Count + @($apps).Count + $uninstallApps.Count
    if ($actionCount -eq 0) {
        Write-Host "Nothing to clean up."
        Write-Host ""
        return
    }

    $logRoot = Get-LaptopCleanupLogRoot
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    try {
        $previewPath = Join-Path $logRoot ("preview-{0}.json" -f $stamp)
        Write-LaptopCleanupJson -Object ([pscustomobject]@{
            summary = $summary
            moves = @($plan.Moves)
            apps = @($apps | ForEach-Object { $_.Name })
            win32 = @($uninstallApps | ForEach-Object { $_.DisplayName })
        }) -Path $previewPath
        Write-Host "Preview saved to $previewPath"
    }
    catch {
        Write-Host "Could not write the cleanup preview. $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if (-not (Confirm-LaptopCleanup -Summary $summary -ActionCount $actionCount)) {
        Write-Host "Laptop cleanup was not applied."
        Write-Host ""
        return
    }

    $manifest = $null
    if (@($plan.Moves).Count -gt 0) {
        $manifestPath = Join-Path $logRoot ("manifest-{0}.json" -f $stamp)
        $manifest = Invoke-LaptopFileMoves -Moves $plan.Moves -ManifestPath $manifestPath
        $movedCount = @($manifest.moves | Where-Object { $_.Status -eq 'moved' }).Count
        if ($movedCount -gt 0) {
            $latestPath = Join-Path $logRoot 'latest.txt'
            [System.IO.File]::WriteAllText($latestPath, $manifestPath)
        }
        Write-Host "Cleanup manifest saved to $manifestPath"
    }

    $removedApps = New-Object System.Collections.Generic.List[string]
    if (@($apps).Count -gt 0) {
        $appIds = @($apps | ForEach-Object { $_.Name })
        Write-Host "> Removing unused preinstalled apps..."
        RemoveApps $appIds
        foreach ($appId in $appIds) {
            $removedApps.Add($appId)
        }
    }

    foreach ($app in $uninstallApps) {
        if ($script:CancelRequested) {
            break
        }
        $removed = $false
        foreach ($wingetId in @($app.WingetIds)) {
            if (Uninstall-LaptopWinGetApp -Id $wingetId) {
                $removedApps.Add([string]$wingetId)
                $removed = $true
                break
            }
        }
        if (-not $removed) {
            Write-Host "Left installed, WinGet did not remove it: $($app.DisplayName)" -ForegroundColor Yellow
        }
    }

    if ($manifest) {
        $manifest.appsRemoved = $removedApps.ToArray()
        Write-LaptopCleanupJson -Object $manifest -Path (Join-Path $logRoot ("manifest-{0}.json" -f $stamp))
    }

    Write-Host ""
}

function Restore-LaptopCleanup {
    $manifestPath = Get-LatestLaptopCleanupManifestPath
    if ([string]::IsNullOrWhiteSpace($manifestPath)) {
        Write-Host "No laptop cleanup manifest was found. Files were not moved back." -ForegroundColor Yellow
        Write-Host ""
        return
    }

    Write-Host "> Putting files back from the last laptop cleanup..."
    Write-Host $manifestPath
    Restore-LaptopFileMoves -ManifestPath $manifestPath
    Write-Host "Removed apps are not reinstalled by this step. Install those again from the Microsoft Store or from the app vendor."
    Write-Host ""
}
