# Exercises the laptop cleanup decisions against a fake user profile.
# Run: pwsh -NoProfile -File Scripts/Storage/Test-LaptopCleanup.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'LaptopCleanup.ps1')

$failures = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        $failures.Add($Message)
        Write-Host "FAIL: $Message" -ForegroundColor Red
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        $failures.Add("$Message (expected '$Expected', got '$Actual')")
        Write-Host "FAIL: $Message (expected '$Expected', got '$Actual')" -ForegroundColor Red
    }
}

function Set-OldTimestamp {
    param(
        [string]$Path,
        [int]$DaysAgo
    )

    $when = [datetime]::UtcNow.AddDays(-1 * $DaysAgo)
    $item = Get-Item -LiteralPath $Path
    $item.LastWriteTimeUtc = $when
    try {
        $item.LastAccessTimeUtc = $when
    }
    catch {
        # Some filesystems reject access-time updates. LastWriteTime still ages the file
        # when access time is older than or equal to the write time.
    }
}

$temp = Join-Path ([System.IO.Path]::GetTempPath()) ("laptop-cleanup-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null

try {
    $desktop = Join-Path $temp 'Desktop'
    $documents = Join-Path $temp 'Documents'
    $downloads = Join-Path $temp 'Downloads'
    $pictures = Join-Path $temp 'Pictures'
    $videos = Join-Path $temp 'Videos'
    $documentsSub = Join-Path $documents 'Sub'
    $archiveHold = Join-Path $desktop 'ArchiveHold'
    $nodeModules = Join-Path $desktop 'node_modules'
    $storageHome = Join-Path $temp 'LaptopArchive'

    foreach ($dir in @($desktop, $documents, $downloads, $pictures, $videos, $documentsSub, $archiveHold, $nodeModules, $storageHome)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    $sharedNotes = "These are the notes that should stay once and archive the extra copy.`r`n"
    $notes = Join-Path $desktop 'notes.txt'
    $notesCopy = Join-Path $downloads 'notes-copy.txt'
    [System.IO.File]::WriteAllText($notes, $sharedNotes)
    [System.IO.File]::WriteAllText($notesCopy, $sharedNotes)
    Set-OldTimestamp -Path $notes -DaysAgo 1
    Set-OldTimestamp -Path $notesCopy -DaysAgo 10

    $report = Join-Path $downloads 'report.pdf'
    [System.IO.File]::WriteAllText($report, "Quarterly report that still gets opened.")
    $budget = Join-Path $documents 'budget.csv'
    [System.IO.File]::WriteAllText($budget, "month,amount`r`nJanuary,10`r`n")
    $kept = Join-Path $documentsSub 'kept.txt'
    [System.IO.File]::WriteAllText($kept, "This file is already filed away and was opened recently.")

    $old = Join-Path $desktop 'old.txt'
    [System.IO.File]::WriteAllText($old, "This note has not been opened for a long time.")
    Set-OldTimestamp -Path $old -DaysAgo 400
    $ancient = Join-Path $documentsSub 'ancient.pdf'
    [System.IO.File]::WriteAllText($ancient, "Archived ages ago from a subfolder.")
    Set-OldTimestamp -Path $ancient -DaysAgo 800

    $photo = Join-Path $desktop 'photo.jpg'
    [System.IO.File]::WriteAllBytes($photo, [byte[]](1..40))
    $shot = Join-Path $pictures 'shot.png'
    [System.IO.File]::WriteAllBytes($shot, [byte[]](41..90))
    $already = Join-Path $archiveHold 'already.jpg'
    [System.IO.File]::WriteAllBytes($already, [byte[]](91..120))

    $clipBytes = [byte[]](121..180)
    $clip = Join-Path $videos 'clip.mp4'
    $movie = Join-Path $desktop 'movie.mp4'
    [System.IO.File]::WriteAllBytes($clip, $clipBytes)
    [System.IO.File]::WriteAllBytes($movie, $clipBytes)

    $big = Join-Path $desktop 'big.bin'
    [System.IO.File]::WriteAllBytes($big, (New-Object byte[] 250))
    [System.IO.File]::WriteAllText((Join-Path $desktop 'desktop.ini'), "ignored")
    [System.IO.File]::WriteAllText((Join-Path $desktop 'Thumbs.db'), "ignored")
    [System.IO.File]::WriteAllText((Join-Path $nodeModules 'secret.txt'), "do not take files out of node_modules")

    $symlinkCreated = $false
    $symlink = Join-Path $desktop 'linked.txt'
    try {
        New-Item -ItemType SymbolicLink -Path $symlink -Target $notes -ErrorAction Stop | Out-Null
        $symlinkCreated = $true
    }
    catch {
        Write-Host "Symlink fixture was not created: $($_.Exception.Message)"
    }

    Assert-True (Test-LaptopStorageHomeSafe -StorageHome $storageHome -ScanRoots @($desktop, $documents)) "Archive beside the profile is safe"
    Assert-True (-not (Test-LaptopStorageHomeSafe -StorageHome $temp -ScanRoots @($desktop))) "Archive that contains a scanned folder is rejected"
    Assert-True (-not (Test-LaptopStorageHomeSafe -StorageHome $desktop -ScanRoots @($desktop))) "Archive equal to a scanned folder is rejected"
    Assert-True (Test-LaptopStorageHomeSafe -StorageHome $archiveHold -ScanRoots @($desktop)) "Archive inside a scanned folder is allowed"

    $plan = Get-LaptopCleanupPlan `
        -ScanRoots @($desktop, $documents, $downloads, $pictures, $videos) `
        -LooseDocRoots @($desktop, $documents, $downloads) `
        -LibraryRoots @($documents, $pictures, $videos) `
        -OrganizedRoot (Join-Path $documents 'Organized') `
        -StorageHome $storageHome `
        -ExcludeRoots @($archiveHold) `
        -StaleDays 365 `
        -LargeFileBytes 200 `
        -DuplicateMinBytes 4 `
        -StaleMinBytes 4 `
        -Now ([datetime]::UtcNow)

    $bySource = @{}
    foreach ($move in @($plan.Moves)) {
        $bySource[[System.IO.Path]::GetFileName($move.Source)] = $move
    }

    Assert-Equal $bySource['notes.txt'].Reason 'organize-doc' 'Newer loose notes are organized'
    Assert-True ($bySource['notes.txt'].Destination -match 'Organized') 'Organized notes stay in Documents'
    Assert-True ($bySource['notes.txt'].Destination -match 'Text') 'Text notes get a Text folder'
    Assert-Equal $bySource['report.pdf'].Reason 'organize-doc' 'Loose PDFs are organized'
    Assert-True ($bySource['report.pdf'].Destination -match 'PDFs') 'PDFs get a PDF folder'
    Assert-Equal $bySource['budget.csv'].Reason 'organize-doc' 'Loose spreadsheets are organized'
    Assert-True ($bySource['budget.csv'].Destination -match 'Spreadsheets') 'Spreadsheets get their own folder'

    Assert-Equal $bySource['notes-copy.txt'].Reason 'duplicate' 'Older duplicate notes are archived'
    Assert-True ($bySource['notes-copy.txt'].Destination -match 'Duplicates') 'Duplicate copies go to the duplicate archive'
    Assert-Equal $bySource['movie.mp4'].Reason 'duplicate' 'Desktop copy of a video is the extra'
    Assert-True ($bySource['movie.mp4'].Destination -match 'Duplicates') 'Extra video copy is stored with duplicates'
    Assert-Equal $bySource['clip.mp4'].Reason 'video' 'Library video is the copy that is filed as video'
    Assert-True ($bySource['clip.mp4'].Destination -match 'Videos') 'Videos are filed under Videos'

    Assert-Equal $bySource['photo.jpg'].Reason 'image' 'Desktop images are relocated'
    Assert-Equal $bySource['shot.png'].Reason 'image' 'Pictures library images are relocated'
    Assert-True ($bySource['photo.jpg'].Destination -match 'Pictures') 'Images are filed under Pictures'
    Assert-Equal $bySource['big.bin'].Reason 'large' 'Oversized files are relocated'
    Assert-True ($bySource['big.bin'].Destination -match 'Large') 'Large files are filed under Large'
    Assert-Equal $bySource['old.txt'].Reason 'stale' 'Long-unopened loose files are archived'
    Assert-Equal $bySource['ancient.pdf'].Reason 'stale' 'Long-unopened filed documents are archived'
    Assert-True ($bySource['old.txt'].Destination -match 'Unopened') 'Stale files are filed under Unopened'

    Assert-True (-not $bySource.ContainsKey('kept.txt')) 'Recent filed documents stay put'
    Assert-True (-not $bySource.ContainsKey('desktop.ini')) 'desktop.ini is ignored'
    Assert-True (-not $bySource.ContainsKey('Thumbs.db')) 'Thumbs.db is ignored'
    Assert-True (-not $bySource.ContainsKey('secret.txt')) 'node_modules is not scanned'
    Assert-True (-not $bySource.ContainsKey('already.jpg')) 'The archive folder inside Desktop is not scanned again'
    if ($symlinkCreated) {
        Assert-True (-not $bySource.ContainsKey('linked.txt')) 'Symlinks are not followed or moved'
    }
    Assert-Equal @($plan.Moves).Count 11 'Every planned file has one destination'

    $manifestPath = Join-Path $temp 'manifest.json'
    $manifest = Invoke-LaptopFileMoves -Moves $plan.Moves -ManifestPath $manifestPath
    $moved = @($manifest.moves | Where-Object { $_.Status -eq 'moved' -or $_.status -eq 'moved' })
    Assert-Equal $moved.Count 11 'Every planned file is moved'
    Assert-True (-not (Test-Path -LiteralPath $notes)) 'Organized notes leave the Desktop'
    Assert-True (Test-Path -LiteralPath $bySource['notes.txt'].Destination) 'Organized notes arrive in Documents'
    Assert-True (Test-Path -LiteralPath $kept) 'Untouched files are not removed'
    Assert-True (Test-Path -LiteralPath (Join-Path $desktop 'desktop.ini')) 'Ignored files stay on disk'

    Restore-LaptopFileMoves -ManifestPath $manifestPath
    Assert-True (Test-Path -LiteralPath $notes) 'Undo puts notes back on the Desktop'
    Assert-True (-not (Test-Path -LiteralPath $bySource['notes.txt'].Destination)) 'Undo removes the organized copy'
    Assert-Equal ([System.IO.File]::ReadAllText($notes)) $sharedNotes 'Restored notes keep their contents'
    Assert-True (Test-Path -LiteralPath $movie) 'Undo puts the extra video back'
    Assert-True (Test-Path -LiteralPath $big) 'Undo puts the large file back'

    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $appsFile = Join-Path (Join-Path $repoRoot 'Config') 'Apps.json'
    $safeIds = @(Get-SafeBloatAppIds -AppsFilePath $appsFile)
    Assert-True ($safeIds -contains 'Clipchamp.Clipchamp') 'Default safe bloat includes Clipchamp'
    Assert-True ($safeIds -contains 'Spotify') 'Default safe bloat includes Spotify'
    Assert-True ($safeIds -notcontains 'Microsoft.Edge') 'Edge is not auto-removed'
    Assert-True ($safeIds -notcontains 'Microsoft.WindowsStore') 'The Microsoft Store is not auto-removed'

    $protected = @(Get-LaptopAppProtectedPatterns)
    $oemNames = @(Get-OemThirdPartyNamePatterns)
    $packages = @(
        [pscustomobject]@{ Name = 'Clipchamp.Clipchamp'; Publisher = 'CN=Microsoft Corporation'; IsFramework = $false },
        [pscustomobject]@{ Name = 'SpotifyAB.SpotifyMusic'; Publisher = 'CN=Spotify AB'; IsFramework = $false },
        [pscustomobject]@{ Name = 'Microsoft.WindowsCalculator'; Publisher = 'CN=Microsoft Corporation'; IsFramework = $false },
        [pscustomobject]@{ Name = 'Microsoft.Edge'; Publisher = 'CN=Microsoft Corporation'; IsFramework = $false },
        [pscustomobject]@{ Name = 'NVIDIACorp.NVIDIAControlPanel'; Publisher = 'CN=NVIDIA Corporation'; IsFramework = $false },
        [pscustomobject]@{ Name = 'DellInc.DellDigitalDelivery'; Publisher = 'CN=Dell Inc.'; IsFramework = $false },
        [pscustomobject]@{ Name = 'Contoso.UsefulTool'; Publisher = 'CN=Contoso'; IsFramework = $false },
        [pscustomobject]@{ Name = 'Microsoft.NET.Native.Runtime'; Publisher = 'CN=Microsoft Corporation'; IsFramework = $true },
        [pscustomobject]@{ Name = 'king.com.CandyCrushSaga'; Publisher = 'CN=King'; IsFramework = $false }
    )
    $provisioned = @(
        'Clipchamp.Clipchamp',
        'SpotifyAB.SpotifyMusic_1.0.0.0_neutral',
        'Microsoft.WindowsCalculator',
        'NVIDIACorp.NVIDIAControlPanel',
        'DellInc.DellDigitalDelivery',
        'Contoso.UsefulTool',
        'king.com.CandyCrushSaga'
    )
    $launched = @('SpotifyAB.SpotifyMusic_8wekyb3d8bbwe!App')
    $remove = @(Select-LaptopAppsToRemove `
        -SafeAppIds $safeIds `
        -InstalledPackages $packages `
        -ProvisionedNames $provisioned `
        -LaunchedTokens $launched `
        -HaveLaunchData $true `
        -ProtectedPatterns $protected `
        -OemNamePatterns $oemNames)
    $removeNames = @($remove | ForEach-Object { $_.Name })
    Assert-True ($removeNames -contains 'Clipchamp.Clipchamp') 'Unused provisioned bloat is removed'
    Assert-True ($removeNames -contains 'king.com.CandyCrushSaga') 'Catalog id matches the real package name'
    Assert-True ($removeNames -contains 'DellInc.DellDigitalDelivery') 'Unused provisioned OEM apps are removed'
    Assert-True ($removeNames -notcontains 'SpotifyAB.SpotifyMusic') 'A preinstalled app that was opened stays'
    Assert-True ($removeNames -notcontains 'Microsoft.WindowsCalculator') 'Calculator is protected'
    Assert-True ($removeNames -notcontains 'Microsoft.Edge') 'Edge is protected'
    Assert-True ($removeNames -notcontains 'NVIDIACorp.NVIDIAControlPanel') 'Driver panels stay installed'
    Assert-True ($removeNames -notcontains 'Contoso.UsefulTool') 'Unknown third-party apps stay installed'
    Assert-True ($removeNames -notcontains 'Microsoft.NET.Native.Runtime') 'Framework packages stay installed'

    $withoutHistory = @(Select-LaptopAppsToRemove `
        -SafeAppIds $safeIds `
        -InstalledPackages $packages `
        -ProvisionedNames @('Clipchamp.Clipchamp') `
        -LaunchedTokens @() `
        -HaveLaunchData $false `
        -ProtectedPatterns $protected `
        -OemNamePatterns $oemNames)
    $withoutHistoryNames = @($withoutHistory | ForEach-Object { $_.Name })
    Assert-True ($withoutHistoryNames -contains 'Clipchamp.Clipchamp') 'Provisioned bloat is removed when no launch history exists'
    Assert-True ($withoutHistoryNames -notcontains 'king.com.CandyCrushSaga') 'Unprovisioned apps are kept when launch history is missing'
    Assert-True ($withoutHistoryNames -notcontains 'DellInc.DellDigitalDelivery') 'OEM apps are kept when launch history is missing'

    $windowsInstall = [datetime]'2024-01-15'
    $catalog = @(Get-OemWin32Catalog)
    $win32 = @(Select-OemPreinstalledWin32 -WindowsInstallDate $windowsInstall -Catalog $catalog -Entries @(
        [pscustomobject]@{ DisplayName = 'McAfee LiveSafe'; InstallDate = [datetime]'2024-01-15' },
        [pscustomobject]@{ DisplayName = 'McAfee Total Protection'; InstallDate = [datetime]'2024-01-20' },
        [pscustomobject]@{ DisplayName = 'McAfee Total Protection'; InstallDate = [datetime]'2024-06-01' },
        [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2015 Redistributable'; InstallDate = [datetime]'2024-01-15' },
        [pscustomobject]@{ DisplayName = 'NVIDIA Graphics Driver'; InstallDate = [datetime]'2024-01-15' },
        [pscustomobject]@{ DisplayName = 'HP Support Assistant'; InstallDate = [datetime]'2024-01-16' },
        [pscustomobject]@{ DisplayName = 'Dell SupportAssist'; InstallDate = [datetime]'2024-01-16' },
        [pscustomobject]@{ DisplayName = 'Booking.com'; InstallDate = [datetime]'2024-01-15' },
        [pscustomobject]@{ DisplayName = 'Some Vendor Toolbar'; InstallDate = [datetime]'2024-01-15' },
        [pscustomobject]@{ DisplayName = 'McAfee Total Protection'; InstallDate = $null }
    ))

    function Get-Win32 {
        param([string]$Name)
        return @($win32 | Where-Object { $_.DisplayName -eq $Name })
    }

    $liveSafe = @(Get-Win32 'McAfee LiveSafe')
    Assert-Equal $liveSafe.Count 1 'McAfee LiveSafe installed with Windows is selected'
    Assert-Equal @($liveSafe[0].WingetIds)[0] 'McAfee.LiveSafe' 'LiveSafe uses its own WinGet id'
    $recentMcAfee = @($win32 | Where-Object { $_.DisplayName -eq 'McAfee Total Protection' })
    Assert-Equal $recentMcAfee.Count 1 'McAfee installed days later is selected once'
    Assert-True (@($recentMcAfee[0].WingetIds) -contains 'McAfee.McAfee') 'Generic McAfee maps to the McAfee WinGet id'
    Assert-Equal (Get-Win32 'Microsoft Visual C++ 2015 Redistributable').Count 0 'Runtimes installed with Windows stay'
    Assert-Equal (Get-Win32 'NVIDIA Graphics Driver').Count 0 'Drivers installed with Windows stay'
    $hp = @(Get-Win32 'HP Support Assistant')
    Assert-Equal @($hp[0].WingetIds)[0] 'HP.HPSupportAssistant' 'HP Support Assistant uses the HP package id'
    $dell = @(Get-Win32 'Dell SupportAssist')
    Assert-Equal @($dell[0].WingetIds)[0] 'Dell.SupportAssist' 'Dell SupportAssist uses the Dell package id'
    $booking = @(Get-Win32 'Booking.com')
    Assert-Equal $booking[0].Action 'report' 'OEM apps without a WinGet id are reported, not uninstalled'
    Assert-Equal (Get-Win32 'Some Vendor Toolbar').Count 0 'Unknown desktop apps stay installed'

    $summary = Get-LaptopCleanupSummary `
        -Moves $plan.Moves `
        -Apps @([pscustomobject]@{ Name = 'Clipchamp.Clipchamp' }) `
        -Win32 @([pscustomobject]@{ DisplayName = 'McAfee LiveSafe'; Action = 'uninstall' }) `
        -StorageHome $storageHome `
        -OrganizedRoot (Join-Path $documents 'Organized') `
        -Warnings @('No archive location was found.')
    Assert-True ($summary -match 'Sort 3 document') 'Summary counts organized documents'
    Assert-True ($summary -match 'not deleted') 'Summary tells the user files are not deleted'
    Assert-True ($summary -match 'Clipchamp') 'Summary names apps that would be removed'

    $chelseaDocs = Join-Path (Join-Path $temp 'DesktopDocuments') 'Documents'
    $gemini = Join-Path $chelseaDocs '.gemini'
    New-Item -ItemType Directory -Path $gemini -Force | Out-Null
    $chelseaNote = Join-Path $chelseaDocs 'lesson.pdf'
    [System.IO.File]::WriteAllText($chelseaNote, "A document that lives in Desktop\Documents.")
    [System.IO.File]::WriteAllText((Join-Path $gemini 'settings.json'), '{"theme":"dark"}')
    [System.IO.File]::WriteAllBytes((Join-Path $gemini 'token.bin'), (New-Object byte[] 300))
    $geminiOld = Join-Path $gemini 'history.txt'
    [System.IO.File]::WriteAllText($geminiOld, "Gemini history that must stay here.")
    Set-OldTimestamp -Path $geminiOld -DaysAgo 900

    $geminiPath = Join-Path $chelseaDocs '.gemini'
    $resolved = Resolve-LaptopCleanupRoot -Requested $geminiPath
    Assert-Equal $resolved.Path ([System.IO.Path]::GetFullPath($chelseaDocs)) 'A .gemini path cleans the Documents folder above it'
    Assert-True ($resolved.Warning -match 'left in place') 'The warning says .gemini stays put'
    Assert-True (Test-CleanupPathIsGemini -Path (Join-Path $gemini 'settings.json')) 'Files inside .gemini are recognized'
    Assert-True (-not (Test-CleanupPathIsGemini -Path $chelseaDocs)) 'The Documents folder itself is not Gemini data'

    $geminiArchive = Join-Path $temp 'GeminiArchive'
    New-Item -ItemType Directory -Path $geminiArchive | Out-Null
    $chelseaPlan = Get-LaptopCleanupPlan `
        -ScanRoots @($chelseaDocs) `
        -LooseDocRoots @($chelseaDocs) `
        -LibraryRoots @($chelseaDocs) `
        -OrganizedRoot (Join-Path $chelseaDocs 'Organized') `
        -StorageHome $geminiArchive `
        -ExcludeRoots @() `
        -StaleDays 365 `
        -LargeFileBytes 200 `
        -DuplicateMinBytes 4 `
        -StaleMinBytes 4 `
        -Now ([datetime]::UtcNow)
    $chelseaSources = @($chelseaPlan.Moves | ForEach-Object { $_.Source })
    Assert-Equal @($chelseaPlan.Moves).Count 1 'Only the loose document is planned'
    Assert-True ($chelseaSources[0] -eq ([System.IO.Path]::GetFullPath($chelseaNote))) 'Desktop\Documents file is organized'
    Assert-Equal $chelseaPlan.Moves[0].Reason 'organize-doc' 'The lesson is filed as a document'
    foreach ($source in $chelseaSources) {
        Assert-True ($source -notmatch '\.gemini') '.gemini is not moved'
    }
    Assert-True (Test-Path -LiteralPath (Join-Path $gemini 'settings.json')) 'Gemini settings stay on disk before a move'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "$($failures.Count) test(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host "Laptop cleanup tests passed."
exit 0
