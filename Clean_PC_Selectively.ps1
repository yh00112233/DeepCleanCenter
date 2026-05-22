param(
    [switch]$ConsoleScan,
    [int]$LargeFileMB = 500,
    [switch]$FullDriveLargeScan
)

if (-not $ConsoleScan -and [Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-STA",
        "-File", "`"$PSCommandPath`""
    )
    exit
}

$ErrorActionPreference = "SilentlyContinue"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Data

$script:Rows = $null
$script:SeenPaths = @{}
$script:StatusLabel = $null
$script:ProgressBar = $null
$script:IncludeLargeFiles = $true
$script:LargeThresholdMB = $LargeFileMB
$script:FullDriveLargeScan = [bool]$FullDriveLargeScan
$script:EnableDeepScan = $true
$script:ScriptRoot = Split-Path -Parent $PSCommandPath
$script:QuarantineRoot = Join-Path $script:ScriptRoot "Quarantine"
$script:QuarantineSession = $null
$script:ActionLog = Join-Path $script:ScriptRoot "cleanup_actions.jsonl"
$script:TreeSyncing = $false

function Initialize-ResultTable {
    $script:Rows = New-Object System.Data.DataTable
    [void]$script:Rows.Columns.Add("Selected", [bool])
    [void]$script:Rows.Columns.Add("Category", [string])
    [void]$script:Rows.Columns.Add("Group", [string])
    [void]$script:Rows.Columns.Add("Name", [string])
    [void]$script:Rows.Columns.Add("Size", [string])
    [void]$script:Rows.Columns.Add("Risk", [string])
    [void]$script:Rows.Columns.Add("Note", [string])
    [void]$script:Rows.Columns.Add("SelectionReason", [string])
    [void]$script:Rows.Columns.Add("Path", [string])
    [void]$script:Rows.Columns.Add("Action", [string])
    [void]$script:Rows.Columns.Add("Bytes", [int64])
    [void]$script:Rows.Columns.Add("Recommended", [bool])
    $script:SeenPaths = @{}
}

function Format-Bytes {
    param([int64]$Bytes)

    if ($Bytes -ge 1GB) { return ("{0:N2} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N2} KB" -f ($Bytes / 1KB)) }
    return ("{0} B" -f $Bytes)
}

function Set-Status {
    param(
        [string]$Text,
        [bool]$Busy = $true
    )

    if (Get-Command Convert-StatusText -ErrorAction SilentlyContinue) {
        $Text = Convert-StatusText $Text
    }

    if ($script:StatusLabel) {
        $script:StatusLabel.Text = $Text
    }
    else {
        Write-Host $Text
    }

    if ($script:ProgressBar) {
        if ($Busy) {
            $script:ProgressBar.Style = "Marquee"
        }
        else {
            $script:ProgressBar.Style = "Blocks"
            $script:ProgressBar.Value = 0
        }
    }

    [System.Windows.Forms.Application]::DoEvents()
}

function Get-DirectorySizeBytes {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    $sum = [int64]0
    try {
        Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object {
            $sum += [int64]$_.Length
        }
    }
    catch {
    }
    return $sum
}

function Resolve-TargetPaths {
    param([string]$Pattern)

    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Pattern)) {
        Resolve-Path -Path $Pattern -ErrorAction SilentlyContinue | ForEach-Object {
            $_.ProviderPath
        }
    }
    elseif (Test-Path -LiteralPath $Pattern) {
        try {
            (Get-Item -LiteralPath $Pattern -Force -ErrorAction Stop).FullName
        }
        catch {
        }
    }
}

function Get-ResultGroupName {
    param(
        [string]$Category,
        [string]$Name,
        [string]$Path
    )

    $text = (@($Category, $Name, $Path) -join " ").ToLowerInvariant()

    $knownGroups = @(
        @{ Pattern = "google\\chrome|google chrome"; Group = "Google Chrome" },
        @{ Pattern = "microsoft\\edge|microsoft edge|msedge"; Group = "Microsoft Edge" },
        @{ Pattern = "mozilla\\firefox|firefox"; Group = "Firefox" },
        @{ Pattern = "bravesoftware|brave"; Group = "Brave" },
        @{ Pattern = "opera software|opera"; Group = "Opera" },
        @{ Pattern = "qqbrowser|qq browser"; Group = "QQ Browser" },
        @{ Pattern = "360chrome|360 chrome"; Group = "360 Browser" },
        @{ Pattern = "doudian|partitions"; Group = "Doudian Workbench" },
        @{ Pattern = "wechat files|wechat|wechatappex"; Group = "WeChat" },
        @{ Pattern = "wxwork|enterprise wechat"; Group = "Enterprise WeChat / WXWork" },
        @{ Pattern = "qqpcmgr|qqpctray|qmpc|qmbsrv|qmusbguard|qqpcrtp|tencent pc manager"; Group = "Tencent PC Manager / QQPCMgr" },
        @{ Pattern = "kingsoft\\wps|kingsoft\\office|kingsoft|wps"; Group = "WPS Office" },
        @{ Pattern = "waxiang"; Group = "Waxiang" },
        @{ Pattern = "shadowbotbrowser"; Group = "ShadowBot Browser" },
        @{ Pattern = "shadowbot|影刀"; Group = "ShadowBot" },
        @{ Pattern = "trae"; Group = "Trae" },
        @{ Pattern = "clash-verge|clash verge"; Group = "Clash Verge" },
        @{ Pattern = "netease\\cloudmusic|netease cloudmusic|cloudmusic"; Group = "NetEase CloudMusic" },
        @{ Pattern = "anaconda|conda"; Group = "Anaconda / Conda" },
        @{ Pattern = "visual studio|buildtools|microsoft visual studio"; Group = "Microsoft Visual Studio" },
        @{ Pattern = "autodesk|maya"; Group = "Autodesk / Maya" },
        @{ Pattern = "ollama"; Group = "Ollama" },
        @{ Pattern = "jetbrains|pycharm"; Group = "JetBrains / PyCharm" },
        @{ Pattern = "docker"; Group = "Docker" },
        @{ Pattern = "dingding"; Group = "DingDing" },
        @{ Pattern = "\\cursor\\|cursor"; Group = "Cursor" },
        @{ Pattern = "\\code\\|vs code|visual studio code"; Group = "VS Code" },
        @{ Pattern = "dingtalk"; Group = "DingTalk" },
        @{ Pattern = "larkshell|feishu|lark"; Group = "Feishu / Lark" },
        @{ Pattern = "telegram"; Group = "Telegram Desktop" },
        @{ Pattern = "microsoft\\teams|new teams"; Group = "Microsoft Teams" },
        @{ Pattern = "discord"; Group = "Discord" },
        @{ Pattern = "slack"; Group = "Slack" },
        @{ Pattern = "spotify"; Group = "Spotify" },
        @{ Pattern = "nvidia|\\amd\\|amd dxcache|amd glcache|directx|d3dscache"; Group = "Graphics driver caches" },
        @{ Pattern = "npm|yarn|pip|pnpm|nuget|gradle|maven"; Group = "Developer caches" },
        @{ Pattern = "ludashi"; Group = "LuDaShi" },
        @{ Pattern = "lhpwebfence"; Group = "LhpWebFence" },
        @{ Pattern = "dllrepair"; Group = "DLLRepair" },
        @{ Pattern = "cleancut"; Group = "CleanCut" },
        @{ Pattern = "easyclean"; Group = "EasyClean" },
        @{ Pattern = "quark"; Group = "Quark" }
    )

    foreach ($entry in $knownGroups) {
        if ($text -match $entry.Pattern) {
            return $entry.Group
        }
    }

    if ($Category -match "Windows|System|Update|Recycle|Network") {
        return "Windows system"
    }
    if ($Category -match "Browser") {
        return "Other browser cleanup"
    }
    if ($Category -match "Download") {
        return "Downloads"
    }
    if ($Category -match "Large file") {
        return "Large files"
    }
    if ($Category -match "Large installed app") {
        return ("Installed app: " + $Name)
    }
    if ($Category -match "Large software folder") {
        return ("Software folder: " + $Name)
    }
    if ($Category -match "Installed PUP") {
        return ("Installed app: " + $Name)
    }
    if ($Category -match "Suspicious") {
        return ("Suspicious item: " + $Name)
    }
    if ($Name -match "^(.+?)\s+-\s+") {
        return $matches[1]
    }
    return $Category
}

function Get-SelectionReason {
    param(
        [bool]$Recommended,
        [string]$Risk,
        [string]$Action,
        [string]$Note
    )

    if ($Recommended) {
        if ($Action -eq "ClearContents" -or $Action -eq "RemoveFile") {
            return ("Selected by default because it is marked {0} and is a rebuildable cache/temp/log/dump item. Reason: {1}" -f $Risk, $Note)
        }
        return ("Selected by default because it is marked {0}. Reason: {1}" -f $Risk, $Note)
    }

    if ($Risk -eq "Safe") {
        return ("Not selected by default because this safe item may still be user-dependent. Reason: {0}" -f $Note)
    }
    return ("Not selected by default because it is {0} and needs review before action. Reason: {1}" -f $Risk, $Note)
}

function Add-ResultRow {
    param(
        [bool]$Selected,
        [string]$Category,
        [string]$Name,
        [int64]$Bytes,
        [string]$Risk,
        [string]$Note,
        [string]$Path,
        [string]$Action,
        [bool]$Recommended
    )

    if ($Bytes -lt 0 -or [string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $key = ($Action + "|" + $Path).ToLowerInvariant()
    if ($script:SeenPaths.ContainsKey($key)) {
        return
    }
    $script:SeenPaths[$key] = $true

    $row = $script:Rows.NewRow()
    $row["Selected"] = $Selected
    $row["Category"] = $Category
    $row["Group"] = Get-ResultGroupName -Category $Category -Name $Name -Path $Path
    $row["Name"] = $Name
    $row["Size"] = Format-Bytes $Bytes
    $row["Risk"] = $Risk
    $row["Note"] = $Note
    $row["SelectionReason"] = Get-SelectionReason -Recommended:$Recommended -Risk $Risk -Action $Action -Note $Note
    $row["Path"] = $Path
    $row["Action"] = $Action
    $row["Bytes"] = $Bytes
    $row["Recommended"] = $Recommended
    [void]$script:Rows.Rows.Add($row)
}

function Add-DirectoryTarget {
    param(
        [string]$Name,
        [string]$Pattern,
        [string]$Category,
        [string]$Risk = "Safe",
        [bool]$Recommended = $true,
        [string]$Note = "Cache or temporary files. The app can rebuild them.",
        [string]$Action = "ClearContents"
    )

    foreach ($path in Resolve-TargetPaths $Pattern) {
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if (-not $item.PSIsContainer) {
                continue
            }

            $key = ($Action + "|" + $item.FullName).ToLowerInvariant()
            if ($script:SeenPaths.ContainsKey($key)) {
                continue
            }

            Set-Status ("Scanning: {0}" -f $path)
            $size = Get-DirectorySizeBytes -Path $path
            Add-ResultRow -Selected:$Recommended -Category $Category -Name $Name -Bytes $size -Risk $Risk -Note $Note -Path $item.FullName -Action $Action -Recommended:$Recommended
        }
        catch {
        }
    }
}

function Add-FilePatternTarget {
    param(
        [string]$Name,
        [string]$Pattern,
        [string]$Category,
        [string]$Risk = "Safe",
        [bool]$Recommended = $true,
        [string]$Note = "Regenerable cache, log, or dump file."
    )

    foreach ($path in Resolve-TargetPaths $Pattern) {
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                continue
            }

            Add-ResultRow -Selected:$Recommended -Category $Category -Name $Name -Bytes ([int64]$item.Length) -Risk $Risk -Note $Note -Path $item.FullName -Action "RemoveFile" -Recommended:$Recommended
        }
        catch {
        }
    }
}

function Add-FileReviewTarget {
    param(
        [string]$Name,
        [string]$Pattern,
        [string]$Category,
        [string]$Risk = "Manual",
        [string]$Note = "Large data file. Review before deleting.",
        [string]$Action = "ManualReview",
        [bool]$Recommended = $false
    )

    foreach ($path in Resolve-TargetPaths $Pattern) {
        try {
            $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
            if ($item.PSIsContainer) {
                continue
            }

            Add-ResultRow -Selected:$Recommended -Category $Category -Name $Name -Bytes ([int64]$item.Length) -Risk $Risk -Note $Note -Path $item.FullName -Action $Action -Recommended:$Recommended
        }
        catch {
        }
    }
}

function Add-ChromiumProfileCaches {
    param(
        [string]$BrowserName,
        [string]$UserDataRoot
    )

    if (-not (Test-Path -LiteralPath $UserDataRoot)) {
        return
    }

    $targets = @(
        "Cache",
        "Code Cache",
        "GPUCache",
        "DawnCache",
        "ShaderCache",
        "GrShaderCache",
        "Network\Cache",
        "Network\Code Cache",
        "Service Worker\CacheStorage",
        "Service Worker\ScriptCache",
        "Crashpad\reports",
        "Crashpad\completed",
        "Crashpad\pending"
    )

    foreach ($target in $targets) {
        Add-DirectoryTarget `
            -Name ("{0} - {1}" -f $BrowserName, $target) `
            -Pattern (Join-Path $UserDataRoot ("*\" + $target)) `
            -Category "Browser cache" `
            -Risk "Safe" `
            -Recommended:$true `
            -Note "Cache, GPU cache, service-worker cache, or crash report. Cookies, Local Storage, IndexedDB, bookmarks, and sign-in state are not targeted."
    }

    foreach ($target in @("ShaderCache", "GrShaderCache", "DawnCache", "Crashpad\reports")) {
        Add-DirectoryTarget `
            -Name ("{0} - {1}" -f $BrowserName, $target) `
            -Pattern (Join-Path $UserDataRoot $target) `
            -Category "Browser cache" `
            -Risk "Safe" `
            -Recommended:$true `
            -Note "Global browser cache. Account data, bookmarks, and settings are not targeted."
    }
}

function Add-SingleProfileChromiumCaches {
    param(
        [string]$AppName,
        [string]$Root
    )

    if (-not (Test-Path -LiteralPath $Root)) {
        return
    }

    foreach ($target in @("Cache", "Code Cache", "GPUCache", "DawnCache", "ShaderCache", "GrShaderCache", "Service Worker\CacheStorage", "Service Worker\ScriptCache", "Crashpad\reports", "logs")) {
        Add-DirectoryTarget `
            -Name ("{0} - {1}" -f $AppName, $target) `
            -Pattern (Join-Path $Root $target) `
            -Category "App cache" `
            -Risk "Safe" `
            -Recommended:$true `
            -Note "Electron or Chromium app cache/logs. Sign-in data and user settings are not targeted."
    }
}

function Get-DoudianPartitionsPath {
    $appName = -join ([char[]](0x6296, 0x5E97, 0x5DE5, 0x4F5C, 0x53F0))
    return (Join-Path $env:APPDATA (Join-Path $appName "Partitions"))
}

function Add-DoudianCaches {
    $base = Get-DoudianPartitionsPath
    if (-not (Test-Path -LiteralPath $base)) {
        return
    }

    $targets = @(
        "Cache",
        "GPUCache",
        "Code Cache",
        "DawnCache",
        "ShaderCache",
        "GrShaderCache",
        "Service Worker\CacheStorage",
        "Service Worker\ScriptCache",
        "Network\Cache",
        "Network\Code Cache",
        "Crashpad\reports",
        "logs"
    )

    Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $partition = $_.FullName
        foreach ($target in $targets) {
            Add-DirectoryTarget `
                -Name ("Doudian Workbench - {0}" -f $target) `
                -Pattern (Join-Path $partition $target) `
                -Category "E-commerce app cache" `
                -Risk "Safe" `
                -Recommended:$true `
                -Note "Only cache/log targets are cleaned. Cookies, Local Storage, IndexedDB, Session Storage, sign-in state, and shop settings are not targeted."
        }
    }
}

function Add-WeChatCaches {
    $doc = [Environment]::GetFolderPath("MyDocuments")
    if ([string]::IsNullOrWhiteSpace($doc)) {
        return
    }

    $wechatRoot = Join-Path $doc "WeChat Files"
    Add-DirectoryTarget -Name "WeChat - FileStorage Cache" -Pattern (Join-Path $wechatRoot "*\FileStorage\Cache") -Category "Chat app cache" -Risk "Safe" -Recommended:$true -Note "WeChat cache folder. Chat databases, images, videos, and file bodies are not targeted."
    Add-DirectoryTarget -Name "WeChat - FileStorage Temp" -Pattern (Join-Path $wechatRoot "*\FileStorage\Temp") -Category "Chat app cache" -Risk "Safe" -Recommended:$true -Note "WeChat temporary files. Chat databases, images, videos, and file bodies are not targeted."
    Add-DirectoryTarget -Name "WeChat - CustomEmotion Temp" -Pattern (Join-Path $wechatRoot "*\FileStorage\CustomEmotion\Temp") -Category "Chat app cache" -Risk "Review" -Recommended:$false -Note "Temporary custom-emotion cache. Review before deleting."
}

function Add-WXWorkCaches {
    $doc = [Environment]::GetFolderPath("MyDocuments")
    if ([string]::IsNullOrWhiteSpace($doc)) {
        return
    }

    $wxworkRoot = Join-Path $doc "WXWork"
    Add-DirectoryTarget -Name "WXWork - Global CefCache" -Pattern (Join-Path $wxworkRoot "Global\CefCache") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "Enterprise WeChat CEF cache. Chat files and WeDrive content are not targeted."
    Add-DirectoryTarget -Name "WXWork - Account CefCache" -Pattern (Join-Path $wxworkRoot "*\WXWorkCefCache") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "Enterprise WeChat account CEF cache. Review first; chat files and WeDrive content are not targeted."
    Add-DirectoryTarget -Name "WXWork - qtCef" -Pattern (Join-Path $wxworkRoot "qtCef") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "Enterprise WeChat embedded-browser cache. Review first; chat files and WeDrive content are not targeted."
}

function Add-WpsDeepCaches {
    Add-DirectoryTarget -Name "WPS cache" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS cache. Documents are not targeted."
    Add-DirectoryTarget -Name "WPS Office cache" -Pattern (Join-Path $env:LOCALAPPDATA "Kingsoft\WPS Office\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS Office cache. Documents are not targeted."
    Add-DirectoryTarget -Name "WPS office6 cache" -Pattern (Join-Path $env:APPDATA "kingsoft\office6\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS office6 cache. Documents are not targeted."
    Add-DirectoryTarget -Name "WPS add-on CEF cache" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\addons\data\win-i386\cef\*\cache") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "WPS add-on embedded-browser cache. Review first if WPS is running."
    Add-DirectoryTarget -Name "WPS add-on package pool" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\addons\pool") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "WPS add-on package pool/cache. WPS may re-download add-ons; documents are not targeted."
    Add-DirectoryTarget -Name "WPS add-on index cache" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\addons\list") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS add-on index cache. WPS rebuilds it; documents are not targeted."
    Add-DirectoryTarget -Name "WPS add-on index cache V3" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\addons\listV3") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS add-on index cache. WPS rebuilds it; documents are not targeted."
    Add-DirectoryTarget -Name "WPS download cache" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\download") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "WPS internal download cache. Review first; documents are not targeted."

    $wpsInstallRoot = Join-Path $env:LOCALAPPDATA "Kingsoft\WPS Office"
    if (Test-Path -LiteralPath $wpsInstallRoot) {
        $versionDirs = @(
            Get-ChildItem -LiteralPath $wpsInstallRoot -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+){2,}$' } |
                ForEach-Object {
                    try {
                        [pscustomobject]@{ Directory = $_; Version = [version]$_.Name }
                    }
                    catch {
                    }
                }
        ) | Sort-Object Version -Descending

        foreach ($entry in ($versionDirs | Select-Object -Skip 1)) {
            try {
                Set-Status ("Sizing old WPS version folder: {0}" -f $entry.Directory.FullName)
                $bytes = Get-DirectorySizeBytes -Path $entry.Directory.FullName
                Add-ResultRow -Selected:$false -Category "Old app version folder" -Name ("WPS old version folder - {0}" -f $entry.Directory.Name) -Bytes $bytes -Risk "Manual" -Note "WPS old version/update rollback folder. It is not a document cache; review before quarantining." -Path $entry.Directory.FullName -Action "QuarantinePath" -Recommended:$false
            }
            catch {
            }
        }
    }
}

function Add-DingTalkDeepCaches {
    Add-SingleProfileChromiumCaches -AppName "DingTalk" -Root (Join-Path $env:APPDATA "DingTalk")
    Add-ChromiumProfileCaches -BrowserName "DingTalk Chromium" -UserDataRoot (Join-Path $env:LOCALAPPDATA "DingTalk_133")
    Add-DirectoryTarget -Name "DingTalk logs" -Pattern (Join-Path $env:APPDATA "DingTalk\log") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "DingTalk logs. Chat files and user settings are not targeted."
    Add-DirectoryTarget -Name "DingTalk holmes logs" -Pattern (Join-Path $env:APPDATA "DingTalk\holmeslogs") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "DingTalk diagnostic logs. Chat files and user settings are not targeted."
    Add-DirectoryTarget -Name "DingTalk updater logs" -Pattern (Join-Path $env:APPDATA "DingTalk\updaterlogs") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "DingTalk updater logs. They can be rebuilt."
    Add-DirectoryTarget -Name "DingTalk crash dumps" -Pattern (Join-Path $env:LOCALAPPDATA "DingTalk\dumps") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "DingTalk crash dumps, usually only needed for troubleshooting."
    Add-DirectoryTarget -Name "DingTalk media/cache candidate" -Pattern (Join-Path $env:APPDATA "DingTalk\*_v3") -Category "App cache" -Risk "Review" -Recommended:$false -Note "DingTalk account media/cache directory. Review first because it may contain user-dependent local data."

    $dingMain = "C:\Program Files (x86)\DingDing\main"
    if (Test-Path -LiteralPath $dingMain) {
        $currentDirs = @(Get-ChildItem -LiteralPath $dingMain -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @("current", "current_new") } | Sort-Object LastWriteTime -Descending)
        if ($currentDirs.Count -gt 1) {
            foreach ($dir in ($currentDirs | Select-Object -Skip 1)) {
                try {
                    Set-Status ("Sizing DingDing possible old version folder: {0}" -f $dir.FullName)
                    $bytes = Get-DirectorySizeBytes -Path $dir.FullName
                    Add-ResultRow -Selected:$false -Category "Old app version folder" -Name ("DingDing possible old version folder - {0}" -f $dir.Name) -Bytes $bytes -Risk "Manual" -Note "DingDing keeps current/current_new version folders. This looks like an update leftover, but confirm which one is active before quarantining." -Path $dir.FullName -Action "QuarantinePath" -Recommended:$false
                }
                catch {
                }
            }
        }
    }
}

function Add-DockerTargets {
    Add-SingleProfileChromiumCaches -AppName "Docker Desktop" -Root (Join-Path $env:APPDATA "Docker Desktop")
    Add-DirectoryTarget -Name "Docker Desktop DawnWebGPUCache" -Pattern (Join-Path $env:APPDATA "Docker Desktop\DawnWebGPUCache") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "Docker Desktop UI graphics cache. Docker rebuilds it."
    Add-DirectoryTarget -Name "Docker Desktop DawnGraphiteCache" -Pattern (Join-Path $env:APPDATA "Docker Desktop\DawnGraphiteCache") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "Docker Desktop UI graphics cache. Docker rebuilds it."
    Add-DirectoryTarget -Name "Docker logs" -Pattern (Join-Path $env:LOCALAPPDATA "Docker\log") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "Docker Desktop logs. Containers, images, volumes, and settings are not targeted."
    Add-FilePatternTarget -Name "Docker install logs" -Pattern (Join-Path $env:LOCALAPPDATA "Docker\install-log*.txt") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "Docker Desktop installation logs."
    Add-FilePatternTarget -Name "Docker admin install logs" -Pattern (Join-Path $env:ProgramData "DockerDesktop\install-*-admin*.txt") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "Docker Desktop installation logs. Administrator rights may be needed."
    Add-FileReviewTarget -Name "Docker WSL data disk" -Pattern (Join-Path $env:LOCALAPPDATA "Docker\wsl\*\ext4.vhdx") -Category "Container data / disk image" -Risk "Manual" -Note "Docker WSL disk image. This is not simple cache; use Docker Desktop cleanup or docker system prune instead of deleting the VHDX blindly."
    Add-FileReviewTarget -Name "Docker Desktop VM data disk" -Pattern (Join-Path $env:ProgramData "DockerDesktop\vm-data\*.vhdx") -Category "Container data / disk image" -Risk "Manual" -Note "Docker Desktop VM disk image. This may contain containers/images/volumes; use Docker cleanup tools instead of deleting the file blindly."
}

function Add-OllamaTargets {
    Add-DirectoryTarget -Name "Ollama logs" -Pattern (Join-Path $env:LOCALAPPDATA "Ollama\logs") -Category "App cache" -Risk "Safe" -Recommended:$true -Note "Ollama logs. Models and settings are not targeted."
    Add-DirectoryTarget -Name "Ollama downloader cache" -Pattern (Join-Path $env:APPDATA "ollamadownloader") -Category "App cache" -Risk "Review" -Recommended:$false -Note "Ollama downloader temporary/cache directory. Review first."
    Add-DirectoryTarget -Name "Ollama model store" -Pattern (Join-Path $env:USERPROFILE ".ollama\models") -Category "AI model data" -Risk "Manual" -Recommended:$false -Note "Ollama downloaded model store. This is not cache; remove unused models with ollama rm or review manually." -Action "ManualReview"
}

function Add-CommonSystemCaches {
    Add-DirectoryTarget -Name "User TEMP" -Pattern $env:TEMP -Category "Windows temp" -Risk "Safe" -Recommended:$true -Note "Current-user temporary files. Locked files are skipped."
    Add-DirectoryTarget -Name "LocalAppData Temp" -Pattern (Join-Path $env:LOCALAPPDATA "Temp") -Category "Windows temp" -Risk "Safe" -Recommended:$true -Note "Application temporary files. Locked files are skipped."
    Add-DirectoryTarget -Name "Windows Temp" -Pattern (Join-Path $env:SystemRoot "Temp") -Category "Windows temp" -Risk "Safe" -Recommended:$true -Note "System temporary files. Some items may need administrator rights."
    Add-DirectoryTarget -Name "WER report archive - user" -Pattern (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\ReportArchive") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "Windows Error Reporting archive."
    Add-DirectoryTarget -Name "WER report queue - user" -Pattern (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\WER\ReportQueue") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "Windows Error Reporting queue."
    Add-DirectoryTarget -Name "WER report archive - global" -Pattern (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportArchive") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "Global Windows Error Reporting archive. Administrator rights may be needed."
    Add-DirectoryTarget -Name "WER report queue - global" -Pattern (Join-Path $env:ProgramData "Microsoft\Windows\WER\ReportQueue") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "Global Windows Error Reporting queue. Administrator rights may be needed."
    Add-DirectoryTarget -Name "DirectX Shader Cache" -Pattern (Join-Path $env:LOCALAPPDATA "D3DSCache") -Category "Graphics cache" -Risk "Safe" -Recommended:$true -Note "DirectX shader cache. Games and apps rebuild it."
    Add-DirectoryTarget -Name "NVIDIA DXCache" -Pattern (Join-Path $env:LOCALAPPDATA "NVIDIA\DXCache") -Category "Graphics cache" -Risk "Safe" -Recommended:$true -Note "NVIDIA shader cache."
    Add-DirectoryTarget -Name "NVIDIA GLCache" -Pattern (Join-Path $env:LOCALAPPDATA "NVIDIA\GLCache") -Category "Graphics cache" -Risk "Safe" -Recommended:$true -Note "NVIDIA OpenGL cache."
    Add-DirectoryTarget -Name "NVIDIA global cache" -Pattern (Join-Path $env:ProgramData "NVIDIA Corporation\NV_Cache") -Category "Graphics cache" -Risk "Safe" -Recommended:$true -Note "NVIDIA global cache. Administrator rights may be needed."
    Add-DirectoryTarget -Name "AMD DXCache" -Pattern (Join-Path $env:LOCALAPPDATA "AMD\DxCache") -Category "Graphics cache" -Risk "Safe" -Recommended:$true -Note "AMD shader cache."
    Add-DirectoryTarget -Name "AMD GLCache" -Pattern (Join-Path $env:LOCALAPPDATA "AMD\GLCache") -Category "Graphics cache" -Risk "Safe" -Recommended:$true -Note "AMD OpenGL cache."
    Add-DirectoryTarget -Name "Windows Update downloads" -Pattern (Join-Path $env:SystemRoot "SoftwareDistribution\Download") -Category "Update cache" -Risk "Review" -Recommended:$false -Note "Windows Update installer cache. Review first; avoid deleting during an update."
    Add-DirectoryTarget -Name "Delivery Optimization cache" -Pattern (Join-Path $env:SystemRoot "ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache") -Category "Update cache" -Risk "Review" -Recommended:$false -Note "Delivery Optimization cache. Administrator rights may be needed."
    Add-FilePatternTarget -Name "Thumbnail cache" -Pattern (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer\thumbcache_*.db") -Category "Windows cache files" -Risk "Safe" -Recommended:$true -Note "Windows thumbnail cache. Explorer rebuilds it."
    Add-FilePatternTarget -Name "Icon cache" -Pattern (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Explorer\iconcache_*.db") -Category "Windows cache files" -Risk "Safe" -Recommended:$true -Note "Windows icon cache. Explorer rebuilds it."
    Add-FilePatternTarget -Name "User crash dumps" -Pattern (Join-Path $env:LOCALAPPDATA "CrashDumps\*.dmp") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "Application crash dumps, usually only needed for troubleshooting."
    Add-FilePatternTarget -Name "Windows minidumps" -Pattern (Join-Path $env:SystemRoot "Minidump\*.dmp") -Category "System reports" -Risk "Safe" -Recommended:$true -Note "Blue-screen minidumps. Delete only if you do not need debugging records."

    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | ForEach-Object {
        $root = $_.DeviceID + "\"
        Add-DirectoryTarget -Name ("Recycle Bin - {0}" -f $_.DeviceID) -Pattern (Join-Path $root '$Recycle.Bin') -Category "Recycle Bin" -Risk "Manual" -Recommended:$false -Note "Clears the recycle bin folder on this drive. Review first."
    }
}

function Add-BrowserCaches {
    Add-ChromiumProfileCaches -BrowserName "Google Chrome" -UserDataRoot (Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data")
    Add-ChromiumProfileCaches -BrowserName "Microsoft Edge" -UserDataRoot (Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data")
    Add-ChromiumProfileCaches -BrowserName "Brave" -UserDataRoot (Join-Path $env:LOCALAPPDATA "BraveSoftware\Brave-Browser\User Data")
    Add-ChromiumProfileCaches -BrowserName "QQ Browser" -UserDataRoot (Join-Path $env:LOCALAPPDATA "Tencent\QQBrowser\User Data")
    Add-ChromiumProfileCaches -BrowserName "360 Chrome" -UserDataRoot (Join-Path $env:LOCALAPPDATA "360Chrome\Chrome\User Data")
    Add-ChromiumProfileCaches -BrowserName "360 Chrome X" -UserDataRoot (Join-Path $env:LOCALAPPDATA "360ChromeX\Chrome\User Data")
    Add-SingleProfileChromiumCaches -AppName "Opera" -Root (Join-Path $env:APPDATA "Opera Software\Opera Stable")

    Add-DirectoryTarget -Name "Firefox cache2" -Pattern (Join-Path $env:LOCALAPPDATA "Mozilla\Firefox\Profiles\*\cache2") -Category "Browser cache" -Risk "Safe" -Recommended:$true -Note "Firefox network cache. Bookmarks, extensions, and sign-in state are not targeted."
    Add-DirectoryTarget -Name "Firefox startupCache" -Pattern (Join-Path $env:LOCALAPPDATA "Mozilla\Firefox\Profiles\*\startupCache") -Category "Browser cache" -Risk "Safe" -Recommended:$true -Note "Firefox startup cache."
}

function Add-ApplicationCaches {
    Add-DoudianCaches
    Add-WeChatCaches
    Add-WXWorkCaches
    Add-WpsDeepCaches
    Add-DingTalkDeepCaches
    Add-DockerTargets
    Add-OllamaTargets

    Add-SingleProfileChromiumCaches -AppName "VS Code" -Root (Join-Path $env:APPDATA "Code")
    Add-SingleProfileChromiumCaches -AppName "Cursor" -Root (Join-Path $env:APPDATA "Cursor")
    Add-SingleProfileChromiumCaches -AppName "Discord" -Root (Join-Path $env:APPDATA "discord")
    Add-SingleProfileChromiumCaches -AppName "Discord PTB" -Root (Join-Path $env:APPDATA "discordptb")
    Add-SingleProfileChromiumCaches -AppName "Discord Canary" -Root (Join-Path $env:APPDATA "discordcanary")
    Add-SingleProfileChromiumCaches -AppName "Slack" -Root (Join-Path $env:APPDATA "Slack")
    Add-SingleProfileChromiumCaches -AppName "DingTalk" -Root (Join-Path $env:APPDATA "DingTalk")
    Add-SingleProfileChromiumCaches -AppName "LarkShell" -Root (Join-Path $env:APPDATA "LarkShell")
    Add-SingleProfileChromiumCaches -AppName "Feishu" -Root (Join-Path $env:APPDATA "Feishu")
    Add-SingleProfileChromiumCaches -AppName "Telegram Desktop" -Root (Join-Path $env:APPDATA "Telegram Desktop\tdata\user_data")
    Add-SingleProfileChromiumCaches -AppName "Microsoft Teams" -Root (Join-Path $env:APPDATA "Microsoft\Teams")
    Add-SingleProfileChromiumCaches -AppName "New Teams" -Root (Join-Path $env:LOCALAPPDATA "Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams")
    Add-SingleProfileChromiumCaches -AppName "Trae" -Root (Join-Path $env:APPDATA "Trae")
    Add-ChromiumProfileCaches -BrowserName "Waxiang" -UserDataRoot (Join-Path $env:LOCALAPPDATA "Waxiang\User Data")
    Add-ChromiumProfileCaches -BrowserName "ShadowBot Browser" -UserDataRoot (Join-Path $env:LOCALAPPDATA "ShadowBotBrowser\User Data")

    Add-DirectoryTarget -Name "WPS cache" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS cache. Documents are not targeted."
    Add-DirectoryTarget -Name "WPS Office cache" -Pattern (Join-Path $env:LOCALAPPDATA "Kingsoft\WPS Office\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS Office cache. Documents are not targeted."
    Add-DirectoryTarget -Name "WPS office6 cache" -Pattern (Join-Path $env:APPDATA "kingsoft\office6\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "WPS office6 cache. Documents are not targeted."
    Add-DirectoryTarget -Name "WPS add-on CEF cache" -Pattern (Join-Path $env:APPDATA "kingsoft\wps\addons\data\win-i386\cef\*\cache") -Category "Office app cache" -Risk "Review" -Recommended:$false -Note "WPS add-on embedded-browser cache. Review first if WPS is running."
    Add-DirectoryTarget -Name "Tencent Meeting cache" -Pattern (Join-Path $env:APPDATA "Tencent\WeMeet\cache") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "Tencent Meeting cache. Account settings are not targeted."
    Add-DirectoryTarget -Name "Tencent Meeting logs" -Pattern (Join-Path $env:APPDATA "Tencent\WeMeet\Global\Logs") -Category "Office app cache" -Risk "Safe" -Recommended:$true -Note "Tencent Meeting logs. Meeting data and account settings are not targeted."
    Add-DirectoryTarget -Name "Tencent xwechat logs" -Pattern (Join-Path $env:APPDATA "Tencent\xwechat\log") -Category "Chat app cache" -Risk "Safe" -Recommended:$true -Note "Tencent xwechat logs. Chat databases and files are not targeted."
    Add-DirectoryTarget -Name "Tencent xwechat Code Cache" -Pattern (Join-Path $env:APPDATA "Tencent\xwechat\radium\web\profiles\*\Code Cache") -Category "Chat app cache" -Risk "Safe" -Recommended:$true -Note "Tencent xwechat embedded-browser code cache. Chat databases and files are not targeted."
    Add-DirectoryTarget -Name "NetEase CloudMusic cache" -Pattern (Join-Path $env:LOCALAPPDATA "NetEase\CloudMusic\Cache") -Category "Media app cache" -Risk "Review" -Recommended:$false -Note "NetEase CloudMusic media/browser cache. Review first if you rely on offline music cache."
    Add-DirectoryTarget -Name "ShadowBot cache" -Pattern (Join-Path $env:LOCALAPPDATA "ShadowBot\cache") -Category "RPA app cache" -Risk "Review" -Recommended:$false -Note "ShadowBot cache. Review first if automations are running."
    Add-DirectoryTarget -Name "ShadowBot logs" -Pattern (Join-Path $env:LOCALAPPDATA "ShadowBot\log") -Category "RPA app cache" -Risk "Safe" -Recommended:$true -Note "ShadowBot logs. Automation projects are not targeted."
    Add-DirectoryTarget -Name "Clash Verge logs" -Pattern (Join-Path $env:APPDATA "io.github.clash-verge-rev.clash-verge-rev\logs") -Category "Network app cache" -Risk "Safe" -Recommended:$true -Note "Clash Verge logs. Proxy profiles are not targeted."
    Add-DirectoryTarget -Name "Spotify Data Cache" -Pattern (Join-Path $env:LOCALAPPDATA "Spotify\Data") -Category "Media app cache" -Risk "Review" -Recommended:$false -Note "Spotify media/offline cache. Review before deleting."
}

function Add-DeveloperCaches {
    Add-DirectoryTarget -Name "npm cache" -Pattern (Join-Path $env:APPDATA "npm-cache") -Category "Developer cache" -Risk "Safe" -Recommended:$true -Note "npm download cache. It can be rebuilt."
    Add-DirectoryTarget -Name "Yarn cache" -Pattern (Join-Path $env:LOCALAPPDATA "Yarn\Cache") -Category "Developer cache" -Risk "Safe" -Recommended:$true -Note "Yarn download cache. It can be rebuilt."
    Add-DirectoryTarget -Name "pip cache" -Pattern (Join-Path $env:LOCALAPPDATA "pip\Cache") -Category "Developer cache" -Risk "Safe" -Recommended:$true -Note "Python pip download cache. It can be rebuilt."
    Add-DirectoryTarget -Name "pnpm store" -Pattern (Join-Path $env:LOCALAPPDATA "pnpm\store") -Category "Developer cache" -Risk "Review" -Recommended:$false -Note "pnpm global package store. Projects may re-download dependencies."
    Add-DirectoryTarget -Name "NuGet packages" -Pattern (Join-Path $env:USERPROFILE ".nuget\packages") -Category "Developer cache" -Risk "Review" -Recommended:$false -Note "NuGet global package cache. .NET projects may restore dependencies again."
    Add-DirectoryTarget -Name "Gradle caches" -Pattern (Join-Path $env:USERPROFILE ".gradle\caches") -Category "Developer cache" -Risk "Review" -Recommended:$false -Note "Gradle build caches. Java projects may re-download and re-index."
    Add-DirectoryTarget -Name "Maven repository" -Pattern (Join-Path $env:USERPROFILE ".m2\repository") -Category "Developer cache" -Risk "Review" -Recommended:$false -Note "Maven local repository. Java projects may re-download dependencies."
    Add-DirectoryTarget -Name "Anaconda package cache" -Pattern (Join-Path $env:ProgramData "anaconda3\pkgs\cache") -Category "Developer cache" -Risk "Review" -Recommended:$false -Note "Conda package cache metadata/download cache. Prefer conda clean when possible; review before deleting directly."
    Add-DirectoryTarget -Name "User conda package cache" -Pattern (Join-Path $env:USERPROFILE ".conda\pkgs\cache") -Category "Developer cache" -Risk "Review" -Recommended:$false -Note "User conda package cache metadata/download cache. Prefer conda clean when possible."
}

function Add-DownloadCandidates {
    $download = Join-Path $env:USERPROFILE "Downloads"
    if (-not (Test-Path -LiteralPath $download)) {
        return
    }

    $extensions = @("*.exe", "*.msi", "*.msp", "*.zip", "*.7z", "*.rar", "*.iso", "*.img", "*.apk", "*.dmg", "*.tar", "*.gz", "*.whl")
    $minBytes = 50MB
    $olderThan = (Get-Date).AddDays(-3)

    foreach ($ext in $extensions) {
        Get-ChildItem -Path (Join-Path $download $ext) -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Length -ge $minBytes -and $_.LastWriteTime -lt $olderThan
        } | ForEach-Object {
            Add-ResultRow -Selected:$false -Category "Download candidates" -Name $_.Name -Bytes ([int64]$_.Length) -Risk "Manual" -Note "Installer/archive/image in Downloads. It may be disposable or worth keeping." -Path $_.FullName -Action "RemoveFile" -Recommended:$false
        }
    }
}

function Add-LargeInstalledApps {
    param([int]$ThresholdMB)

    $thresholdBytes = [int64]$ThresholdMB * 1MB
    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($p.DisplayName)) {
                    return
                }

                $bytes = [int64]0
                if ($p.EstimatedSize) {
                    try { $bytes = [int64]$p.EstimatedSize * 1KB } catch { $bytes = 0 }
                }

                $installLocation = [string]$p.InstallLocation
                if ($bytes -lt $thresholdBytes -and -not [string]::IsNullOrWhiteSpace($installLocation) -and (Test-Path -LiteralPath $installLocation)) {
                    Set-Status ("Sizing installed app: {0}" -f $p.DisplayName)
                    $bytes = Get-DirectorySizeBytes -Path $installLocation
                }

                if ($bytes -lt $thresholdBytes) {
                    return
                }

                $command = [string]$p.UninstallString
                if ([string]::IsNullOrWhiteSpace($command)) {
                    $command = [string]$p.QuietUninstallString
                }

                $action = "OpenUninstaller"
                $path = "UninstallCommand::" + $command
                if ([string]::IsNullOrWhiteSpace($command)) {
                    $action = "ManualReview"
                    if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                        $path = $installLocation
                    }
                    else {
                        $path = $_.Name
                    }
                }

                $note = "Large installed application. Review before uninstalling. Install location: {0}" -f $installLocation
                Add-ResultRow -Selected:$false -Category "Large installed app" -Name ([string]$p.DisplayName) -Bytes $bytes -Risk "Manual" -Note $note -Path $path -Action $action -Recommended:$false
            }
            catch {
            }
        }
    }
}

function Add-LargeSoftwareFolders {
    param([int]$ThresholdMB)

    $thresholdBytes = [int64]$ThresholdMB * 1MB
    $roots = @(
        [Environment]::GetEnvironmentVariable("ProgramFiles"),
        [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"),
        $env:ProgramData,
        $env:LOCALAPPDATA,
        $env:APPDATA
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $skipNames = @(
        "Microsoft",
        "Common Files",
        "Packages",
        "Package Cache",
        "WindowsApps",
        "Temp"
    )

    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            if ($skipNames -contains $_.Name) {
                return
            }

            Set-Status ("Sizing large software folder: {0}" -f $_.FullName)
            $bytes = Get-DirectorySizeBytes -Path $_.FullName
            if ($bytes -ge $thresholdBytes) {
                Add-ResultRow -Selected:$false -Category "Large software folder" -Name $_.Name -Bytes $bytes -Risk "Manual" -Note "Large top-level software or application-data folder. Use Open location and prefer official uninstallers; do not delete blindly." -Path $_.FullName -Action "ManualReview" -Recommended:$false
            }
        }
    }
}

function Get-LargeScanRoots {
    param([bool]$FullDrive)

    $roots = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    function Add-Root {
        param([string]$Path)

        if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
            return
        }

        try {
            $full = (Get-Item -LiteralPath $Path -Force).FullName.TrimEnd("\")
            $key = $full.ToLowerInvariant()
            if (-not $seen.ContainsKey($key)) {
                $seen[$key] = $true
                [void]$roots.Add($full)
            }
        }
        catch {
        }
    }

    Add-Root (Join-Path $env:USERPROFILE "Desktop")
    Add-Root (Join-Path $env:USERPROFILE "Downloads")
    Add-Root ([Environment]::GetFolderPath("MyDocuments"))
    Add-Root ([Environment]::GetFolderPath("MyPictures"))
    Add-Root ([Environment]::GetFolderPath("MyVideos"))
    Add-Root ([Environment]::GetFolderPath("MyMusic"))

    if ($FullDrive) {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Root ($_.DeviceID + "\")
        }
    }

    return $roots
}

function Add-LargeFileCandidates {
    param(
        [int]$ThresholdMB,
        [bool]$FullDrive
    )

    $thresholdBytes = [int64]$ThresholdMB * 1MB
    $candidates = New-Object System.Collections.Generic.List[object]
    $skipNames = @(
        "Windows",
        "Program Files",
        "Program Files (x86)",
        "ProgramData",
        "System Volume Information",
        '$Recycle.Bin',
        "Recovery",
        "PerfLogs",
        "AppData",
        "node_modules",
        ".git"
    )

    foreach ($root in Get-LargeScanRoots -FullDrive:$FullDrive) {
        Set-Status ("Scanning large files: {0}" -f $root)
        $stack = New-Object System.Collections.Generic.Stack[string]
        $stack.Push($root)
        $visited = 0

        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            $visited++
            if (($visited % 50) -eq 0) {
                Set-Status ("Scanning large files: {0}" -f $dir)
            }

            try {
                foreach ($file in [System.IO.Directory]::EnumerateFiles($dir)) {
                    try {
                        $info = [System.IO.FileInfo]::new($file)
                        if (($info.Attributes -band [System.IO.FileAttributes]::System) -ne 0) {
                            continue
                        }
                        if ($info.Length -ge $thresholdBytes) {
                            [void]$candidates.Add([pscustomobject]@{
                                Name = $info.Name
                                Path = $info.FullName
                                Bytes = [int64]$info.Length
                                LastWriteTime = $info.LastWriteTime
                            })
                        }
                    }
                    catch {
                    }
                }
            }
            catch {
            }

            try {
                foreach ($subdir in [System.IO.Directory]::EnumerateDirectories($dir)) {
                    try {
                        $name = [System.IO.Path]::GetFileName($subdir)
                        if ($skipNames -contains $name) {
                            continue
                        }
                        $info = [System.IO.DirectoryInfo]::new($subdir)
                        if (($info.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                            continue
                        }
                        if (($info.Attributes -band [System.IO.FileAttributes]::System) -ne 0) {
                            continue
                        }
                        $stack.Push($subdir)
                    }
                    catch {
                    }
                }
            }
            catch {
            }
        }
    }

    $candidates | Sort-Object Bytes -Descending | Select-Object -First 300 | ForEach-Object {
        Add-ResultRow -Selected:$false -Category "Large file candidates" -Name $_.Name -Bytes $_.Bytes -Risk "Manual" -Note ("File larger than {0} MB. Review before deleting. Last write: {1}" -f $ThresholdMB, $_.LastWriteTime) -Path $_.Path -Action "RemoveFile" -Recommended:$false
    }
}

function New-UString {
    param([int[]]$CodePoints)
    return -join ($CodePoints | ForEach-Object { [char]$_ })
}

function Get-PupKeywords {
    $unicodeKeywords = @(
        (New-UString @(0x9C81, 0x5927, 0x5E08)),
        (New-UString @(0x9A71, 0x52A8, 0x7CBE, 0x7075)),
        (New-UString @(0x9A71, 0x52A8, 0x4EBA, 0x751F)),
        (New-UString @(0x5FEB, 0x538B)),
        (New-UString @(0x597D, 0x538B)),
        (New-UString @(0x91D1, 0x5C71, 0x6BD2, 0x9738)),
        ("360" + (New-UString @(0x5B89, 0x5168, 0x536B, 0x58EB))),
        ((New-UString @(0x730E, 0x8C79))),
        ((New-UString @(0x767E, 0x5EA6, 0x536B, 0x58EB)))
    )

    return @(
        "2345",
        "hao123",
        "ludashi",
        "ldsafe",
        "drivergenius",
        "driver genius",
        "driver talent",
        "drivethelife",
        "kuaizip",
        "kuaikan",
        "fastpic",
        "duba",
        "kingsoft antivirus",
        "liebao",
        "cmcm",
        "sogouexplorer",
        "sogou browser",
        "baidu safe",
        "qqpcmgr",
        "tencent pc manager",
        "bytefence",
        "segurazo",
        "webcompanion",
        "web companion",
        "onelaunch",
        "wavebrowser",
        "relevantknowledge",
        "rav endpoint",
        "rsenginesvc",
        "wajam",
        "pc app store",
        "pcfaster",
        "lhpwebfence",
        "dllrepair",
        "cleancut",
        "easyclean",
        "adaware",
        "quick driver updater",
        "search protect",
        "browser assistant"
    ) + $unicodeKeywords
}

function Get-HitReason {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $lower = $Text.ToLowerInvariant()
    $hits = New-Object System.Collections.Generic.List[string]
    foreach ($keyword in Get-PupKeywords) {
        if ([string]::IsNullOrWhiteSpace($keyword)) {
            continue
        }
        if ($lower.Contains($keyword.ToLowerInvariant())) {
            [void]$hits.Add($keyword)
        }
    }

    if ($lower -match "\\temp\\.*\.(exe|dll|scr|bat|cmd|vbs|js|ps1)" -or
        $lower -match "\\downloads\\.*\.(exe|dll|scr|bat|cmd|vbs|js|ps1)" -or
        $lower -match "\\users\\public\\.*\.(exe|dll|scr|bat|cmd|vbs|js|ps1)" -or
        $lower -match "powershell.*(-enc|encodedcommand)" -or
        $lower -match "(mshta|wscript|cscript|regsvr32|bitsadmin)" -or
        $lower -match "certutil.*http") {
        [void]$hits.Add("suspicious persistence command/path")
    }

    if ($hits.Count -eq 0) {
        return $null
    }

    return (($hits | Select-Object -Unique) -join ", ")
}

function Get-PersistenceHitReason {
    param([string]$Text)

    $hits = New-Object System.Collections.Generic.List[string]
    $base = Get-HitReason $Text
    if ($base) {
        foreach ($hit in ($base -split ", ")) {
            [void]$hits.Add($hit)
        }
    }

    $lower = ([string]$Text).ToLowerInvariant()
    if ($lower -match "\\appdata\\.*\.(exe|dll|scr|bat|cmd|vbs|js|ps1)") {
        [void]$hits.Add("startup from AppData")
    }

    if ($hits.Count -eq 0) {
        return $null
    }
    return (($hits | Select-Object -Unique) -join ", ")
}

function Test-AllowlistedPersistence {
    param([string]$Text)

    $lower = ([string]$Text).ToLowerInvariant()
    if ($lower -match "microsoft\\onedrive\\onedrive\.exe" -or
        $lower -match "\\onedrive\.exe" -or
        $lower -match "onedrive startup task") {
        return $true
    }
    return $false
}

function Add-InstalledPupCandidates {
    $uninstallRoots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $uninstallRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($p.DisplayName)) {
                    return
                }

                $text = @($p.DisplayName, $p.DisplayVersion, $p.Publisher, $p.InstallLocation, $p.UninstallString) -join " "
                $hits = Get-HitReason $text
                if (-not $hits) {
                    return
                }

                $bytes = [int64]0
                if ($p.EstimatedSize) {
                    try { $bytes = [int64]$p.EstimatedSize * 1KB } catch { $bytes = 0 }
                }

                $command = [string]$p.UninstallString
                if ([string]::IsNullOrWhiteSpace($command)) {
                    $command = [string]$p.QuietUninstallString
                }
                if ([string]::IsNullOrWhiteSpace($command)) {
                    $command = "ms-settings:appsfeatures"
                }

                Add-ResultRow -Selected:$false -Category "Installed PUP candidate" -Name ([string]$p.DisplayName) -Bytes $bytes -Risk "Manual" -Note ("Matched: {0}. Opens the vendor uninstaller or Apps & Features; this does not silently remove programs." -f $hits) -Path ("UninstallCommand::" + $command) -Action "OpenUninstaller" -Recommended:$false
            }
            catch {
            }
        }
    }
}

function Add-RegistryValueCandidate {
    param(
        [string]$Category,
        [string]$Name,
        [string]$KeyPath,
        [string]$ValueName,
        [string]$ValueData,
        [string]$Risk,
        [string]$Note
    )

    Add-ResultRow -Selected:$false -Category $Category -Name $Name -Bytes 0 -Risk $Risk -Note $Note -Path ($KeyPath + "|" + $ValueName) -Action "DisableRegistryValue" -Recommended:$false
}

function Add-StartupCandidates {
    $runKeys = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce"
    )

    foreach ($key in $runKeys) {
        if (-not (Test-Path -LiteralPath $key)) {
            continue
        }

        try {
            $regKey = Get-Item -LiteralPath $key -ErrorAction Stop
            foreach ($valueName in $regKey.GetValueNames()) {
                $valueData = [string]$regKey.GetValue($valueName)
                $hits = Get-PersistenceHitReason ($valueName + " " + $valueData)
                if ($hits) {
                    if (Test-AllowlistedPersistence ($valueName + " " + $valueData)) {
                        continue
                    }
                    Add-RegistryValueCandidate -Category "Startup registry" -Name $valueName -KeyPath $key -ValueName $valueName -ValueData $valueData -Risk "Review" -Note ("Matched: {0}. Action removes this startup value after logging it." -f $hits)
                }
            }
        }
        catch {
        }
    }

    foreach ($startupFolder in @(
        [Environment]::GetFolderPath("Startup"),
        [Environment]::GetFolderPath("CommonStartup")
    )) {
        if (-not (Test-Path -LiteralPath $startupFolder)) {
            continue
        }

        Get-ChildItem -LiteralPath $startupFolder -Force -ErrorAction SilentlyContinue | ForEach-Object {
            $targetText = $_.FullName
            if ($_.Extension -ieq ".lnk") {
                try {
                    $shell = New-Object -ComObject WScript.Shell
                    $shortcut = $shell.CreateShortcut($_.FullName)
                    $targetText = $targetText + " " + $shortcut.TargetPath + " " + $shortcut.Arguments
                }
                catch {
                }
            }

            $hits = Get-PersistenceHitReason $targetText
            if ($hits) {
                Add-ResultRow -Selected:$false -Category "Startup folder" -Name $_.Name -Bytes ([int64]$_.Length) -Risk "Review" -Note ("Matched: {0}. Action moves the startup shortcut/file to quarantine." -f $hits) -Path $_.FullName -Action "QuarantinePath" -Recommended:$false
            }
        }
    }
}

function Add-ScheduledTaskCandidates {
    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
            $task = $_
            $actionText = ($task.Actions | ForEach-Object { @($_.Execute, $_.Arguments, $_.WorkingDirectory) -join " " }) -join " "
            $text = @($task.TaskName, $task.TaskPath, $task.Author, $task.Description, $actionText) -join " "
            $hits = Get-PersistenceHitReason $text
            if (-not $hits) {
                return
            }
            if (Test-AllowlistedPersistence $text) {
                return
            }

            $risk = "Review"
            if ($hits -match "suspicious persistence") {
                $risk = "High"
            }

            Add-ResultRow -Selected:$false -Category "Scheduled task" -Name ($task.TaskPath + $task.TaskName) -Bytes 0 -Risk $risk -Note ("Matched: {0}. Action disables this scheduled task." -f $hits) -Path ($task.TaskPath + "|" + $task.TaskName) -Action "DisableTask" -Recommended:$false
        }
    }
    catch {
    }
}

function Add-ServiceCandidates {
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object {
        $_.StartMode -ne "Disabled"
    } | ForEach-Object {
        $svc = $_
        $text = @($svc.Name, $svc.DisplayName, $svc.Description, $svc.PathName) -join " "
        $hits = Get-PersistenceHitReason $text
        if (-not $hits) {
            return
        }

        $risk = "Review"
        if ($hits -match "suspicious persistence") {
            $risk = "High"
        }
        Add-ResultRow -Selected:$false -Category "Service" -Name ($svc.DisplayName + " [" + $svc.Name + "]") -Bytes 0 -Risk $risk -Note ("Matched: {0}. Action stops and disables the service; it does not delete service files." -f $hits) -Path $svc.Name -Action "DisableService" -Recommended:$false
    }
}

function Add-RunningProcessCandidates {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | ForEach-Object {
        $proc = $_
        $text = @($proc.Name, $proc.ExecutablePath, $proc.CommandLine) -join " "
        $hits = Get-HitReason $text
        if (-not $hits) {
            return
        }

        if ($proc.ExecutablePath -match "\\Windows\\System32\\(WindowsPowerShell\\v1\.0\\)?(powershell|cmd)\.exe$") {
            return
        }

        Add-ResultRow -Selected:$false -Category "Running process" -Name ($proc.Name + " PID " + $proc.ProcessId) -Bytes 0 -Risk "Review" -Note ("Matched: {0}. This row is for review; use Open location and Defender scan before removal." -f $hits) -Path ("Process::" + $proc.ProcessId + "::" + $proc.ExecutablePath) -Action "ManualReview" -Recommended:$false
    }
}

function Add-BrowserPolicyCandidates {
    $policyRoots = @(
        "HKCU:\Software\Policies\Google\Chrome",
        "HKLM:\Software\Policies\Google\Chrome",
        "HKCU:\Software\Policies\Microsoft\Edge",
        "HKLM:\Software\Policies\Microsoft\Edge"
    )

    foreach ($root in $policyRoots) {
        foreach ($sub in @("ExtensionInstallForcelist", "ExtensionInstallSources", "RestoreOnStartupURLs")) {
            $key = Join-Path $root $sub
            if (-not (Test-Path -LiteralPath $key)) {
                continue
            }

            try {
                $regKey = Get-Item -LiteralPath $key -ErrorAction Stop
                foreach ($valueName in $regKey.GetValueNames()) {
                    $valueData = [string]$regKey.GetValue($valueName)
                    Add-RegistryValueCandidate -Category "Browser forced policy" -Name ($sub + " / " + $valueName) -KeyPath $key -ValueName $valueName -ValueData $valueData -Risk "High" -Note ("Forced browser policy: {0}. Action removes this policy value after logging it." -f $valueData)
                }
            }
            catch {
            }
        }

        if (Test-Path -LiteralPath $root) {
            try {
                $regKey = Get-Item -LiteralPath $root -ErrorAction Stop
                foreach ($valueName in @("HomepageLocation", "RestoreOnStartup", "DefaultSearchProviderSearchURL", "ExtensionInstallBlocklist")) {
                    if ($regKey.GetValueNames() -contains $valueName) {
                        $valueData = [string]$regKey.GetValue($valueName)
                        Add-RegistryValueCandidate -Category "Browser policy" -Name $valueName -KeyPath $root -ValueName $valueName -ValueData $valueData -Risk "Review" -Note ("Browser policy value: {0}. Action removes this policy value after logging it." -f $valueData)
                    }
                }
            }
            catch {
            }
        }
    }
}

function Add-NetworkHijackCandidates {
    $inetKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    try {
        $p = Get-ItemProperty -LiteralPath $inetKey -ErrorAction Stop
        if ([int]$p.ProxyEnable -eq 1 -and -not [string]::IsNullOrWhiteSpace($p.ProxyServer)) {
            Add-ResultRow -Selected:$false -Category "Network setting" -Name "User proxy is enabled" -Bytes 0 -Risk "Review" -Note ("ProxyServer: {0}. Action disables the user proxy and logs old values." -f $p.ProxyServer) -Path $inetKey -Action "ResetProxy" -Recommended:$false
        }
    }
    catch {
    }

    $hosts = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    if (Test-Path -LiteralPath $hosts) {
        try {
            $customLines = @(Get-Content -LiteralPath $hosts -ErrorAction Stop | Where-Object {
                $line = $_.Trim()
                $line -and -not $line.StartsWith("#") -and $line -notmatch "localhost|255\.255\.255\.255|::1"
            })
            if ($customLines.Count -gt 0) {
                Add-ResultRow -Selected:$false -Category "Network setting" -Name "Hosts file has custom entries" -Bytes ([int64](Get-Item -LiteralPath $hosts).Length) -Risk "Manual" -Note ("Found {0} custom hosts line(s). Review manually before editing." -f $customLines.Count) -Path $hosts -Action "ManualReview" -Recommended:$false
            }
        }
        catch {
        }
    }
}

function Add-SuspiciousDirectoryCandidates {
    $roots = @(
        [Environment]::GetEnvironmentVariable("ProgramFiles"),
        [Environment]::GetEnvironmentVariable("ProgramFiles(x86)"),
        $env:ProgramData,
        $env:LOCALAPPDATA,
        $env:APPDATA,
        (Join-Path $env:USERPROFILE "Downloads"),
        (Join-Path $env:USERPROFILE "Desktop")
    )

    foreach ($root in $roots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Set-Status ("Deep scan folders: {0}" -f $root)
        $dirs = @()
        try {
            $firstLevel = @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)
            $dirs += $firstLevel
            foreach ($dir in $firstLevel) {
                try {
                    $dirs += @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue)
                }
                catch {
                }
            }
        }
        catch {
        }

        foreach ($dir in $dirs) {
            $hits = Get-HitReason $dir.FullName
            if (-not $hits) {
                continue
            }

            $size = Get-DirectorySizeBytes -Path $dir.FullName
            Add-ResultRow -Selected:$false -Category "Suspicious folder" -Name $dir.Name -Bytes $size -Risk "Manual" -Note ("Matched: {0}. Action moves the folder to quarantine; review before selecting." -f $hits) -Path $dir.FullName -Action "QuarantinePath" -Recommended:$false
        }
    }
}

function Add-SuspiciousDownloadCandidates {
    foreach ($root in @((Join-Path $env:USERPROFILE "Downloads"), (Join-Path $env:USERPROFILE "Desktop"))) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        Get-ChildItem -LiteralPath $root -File -Force -ErrorAction SilentlyContinue | Where-Object {
            $_.Extension -match "\.(exe|msi|bat|cmd|vbs|js|ps1|scr|zip|rar|7z)$"
        } | ForEach-Object {
            $hits = Get-HitReason $_.Name
            if ($hits) {
                Add-ResultRow -Selected:$false -Category "Suspicious installer/archive" -Name $_.Name -Bytes ([int64]$_.Length) -Risk "Manual" -Note ("Matched: {0}. Action moves this file to quarantine." -f $hits) -Path $_.FullName -Action "QuarantinePath" -Recommended:$false
            }
        }
    }
}

function Add-DeepPupScan {
    Set-Status "Deep scan: installed apps..."
    Add-InstalledPupCandidates
    Set-Status "Deep scan: startup entries..."
    Add-StartupCandidates
    Set-Status "Deep scan: scheduled tasks..."
    Add-ScheduledTaskCandidates
    Set-Status "Deep scan: services..."
    Add-ServiceCandidates
    Set-Status "Deep scan: browser policies..."
    Add-BrowserPolicyCandidates
    Set-Status "Deep scan: network settings..."
    Add-NetworkHijackCandidates
    Set-Status "Deep scan: running processes..."
    Add-RunningProcessCandidates
    Set-Status "Deep scan: suspicious folders..."
    Add-SuspiciousDirectoryCandidates
    Set-Status "Deep scan: suspicious installers..."
    Add-SuspiciousDownloadCandidates
}

function Get-TotalBytes {
    param($Rows)

    $total = [int64]0
    foreach ($row in $Rows) {
        $total += [int64]$row["Bytes"]
    }
    return $total
}

function Invoke-Scan {
    Initialize-ResultTable
    Set-Status "Scanning cache and file candidates..."

    Add-CommonSystemCaches
    Add-BrowserCaches
    Add-ApplicationCaches
    Add-DeveloperCaches
    Add-DownloadCandidates

    if ($script:EnableDeepScan) {
        Add-DeepPupScan
    }

    if ($script:IncludeLargeFiles) {
        Add-LargeInstalledApps -ThresholdMB $script:LargeThresholdMB
        Add-LargeSoftwareFolders -ThresholdMB $script:LargeThresholdMB
        Add-LargeFileCandidates -ThresholdMB $script:LargeThresholdMB -FullDrive:$script:FullDriveLargeScan
    }

    if ($script:Rows.Rows.Count -gt 0) {
        $script:Rows.DefaultView.Sort = "Bytes DESC"
    }

    $total = Get-TotalBytes $script:Rows.Rows
    Set-Status ("Scan complete: {0} items, {1} total" -f $script:Rows.Rows.Count, (Format-Bytes $total)) -Busy:$false
}

function Test-DeletableTarget {
    param(
        [string]$Path,
        [string]$Action
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($Action -eq "RemoveFile") {
            return (-not $item.PSIsContainer)
        }

        if ($Action -eq "ClearContents") {
            if (-not $item.PSIsContainer) {
                return $false
            }

            $full = $item.FullName.TrimEnd("\")
            $blocked = New-Object System.Collections.Generic.List[string]
            Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Root) {
                    [void]$blocked.Add($_.Root.TrimEnd("\"))
                }
            }

            foreach ($pathToBlock in @(
                $env:SystemRoot,
                $env:USERPROFILE,
                $env:APPDATA,
                $env:LOCALAPPDATA,
                $env:ProgramData,
                [Environment]::GetEnvironmentVariable("ProgramFiles"),
                [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
            )) {
                if (-not [string]::IsNullOrWhiteSpace($pathToBlock)) {
                    [void]$blocked.Add($pathToBlock.TrimEnd("\"))
                }
            }

            foreach ($blockedPath in $blocked) {
                if ($full -ieq $blockedPath) {
                    return $false
                }
            }
            return $true
        }
    }
    catch {
        return $false
    }

    return $false
}

function Get-SelectedDataRows {
    $selected = @()
    foreach ($row in $script:Rows.Rows) {
        if ([bool]$row["Selected"]) {
            $selected += $row
        }
    }
    return $selected
}

function Write-ActionLog {
    param(
        [System.Data.DataRow]$Row,
        [string]$Result,
        [string]$Detail
    )

    try {
        $entry = [pscustomobject]@{
            Time = (Get-Date).ToString("s")
            Category = [string]$Row["Category"]
            Name = [string]$Row["Name"]
            Action = [string]$Row["Action"]
            Path = [string]$Row["Path"]
            Result = $Result
            Detail = $Detail
        }
        $entry | ConvertTo-Json -Compress | Add-Content -LiteralPath $script:ActionLog -Encoding UTF8
    }
    catch {
    }
}

function Get-SafeFileName {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return "item"
    }

    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $safe = New-Object System.Text.StringBuilder
    foreach ($ch in $Name.ToCharArray()) {
        if ($invalid -contains $ch -or $ch -eq ':') {
            [void]$safe.Append('_')
        }
        else {
            [void]$safe.Append($ch)
        }
    }

    $result = $safe.ToString()
    if ($result.Length -gt 120) {
        $result = $result.Substring(0, 120)
    }
    if ([string]::IsNullOrWhiteSpace($result)) {
        return "item"
    }
    return $result
}

function Get-QuarantineSessionPath {
    if ([string]::IsNullOrWhiteSpace($script:QuarantineSession)) {
        $script:QuarantineSession = Join-Path $script:QuarantineRoot (Get-Date -Format "yyyyMMdd_HHmmss")
    }
    if (-not (Test-Path -LiteralPath $script:QuarantineSession)) {
        New-Item -Path $script:QuarantineSession -ItemType Directory -Force | Out-Null
    }
    return $script:QuarantineSession
}

function Move-ToQuarantine {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path does not exist."
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $session = Get-QuarantineSessionPath
    $leaf = Get-SafeFileName ($item.Name)
    $dest = Join-Path $session $leaf
    $i = 1
    while (Test-Path -LiteralPath $dest) {
        $dest = Join-Path $session ("{0}_{1}" -f $leaf, $i)
        $i++
    }

    Move-Item -LiteralPath $Path -Destination $dest -Force -ErrorAction Stop
    return $dest
}

function Disable-RegistryValue {
    param([string]$PathSpec)

    $parts = $PathSpec -split "\|", 2
    if ($parts.Count -ne 2) {
        throw "Invalid registry value spec."
    }

    $keyPath = $parts[0]
    $valueName = $parts[1]
    $regKey = Get-Item -LiteralPath $keyPath -ErrorAction Stop
    $oldValue = $regKey.GetValue($valueName)
    Remove-ItemProperty -LiteralPath $keyPath -Name $valueName -Force -ErrorAction Stop
    return ("Removed registry value. Old value: {0}" -f $oldValue)
}

function Disable-TaskCandidate {
    param([string]$PathSpec)

    $parts = $PathSpec -split "\|", 2
    if ($parts.Count -ne 2) {
        throw "Invalid scheduled task spec."
    }

    Disable-ScheduledTask -TaskPath $parts[0] -TaskName $parts[1] -ErrorAction Stop | Out-Null
    return "Scheduled task disabled."
}

function Disable-ServiceCandidate {
    param([string]$ServiceName)

    try {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }
    catch {
    }
    Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
    return "Service stopped if possible and startup type set to Disabled."
}

function Reset-ProxyCandidate {
    param([string]$KeyPath)

    $p = Get-ItemProperty -LiteralPath $KeyPath -ErrorAction Stop
    $old = @($p.ProxyEnable, $p.ProxyServer) -join " | "
    Set-ItemProperty -LiteralPath $KeyPath -Name ProxyEnable -Value 0 -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $KeyPath -Name ProxyServer -Value "" -Force -ErrorAction SilentlyContinue
    return ("Proxy disabled. Old values: {0}" -f $old)
}

function Start-UninstallerCommand {
    param([string]$CommandSpec)

    $cmd = $CommandSpec
    if ($cmd.StartsWith("UninstallCommand::")) {
        $cmd = $cmd.Substring("UninstallCommand::".Length)
    }
    $cmd = $cmd.Trim()

    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Start-Process "ms-settings:appsfeatures"
        return "Opened Apps & Features."
    }

    if ($cmd -ieq "ms-settings:appsfeatures") {
        Start-Process $cmd
        return "Opened Apps & Features."
    }

    if ($cmd -match "(?i)msiexec(\.exe)?\s+/(i|x)\s*(\{[0-9a-f\-]+\})") {
        Start-Process "msiexec.exe" -ArgumentList ("/x " + $matches[3])
        return "Started MSI uninstaller."
    }

    if ($cmd.StartsWith('"')) {
        $end = $cmd.IndexOf('"', 1)
        if ($end -gt 1) {
            $exe = $cmd.Substring(1, $end - 1)
            $args = $cmd.Substring($end + 1).Trim()
            Start-Process -FilePath $exe -ArgumentList $args
            return "Started vendor uninstaller."
        }
    }

    Start-Process "cmd.exe" -ArgumentList ("/c start """" " + $cmd)
    return "Started uninstall command through cmd."
}

function Invoke-CleanupAction {
    param([System.Data.DataRow]$Row)

    $path = [string]$Row["Path"]
    $action = [string]$Row["Action"]

    switch ($action) {
        "RemoveFile" {
            if (-not (Test-DeletableTarget -Path $path -Action $action)) {
                throw "Path missing, not a file, or blocked by safety guard."
            }
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
            return "File removed."
        }
        "ClearContents" {
            if (-not (Test-DeletableTarget -Path $path -Action $action)) {
                throw "Path missing, not a folder, or blocked by safety guard."
            }
            Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            return "Folder contents removed. Locked items may remain."
        }
        "QuarantinePath" {
            $dest = Move-ToQuarantine -Path $path
            return ("Moved to quarantine: {0}" -f $dest)
        }
        "DisableRegistryValue" {
            return (Disable-RegistryValue -PathSpec $path)
        }
        "DisableTask" {
            return (Disable-TaskCandidate -PathSpec $path)
        }
        "DisableService" {
            return (Disable-ServiceCandidate -ServiceName $path)
        }
        "ResetProxy" {
            return (Reset-ProxyCandidate -KeyPath $path)
        }
        "OpenUninstaller" {
            return (Start-UninstallerCommand -CommandSpec $path)
        }
        "ManualReview" {
            throw "Manual review only. No automated cleanup action is attached."
        }
        default {
            throw ("Unknown action: {0}" -f $action)
        }
    }
}

function Remove-SelectedRows {
    param([System.Windows.Forms.DataGridView]$Grid)

    if ($Grid) {
        [void]$Grid.EndEdit()
    }

    $selectedRows = @(Get-SelectedDataRows)
    if ($selectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("还没有勾选要处理的项目。", "未选择项目", "OK", "Information") | Out-Null
        return
    }

    $total = Get-TotalBytes $selectedRows
    $message = "将处理 {0} 个已选项目，预计涉及 {1}。`r`n`r`n可能执行的动作包括：删除缓存文件、把可疑项目移入隔离区、禁用启动项/计划任务/服务、重置代理，或打开卸载程序。操作日志会写在脚本所在目录。" -f $selectedRows.Count, (Format-Bytes $total)
    $confirm = [System.Windows.Forms.MessageBox]::Show($message, "确认处理选中项", "YesNo", "Warning")
    if ($confirm -ne "Yes") {
        return
    }

    $deleted = 0
    $failed = 0
    $deletedBytes = [int64]0

    foreach ($row in $selectedRows) {
        $path = [string]$row["Path"]
        $action = [string]$row["Action"]
        Set-Status ("正在处理 {0}: {1}" -f (Convert-ActionText $action), $path)

        try {
            $detail = Invoke-CleanupAction -Row $row
            $deleted++
            $deletedBytes += [int64]$row["Bytes"]
            $row["Selected"] = $false
            $row["Size"] = "已处理"
            $row["Bytes"] = 0
            $row["Note"] = $detail
            Write-ActionLog -Row $row -Result "OK" -Detail $detail
        }
        catch {
            $failed++
            $row["Selected"] = $false
            $row["Note"] = "处理失败或已跳过：$($_.Exception.Message)"
            Write-ActionLog -Row $row -Result "FAILED" -Detail $_.Exception.Message
        }
    }

    Set-Status ("处理完成：成功 {0} 项，失败/跳过 {1} 项，预计释放或隔离 {2}" -f $deleted, $failed, (Format-Bytes $deletedBytes)) -Busy:$false
    [System.Windows.Forms.MessageBox]::Show(("处理完成。`r`n成功: {0}`r`n失败/跳过: {1}`r`n预计释放或隔离: {2}" -f $deleted, $failed, (Format-Bytes $deletedBytes)), "完成", "OK", "Information") | Out-Null
}

function Update-GridColumns {
    param([System.Windows.Forms.DataGridView]$Grid)

    foreach ($column in $Grid.Columns) {
        $column.ReadOnly = $true
    }

    if ($Grid.Columns["Selected"]) {
        $Grid.Columns["Selected"].ReadOnly = $false
        $Grid.Columns["Selected"].Width = 70
    }
    if ($Grid.Columns["Category"]) { $Grid.Columns["Category"].Width = 145 }
    if ($Grid.Columns["Name"]) { $Grid.Columns["Name"].Width = 220 }
    if ($Grid.Columns["Size"]) { $Grid.Columns["Size"].Width = 100 }
    if ($Grid.Columns["Risk"]) { $Grid.Columns["Risk"].Width = 86 }
    if ($Grid.Columns["Note"]) { $Grid.Columns["Note"].Width = 420 }
    if ($Grid.Columns["Path"]) { $Grid.Columns["Path"].AutoSizeMode = "Fill" }
    if ($Grid.Columns["Action"]) { $Grid.Columns["Action"].Visible = $false }
    if ($Grid.Columns["Bytes"]) { $Grid.Columns["Bytes"].Visible = $false }
    if ($Grid.Columns["Recommended"]) { $Grid.Columns["Recommended"].Visible = $false }
}

function Start-DefenderScan {
    param([string]$ScanType)

    $command = "Start-MpScan -ScanType {0}; Write-Host ''; Write-Host '已提交 Windows Defender 扫描请求。命令返回后可以关闭此窗口。'; pause" -f $ScanType
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-NoExit", "-Command", $command)
}

function Open-QuarantineFolder {
    if (-not (Test-Path -LiteralPath $script:QuarantineRoot)) {
        New-Item -Path $script:QuarantineRoot -ItemType Directory -Force | Out-Null
    }
    Start-Process explorer.exe -ArgumentList "`"$script:QuarantineRoot`""
}

function Get-RiskRank {
    param([string]$Risk)

    switch -Regex ($Risk) {
        "High" { return 4 }
        "Manual" { return 3 }
        "Review" { return 2 }
        "Safe" { return 1 }
        default { return 0 }
    }
}

function Get-WorstRisk {
    param($Rows)

    $risk = "Safe"
    $rank = 0
    foreach ($row in $Rows) {
        $rowRisk = [string]$row["Risk"]
        $rowRank = Get-RiskRank $rowRisk
        if ($rowRank -gt $rank) {
            $rank = $rowRank
            $risk = $rowRisk
        }
    }
    return $risk
}

function Get-RiskColor {
    param([string]$Risk)

    switch -Regex ($Risk) {
        "High" { return [System.Drawing.Color]::Firebrick }
        "Manual" { return [System.Drawing.Color]::DarkOrange }
        "Review" { return [System.Drawing.Color]::SaddleBrown }
        "Safe" { return [System.Drawing.Color]::ForestGreen }
        default { return [System.Drawing.Color]::Black }
    }
}

function Convert-RiskText {
    param([string]$Risk)

    switch -Regex ($Risk) {
        "High" { return "高风险" }
        "Manual" { return "人工确认" }
        "Review" { return "需确认" }
        "Safe" { return "安全" }
        default { return $Risk }
    }
}

function Convert-StatusText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }
    $text = $Text
    $text = $text -replace "^Ready$", "准备就绪"
    $text = $text -replace "^Scanning cache and file candidates\.\.\.$", "正在扫描缓存和候选文件..."
    $text = $text -replace "^Scanning: ", "正在扫描: "
    $text = $text -replace "^Deep scan: installed apps\.\.\.$", "深度扫描：已安装软件..."
    $text = $text -replace "^Deep scan: startup entries\.\.\.$", "深度扫描：开机启动项..."
    $text = $text -replace "^Deep scan: scheduled tasks\.\.\.$", "深度扫描：计划任务..."
    $text = $text -replace "^Deep scan: services\.\.\.$", "深度扫描：系统服务..."
    $text = $text -replace "^Deep scan: browser policies\.\.\.$", "深度扫描：浏览器策略..."
    $text = $text -replace "^Deep scan: network settings\.\.\.$", "深度扫描：网络设置..."
    $text = $text -replace "^Deep scan: running processes\.\.\.$", "深度扫描：运行中进程..."
    $text = $text -replace "^Deep scan: suspicious folders\.\.\.$", "深度扫描：可疑目录..."
    $text = $text -replace "^Deep scan: suspicious installers\.\.\.$", "深度扫描：可疑安装包..."
    $text = $text -replace "^Deep scan folders: ", "深度扫描目录: "
    $text = $text -replace "^Scanning large files: ", "正在扫描大文件: "
    $text = $text -replace "^Sizing installed app: ", "正在计算已安装软件大小: "
    $text = $text -replace "^Sizing large software folder: ", "正在计算大型软件目录: "
    $text = $text -replace "^Sizing old WPS version folder: ", "正在计算 WPS 旧版本目录: "
    $text = $text -replace "^Sizing DingDing possible old version folder: ", "正在计算钉钉疑似旧版本目录: "
    if ($text -match "^Scan complete: (\d+) items, (.+) total$") {
        return ("扫描完成：{0} 项，总计 {1}" -f $matches[1], $matches[2])
    }
    return $text
}

function Convert-ActionText {
    param([string]$Action)

    switch ($Action) {
        "RemoveFile" { return "删除文件" }
        "ClearContents" { return "清空目录内容" }
        "QuarantinePath" { return "移入隔离区" }
        "DisableRegistryValue" { return "禁用注册表启动项" }
        "DisableTask" { return "禁用计划任务" }
        "DisableService" { return "禁用服务" }
        "ResetProxy" { return "重置代理" }
        "OpenUninstaller" { return "打开卸载程序" }
        "ManualReview" { return "仅供人工查看" }
        default { return $Action }
    }
}

function Convert-CategoryText {
    param([string]$Category)

    switch -Regex ($Category) {
        "Browser cache" { return "浏览器缓存" }
        "App cache" { return "应用缓存" }
        "Windows temp" { return "Windows 临时文件" }
        "System reports" { return "系统报告/崩溃转储" }
        "Graphics cache" { return "显卡/图形缓存" }
        "Update cache" { return "系统更新缓存" }
        "Windows cache files" { return "Windows 缓存文件" }
        "E-commerce app cache" { return "电商软件缓存" }
        "Recycle Bin" { return "回收站" }
        "Chat app cache" { return "聊天软件缓存" }
        "Office app cache" { return "办公软件缓存" }
        "Media app cache" { return "媒体软件缓存" }
        "RPA app cache" { return "自动化软件缓存" }
        "Network app cache" { return "网络软件日志/缓存" }
        "Old app version folder" { return "旧版本/升级残留目录" }
        "Container data / disk image" { return "容器数据盘/镜像文件" }
        "AI model data" { return "AI 模型数据" }
        "Developer cache" { return "开发工具缓存" }
        "Download candidates" { return "下载目录候选文件" }
        "Large file candidates" { return "大文件候选" }
        "Large installed app" { return "大型已安装软件" }
        "Large software folder" { return "大型软件目录" }
        "Installed PUP candidate" { return "疑似捆绑/流氓软件" }
        "Startup registry" { return "注册表启动项" }
        "Startup folder" { return "启动文件夹" }
        "Scheduled task" { return "计划任务" }
        "Service" { return "系统服务" }
        "Browser policy" { return "浏览器策略" }
        "Browser forced policy" { return "浏览器强制策略" }
        "Network setting" { return "网络设置" }
        "Running process" { return "运行中进程" }
        "Suspicious folder" { return "可疑目录" }
        "Suspicious installer" { return "可疑安装包/压缩包" }
        default { return $Category }
    }
}

function Convert-GroupText {
    param([string]$Group)

    switch -Regex ($Group) {
        "^Windows system$" { return "Windows 系统" }
        "^Developer caches$" { return "开发工具缓存" }
        "^Graphics driver caches$" { return "显卡驱动缓存" }
        "^Downloads$" { return "下载目录" }
        "^Large files$" { return "大文件" }
        "^Other browser cleanup$" { return "其他浏览器清理" }
        "^Enterprise WeChat / WXWork$" { return "企业微信 / WXWork" }
        "^Tencent PC Manager / QQPCMgr$" { return "腾讯电脑管家 / QQPCMgr" }
        "^Doudian Workbench$" { return "抖店工作台" }
        "^DingDing$" { return "钉钉" }
        "^DingTalk$" { return "钉钉" }
        "^NetEase CloudMusic$" { return "网易云音乐" }
        "^Anaconda / Conda$" { return "Anaconda / Conda" }
        "^Autodesk / Maya$" { return "Autodesk / Maya" }
        "^JetBrains / PyCharm$" { return "JetBrains / PyCharm" }
        "^Software folder: (.+)$" { return ("大型目录: " + $matches[1]) }
        "^Installed app: (.+)$" { return ("已安装软件: " + $matches[1]) }
        "^Suspicious item: (.+)$" { return ("可疑项目: " + $matches[1]) }
        default { return $Group }
    }
}

function Convert-ItemNameText {
    param([string]$Name)

    $result = $Name
    $replacements = [ordered]@{
        "User TEMP" = "当前用户临时文件"
        "LocalAppData Temp" = "应用临时目录"
        "Windows Temp" = "Windows 临时目录"
        "Windows Update downloads" = "Windows 更新下载缓存"
        "Delivery Optimization cache" = "传递优化缓存"
        "Thumbnail cache" = "缩略图缓存"
        "Icon cache" = "图标缓存"
        "User crash dumps" = "用户崩溃转储"
        "Windows minidumps" = "Windows 蓝屏小转储"
        "Hosts file has custom entries" = "hosts 文件存在自定义条目"
        "User proxy is enabled" = "当前用户代理已启用"
        "Recycle Bin" = "回收站"
        "old version folder" = "旧版本目录"
        "possible old version folder" = "疑似旧版本目录"
        "add-on package pool" = "插件包缓存池"
        "add-on index cache" = "插件索引缓存"
        "download cache" = "下载缓存"
        "logs" = "日志"
        "crash dumps" = "崩溃转储"
        "WSL data disk" = "WSL 数据盘"
        "VM data disk" = "虚拟机数据盘"
        "model store" = "模型目录"
        "Cache" = "缓存"
        "Code Cache" = "代码缓存"
        "GPUCache" = "GPU 缓存"
        "ShaderCache" = "着色器缓存"
        "GrShaderCache" = "图形着色器缓存"
        "DawnCache" = "Dawn 缓存"
        "Crashpad\reports" = "崩溃报告"
        "Service Worker\CacheStorage" = "Service Worker 缓存"
        "Service Worker\ScriptCache" = "Service Worker 脚本缓存"
    }

    foreach ($key in $replacements.Keys) {
        $result = $result -replace [regex]::Escape($key), $replacements[$key]
    }
    return $result
}

function Convert-NoteText {
    param([string]$Note)

    if ([string]::IsNullOrWhiteSpace($Note)) {
        return ""
    }

    $text = $Note
    if ($text -match "^WeChat cache folder") {
        return "微信缓存目录；不会清理聊天数据库、图片、视频和文件正文。"
    }
    if ($text -match "^WeChat temporary files") {
        return "微信临时文件；不会清理聊天数据库、图片、视频和文件正文。"
    }
    if ($text -match "^Temporary custom-emotion cache") {
        return "微信自定义表情临时缓存；删除前建议确认。"
    }
    if ($text -match "^Enterprise WeChat") {
        return "企业微信内置浏览器缓存；不会清理聊天文件和微盘内容，建议在企业微信关闭时处理。"
    }
    if ($text -match "^Current-user temporary files") {
        return "当前用户临时文件；正在占用的文件会自动跳过。"
    }
    if ($text -match "^Application temporary files") {
        return "应用临时文件；正在占用的文件会自动跳过。"
    }
    if ($text -match "^System temporary files") {
        return "系统临时文件；部分项目可能需要管理员权限。"
    }
    if ($text -match "^Windows Error Reporting archive") {
        return "Windows 错误报告归档；通常只在排查崩溃问题时需要。"
    }
    if ($text -match "^Windows Error Reporting queue") {
        return "Windows 错误报告队列；通常只在排查崩溃问题时需要。"
    }
    if ($text -match "^Global Windows Error Reporting archive") {
        return "全局 Windows 错误报告归档；通常只在排查崩溃问题时需要，可能需要管理员权限。"
    }
    if ($text -match "^Global Windows Error Reporting queue") {
        return "全局 Windows 错误报告队列；通常只在排查崩溃问题时需要，可能需要管理员权限。"
    }
    if ($text -match "^DirectX shader cache") {
        return "DirectX 着色器缓存；游戏和应用会自动重建。"
    }
    if ($text -match "^NVIDIA shader cache") {
        return "NVIDIA 着色器缓存；显卡驱动会按需重建。"
    }
    if ($text -match "^NVIDIA OpenGL cache") {
        return "NVIDIA OpenGL 缓存；显卡驱动会按需重建。"
    }
    if ($text -match "^NVIDIA global cache") {
        return "NVIDIA 全局缓存；显卡驱动会按需重建，可能需要管理员权限。"
    }
    if ($text -match "^AMD shader cache") {
        return "AMD 着色器缓存；显卡驱动会按需重建。"
    }
    if ($text -match "^AMD OpenGL cache") {
        return "AMD OpenGL 缓存；显卡驱动会按需重建。"
    }
    if ($text -match "^Windows Update installer cache") {
        return "Windows 更新安装缓存；建议确认当前没有正在更新后再清理。"
    }
    if ($text -match "^Delivery Optimization cache") {
        return "Windows 传递优化缓存；清理后系统需要时会重新下载，可能需要管理员权限。"
    }
    if ($text -match "^Blue-screen minidumps") {
        return "蓝屏小转储；如果不需要排查蓝屏问题，可以清理。"
    }
    if ($text -match "^Clears the recycle bin folder") {
        return "清理该磁盘的回收站目录；请先确认里面没有要恢复的文件。"
    }
    if ($text -match "^Firefox network cache") {
        return "Firefox 网络缓存；不会清理书签、扩展和登录状态。"
    }
    if ($text -match "^Firefox startup cache") {
        return "Firefox 启动缓存；浏览器会自动重建。"
    }
    if ($text -match "^WPS cache\.|^WPS Office cache|^WPS office6 cache") {
        return "WPS 缓存；不会清理文档。"
    }
    if ($text -match "^WPS add-on package pool") {
        return "WPS 插件包缓存池；WPS 可能会重新下载插件，不会清理文档。"
    }
    if ($text -match "^WPS add-on index cache") {
        return "WPS 插件索引缓存；WPS 会自动重建，不会清理文档。"
    }
    if ($text -match "^WPS internal download cache") {
        return "WPS 内部下载缓存；不会清理文档，删除前建议确认。"
    }
    if ($text -match "^WPS old version/update rollback folder") {
        return "WPS 旧版本或升级回滚目录；这不是文档缓存，隔离前请确认当前 WPS 可正常运行。"
    }
    if ($text -match "^Tencent Meeting") {
        return "腾讯会议缓存或日志；不会清理会议文件和账号设置。"
    }
    if ($text -match "^DingTalk logs") {
        return "钉钉日志；不会清理聊天文件和用户设置。"
    }
    if ($text -match "^DingTalk diagnostic logs") {
        return "钉钉诊断日志；不会清理聊天文件和用户设置。"
    }
    if ($text -match "^DingTalk updater logs") {
        return "钉钉更新日志；可以自动重建。"
    }
    if ($text -match "^DingTalk crash dumps") {
        return "钉钉崩溃转储；通常只在排查问题时需要。"
    }
    if ($text -match "^DingTalk account media/cache directory") {
        return "钉钉账号媒体/缓存目录；可能包含和账号相关的本地数据，请先确认。"
    }
    if ($text -match "^DingDing keeps current/current_new") {
        return "钉钉同时保留 current/current_new 版本目录。看起来像升级残留，但需要先确认当前正在使用哪个目录。"
    }
    if ($text -match "^Docker Desktop UI graphics cache") {
        return "Docker Desktop 界面图形缓存；Docker 会自动重建。"
    }
    if ($text -match "^Docker Desktop logs") {
        return "Docker Desktop 日志；不会清理容器、镜像、卷和设置。"
    }
    if ($text -match "^Docker Desktop installation logs") {
        return "Docker Desktop 安装日志；通常可以清理。"
    }
    if ($text -match "^Docker WSL disk image") {
        return "Docker WSL 数据盘。这不是普通缓存，里面可能有镜像、容器和卷；建议使用 Docker Desktop 清理或 docker system prune，不要直接删除 VHDX。"
    }
    if ($text -match "^Docker Desktop VM disk image") {
        return "Docker Desktop 虚拟机数据盘，可能包含容器、镜像和卷；建议用 Docker 自带清理功能，不要直接删除文件。"
    }
    if ($text -match "^Ollama logs") {
        return "Ollama 日志；不会清理模型和设置。"
    }
    if ($text -match "^Ollama downloader temporary/cache") {
        return "Ollama 下载器临时/缓存目录；删除前建议确认。"
    }
    if ($text -match "^Ollama downloaded model store") {
        return "Ollama 已下载模型目录。这不是普通缓存；请用 ollama rm 删除不用的模型，或手动确认后处理。"
    }
    if ($text -match "^Tencent xwechat logs") {
        return "腾讯 xwechat 日志；不会清理聊天数据库和文件。"
    }
    if ($text -match "^Tencent xwechat embedded-browser code cache") {
        return "腾讯 xwechat 内置浏览器代码缓存；不会清理聊天数据库和文件。"
    }
    if ($text -match "^NetEase CloudMusic") {
        return "网易云音乐缓存；如果依赖离线音乐缓存，请先确认。"
    }
    if ($text -match "^ShadowBot cache") {
        return "影刀缓存；如果自动化任务正在运行，请先确认再处理。"
    }
    if ($text -match "^ShadowBot logs") {
        return "影刀日志；不会清理自动化项目。"
    }
    if ($text -match "^Clash Verge logs") {
        return "Clash Verge 日志；不会清理代理配置。"
    }
    if ($text -match "^Spotify") {
        return "Spotify 媒体或离线缓存；如果依赖离线内容，请先确认。"
    }
    if ($text -match "^npm download cache") {
        return "npm 下载缓存；以后安装依赖时可重新下载。"
    }
    if ($text -match "^Yarn download cache") {
        return "Yarn 下载缓存；以后安装依赖时可重新下载。"
    }
    if ($text -match "^Python pip download cache") {
        return "Python pip 下载缓存；以后安装依赖时可重新下载。"
    }
    if ($text -match "^pnpm global package store") {
        return "pnpm 全局包存储；项目可能需要重新下载依赖，建议确认。"
    }
    if ($text -match "^NuGet global package cache") {
        return "NuGet 全局包缓存；.NET 项目可能需要重新还原依赖，建议确认。"
    }
    if ($text -match "^Gradle build caches") {
        return "Gradle 构建缓存；Java 项目可能需要重新下载和索引依赖，建议确认。"
    }
    if ($text -match "^Maven local repository") {
        return "Maven 本地仓库；Java 项目可能需要重新下载依赖，建议确认。"
    }
    if ($text -match "^Conda package cache|^User conda package cache") {
        return "Conda 包缓存；更推荐使用 conda clean，直接删除前请确认。"
    }
    if ($text -match "^Installer/archive/image in Downloads") {
        return "下载目录中的安装包、压缩包或镜像文件；可能已经没用，也可能需要保留。"
    }
    if ($text -match "^File larger than (\d+) MB\. Review before deleting\. Last write: (.+)$") {
        return ("超过 {0} MB 的大文件；删除前请确认用途。最后修改时间: {1}" -f $matches[1], $matches[2])
    }
    if ($text -match "^Matched: (.+)\. Opens the vendor uninstaller") {
        return ("命中规则: {0}。动作会打开软件自带卸载程序或系统「应用和功能」，不会静默卸载。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. Action removes this startup value") {
        return ("命中规则: {0}。动作会记录后移除这个开机启动注册表项。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. Action moves the startup shortcut/file to quarantine") {
        return ("命中规则: {0}。动作会把这个启动项快捷方式或文件移入隔离区。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. Action disables this scheduled task") {
        return ("命中规则: {0}。动作会禁用这个计划任务。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. Action stops and disables the service") {
        return ("命中规则: {0}。动作会停止并禁用服务，但不会删除服务文件。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. This row is for review") {
        return ("命中规则: {0}。这是运行中进程，仅供检查；建议先打开位置并进行杀毒扫描。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. Action moves the folder to quarantine") {
        return ("命中规则: {0}。动作会把目录移入隔离区；选择前请确认。" -f $matches[1])
    }
    if ($text -match "^Matched: (.+)\. Action moves this file to quarantine") {
        return ("命中规则: {0}。动作会把文件移入隔离区。" -f $matches[1])
    }
    if ($text -match "^Browser policy value: (.+)\. Action removes this policy value") {
        return ("浏览器策略值: {0}。动作会记录后移除此策略项。" -f $matches[1])
    }
    if ($text -match "^ProxyServer: (.+)\. Action disables the user proxy") {
        return ("当前代理服务器: {0}。动作会关闭当前用户代理并记录旧值。" -f $matches[1])
    }
    if ($text -match "^Found (\d+) custom hosts line") {
        return ("hosts 文件发现 {0} 行自定义记录；请手动确认后再处理。" -f $matches[1])
    }
    if ($text -match "Large installed application") {
        return ($text -replace "Large installed application\. Review before uninstalling\. Install location:", "这是大型已安装软件。卸载前请确认用途。安装位置:")
    }
    if ($text -match "Large top-level software or application-data folder") {
        return "这是大型软件目录或应用数据目录。请先打开位置确认用途，优先使用官方卸载程序，不要直接盲删。"
    }
    if ($text -match "Cache, GPU cache, service-worker cache") {
        return "浏览器缓存、GPU 缓存、Service Worker 缓存或崩溃报告；不会清理 Cookies、Local Storage、IndexedDB、书签和登录状态。"
    }
    if ($text -match "Electron or Chromium app cache") {
        return "Electron/Chromium 应用缓存或日志；不会清理登录数据和用户配置。"
    }
    if ($text -match "Windows thumbnail cache") {
        return "Windows 缩略图缓存；资源管理器会自动重建。"
    }
    if ($text -match "Windows icon cache") {
        return "Windows 图标缓存；资源管理器会自动重建。"
    }
    if ($text -match "Application crash dumps") {
        return "应用崩溃转储文件；通常只在排查问题时需要。"
    }
    if ($text -match "temporary files|Temporary files|temp") {
        return "临时文件；正在占用或权限不足的文件会自动跳过。"
    }
    if ($text -match "logs") {
        return "日志文件；通常可清理，正在使用的软件可能会重新生成。"
    }
    if ($text -match "Review before") {
        return ($text -replace "Review before deleting\.", "删除前请确认。" -replace "Review first", "请先确认")
    }
    if ($text -match "not targeted") {
        return ($text -replace "are not targeted", "不会被清理" -replace "is not targeted", "不会被清理")
    }
    return $text
}

function Convert-SelectionReasonText {
    param(
        [bool]$Selected,
        [bool]$Recommended,
        [string]$Risk,
        [string]$Action,
        [string]$Note
    )

    $riskText = Convert-RiskText $Risk
    $noteText = Convert-NoteText $Note
    if ($Recommended) {
        if ($Action -eq "ClearContents" -or $Action -eq "RemoveFile") {
            return ("默认勾选：风险等级为「{0}」，属于可重建的缓存/临时文件/日志/转储。原因：{1}" -f $riskText, $noteText)
        }
        return ("默认勾选：风险等级为「{0}」。原因：{1}" -f $riskText, $noteText)
    }

    if ($Risk -eq "Safe") {
        return ("默认不勾选：虽然标记为安全，但可能和用户数据或当前工作流有关，需要你确认。原因：{0}" -f $noteText)
    }
    return ("默认不勾选：风险等级为「{0}」，执行前需要人工确认。原因：{1}" -f $riskText, $noteText)
}

function Get-RowArrayFromNode {
    param([System.Windows.Forms.TreeNode]$Node)

    if (-not $Node) {
        return @()
    }
    if ($Node.Tag -is [System.Data.DataRow]) {
        return @($Node.Tag)
    }

    $rows = @()
    foreach ($child in $Node.Nodes) {
        if ($child.Tag -is [System.Data.DataRow]) {
            $rows += $child.Tag
        }
    }
    return $rows
}

function Update-GroupNodeText {
    param([System.Windows.Forms.TreeNode]$Node)

    if (-not $Node -or ($Node.Tag -is [System.Data.DataRow])) {
        return
    }

    $rows = @(Get-RowArrayFromNode $Node)
    $count = $rows.Count
    $selected = @($rows | Where-Object { [bool]$_["Selected"] }).Count
    $total = Get-TotalBytes $rows
    $risk = Get-WorstRisk $rows
    $groupName = [string]$Node.Tag.Group

    $Node.Text = ("{0}    已选 {1}/{2}    {3}    {4}" -f (Convert-GroupText $groupName), $selected, $count, (Format-Bytes $total), (Convert-RiskText $risk))
    $Node.ForeColor = Get-RiskColor $risk
    $Node.Checked = ($count -gt 0 -and $selected -eq $count)
}

function Set-DetailText {
    param(
        [System.Windows.Forms.TreeNode]$Node,
        [System.Windows.Forms.RichTextBox]$Detail
    )

    if (-not $Detail) {
        return
    }

    if (-not $Node) {
        $Detail.Text = "请选择左侧的软件分组或具体项目，右侧会显示为什么被扫描出来、为什么默认勾选或不勾选，以及将执行什么动作。"
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $rows = @(Get-RowArrayFromNode $Node)

    if ($Node.Tag -is [System.Data.DataRow]) {
        $row = $Node.Tag
        [void]$lines.Add((Convert-ItemNameText ([string]$row["Name"])))
        [void]$lines.Add("")
        [void]$lines.Add("所属分组: " + (Convert-GroupText ([string]$row["Group"])))
        [void]$lines.Add("项目类型: " + (Convert-CategoryText ([string]$row["Category"])))
        [void]$lines.Add("预计大小: " + [string]$row["Size"])
        [void]$lines.Add("风险等级: " + (Convert-RiskText ([string]$row["Risk"])))
        [void]$lines.Add("执行动作: " + (Convert-ActionText ([string]$row["Action"])))
        [void]$lines.Add("当前是否勾选: " + $(if ([bool]$row["Selected"]) { "是" } else { "否" }))
        [void]$lines.Add("")
        [void]$lines.Add("为什么会出现在这里:")
        [void]$lines.Add((Convert-NoteText ([string]$row["Note"])))
        [void]$lines.Add("")
        [void]$lines.Add("默认选择理由:")
        [void]$lines.Add((Convert-SelectionReasonText -Selected ([bool]$row["Selected"]) -Recommended ([bool]$row["Recommended"]) -Risk ([string]$row["Risk"]) -Action ([string]$row["Action"]) -Note ([string]$row["Note"])))
        [void]$lines.Add("")
        [void]$lines.Add("路径 / 命令:")
        [void]$lines.Add([string]$row["Path"])
    }
    else {
        $group = [string]$Node.Tag.Group
        $selected = @($rows | Where-Object { [bool]$_["Selected"] }).Count
        $total = Get-TotalBytes $rows
        $risk = Get-WorstRisk $rows

        [void]$lines.Add((Convert-GroupText $group))
        [void]$lines.Add("")
        [void]$lines.Add(("项目数量: {0}" -f $rows.Count))
        [void]$lines.Add(("已勾选: {0}" -f $selected))
        [void]$lines.Add(("预计大小/动作影响: {0}" -f (Format-Bytes $total)))
        [void]$lines.Add(("最高风险等级: {0}" -f (Convert-RiskText $risk)))
        [void]$lines.Add("")
        [void]$lines.Add("这个分组为什么出现:")
        $notes = @($rows | ForEach-Object { [string]$_["Note"] } | Select-Object -Unique -First 5)
        foreach ($note in $notes) {
            [void]$lines.Add("- " + (Convert-NoteText $note))
        }
        [void]$lines.Add("")
        [void]$lines.Add("默认勾选逻辑:")
        $reasonRows = @($rows | Select-Object -First 5)
        foreach ($reasonRow in $reasonRows) {
            [void]$lines.Add("- " + (Convert-SelectionReasonText -Selected ([bool]$reasonRow["Selected"]) -Recommended ([bool]$reasonRow["Recommended"]) -Risk ([string]$reasonRow["Risk"]) -Action ([string]$reasonRow["Action"]) -Note ([string]$reasonRow["Note"])))
        }
        [void]$lines.Add("")
        [void]$lines.Add("展开左侧分组后，可以逐个勾选或取消具体项目。")
    }

    $Detail.Text = ($lines -join [Environment]::NewLine)
}

function Build-ResultTree {
    param(
        [System.Windows.Forms.TreeView]$Tree,
        [System.Windows.Forms.RichTextBox]$Detail
    )

    if (-not $Tree) {
        return
    }

    $script:TreeSyncing = $true
    try {
        $Tree.BeginUpdate()
        $Tree.Nodes.Clear()

        $groups = @{}
        foreach ($row in $script:Rows.Rows) {
            $group = [string]$row["Group"]
            if (-not $groups.ContainsKey($group)) {
                $groups[$group] = New-Object System.Collections.ArrayList
            }
            [void]$groups[$group].Add($row)
        }

        $orderedGroups = foreach ($key in $groups.Keys) {
            $rows = @($groups[$key].ToArray())
            [pscustomobject]@{
                Name = $key
                Rows = $rows
                Bytes = Get-TotalBytes $rows
                RiskRank = Get-RiskRank (Get-WorstRisk $rows)
            }
        }

        foreach ($groupInfo in ($orderedGroups | Sort-Object RiskRank, Bytes -Descending)) {
            $parent = New-Object System.Windows.Forms.TreeNode
            $parent.Tag = [pscustomobject]@{ Group = $groupInfo.Name }

            foreach ($row in ($groupInfo.Rows | Sort-Object @{ Expression = { Get-RiskRank ([string]$_["Risk"]) }; Descending = $true }, @{ Expression = { [int64]$_["Bytes"] }; Descending = $true })) {
                $child = New-Object System.Windows.Forms.TreeNode
                $child.Tag = $row
                $child.Text = ("{0}    {1}    {2}" -f (Convert-ItemNameText ([string]$row["Name"])), [string]$row["Size"], (Convert-RiskText ([string]$row["Risk"])))
                $child.Checked = [bool]$row["Selected"]
                $child.ForeColor = Get-RiskColor ([string]$row["Risk"])
                $child.ToolTipText = Convert-SelectionReasonText -Selected ([bool]$row["Selected"]) -Recommended ([bool]$row["Recommended"]) -Risk ([string]$row["Risk"]) -Action ([string]$row["Action"]) -Note ([string]$row["Note"])
                [void]$parent.Nodes.Add($child)
            }

            Update-GroupNodeText $parent
            $parent.ToolTipText = "展开后可以查看具体项目和默认选择理由。"
            [void]$Tree.Nodes.Add($parent)
        }

        $Tree.CollapseAll()
        if ($Tree.Nodes.Count -gt 0) {
            $Tree.SelectedNode = $Tree.Nodes[0]
        }
    }
    finally {
        $Tree.EndUpdate()
        $script:TreeSyncing = $false
    }

    Set-DetailText -Node $Tree.SelectedNode -Detail $Detail
}

function Get-OpenablePathFromNode {
    param([System.Windows.Forms.TreeNode]$Node)

    $rows = @(Get-RowArrayFromNode $Node)
    foreach ($row in $rows) {
        $path = [string]$row["Path"]
        if ($path.StartsWith("Process::")) {
            $parts = $path -split "::", 3
            if ($parts.Count -eq 3 -and (Test-Path -LiteralPath $parts[2])) {
                return $parts[2]
            }
        }
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

function Show-MainWindow {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Initialize-ResultTable

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "深度清理中心 - 缓存、捆绑软件、启动项、服务和任务"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(1240, 760)
    $form.MinimumSize = New-Object System.Drawing.Size(980, 620)
    $form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = "Top"
    $top.Height = 132
    $top.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 6)
    $top.AutoScroll = $true
    $top.WrapContents = $true
    $form.Controls.Add($top)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = "扫描"
    $btnScan.Width = 96
    $btnScan.Height = 32
    [void]$top.Controls.Add($btnScan)

    $btnRecommended = New-Object System.Windows.Forms.Button
    $btnRecommended.Text = "推荐勾选"
    $btnRecommended.Width = 106
    $btnRecommended.Height = 32
    [void]$top.Controls.Add($btnRecommended)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "清空勾选"
    $btnClear.Width = 96
    $btnClear.Height = 32
    [void]$top.Controls.Add($btnClear)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "处理选中项"
    $btnDelete.Width = 112
    $btnDelete.Height = 32
    [void]$top.Controls.Add($btnDelete)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "打开位置"
    $btnOpen.Width = 104
    $btnOpen.Height = 32
    [void]$top.Controls.Add($btnOpen)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "导出清单"
    $btnExport.Width = 92
    $btnExport.Height = 32
    [void]$top.Controls.Add($btnExport)

    $btnQuarantine = New-Object System.Windows.Forms.Button
    $btnQuarantine.Text = "隔离区"
    $btnQuarantine.Width = 96
    $btnQuarantine.Height = 32
    [void]$top.Controls.Add($btnQuarantine)

    $btnDefenderQuick = New-Object System.Windows.Forms.Button
    $btnDefenderQuick.Text = "快速杀毒"
    $btnDefenderQuick.Width = 112
    $btnDefenderQuick.Height = 32
    [void]$top.Controls.Add($btnDefenderQuick)

    $btnDefenderFull = New-Object System.Windows.Forms.Button
    $btnDefenderFull.Text = "全盘杀毒"
    $btnDefenderFull.Width = 104
    $btnDefenderFull.Height = 32
    [void]$top.Controls.Add($btnDefenderFull)

    $chkDeep = New-Object System.Windows.Forms.CheckBox
    $chkDeep.Text = "深度扫描捆绑/流氓软件"
    $chkDeep.Checked = $true
    $chkDeep.Width = 160
    $chkDeep.Height = 32
    [void]$top.Controls.Add($chkDeep)

    $chkLarge = New-Object System.Windows.Forms.CheckBox
    $chkLarge.Text = "扫描大文件/大型软件"
    $chkLarge.Checked = $true
    $chkLarge.Width = 126
    $chkLarge.Height = 32
    [void]$top.Controls.Add($chkLarge)

    $lblThreshold = New-Object System.Windows.Forms.Label
    $lblThreshold.Text = "MB"
    $lblThreshold.TextAlign = "MiddleLeft"
    $lblThreshold.Width = 28
    $lblThreshold.Height = 32
    [void]$top.Controls.Add($lblThreshold)

    $numThreshold = New-Object System.Windows.Forms.NumericUpDown
    $numThreshold.Minimum = 50
    $numThreshold.Maximum = 102400
    $numThreshold.Value = [decimal]$LargeFileMB
    $numThreshold.Increment = 50
    $numThreshold.Width = 78
    $numThreshold.Height = 32
    [void]$top.Controls.Add($numThreshold)

    $chkFullDrive = New-Object System.Windows.Forms.CheckBox
    $chkFullDrive.Text = "大文件扫描所有固定磁盘（较慢）"
    $chkFullDrive.Checked = $false
    $chkFullDrive.Width = 230
    $chkFullDrive.Height = 32
    [void]$top.Controls.Add($chkFullDrive)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Dock = "Fill"
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AutoGenerateColumns = $true
    $grid.MultiSelect = $true
    $grid.SelectionMode = "FullRowSelect"
    $grid.RowHeadersVisible = $false
    $grid.DataSource = $script:Rows.DefaultView
    $form.Controls.Add($grid)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:StatusLabel.Text = "准备就绪"
    $script:StatusLabel.Spring = $true
    $script:StatusLabel.TextAlign = "MiddleLeft"
    [void]$statusStrip.Items.Add($script:StatusLabel)

    $script:ProgressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:ProgressBar.Width = 170
    $script:ProgressBar.Style = "Blocks"
    [void]$statusStrip.Items.Add($script:ProgressBar)
    $form.Controls.Add($statusStrip)

    Update-GridColumns -Grid $grid

    $btnScan.Add_Click({
        $btnScan.Enabled = $false
        $btnDelete.Enabled = $false
        try {
            $script:IncludeLargeFiles = $chkLarge.Checked
            $script:EnableDeepScan = $chkDeep.Checked
            $script:LargeThresholdMB = [int]$numThreshold.Value
            $script:FullDriveLargeScan = $chkFullDrive.Checked
            Invoke-Scan
            $grid.DataSource = $script:Rows.DefaultView
            Update-GridColumns -Grid $grid
        }
        finally {
            $btnScan.Enabled = $true
            $btnDelete.Enabled = $true
        }
    })

    $btnRecommended.Add_Click({
        [void]$grid.EndEdit()
        foreach ($row in $script:Rows.Rows) {
            $row["Selected"] = [bool]$row["Recommended"]
        }
    })

    $btnClear.Add_Click({
        [void]$grid.EndEdit()
        foreach ($row in $script:Rows.Rows) {
            $row["Selected"] = $false
        }
    })

    $btnDelete.Add_Click({
        Remove-SelectedRows -Grid $grid
    })

    $btnQuarantine.Add_Click({
        Open-QuarantineFolder
    })

    $btnDefenderQuick.Add_Click({
        Start-DefenderScan -ScanType "QuickScan"
    })

    $btnDefenderFull.Add_Click({
        Start-DefenderScan -ScanType "FullScan"
    })

    $btnOpen.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) {
            return
        }
        $rowView = $grid.SelectedRows[0].DataBoundItem
        if (-not $rowView) {
            return
        }
        $path = [string]$rowView.Row["Path"]
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) {
            return
        }
        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer) {
            Start-Process explorer.exe -ArgumentList "`"$path`""
        }
        else {
            Start-Process explorer.exe -ArgumentList "/select,`"$path`""
        }
    })

    $btnExport.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = "CSV 清单 (*.csv)|*.csv"
        $dialog.FileName = "清理扫描清单_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")
        if ($dialog.ShowDialog() -eq "OK") {
            $script:Rows | Select-Object Selected, Category, Name, Size, Risk, Note, Path | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("清单已导出。", "完成", "OK", "Information") | Out-Null
        }
    })

    [void][System.Windows.Forms.Application]::Run($form)
}

function Show-MainWindow {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Initialize-ResultTable

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "深度清理中心 - 按软件分组"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(1280, 780)
    $form.MinimumSize = New-Object System.Drawing.Size(1040, 660)
    $form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = "Top"
    $top.Height = 132
    $top.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 6)
    $top.AutoScroll = $true
    $top.WrapContents = $true
    $form.Controls.Add($top)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = "扫描"
    $btnScan.Width = 96
    $btnScan.Height = 32
    [void]$top.Controls.Add($btnScan)

    $btnRecommended = New-Object System.Windows.Forms.Button
    $btnRecommended.Text = "推荐勾选"
    $btnRecommended.Width = 112
    $btnRecommended.Height = 32
    [void]$top.Controls.Add($btnRecommended)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "清空勾选"
    $btnClear.Width = 100
    $btnClear.Height = 32
    [void]$top.Controls.Add($btnClear)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "处理选中项"
    $btnApply.Width = 120
    $btnApply.Height = 32
    [void]$top.Controls.Add($btnApply)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = "打开位置"
    $btnOpen.Width = 104
    $btnOpen.Height = 32
    [void]$top.Controls.Add($btnOpen)

    $btnExpand = New-Object System.Windows.Forms.Button
    $btnExpand.Text = "全部展开"
    $btnExpand.Width = 88
    $btnExpand.Height = 32
    [void]$top.Controls.Add($btnExpand)

    $btnCollapse = New-Object System.Windows.Forms.Button
    $btnCollapse.Text = "全部折叠"
    $btnCollapse.Width = 96
    $btnCollapse.Height = 32
    [void]$top.Controls.Add($btnCollapse)

    $btnExport = New-Object System.Windows.Forms.Button
    $btnExport.Text = "导出清单"
    $btnExport.Width = 92
    $btnExport.Height = 32
    [void]$top.Controls.Add($btnExport)

    $btnQuarantine = New-Object System.Windows.Forms.Button
    $btnQuarantine.Text = "隔离区"
    $btnQuarantine.Width = 96
    $btnQuarantine.Height = 32
    [void]$top.Controls.Add($btnQuarantine)

    $btnDefenderQuick = New-Object System.Windows.Forms.Button
    $btnDefenderQuick.Text = "快速杀毒"
    $btnDefenderQuick.Width = 104
    $btnDefenderQuick.Height = 32
    [void]$top.Controls.Add($btnDefenderQuick)

    $btnDefenderFull = New-Object System.Windows.Forms.Button
    $btnDefenderFull.Text = "全盘杀毒"
    $btnDefenderFull.Width = 104
    $btnDefenderFull.Height = 32
    [void]$top.Controls.Add($btnDefenderFull)

    $chkDeep = New-Object System.Windows.Forms.CheckBox
    $chkDeep.Text = "深度扫描捆绑/流氓软件"
    $chkDeep.Checked = $true
    $chkDeep.Width = 200
    $chkDeep.Height = 32
    [void]$top.Controls.Add($chkDeep)

    $chkLarge = New-Object System.Windows.Forms.CheckBox
    $chkLarge.Text = "扫描大文件/大型软件"
    $chkLarge.Checked = $true
    $chkLarge.Width = 160
    $chkLarge.Height = 32
    [void]$top.Controls.Add($chkLarge)

    $lblThreshold = New-Object System.Windows.Forms.Label
    $lblThreshold.Text = "MB"
    $lblThreshold.TextAlign = "MiddleLeft"
    $lblThreshold.Width = 28
    $lblThreshold.Height = 32
    [void]$top.Controls.Add($lblThreshold)

    $numThreshold = New-Object System.Windows.Forms.NumericUpDown
    $numThreshold.Minimum = 50
    $numThreshold.Maximum = 102400
    $numThreshold.Value = [decimal]$LargeFileMB
    $numThreshold.Increment = 50
    $numThreshold.Width = 78
    $numThreshold.Height = 32
    [void]$top.Controls.Add($numThreshold)

    $chkFullDrive = New-Object System.Windows.Forms.CheckBox
    $chkFullDrive.Text = "大文件扫描所有固定磁盘（较慢）"
    $chkFullDrive.Checked = $false
    $chkFullDrive.Width = 230
    $chkFullDrive.Height = 32
    [void]$top.Controls.Add($chkFullDrive)

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = "Fill"
    $split.Orientation = "Vertical"
    $split.SplitterDistance = 720
    $split.Panel1MinSize = 480
    $split.Panel2MinSize = 280
    $form.Controls.Add($split)

    $tree = New-Object System.Windows.Forms.TreeView
    $tree.Dock = "Fill"
    $tree.CheckBoxes = $true
    $tree.HideSelection = $false
    $tree.ShowNodeToolTips = $true
    $tree.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $split.Panel1.Controls.Add($tree)

    $detailPanel = New-Object System.Windows.Forms.Panel
    $detailPanel.Dock = "Fill"
    $detailPanel.Padding = New-Object System.Windows.Forms.Padding(8)
    $split.Panel2.Controls.Add($detailPanel)

    $detailTitle = New-Object System.Windows.Forms.Label
    $detailTitle.Dock = "Top"
    $detailTitle.Height = 28
    $detailTitle.Text = "扫描理由和处理动作"
    $detailTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)

    $detail = New-Object System.Windows.Forms.RichTextBox
    $detail.Dock = "Fill"
    $detail.ReadOnly = $true
    $detail.BorderStyle = "FixedSingle"
    $detail.BackColor = [System.Drawing.Color]::White
    $detail.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $detail.Text = "点击「扫描」后，结果会按软件或系统区域合并。展开左侧分组，可以逐个勾选具体清理项。"
    $detailPanel.Controls.Add($detail)
    $detailPanel.Controls.Add($detailTitle)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:StatusLabel.Text = "准备就绪"
    $script:StatusLabel.Spring = $true
    $script:StatusLabel.TextAlign = "MiddleLeft"
    [void]$statusStrip.Items.Add($script:StatusLabel)

    $script:ProgressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:ProgressBar.Width = 170
    $script:ProgressBar.Style = "Blocks"
    [void]$statusStrip.Items.Add($script:ProgressBar)
    $form.Controls.Add($statusStrip)

    $tree.Add_AfterSelect({
        Set-DetailText -Node $tree.SelectedNode -Detail $detail
    })

    $tree.Add_AfterCheck({
        if ($script:TreeSyncing) {
            return
        }

        $script:TreeSyncing = $true
        try {
            $node = $_.Node
            if ($node.Tag -is [System.Data.DataRow]) {
                $node.Tag["Selected"] = [bool]$node.Checked
                if ($node.Parent) {
                    Update-GroupNodeText $node.Parent
                }
            }
            else {
                foreach ($child in $node.Nodes) {
                    $child.Checked = [bool]$node.Checked
                    if ($child.Tag -is [System.Data.DataRow]) {
                        $child.Tag["Selected"] = [bool]$node.Checked
                    }
                }
                Update-GroupNodeText $node
            }
        }
        finally {
            $script:TreeSyncing = $false
        }

        Set-DetailText -Node $tree.SelectedNode -Detail $detail
    })

    $btnScan.Add_Click({
        $btnScan.Enabled = $false
        $btnApply.Enabled = $false
        try {
            $script:IncludeLargeFiles = $chkLarge.Checked
            $script:EnableDeepScan = $chkDeep.Checked
            $script:LargeThresholdMB = [int]$numThreshold.Value
            $script:FullDriveLargeScan = $chkFullDrive.Checked
            Invoke-Scan
            Build-ResultTree -Tree $tree -Detail $detail
        }
        finally {
            $btnScan.Enabled = $true
            $btnApply.Enabled = $true
        }
    })

    $btnRecommended.Add_Click({
        foreach ($row in $script:Rows.Rows) {
            $row["Selected"] = [bool]$row["Recommended"]
        }
        Build-ResultTree -Tree $tree -Detail $detail
    })

    $btnClear.Add_Click({
        foreach ($row in $script:Rows.Rows) {
            $row["Selected"] = $false
        }
        Build-ResultTree -Tree $tree -Detail $detail
    })

    $btnApply.Add_Click({
        Remove-SelectedRows -Grid $null
        Build-ResultTree -Tree $tree -Detail $detail
    })

    $btnOpen.Add_Click({
        $path = Get-OpenablePathFromNode $tree.SelectedNode
        if ([string]::IsNullOrWhiteSpace($path)) {
            [System.Windows.Forms.MessageBox]::Show("这个分组或项目没有可直接打开的文件路径。", "打开位置", "OK", "Information") | Out-Null
            return
        }

        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer) {
            Start-Process explorer.exe -ArgumentList "`"$path`""
        }
        else {
            Start-Process explorer.exe -ArgumentList "/select,`"$path`""
        }
    })

    $btnExpand.Add_Click({
        $tree.ExpandAll()
    })

    $btnCollapse.Add_Click({
        $tree.CollapseAll()
    })

    $btnExport.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = "CSV 清单 (*.csv)|*.csv"
        $dialog.FileName = "清理扫描清单_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")
        if ($dialog.ShowDialog() -eq "OK") {
            $script:Rows | Select-Object `
                @{Name="是否勾选";Expression={ if ([bool]$_["Selected"]) { "是" } else { "否" } }}, `
                @{Name="分组";Expression={ Convert-GroupText ([string]$_["Group"]) }}, `
                @{Name="类型";Expression={ Convert-CategoryText ([string]$_["Category"]) }}, `
                @{Name="名称";Expression={ Convert-ItemNameText ([string]$_["Name"]) }}, `
                @{Name="预计大小";Expression={ [string]$_["Size"] }}, `
                @{Name="风险等级";Expression={ Convert-RiskText ([string]$_["Risk"]) }}, `
                @{Name="处理动作";Expression={ Convert-ActionText ([string]$_["Action"]) }}, `
                @{Name="扫描原因";Expression={ Convert-NoteText ([string]$_["Note"]) }}, `
                @{Name="默认选择理由";Expression={ Convert-SelectionReasonText -Selected ([bool]$_["Selected"]) -Recommended ([bool]$_["Recommended"]) -Risk ([string]$_["Risk"]) -Action ([string]$_["Action"]) -Note ([string]$_["Note"]) }}, `
                @{Name="路径或命令";Expression={ [string]$_["Path"] }} |
                Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("清单已导出。", "完成", "OK", "Information") | Out-Null
        }
    })

    $btnQuarantine.Add_Click({
        Open-QuarantineFolder
    })

    $btnDefenderQuick.Add_Click({
        Start-DefenderScan -ScanType "QuickScan"
    })

    $btnDefenderFull.Add_Click({
        Start-DefenderScan -ScanType "FullScan"
    })

    [void][System.Windows.Forms.Application]::Run($form)
}

function Get-RowsForGroupKey {
    param([string]$GroupKey)

    if ([string]::IsNullOrWhiteSpace($GroupKey)) {
        return @()
    }
    return @($script:Rows.Rows | Where-Object { [string]$_["Group"] -eq $GroupKey })
}

function New-GroupSummaryTable {
    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add("Selected", [bool])
    [void]$table.Columns.Add("DisplayGroup", [string])
    [void]$table.Columns.Add("SelectedText", [string])
    [void]$table.Columns.Add("Count", [int])
    [void]$table.Columns.Add("Size", [string])
    [void]$table.Columns.Add("Risk", [string])
    [void]$table.Columns.Add("GroupKey", [string])
    [void]$table.Columns.Add("Bytes", [int64])
    [void]$table.Columns.Add("RiskRank", [int])
    [void]$table.Columns.Add("RiskRaw", [string])

    $groups = @{}
    foreach ($row in $script:Rows.Rows) {
        $group = [string]$row["Group"]
        if (-not $groups.ContainsKey($group)) {
            $groups[$group] = New-Object System.Collections.ArrayList
        }
        [void]$groups[$group].Add($row)
    }

    foreach ($group in $groups.Keys) {
        $rows = @($groups[$group].ToArray())
        $count = $rows.Count
        $selected = @($rows | Where-Object { [bool]$_["Selected"] }).Count
        $bytes = Get-TotalBytes $rows
        $riskRaw = Get-WorstRisk $rows
        $newRow = $table.NewRow()
        $newRow["Selected"] = ($count -gt 0 -and $selected -eq $count)
        $newRow["DisplayGroup"] = Convert-GroupText $group
        $newRow["SelectedText"] = ("{0}/{1}" -f $selected, $count)
        $newRow["Count"] = $count
        $newRow["Size"] = Format-Bytes $bytes
        $newRow["Risk"] = Convert-RiskText $riskRaw
        $newRow["GroupKey"] = $group
        $newRow["Bytes"] = $bytes
        $newRow["RiskRank"] = Get-RiskRank $riskRaw
        $newRow["RiskRaw"] = $riskRaw
        [void]$table.Rows.Add($newRow)
    }

    $table.DefaultView.Sort = "RiskRank DESC, Bytes DESC"
    return ,$table
}

function New-ItemTableForGroup {
    param([string]$GroupKey)

    $table = New-Object System.Data.DataTable
    [void]$table.Columns.Add("Selected", [bool])
    [void]$table.Columns.Add("Name", [string])
    [void]$table.Columns.Add("Category", [string])
    [void]$table.Columns.Add("Size", [string])
    [void]$table.Columns.Add("Risk", [string])
    [void]$table.Columns.Add("Action", [string])
    [void]$table.Columns.Add("Note", [string])
    [void]$table.Columns.Add("Path", [string])
    [void]$table.Columns.Add("Bytes", [int64])
    [void]$table.Columns.Add("RiskRaw", [string])
    [void]$table.Columns.Add("RowRef", [object])

    foreach ($row in (Get-RowsForGroupKey $GroupKey | Sort-Object @{ Expression = { Get-RiskRank ([string]$_["Risk"]) }; Descending = $true }, @{ Expression = { [int64]$_["Bytes"] }; Descending = $true })) {
        $newRow = $table.NewRow()
        $newRow["Selected"] = [bool]$row["Selected"]
        $newRow["Name"] = Convert-ItemNameText ([string]$row["Name"])
        $newRow["Category"] = Convert-CategoryText ([string]$row["Category"])
        $newRow["Size"] = [string]$row["Size"]
        $newRow["Risk"] = Convert-RiskText ([string]$row["Risk"])
        $newRow["Action"] = Convert-ActionText ([string]$row["Action"])
        $newRow["Note"] = Convert-NoteText ([string]$row["Note"])
        $newRow["Path"] = [string]$row["Path"]
        $newRow["Bytes"] = [int64]$row["Bytes"]
        $newRow["RiskRaw"] = [string]$row["Risk"]
        $newRow["RowRef"] = $row
        [void]$table.Rows.Add($newRow)
    }

    return ,$table
}

function Set-DetailFromRows {
    param(
        $Rows,
        [System.Windows.Forms.RichTextBox]$Detail,
        [string]$GroupName = ""
    )

    if (-not $Detail) {
        return
    }

    $rows = @($Rows)
    if ($rows.Count -eq 0) {
        $Detail.Text = "点击「扫描」后，左侧会显示软件/系统分组；选中分组后，右侧会列出具体项目和处理原因。"
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if ($rows.Count -eq 1) {
        $row = $rows[0]
        [void]$lines.Add((Convert-ItemNameText ([string]$row["Name"])))
        [void]$lines.Add("")
        [void]$lines.Add("所属分组: " + (Convert-GroupText ([string]$row["Group"])))
        [void]$lines.Add("项目类型: " + (Convert-CategoryText ([string]$row["Category"])))
        [void]$lines.Add("预计大小: " + [string]$row["Size"])
        [void]$lines.Add("风险等级: " + (Convert-RiskText ([string]$row["Risk"])))
        [void]$lines.Add("执行动作: " + (Convert-ActionText ([string]$row["Action"])))
        [void]$lines.Add("当前是否勾选: " + $(if ([bool]$row["Selected"]) { "是" } else { "否" }))
        [void]$lines.Add("")
        [void]$lines.Add("为什么会出现在这里:")
        [void]$lines.Add((Convert-NoteText ([string]$row["Note"])))
        [void]$lines.Add("")
        [void]$lines.Add("默认选择理由:")
        [void]$lines.Add((Convert-SelectionReasonText -Selected ([bool]$row["Selected"]) -Recommended ([bool]$row["Recommended"]) -Risk ([string]$row["Risk"]) -Action ([string]$row["Action"]) -Note ([string]$row["Note"])))
        [void]$lines.Add("")
        [void]$lines.Add("路径 / 命令:")
        [void]$lines.Add([string]$row["Path"])
    }
    else {
        $selected = @($rows | Where-Object { [bool]$_["Selected"] }).Count
        $total = Get-TotalBytes $rows
        $risk = Get-WorstRisk $rows
        $name = if ([string]::IsNullOrWhiteSpace($GroupName)) { Convert-GroupText ([string]$rows[0]["Group"]) } else { Convert-GroupText $GroupName }

        [void]$lines.Add($name)
        [void]$lines.Add("")
        [void]$lines.Add(("项目数量: {0}" -f $rows.Count))
        [void]$lines.Add(("已勾选: {0}" -f $selected))
        [void]$lines.Add(("预计大小/动作影响: {0}" -f (Format-Bytes $total)))
        [void]$lines.Add(("最高风险等级: {0}" -f (Convert-RiskText $risk)))
        [void]$lines.Add("")
        [void]$lines.Add("这个分组为什么出现:")
        $notes = @($rows | ForEach-Object { [string]$_["Note"] } | Select-Object -Unique -First 4)
        foreach ($note in $notes) {
            [void]$lines.Add("- " + (Convert-NoteText $note))
        }
        [void]$lines.Add("")
        [void]$lines.Add("提示: 勾选左侧分组会批量勾选该组全部项目；也可以在右侧逐项勾选。")
    }

    $Detail.Text = ($lines -join [Environment]::NewLine)
}

function Get-OpenablePathFromRows {
    param($Rows)

    foreach ($row in @($Rows)) {
        $path = [string]$row["Path"]
        if ($path.StartsWith("Process::")) {
            $parts = $path -split "::", 3
            if ($parts.Count -eq 3 -and (Test-Path -LiteralPath $parts[2])) {
                return $parts[2]
            }
        }
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }
    return $null
}

function Set-CleanupGridStyle {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [string]$Kind
    )

    $Grid.AutoGenerateColumns = $false
    if ($Grid.Columns.Count -eq 0) {
        if ($Kind -eq "Group") {
            $colSelected = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
            $colSelected.Name = "Selected"
            $colSelected.DataPropertyName = "Selected"
            [void]$Grid.Columns.Add($colSelected)

            foreach ($spec in @(
                @{ Name = "DisplayGroup"; Property = "DisplayGroup" },
                @{ Name = "SelectedText"; Property = "SelectedText" },
                @{ Name = "Count"; Property = "Count" },
                @{ Name = "Size"; Property = "Size" },
                @{ Name = "Risk"; Property = "Risk" }
            )) {
                $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
                $col.Name = $spec.Name
                $col.DataPropertyName = $spec.Property
                [void]$Grid.Columns.Add($col)
            }
        }
        else {
            $colSelected = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
            $colSelected.Name = "Selected"
            $colSelected.DataPropertyName = "Selected"
            [void]$Grid.Columns.Add($colSelected)

            foreach ($spec in @(
                @{ Name = "Name"; Property = "Name" },
                @{ Name = "Category"; Property = "Category" },
                @{ Name = "Size"; Property = "Size" },
                @{ Name = "Risk"; Property = "Risk" },
                @{ Name = "Action"; Property = "Action" },
                @{ Name = "Note"; Property = "Note" }
            )) {
                $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
                $col.Name = $spec.Name
                $col.DataPropertyName = $spec.Property
                [void]$Grid.Columns.Add($col)
            }
        }
    }

    $Grid.AllowUserToAddRows = $false
    $Grid.AllowUserToDeleteRows = $false
    $Grid.AllowUserToResizeRows = $false
    $Grid.MultiSelect = $false
    $Grid.RowHeadersVisible = $false
    $Grid.SelectionMode = "FullRowSelect"
    $Grid.BackgroundColor = [System.Drawing.Color]::White
    $Grid.BorderStyle = "FixedSingle"
    $Grid.GridColor = [System.Drawing.Color]::Gainsboro
    $Grid.EnableHeadersVisualStyles = $false
    $Grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $Grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $Grid.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    $Grid.DefaultCellStyle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $Grid.RowTemplate.Height = 28
    $Grid.ColumnHeadersHeight = 34
    $Grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $Grid.AutoSizeColumnsMode = "None"

    foreach ($col in $Grid.Columns) {
        $col.SortMode = "Automatic"
        if ($col.Name -ne "Selected") {
            $col.ReadOnly = $true
        }
    }

    if ($Kind -eq "Group") {
        $Grid.Columns["Selected"].HeaderText = "选"
        $Grid.Columns["Selected"].Width = 44
        $Grid.Columns["DisplayGroup"].HeaderText = "分组"
        $Grid.Columns["DisplayGroup"].AutoSizeMode = "Fill"
        $Grid.Columns["SelectedText"].HeaderText = "已选"
        $Grid.Columns["SelectedText"].Width = 64
        $Grid.Columns["Count"].HeaderText = "项"
        $Grid.Columns["Count"].Width = 48
        $Grid.Columns["Size"].HeaderText = "大小"
        $Grid.Columns["Size"].Width = 86
        $Grid.Columns["Risk"].HeaderText = "风险"
        $Grid.Columns["Risk"].Width = 76
        foreach ($name in @("GroupKey", "Bytes", "RiskRank", "RiskRaw")) {
            if ($Grid.Columns[$name]) { $Grid.Columns[$name].Visible = $false }
        }
    }
    else {
        $Grid.Columns["Selected"].HeaderText = "选"
        $Grid.Columns["Selected"].Width = 44
        $Grid.Columns["Name"].HeaderText = "项目"
        $Grid.Columns["Name"].Width = 220
        $Grid.Columns["Category"].HeaderText = "类型"
        $Grid.Columns["Category"].Width = 130
        $Grid.Columns["Size"].HeaderText = "大小"
        $Grid.Columns["Size"].Width = 86
        $Grid.Columns["Risk"].HeaderText = "风险"
        $Grid.Columns["Risk"].Width = 76
        $Grid.Columns["Action"].HeaderText = "动作"
        $Grid.Columns["Action"].Width = 100
        $Grid.Columns["Note"].HeaderText = "说明"
        $Grid.Columns["Note"].AutoSizeMode = "Fill"
        foreach ($name in @("Path", "Bytes", "RiskRaw", "RowRef")) {
            if ($Grid.Columns[$name]) { $Grid.Columns[$name].Visible = $false }
        }
    }
}

function Show-MainWindow {
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Initialize-ResultTable

    $script:GridSyncing = $false
    $script:CurrentGroupKey = $null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "深度清理中心 - 分组清理"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(1420, 820)
    $form.MinimumSize = New-Object System.Drawing.Size(1120, 700)
    $form.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)

    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $script:StatusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
    $script:StatusLabel.Text = "准备就绪"
    $script:StatusLabel.Spring = $true
    $script:StatusLabel.TextAlign = "MiddleLeft"
    [void]$statusStrip.Items.Add($script:StatusLabel)

    $script:ProgressBar = New-Object System.Windows.Forms.ToolStripProgressBar
    $script:ProgressBar.Width = 170
    $script:ProgressBar.Style = "Blocks"
    [void]$statusStrip.Items.Add($script:ProgressBar)
    $statusStrip.Dock = "Bottom"
    $form.Controls.Add($statusStrip)

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = "Fill"
    $root.ColumnCount = 1
    $root.RowCount = 3
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 118)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $form.Controls.Add($root)

    $top = New-Object System.Windows.Forms.FlowLayoutPanel
    $top.Dock = "Fill"
    $top.Padding = New-Object System.Windows.Forms.Padding(10, 10, 10, 4)
    $top.AutoScroll = $true
    $top.WrapContents = $true
    [void]$root.Controls.Add($top, 0, 0)

    function New-UiButton([string]$Text, [int]$Width) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Width = $Width
        $button.Height = 32
        $button.Margin = New-Object System.Windows.Forms.Padding(4, 2, 4, 4)
        return $button
    }

    $btnScan = New-UiButton "扫描" 96
    $btnRecommended = New-UiButton "推荐勾选" 112
    $btnClear = New-UiButton "清空勾选" 100
    $btnApply = New-UiButton "处理选中项" 120
    $btnOpen = New-UiButton "打开位置" 104
    $btnExport = New-UiButton "导出清单" 92
    $btnQuarantine = New-UiButton "隔离区" 92
    $btnDefenderQuick = New-UiButton "快速杀毒" 104
    $btnDefenderFull = New-UiButton "全盘杀毒" 104
    foreach ($button in @($btnScan, $btnRecommended, $btnClear, $btnApply, $btnOpen, $btnExport, $btnQuarantine, $btnDefenderQuick, $btnDefenderFull)) {
        [void]$top.Controls.Add($button)
    }

    $chkDeep = New-Object System.Windows.Forms.CheckBox
    $chkDeep.Text = "深度扫描捆绑/流氓软件"
    $chkDeep.Checked = $true
    $chkDeep.Width = 205
    $chkDeep.Height = 32
    $chkDeep.Margin = New-Object System.Windows.Forms.Padding(8, 4, 4, 4)
    [void]$top.Controls.Add($chkDeep)

    $chkLarge = New-Object System.Windows.Forms.CheckBox
    $chkLarge.Text = "扫描大文件/大型软件"
    $chkLarge.Checked = $true
    $chkLarge.Width = 170
    $chkLarge.Height = 32
    $chkLarge.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
    [void]$top.Controls.Add($chkLarge)

    $lblThreshold = New-Object System.Windows.Forms.Label
    $lblThreshold.Text = "阈值(MB)"
    $lblThreshold.TextAlign = "MiddleLeft"
    $lblThreshold.Width = 76
    $lblThreshold.Height = 32
    $lblThreshold.Margin = New-Object System.Windows.Forms.Padding(8, 4, 0, 4)
    [void]$top.Controls.Add($lblThreshold)

    $numThreshold = New-Object System.Windows.Forms.NumericUpDown
    $numThreshold.Minimum = 50
    $numThreshold.Maximum = 102400
    $numThreshold.Value = [decimal]$LargeFileMB
    $numThreshold.Increment = 50
    $numThreshold.Width = 80
    $numThreshold.Height = 32
    $numThreshold.Margin = New-Object System.Windows.Forms.Padding(0, 4, 4, 4)
    [void]$top.Controls.Add($numThreshold)

    $chkFullDrive = New-Object System.Windows.Forms.CheckBox
    $chkFullDrive.Text = "扫描所有固定磁盘（较慢）"
    $chkFullDrive.Checked = $false
    $chkFullDrive.Width = 235
    $chkFullDrive.Height = 32
    $chkFullDrive.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
    [void]$top.Controls.Add($chkFullDrive)

    $summary = New-Object System.Windows.Forms.Label
    $summary.Dock = "Fill"
    $summary.TextAlign = "MiddleLeft"
    $summary.Padding = New-Object System.Windows.Forms.Padding(14, 0, 10, 0)
    $summary.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $summary.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $summary.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
    $summary.Text = "尚未扫描。点击「扫描」开始。"
    [void]$root.Controls.Add($summary, 0, 1)

    $mainSplit = New-Object System.Windows.Forms.SplitContainer
    $mainSplit.Dock = "Fill"
    $mainSplit.Orientation = "Vertical"
    $mainSplit.SplitterDistance = 430
    $mainSplit.Panel1MinSize = 350
    $mainSplit.Panel2MinSize = 520
    [void]$root.Controls.Add($mainSplit, 0, 2)

    $groupGrid = New-Object System.Windows.Forms.DataGridView
    $groupGrid.Dock = "Fill"
    $mainSplit.Panel1.Controls.Add($groupGrid)

    $rightSplit = New-Object System.Windows.Forms.SplitContainer
    $rightSplit.Dock = "Fill"
    $rightSplit.Orientation = "Horizontal"
    $rightSplit.SplitterDistance = 380
    $rightSplit.Panel1MinSize = 240
    $rightSplit.Panel2MinSize = 150
    $mainSplit.Panel2.Controls.Add($rightSplit)

    $itemGrid = New-Object System.Windows.Forms.DataGridView
    $itemGrid.Dock = "Fill"
    $rightSplit.Panel1.Controls.Add($itemGrid)

    $detailPanel = New-Object System.Windows.Forms.Panel
    $detailPanel.Dock = "Fill"
    $detailPanel.Padding = New-Object System.Windows.Forms.Padding(8)
    $rightSplit.Panel2.Controls.Add($detailPanel)

    $detailTitle = New-Object System.Windows.Forms.Label
    $detailTitle.Dock = "Top"
    $detailTitle.Height = 26
    $detailTitle.Text = "扫描原因和处理建议"
    $detailTitle.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 10, [System.Drawing.FontStyle]::Bold)

    $detail = New-Object System.Windows.Forms.RichTextBox
    $detail.Dock = "Fill"
    $detail.ReadOnly = $true
    $detail.BorderStyle = "FixedSingle"
    $detail.BackColor = [System.Drawing.Color]::White
    $detail.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    $detail.Text = "点击「扫描」后，左侧会显示软件/系统分组；选中分组后，右侧会列出具体项目和处理原因。"
    $detailPanel.Controls.Add($detail)
    $detailPanel.Controls.Add($detailTitle)

    $updateSummary = {
        $totalCount = $script:Rows.Rows.Count
        $totalBytes = Get-TotalBytes $script:Rows.Rows
        $selectedRows = @($script:Rows.Rows | Where-Object { [bool]$_["Selected"] })
        $selectedBytes = Get-TotalBytes $selectedRows
        $manualCount = @($script:Rows.Rows | Where-Object { [string]$_["Risk"] -eq "Manual" }).Count
        $summary.Text = ("扫描结果: {0} 项 / 总计 {1}    当前勾选: {2} 项 / {3}    需人工确认: {4} 项" -f $totalCount, (Format-Bytes $totalBytes), $selectedRows.Count, (Format-Bytes $selectedBytes), $manualCount)
    }

    $refreshItems = {
        if ([string]::IsNullOrWhiteSpace($script:CurrentGroupKey)) {
            $itemGrid.DataSource = $null
            Set-DetailFromRows -Rows @() -Detail $detail
            return
        }
        $itemGrid.DataSource = (New-ItemTableForGroup -GroupKey $script:CurrentGroupKey)
        Set-CleanupGridStyle -Grid $itemGrid -Kind "Item"
        Set-DetailFromRows -Rows (Get-RowsForGroupKey $script:CurrentGroupKey) -Detail $detail -GroupName $script:CurrentGroupKey
    }

    $refreshGroups = {
        $script:GridSyncing = $true
        try {
            $previousGroup = $script:CurrentGroupKey
            $groupGrid.DataSource = (New-GroupSummaryTable)
            Set-CleanupGridStyle -Grid $groupGrid -Kind "Group"
            if ($groupGrid.Rows.Count -gt 0) {
                $found = $false
                if (-not [string]::IsNullOrWhiteSpace($previousGroup)) {
                    foreach ($gridRow in $groupGrid.Rows) {
                        $rowView = $gridRow.DataBoundItem
                        if ($rowView -and [string]$rowView.Row["GroupKey"] -eq $previousGroup) {
                            $gridRow.Selected = $true
                            $groupGrid.CurrentCell = $gridRow.Cells["DisplayGroup"]
                            $script:CurrentGroupKey = $previousGroup
                            $found = $true
                            break
                        }
                    }
                }
                if (-not $found) {
                    $groupGrid.Rows[0].Selected = $true
                    $groupGrid.CurrentCell = $groupGrid.Rows[0].Cells["DisplayGroup"]
                    $script:CurrentGroupKey = [string]$groupGrid.Rows[0].DataBoundItem.Row["GroupKey"]
                }
            }
            else {
                $script:CurrentGroupKey = $null
            }
        }
        finally {
            $script:GridSyncing = $false
        }
        & $refreshItems
        & $updateSummary
    }

    $groupGrid.Add_CurrentCellDirtyStateChanged({
        if ($groupGrid.IsCurrentCellDirty) {
            [void]$groupGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    $itemGrid.Add_CurrentCellDirtyStateChanged({
        if ($itemGrid.IsCurrentCellDirty) {
            [void]$itemGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
        }
    })

    $groupGrid.Add_SelectionChanged({
        if ($script:GridSyncing -or $groupGrid.SelectedRows.Count -eq 0) {
            return
        }
        $rowView = $groupGrid.SelectedRows[0].DataBoundItem
        if ($rowView) {
            $script:CurrentGroupKey = [string]$rowView.Row["GroupKey"]
            & $refreshItems
        }
    })

    $groupGrid.Add_CellValueChanged({
        if ($script:GridSyncing -or $_.RowIndex -lt 0 -or $_.ColumnIndex -lt 0) {
            return
        }
        if ($groupGrid.Columns[$_.ColumnIndex].Name -ne "Selected") {
            return
        }
        $rowView = $groupGrid.Rows[$_.RowIndex].DataBoundItem
        if (-not $rowView) {
            return
        }
        $groupKey = [string]$rowView.Row["GroupKey"]
        $checked = [bool]$rowView.Row["Selected"]
        foreach ($row in Get-RowsForGroupKey $groupKey) {
            $row["Selected"] = $checked
        }
        $script:CurrentGroupKey = $groupKey
        & $refreshGroups
    })

    $itemGrid.Add_SelectionChanged({
        if ($script:GridSyncing -or $itemGrid.SelectedRows.Count -eq 0) {
            return
        }
        $rowView = $itemGrid.SelectedRows[0].DataBoundItem
        if ($rowView -and $rowView.Row["RowRef"] -is [System.Data.DataRow]) {
            Set-DetailFromRows -Rows @($rowView.Row["RowRef"]) -Detail $detail
        }
    })

    $itemGrid.Add_CellValueChanged({
        if ($script:GridSyncing -or $_.RowIndex -lt 0 -or $_.ColumnIndex -lt 0) {
            return
        }
        if ($itemGrid.Columns[$_.ColumnIndex].Name -ne "Selected") {
            return
        }
        $rowView = $itemGrid.Rows[$_.RowIndex].DataBoundItem
        if ($rowView -and $rowView.Row["RowRef"] -is [System.Data.DataRow]) {
            $rowView.Row["RowRef"]["Selected"] = [bool]$rowView.Row["Selected"]
            & $refreshGroups
        }
    })

    $riskColorFormatter = {
        if ($_.RowIndex -lt 0) { return }
        $grid = $this
        $rowView = $grid.Rows[$_.RowIndex].DataBoundItem
        if (-not $rowView) { return }
        $risk = if ($rowView.Row.Table.Columns.Contains("RiskRaw")) { [string]$rowView.Row["RiskRaw"] } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($risk)) {
            $grid.Rows[$_.RowIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
            if ($grid.Columns["Risk"]) {
                $riskCell = $grid.Rows[$_.RowIndex].Cells["Risk"]
                $riskCell.Style.ForeColor = Get-RiskColor $risk
                $riskCell.Style.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9, [System.Drawing.FontStyle]::Bold)
            }
        }
    }
    $groupGrid.Add_CellFormatting($riskColorFormatter)
    $itemGrid.Add_CellFormatting($riskColorFormatter)

    $btnScan.Add_Click({
        $btnScan.Enabled = $false
        $btnApply.Enabled = $false
        try {
            $script:IncludeLargeFiles = $chkLarge.Checked
            $script:EnableDeepScan = $chkDeep.Checked
            $script:LargeThresholdMB = [int]$numThreshold.Value
            $script:FullDriveLargeScan = $chkFullDrive.Checked
            Invoke-Scan
            & $refreshGroups
        }
        catch {
            Set-Status ("界面刷新或扫描失败: {0}" -f $_.Exception.Message) -Busy:$false
            [System.Windows.Forms.MessageBox]::Show(("扫描或刷新界面失败：`r`n{0}" -f $_.Exception.Message), "错误", "OK", "Error") | Out-Null
        }
        finally {
            $btnScan.Enabled = $true
            $btnApply.Enabled = $true
        }
    })

    $btnRecommended.Add_Click({
        foreach ($row in $script:Rows.Rows) {
            $row["Selected"] = [bool]$row["Recommended"]
        }
        & $refreshGroups
    })

    $btnClear.Add_Click({
        foreach ($row in $script:Rows.Rows) {
            $row["Selected"] = $false
        }
        & $refreshGroups
    })

    $btnApply.Add_Click({
        Remove-SelectedRows -Grid $null
        & $refreshGroups
    })

    $btnOpen.Add_Click({
        $rows = @()
        if ($itemGrid.SelectedRows.Count -gt 0) {
            $rowView = $itemGrid.SelectedRows[0].DataBoundItem
            if ($rowView -and $rowView.Row["RowRef"] -is [System.Data.DataRow]) {
                $rows = @($rowView.Row["RowRef"])
            }
        }
        if ($rows.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($script:CurrentGroupKey)) {
            $rows = Get-RowsForGroupKey $script:CurrentGroupKey
        }

        $path = Get-OpenablePathFromRows -Rows $rows
        if ([string]::IsNullOrWhiteSpace($path)) {
            [System.Windows.Forms.MessageBox]::Show("当前分组或项目没有可直接打开的文件路径。", "打开位置", "OK", "Information") | Out-Null
            return
        }

        $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer) {
            Start-Process explorer.exe -ArgumentList "`"$path`""
        }
        else {
            Start-Process explorer.exe -ArgumentList "/select,`"$path`""
        }
    })

    $btnExport.Add_Click({
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = "CSV 清单 (*.csv)|*.csv"
        $dialog.FileName = "清理扫描清单_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")
        if ($dialog.ShowDialog() -eq "OK") {
            $script:Rows | Select-Object `
                @{Name="是否勾选";Expression={ if ([bool]$_["Selected"]) { "是" } else { "否" } }}, `
                @{Name="分组";Expression={ Convert-GroupText ([string]$_["Group"]) }}, `
                @{Name="类型";Expression={ Convert-CategoryText ([string]$_["Category"]) }}, `
                @{Name="名称";Expression={ Convert-ItemNameText ([string]$_["Name"]) }}, `
                @{Name="预计大小";Expression={ [string]$_["Size"] }}, `
                @{Name="风险等级";Expression={ Convert-RiskText ([string]$_["Risk"]) }}, `
                @{Name="处理动作";Expression={ Convert-ActionText ([string]$_["Action"]) }}, `
                @{Name="扫描原因";Expression={ Convert-NoteText ([string]$_["Note"]) }}, `
                @{Name="默认选择理由";Expression={ Convert-SelectionReasonText -Selected ([bool]$_["Selected"]) -Recommended ([bool]$_["Recommended"]) -Risk ([string]$_["Risk"]) -Action ([string]$_["Action"]) -Note ([string]$_["Note"]) }}, `
                @{Name="路径或命令";Expression={ [string]$_["Path"] }} |
                Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("清单已导出。", "完成", "OK", "Information") | Out-Null
        }
    })

    $btnQuarantine.Add_Click({ Open-QuarantineFolder })
    $btnDefenderQuick.Add_Click({ Start-DefenderScan -ScanType "QuickScan" })
    $btnDefenderFull.Add_Click({ Start-DefenderScan -ScanType "FullScan" })

    & $updateSummary
    [void][System.Windows.Forms.Application]::Run($form)
}

if ($ConsoleScan) {
    $script:IncludeLargeFiles = $true
    $script:LargeThresholdMB = $LargeFileMB
    $script:FullDriveLargeScan = [bool]$FullDriveLargeScan
    Invoke-Scan
    $output = foreach ($row in $script:Rows.DefaultView) {
        [pscustomobject]@{
            Selected = $row["Selected"]
            Group = $row["Group"]
            Category = $row["Category"]
            Name = $row["Name"]
            Size = $row["Size"]
            Risk = $row["Risk"]
            Note = $row["Note"]
            SelectionReason = $row["SelectionReason"]
            Path = $row["Path"]
        }
    }
    $output | Format-Table -AutoSize
    exit
}

Show-MainWindow
