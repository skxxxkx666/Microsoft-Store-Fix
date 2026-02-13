#requires -version 5.1
<#!
Microsoft Store Fix Tool (PS1) v1.3.1
- Based on ThioJoe's Windows-Sandbox-Tools script (Install-Microsoft-Store.ps1)
- Adapted for normal Windows use (no Sandbox check)
#>

param(
    [switch]$DebugSaveFiles,
    [switch]$NoInstall,
    [switch]$NoDownload
)

$ErrorActionPreference = 'Stop'
$script:ToolVersion = '1.3.1'
$script:optNoInstall = [bool]$NoInstall
$script:optNoDownload = [bool]$NoDownload
$script:EnableDebugArtifacts = [bool]$DebugSaveFiles
$script:RequestTimeoutSec = 60
$script:BestIpCache = @{}
$script:ToolLogPath = $null
$script:UpdateApi = "https://api.github.com/repos/skxxxkx666/Microsoft-Store-Fix/releases/latest"

function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )

    $entry = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    if ($script:ToolLogPath) {
        try {
            $logDir = [System.IO.Path]::GetDirectoryName($script:ToolLogPath)
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $script:ToolLogPath -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {
            # 日志写入失败不应中断主流程
        }
    }
}

function Write-Section {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )
    Write-Host ""
    Write-Host "==============================" -ForegroundColor DarkGray
    Write-Host $Text -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor DarkGray
}

function Test-Admin {
    [CmdletBinding()]
    param()

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        throw "当前操作需要管理员权限。请以管理员身份运行 PowerShell。"
    }
}

function Get-OSInfo {
    [CmdletBinding()]
    param()

    $product = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').ProductName
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    $type = 'Normal'
    if ($product -match 'LTSC|LTSB') { $type = 'LTSC' }
    if ($product -match 'IoT' -or $edition -match 'IoT') { $type = 'IoT' }
    if ($edition -match 'EnterpriseS') { $type = 'LTSC' }

    Write-Host "[系统信息] 产品: $product"
    Write-Host "[系统信息] Edition: $edition"
    Write-Host "[系统信息] 类型: $type"

    if ($type -eq 'Normal') {
        Write-Host "[提示] 检测到非 LTSC/IoT 版本，建议优先使用系统自带商店修复。" -ForegroundColor Yellow
    }

    return [PSCustomObject]@{
        Product = $product
        Edition = $edition
        Type    = $type
    }
}

function Test-ToolUpdate {
    [CmdletBinding()]
    param()

    try {
        $release = Invoke-RestMethod -Uri $script:UpdateApi -Method Get -TimeoutSec 8 -ErrorAction Stop
        $latest = [string]$release.tag_name
        if ([string]::IsNullOrWhiteSpace($latest)) { return }
        $current = "v$($script:ToolVersion)"
        if ($latest -ne $current) {
            Write-Host "[提示] 检测到新版本: $latest (当前: $current)" -ForegroundColor Yellow
            Write-LogEntry -Level INFO -Message "Update available: latest=$latest current=$current"
        } else {
            Write-LogEntry -Level DEBUG -Message "Already latest version: $current"
        }
    } catch {
        Write-LogEntry -Level DEBUG -Message "Update check skipped: $($_.Exception.Message)"
    }
}

function Test-Proxy {
    [CmdletBinding()]
    param()

    $proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyEnable = (Get-ItemProperty $proxyKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $proxyServer = (Get-ItemProperty $proxyKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer

    if ($proxyEnable -eq 1) {
        Write-Host "[警告] 系统代理已开启: $proxyServer" -ForegroundColor Yellow
        return [PSCustomObject]@{
            Enabled = $true
            Server  = $proxyServer
        }
    } else {
        Write-Host "[OK] 未检测到系统代理。" -ForegroundColor Green
        return [PSCustomObject]@{
            Enabled = $false
            Server  = $null
        }
    }
}

function Write-AdviceFromError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Message -match 'Access is denied|拒绝访问') {
        Write-Host "  [建议] 以管理员身份运行 PowerShell 后重试。" -ForegroundColor Yellow
        Write-LogEntry -Level WARN -Message "Advice: run as admin. RawError=$Message"
        return
    }
    if ($Message -match '0x80073D02') {
        Write-Host "  [建议] 关闭 Microsoft Store / WinStore 进程后重试。" -ForegroundColor Yellow
        Write-LogEntry -Level WARN -Message "Advice: close Store process. RawError=$Message"
        return
    }
    if ($Message -match '0x80073D06|更高版本') {
        Write-Host "  [提示] 已安装更高版本，通常无需重复安装。" -ForegroundColor Yellow
        Write-LogEntry -Level INFO -Message "Advice: higher version already installed. RawError=$Message"
        return
    }
    if ($Message -match 'timeout|timed out|超时') {
        Write-Host "  [建议] 检查网络/代理，或切换下载模式重试。" -ForegroundColor Yellow
        Write-LogEntry -Level WARN -Message "Advice: network/proxy check. RawError=$Message"
        return
    }
    if ($Message -match 'SSL|TLS|证书') {
        Write-Host "  [建议] 检查系统时间、证书链、代理劫持情况。" -ForegroundColor Yellow
        Write-LogEntry -Level WARN -Message "Advice: TLS/certificate check. RawError=$Message"
        return
    }
    if ($Message -match 'not found|找不到') {
        Write-Host "  [建议] 检查路径/文件是否存在，必要时重新下载。" -ForegroundColor Yellow
        Write-LogEntry -Level WARN -Message "Advice: path/file check. RawError=$Message"
        return
    }
    Write-Host "  [建议] 使用菜单 [6] 导出 AppX 日志进一步排查。" -ForegroundColor Yellow
}

function Start-ServiceIfNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    # 服务在不同 Windows 版本上可能不存在，静默处理后给出提示。
    $serviceObj = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $serviceObj) {
        Write-Host "[警告] 未找到服务 $ServiceName" -ForegroundColor Yellow
        return
    }
    if ($serviceObj.Status -eq 'Running') {
        Write-Host "[OK] $ServiceName 正常运行。" -ForegroundColor Green
        return
    }

    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Host "[修复] 启动服务 $ServiceName 成功" -ForegroundColor Green
    } catch {
        Write-Host "[!] 启动服务 $ServiceName 失败: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

function Test-StoreHealth {
    [CmdletBinding()]
    param()

    Write-Host "[检测] 服务状态..."
    $coreServices = @(
        'wuauserv',
        'bits',
        'AppXSvc',
        'ClipSVC',
        'CryptSvc',
        'RpcEptMapper',
        'DcomLaunch',
        'RpcSs',
        'MpsSvc',
        'BFE',
        'InstallService',
        'StorSvc',
        'TokenBroker'
    )
    foreach ($serviceName in $coreServices) {
        Start-ServiceIfNeeded -ServiceName $serviceName
    }

    Write-Host "[检测] Store 包/依赖..."
    if (Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue) {
        Write-Host "[OK] Microsoft.WindowsStore 已存在。" -ForegroundColor Green
    } else {
        Write-Host "[错误] 未检测到 Microsoft.WindowsStore 包。" -ForegroundColor Red
    }

    if (Get-AppxPackage -Name Microsoft.StorePurchaseApp -AllUsers -ErrorAction SilentlyContinue) {
        Write-Host "[OK] StorePurchaseApp 正常。" -ForegroundColor Green
    } else {
        Write-Host "[警告] StorePurchaseApp 缺失。" -ForegroundColor Yellow
    }

    if (Get-AppxPackage -Name Microsoft.DesktopAppInstaller -AllUsers -ErrorAction SilentlyContinue) {
        Write-Host "[OK] AppInstaller 正常。" -ForegroundColor Green
    } else {
        Write-Host "[警告] AppInstaller 缺失。" -ForegroundColor Yellow
    }

    $cache = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache'
    if (Test-Path $cache) {
        Write-Host "[OK] Store 缓存目录存在。" -ForegroundColor Green
    } else {
        Write-Host "[警告] Store 缓存目录不存在。" -ForegroundColor Yellow
    }
    
    Write-Host "[检测] 商店相关注册表项..."
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\WS\License Validation',
        'HKLM:\SOFTWARE\Microsoft\Windows\WS\WSRefreshBannedAppsListTask',
        'HKLM:\SOFTWARE\Microsoft\Windows\PushToInstall\Registration',
        'HKLM:\SOFTWARE\Microsoft\Windows\PushToInstall\LoginCheck'
    )
    foreach ($registryPath in $regPaths) {
        if (Test-Path $registryPath) {
            Write-Host ("[OK] {0}" -f $registryPath) -ForegroundColor Green
        } else {
            Write-Host ("[警告] 缺少注册表项: {0}" -f $registryPath) -ForegroundColor Yellow
        }
    }

    $userSvcPatterns = @('UnistoreSvc_*','UserDataSvc_*')
    foreach ($servicePattern in $userSvcPatterns) {
        $serviceList = Get-Service -Name $servicePattern -ErrorAction SilentlyContinue
        if ($null -eq $serviceList -or $serviceList.Count -eq 0) {
            Write-Host ("[警告] 未找到服务 {0}" -f $servicePattern) -ForegroundColor Yellow
            continue
        }
        foreach ($serviceObj in $serviceList) {
            Start-ServiceIfNeeded -ServiceName $serviceObj.Name
        }
    }
}

function Test-StoreResidue {
    [CmdletBinding()]
    param()

    $storePkg = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue
    $storeDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe'
    $hasResidue = $false

    if (-not $storePkg -and (Test-Path $storeDir)) {
        $hasResidue = $true
        Write-Host "[提示] 检测到可能的商店残留目录：" -ForegroundColor Yellow
        Write-Host ("  {0}" -f $storeDir) -ForegroundColor Yellow

        $choice = Read-Host "是否清理残留目录? (Y/N, 推荐 Y)"
        if ($choice -match '^[Yy]$') {
            try {
                Remove-Item -Path $storeDir -Recurse -Force -ErrorAction Stop
                Write-Host "[OK] 已清理残留目录。" -ForegroundColor Green
            } catch {
                Write-Host ("[!] 清理失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
                Write-AdviceFromError -Message $_.Exception.Message
            }
        }
    }

    if (-not $hasResidue) {
        Write-Host "[OK] 未发现可疑商店残留。" -ForegroundColor Green
    }
}

function Test-StoreInstalled {
    [CmdletBinding()]
    param()

    $pkg = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue
    if ($pkg) {
        $ver = ($pkg | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Host ("[OK] 已检测到 Microsoft.WindowsStore，版本: {0}" -f $ver) -ForegroundColor Green
        return [PSCustomObject]@{
            Installed = $true
            Version   = $ver
        }
    } else {
        Write-Host "[警告] 未检测到 Microsoft.WindowsStore。" -ForegroundColor Yellow
        return [PSCustomObject]@{
            Installed = $false
            Version   = $null
        }
    }
}

function Request-RegionFix {
    [CmdletBinding()]
    param()

    Write-Host "[提示] 商店初始化失败有时与地区设置有关。" -ForegroundColor Yellow
    Write-Host "当前设置将不会自动修改区域。" -ForegroundColor Yellow
    Write-Host "可选区域: [1] US  [2] CN  [3] HK  [4] TW  [5] JP  [0] 不修改"
    $choice = Read-Host "请选择 (0-5)"
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }

    $geoMap = @{
        # GeoID 244 = United States
        '1' = @{ Nation = '244'; Name = 'US'; Label = 'US' }
        # GeoID 45 = China
        '2' = @{ Nation = '45';  Name = 'CN'; Label = 'CN' }
        # GeoID 104 = Hong Kong SAR
        '3' = @{ Nation = '104'; Name = 'HK'; Label = 'HK' }
        # GeoID 237 = Taiwan
        '4' = @{ Nation = '237'; Name = 'TW'; Label = 'TW' }
        # GeoID 122 = Japan
        '5' = @{ Nation = '122'; Name = 'JP'; Label = 'JP' }
    }

    if (-not $geoMap.ContainsKey($choice)) {
        Write-Host "[提示] 无效选择，未修改区域。" -ForegroundColor Yellow
        return
    }

    try {
        $geoKeyPath = "HKCU:\Control Panel\International\Geo"
        if (-not (Test-Path $geoKeyPath)) { New-Item -Path $geoKeyPath -Force | Out-Null }

        $oldNation = (Get-ItemProperty -Path $geoKeyPath -Name "Nation" -ErrorAction SilentlyContinue).Nation
        $oldName = (Get-ItemProperty -Path $geoKeyPath -Name "Name" -ErrorAction SilentlyContinue).Name
        Write-Host "[备份] 原区域: Nation=$oldNation, Name=$oldName" -ForegroundColor DarkGray

        Set-ItemProperty -Path $geoKeyPath -Name "Nation" -Value $geoMap[$choice].Nation
        Set-ItemProperty -Path $geoKeyPath -Name "Name" -Value $geoMap[$choice].Name
        Write-Host ("[OK] 已修改区域为 {0}。" -f $geoMap[$choice].Label) -ForegroundColor Green
    } catch {
        Write-Host "[错误] 区域修复失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-AdviceFromError -Message $_.Exception.Message
    }
}

function Get-DownloadMode {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "下载加速模式："
    Write-Host "[1] 默认（不更改，允许系统代理/加速器）"
    Write-Host "[2] 使用 BITS 下载"
    Write-Host "[3] 最优节点测速（HTTPS 保持域名下载，保障证书验证）"
    $mode = Read-Host "请选择 (1-3)"
    if ($mode -notin @('1','2','3')) { $mode = '1' }
    return $mode
}

function Show-AdvancedOptions {
    [CmdletBinding()]
    param()

    while ($true) {
        Write-Host ""
        Write-Host "高级选项（交互式开关）"
        Write-Host ("[1] 仅解析不下载 (-noDownload): {0}" -f $(if ($script:optNoDownload) { '开启' } else { '关闭' }))
        Write-Host ("[2] 仅下载不安装 (-noInstall): {0}" -f $(if ($script:optNoInstall) { '开启' } else { '关闭' }))
        Write-Host "[3] 返回主菜单"
        $sel = Read-Host "请选择 (1-3)"
        switch ($sel) {
            '1' { $script:optNoDownload = -not $script:optNoDownload }
            '2' { $script:optNoInstall = -not $script:optNoInstall }
            '3' { return }
            default { Write-Host "[提示] 无效选择" -ForegroundColor Yellow }
        }
    }
}

function Resolve-BestIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName
    )

    if ($script:BestIpCache.ContainsKey($HostName)) {
        return $script:BestIpCache[$HostName]
    }

    try {
        $ips = Resolve-DnsName -Name $HostName -Type A -ErrorAction Stop | Select-Object -ExpandProperty IPAddress
    } catch {
        return $null
    }
    $best = $null
    $bestMs = [int]::MaxValue
    foreach ($ip in $ips) {
        $pingResult = Test-Connection -ComputerName $ip -Count 1 -ErrorAction SilentlyContinue
        if ($pingResult -and $pingResult.ResponseTime -lt $bestMs) {
            $bestMs = $pingResult.ResponseTime
            $best = $ip
        }
    }
    $script:BestIpCache[$HostName] = $best
    return $best
}

function Start-FileDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$OutFile,
        [Parameter(Mandatory)]
        [ValidateSet('1','2','3')]
        [string]$Mode
    )

    if ($Mode -eq '2') {
        Start-BitsTransfer -Source $Url -Destination $OutFile -ErrorAction Stop
        return
    }

    if ($Mode -eq '3') {
        try {
            $uri = [System.Uri]$Url
            $targetHost = $uri.Host
            $bestIp = Resolve-BestIp -HostName $targetHost
            if ($bestIp) {
                if ($uri.Scheme -eq 'https') {
                    Write-Host "  -> 最优 IP: $bestIp (TLS 安全模式下保持域名下载)" -ForegroundColor Yellow
                } else {
                    Write-Host "  -> 最优 IP: $bestIp" -ForegroundColor Yellow
                }
            }
        } catch {
            Write-Host "  -> 节点测速失败: $($_.Exception.Message)，继续默认下载。" -ForegroundColor Yellow
        }
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec ($script:RequestTimeoutSec * 5) -ErrorAction Stop
    } catch {
        throw "下载失败: $($_.Exception.Message)"
    }
}

function Save-DebugArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    if (-not $script:EnableDebugArtifacts) {
        return
    }
    New-DirectoryIfMissing -Path $LogDirectory
    $targetPath = Join-Path $LogDirectory $FileName
    [System.IO.File]::WriteAllText($targetPath, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Get-SystemContext {
    [CmdletBinding()]
    param()

    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1

    $rawArch = [string]$env:PROCESSOR_ARCHITECTURE
    if ([string]::IsNullOrWhiteSpace($rawArch)) {
        $rawArch = "AMD64"
    }
    $rawArch = $rawArch.ToUpperInvariant()
    $packageArch = switch ($rawArch) {
        "AMD64" { "x64" }
        "ARM64" { "arm64" }
        "X86"   { "x86" }
        default { "x64" }
    }

    $osVersionObj = [System.Environment]::OSVersion.Version
    $osVersion = "{0}.{1}.{2}.{3}" -f $osVersionObj.Major, $osVersionObj.Minor, $osVersionObj.Build, $osVersionObj.Revision

    try {
        $installLanguage = (Get-WinSystemLocale).Name
    } catch {
        $installLanguage = (Get-Culture).Name
    }
    $uiLocale = $null
    try {
        $overrideLocale = Get-WinUILanguageOverride
        if ($overrideLocale) { $uiLocale = $overrideLocale.Name }
    } catch {
        $uiLocale = $null
    }
    if ([string]::IsNullOrWhiteSpace($uiLocale)) {
        $uiLocale = (Get-Culture).Name
    }

    $langRoot = $installLanguage.Split('-')[0]
    $localeList = @($installLanguage, $langRoot) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $defaultRegion = (Get-ItemProperty -Path 'HKCU:\Control Panel\International\Geo' -Name Nation -ErrorAction SilentlyContinue).Nation
    if ([string]::IsNullOrWhiteSpace([string]$defaultRegion)) {
        $defaultRegion = '244'
    }

    $appVer = '1407.2503.28012.0'
    $installedStore = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue
    if ($installedStore) {
        $appVer = (($installedStore | Sort-Object Version -Descending | Select-Object -First 1).Version).ToString()
    }

    $wuClientVersion = $null
    try {
        $wuClientVersion = (Get-Item (Join-Path $env:WINDIR 'System32\wuaueng.dll') -ErrorAction Stop).VersionInfo.FileVersion
    } catch {
        $wuClientVersion = $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$wuClientVersion)) {
        # 作为回退保留历史稳定值，v1.4 将继续完善自动探测策略。
        $wuClientVersion = "1310.2503.26012.0"
    }

    return [PSCustomObject]@{
        OsSkuId          = [int]$osInfo.OperatingSystemSKU
        OsVersion        = $osVersion
        OsArchitecture   = $rawArch
        PackageArch      = $packageArch
        InstallLanguage  = $installLanguage
        UiLocale         = $uiLocale
        Locales          = $localeList
        CpuManufacturer  = $(if ($cpuInfo -and $cpuInfo.Manufacturer) { $cpuInfo.Manufacturer } else { "UnknownCPU" })
        DefaultUserRegion = [string]$defaultRegion
        AppVer           = $appVer
        WuClientVer      = [string]$wuClientVersion
    }
}

function Convert-ToXmlEscaped {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )
    if ($null -eq $Text) { return "" }
    return [System.Security.SecurityElement]::Escape($Text)
}

function Convert-Base64ToHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Base64Value
    )
    $bytes = [Convert]::FromBase64String($Base64Value)
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-ExpectedSha256FromText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    if ($trimmed -match '^[A-Fa-f0-9]{64}$') {
        return $trimmed.ToUpperInvariant()
    }
    if ($trimmed -match '^[A-Za-z0-9+/]{43}=$') {
        try {
            return (Convert-Base64ToHex -Base64Value $trimmed).ToUpperInvariant()
        } catch {
            return $null
        }
    }
    return $null
}

function Get-ExpectedHashFromFileNode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$FileNode
    )

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('Digest','DigestValue','Sha256','SHA256','AdditionalDigest','AdditionalDigestValue','FileDigest')) {
        if ($FileNode.PSObject.Properties.Name -contains $name) {
            $value = [string]$FileNode.$name
            if (-not [string]::IsNullOrWhiteSpace($value)) { $candidates.Add($value) | Out-Null }
        }
        if ($FileNode.Attributes -and $FileNode.Attributes[$name]) {
            $value = [string]$FileNode.Attributes[$name].Value
            if (-not [string]::IsNullOrWhiteSpace($value)) { $candidates.Add($value) | Out-Null }
        }
    }

    foreach ($candidate in $candidates) {
        $hash = Get-ExpectedSha256FromText -Text $candidate
        if ($hash) { return $hash }
    }
    return $null
}

function Assert-FileIntegrity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [AllowNull()]
        [string]$ExpectedHash
    )

    if ([string]::IsNullOrWhiteSpace($ExpectedHash)) { return }
    $actualHash = (Get-FileHash -Path $FilePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    if ($actualHash -ne $ExpectedHash.ToUpperInvariant()) {
        Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue
        throw "文件完整性校验失败: $FilePath (预期=$ExpectedHash, 实际=$actualHash)"
    }
}

function New-DeviceAttributesString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context
    )

    $attrs = [ordered]@{
        BranchReadinessLevel  = 'CB'
        CurrentBranch         = $currentBranch
        OEMModel              = 'Virtual Machine'
        FlightRing            = $flightRing
        AttrDataVer           = '321'
        InstallLanguage       = $Context.InstallLanguage
        OSUILocale            = $Context.UiLocale
        InstallationType      = 'Client'
        FlightingBranchName   = $flightingBranchName
        OSSkuId               = $Context.OsSkuId
        App                   = 'WU_STORE'
        ProcessorManufacturer = $Context.CpuManufacturer
        OEMName_Uncleaned     = 'Microsoft Corporation'
        AppVer                = $Context.AppVer
        OSArchitecture        = $Context.OsArchitecture
        IsFlightingEnabled    = '1'
        TelemetryLevel        = '1'
        DefaultUserRegion     = $Context.DefaultUserRegion
        WuClientVer           = $Context.WuClientVer
        OSVersion             = $Context.OsVersion
        DeviceFamily          = 'Windows.Desktop'
    }

    $pairs = foreach ($entry in $attrs.GetEnumerator()) {
        "{0}={1}" -f $entry.Key, [System.Uri]::EscapeDataString([string]$entry.Value)
    }
    return "E:{0}" -f ($pairs -join '&')
}

function New-CookieXmlPayload {
    [CmdletBinding()]
    param()

    $messageId = [Guid]::NewGuid()
    return @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
    <s:Header>
        <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</a:Action>
        <a:MessageID>urn:uuid:$messageId</a:MessageID>
        <a:To s:mustUnderstand="1">https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx</a:To>
        <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
            <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
                <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user></user></TicketType>
            </wuws:WindowsUpdateTicketsToken>
        </o:Security>
    </s:Header>
    <s:Body><GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService" /></s:Body>
</s:Envelope>
"@
}

function New-FileListXmlPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncryptedCookieData,
        [Parameter(Mandatory)]
        [object]$Context
    )

    $created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $expires = (Get-Date).ToUniversalTime().AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $expiration = (Get-Date).AddYears(10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $deviceAttributes = Convert-ToXmlEscaped -Text (New-DeviceAttributesString -Context $Context)
    $cookieData = Convert-ToXmlEscaped -Text $EncryptedCookieData
    $clientLang = Convert-ToXmlEscaped -Text $Context.InstallLanguage
    $localesXml = ($Context.Locales | ForEach-Object { "<string>$([System.Security.SecurityElement]::Escape($_))</string>" }) -join ''

    # InstalledNonLeafUpdateIDs 来源于历史稳定脚本，用于 WU SOAP 查询上下文。
    return @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
    <s:Header>
        <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action>
        <a:MessageID>urn:uuid:$([Guid]::NewGuid())</a:MessageID>
        <a:To s:mustUnderstand="1">https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx</a:To>
        <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
            <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
                <Created>$created</Created>
                <Expires>$expires</Expires>
            </Timestamp>
            <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
                <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user/></TicketType>
            </wuws:WindowsUpdateTicketsToken>
        </o:Security>
    </s:Header>
    <s:Body>
        <SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
            <cookie>
                <Expiration>$expiration</Expiration>
                <EncryptedData>$cookieData</EncryptedData>
            </cookie>
            <parameters>
                <ExpressQuery>false</ExpressQuery>
                <InstalledNonLeafUpdateIDs>
                    <int>1</int><int>2</int><int>3</int><int>11</int><int>19</int><int>2359974</int><int>5169044</int>
                    <int>8788830</int><int>23110993</int><int>23110994</int><int>54341900</int><int>59830006</int><int>59830007</int>
                    <int>59830008</int><int>60484010</int><int>62450018</int><int>62450019</int><int>62450020</int><int>98959022</int>
                    <int>98959023</int><int>98959024</int><int>98959025</int><int>98959026</int><int>104433538</int><int>129905029</int>
                    <int>130040031</int><int>132387090</int><int>132393049</int><int>133399034</int><int>138537048</int><int>140377312</int>
                    <int>143747671</int><int>158941041</int><int>158941042</int><int>158941043</int><int>158941044</int><int>159123858</int>
                    <int>159130928</int><int>164836897</int><int>164847386</int><int>164848327</int><int>164852241</int><int>164852246</int>
                    <int>164852253</int>
                </InstalledNonLeafUpdateIDs>
                <SkipSoftwareSync>false</SkipSoftwareSync>
                <NeedTwoGroupOutOfScopeUpdates>false</NeedTwoGroupOutOfScopeUpdates>
                <FilterAppCategoryIds>
                    <CategoryIdentifier><Id>$storeCategoryId</Id></CategoryIdentifier>
                </FilterAppCategoryIds>
                <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
                <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
                <ComputerSpec/>
                <ExtendedUpdateInfoParameters>
                    <XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes>
                    <Locales>$localesXml</Locales>
                </ExtendedUpdateInfoParameters>
                <ClientPreferredLanguages><string>$clientLang</string></ClientPreferredLanguages>
                <ProductsParameters>
                    <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
                    <DeviceAttributes>$deviceAttributes</DeviceAttributes>
                    <CallerAttributes>Interactive=1;IsSeeker=1;</CallerAttributes>
                    <Products/>
                </ProductsParameters>
            </parameters>
        </SyncUpdates>
    </s:Body>
</s:Envelope>
"@
}

function New-FileUrlXmlPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncryptedCookieData,
        [Parameter(Mandatory)]
        [string]$UpdateId,
        [Parameter(Mandatory)]
        [string]$RevisionNumber,
        [Parameter(Mandatory)]
        [object]$Context
    )

    $created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $expires = (Get-Date).ToUniversalTime().AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
    $deviceAttributes = Convert-ToXmlEscaped -Text (New-DeviceAttributesString -Context $Context)
    $cookieData = Convert-ToXmlEscaped -Text $EncryptedCookieData

    # <user> 中填充 Cookie 是 WU SOAP 协议行为，不是用户名。
    return @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
    <s:Header>
        <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action>
        <a:MessageID>urn:uuid:$([Guid]::NewGuid())</a:MessageID>
        <a:To s:mustUnderstand="1">https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured</a:To>
        <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
            <u:Timestamp u:Id="_0" xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
                <u:Created>$created</u:Created>
                <u:Expires>$expires</u:Expires>
            </u:Timestamp>
            <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
                <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user>$cookieData</user></TicketType>
            </wuws:WindowsUpdateTicketsToken>
        </o:Security>
    </s:Header>
    <s:Body>
        <GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
            <updateIDs><UpdateIdentity><UpdateID>$UpdateId</UpdateID><RevisionNumber>$RevisionNumber</RevisionNumber></UpdateIdentity></updateIDs>
            <infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType></infoTypes>
            <DeviceAttributes>$deviceAttributes</DeviceAttributes>
        </GetExtendedUpdateInfo2>
    </s:Body>
</s:Envelope>
"@
}

function Invoke-SoapRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Uri,
        [Parameter(Mandatory)]
        [string]$Payload,
        [Parameter(Mandatory)]
        [string]$StepName,
        [string]$RequestLogName,
        [string]$ResponseLogName
    )

    if ($RequestLogName) { Save-DebugArtifact -FileName $RequestLogName -Content $Payload }
    try {
        $response = Invoke-WebRequest -Uri $Uri -Method Post -Body $Payload -Headers $headers -UseBasicParsing -TimeoutSec $script:RequestTimeoutSec -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'timed out|超时') { throw "$StepName 失败: 请求超时。" }
        if ($msg -match '403|Forbidden') { throw "$StepName 失败: 服务器拒绝请求(403)。" }
        if ($msg -match '500|Internal Server Error') { throw "$StepName 失败: 服务器内部错误(500)。" }
        throw "$StepName 失败: $msg"
    }
    if ($ResponseLogName) { Save-DebugArtifact -FileName $ResponseLogName -Content $response.Content }
    return $response.Content
}

# 动态 SOAP Payload 已迁移到函数:
# New-CookieXmlPayload / New-FileListXmlPayload / New-FileUrlXmlPayload

# --- Script Execution ---
function New-DirectoryIfMissing {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Get-DefaultDownloadsPath {
    [CmdletBinding()]
    param()

    try {
        $shell = New-Object -ComObject Shell.Application
        $downloads = $shell.Namespace('shell:Downloads')
        if ($downloads -and $downloads.Self -and $downloads.Self.Path) {
            return $downloads.Self.Path
        }
    } catch {
        Write-Host "[提示] 无法通过 Shell.Application 读取下载目录，使用默认路径。" -ForegroundColor Yellow
    }
    return (Join-Path $env:USERPROFILE "Downloads")
}

$headers = @{ "Content-Type" = "application/soap+xml; charset=utf-8" }
$baseUri = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx"
$userDownloadsFolder = Get-DefaultDownloadsPath
$workingDir = Join-Path -Path $userDownloadsFolder -ChildPath "MSStore Install"
$LogDirectory = Join-Path -Path $workingDir -ChildPath "Logs"

New-DirectoryIfMissing -Path $workingDir
if ($script:EnableDebugArtifacts) { New-DirectoryIfMissing -Path $LogDirectory }
$script:ToolLogPath = Join-Path $LogDirectory "Tool.log"
New-DirectoryIfMissing -Path $LogDirectory
Write-LogEntry -Level INFO -Message "Tool started. Version=$($script:ToolVersion)"

$storeCategoryId = "64293252-5926-453c-9494-2d4021f1c78d"
$flightRing = "Retail"
$flightingBranchName = ""
$currentBranch = "ge_release"

function Get-AuthCookie {
    [CmdletBinding()]
    param()

    Write-Section "步骤1：获取认证 Cookie"
    $cookieRequestPayload = New-CookieXmlPayload
    $cookieResponseContent = Invoke-SoapRequest -Uri $baseUri -Payload $cookieRequestPayload -StepName "步骤1" -RequestLogName "01_Step1_Request.xml" -ResponseLogName "01_Step1_Response.xml"
    $cookieResponseXml = [xml]$cookieResponseContent
    $encryptedCookieData = $cookieResponseXml.Envelope.Body.GetCookieResponse.GetCookieResult.EncryptedData
    if ([string]::IsNullOrWhiteSpace($encryptedCookieData)) {
        throw "步骤1失败: 未从响应中解析到 EncryptedData。"
    }
    Write-Host "成功：已获取 Cookie。" -ForegroundColor Green
    return $encryptedCookieData
}

function Get-PackageCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncryptedCookieData,
        [Parameter(Mandatory)]
        [object]$SystemContext
    )

    Write-Section "步骤2：获取文件列表"
    $fileListRequestPayload = New-FileListXmlPayload -EncryptedCookieData $EncryptedCookieData -Context $SystemContext
    Save-DebugArtifact -FileName "02_Step2_Request.xml" -Content $fileListRequestPayload
    $fileListResponseContent = Invoke-SoapRequest -Uri $baseUri -Payload $fileListRequestPayload -StepName "步骤2" -ResponseLogName "02_Step2_Response.xml"

    Add-Type -AssemblyName System.Web
    $decodedContent = [System.Web.HttpUtility]::HtmlDecode($fileListResponseContent)
    $fileListResponseXml = [xml]$decodedContent

    $fileIdentityMap = @{}
    $newUpdates = @($fileListResponseXml.Envelope.Body.SyncUpdatesResponse.SyncUpdatesResult.NewUpdates.UpdateInfo)
    $allExtendedUpdates = @($fileListResponseXml.Envelope.Body.SyncUpdatesResponse.SyncUpdatesResult.ExtendedUpdateInfo.Updates.Update)

    Write-Host "--- 正在关联更新信息 ---" -ForegroundColor Magenta
    $downloadableUpdates = $newUpdates | Where-Object { $_.Xml.Properties.SecuredFragment }
    Write-Host "找到 $($downloadableUpdates.Count) 个可下载包（候选）。" -ForegroundColor Cyan

    foreach ($update in $downloadableUpdates) {
        $lookupId = $update.ID
        $extendedInfo = $allExtendedUpdates | Where-Object { $_.ID -eq $lookupId } | Select-Object -First 1
        if (-not $extendedInfo) {
            Write-Host "[警告] 无法关联 ID $lookupId 的扩展信息，已跳过。" -ForegroundColor Yellow
            continue
        }

        $fileNode = @($extendedInfo.Xml.Files.File | Where-Object { $_.FileName -and $_.FileName -notlike "Abm_*" } | Select-Object -First 1)
        if (-not $fileNode) {
            Write-Host "[警告] ID $lookupId 没有有效文件节点，已跳过。" -ForegroundColor Yellow
            continue
        }

        $fullIdentifier = $fileNode.GetAttribute("InstallerSpecificIdentifier")
        if ([string]::IsNullOrWhiteSpace($fullIdentifier)) {
            Write-Host "[警告] ID $lookupId 缺少 InstallerSpecificIdentifier，已跳过。" -ForegroundColor Yellow
            continue
        }

        $regex = "^(?<Name>.+?)_(?<Version>\d+\.\d+\.\d+\.\d+)_(?<Architecture>[a-zA-Z0-9]+)_(?<ResourceId>.*?)_(?<PublisherId>[a-hjkmnp-tv-z0-9]{13})$"
        $packageInfo = [PSCustomObject]@{
            FullName       = $fullIdentifier
            FileName       = $fileNode.FileName
            UpdateID       = [string]$update.Xml.UpdateIdentity.UpdateID
            RevisionNumber = [string]$update.Xml.UpdateIdentity.RevisionNumber
            PackageName    = "Unknown"
            Version        = "0.0.0.0"
            Architecture   = "unknown"
            ResourceId     = ""
            PublisherId    = ""
            ExpectedHash   = (Get-ExpectedHashFromFileNode -FileNode $fileNode)
        }

        if ($fullIdentifier -match $regex) {
            $packageInfo.PackageName = $matches.Name
            $packageInfo.Version = $matches.Version
            $packageInfo.Architecture = $matches.Architecture.ToLowerInvariant()
            $packageInfo.ResourceId = $matches.ResourceId
            $packageInfo.PublisherId = $matches.PublisherId
        }

        $fileIdentityMap[$fullIdentifier] = $packageInfo
        Write-Host "  -> 已关联: $($packageInfo.PackageName) ($($packageInfo.Architecture))" -ForegroundColor Green
    }

    Write-Host "--- 关联完成 ---" -ForegroundColor Magenta
    Write-Host "准备处理文件数: $($fileIdentityMap.Count)" -ForegroundColor Green
    return @($fileIdentityMap.Values)
}

function Select-TargetPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$AllPackages,
        [Parameter(Mandatory)]
        [object]$SystemContext
    )

    Write-Section "步骤3：筛选适配包"
    $systemArch = $SystemContext.PackageArch
    $latestStorePackage = $AllPackages |
        Where-Object { $_.PackageName -eq 'Microsoft.WindowsStore' -and (($_.Architecture -eq $systemArch) -or ($_.Architecture -eq 'neutral')) } |
        Sort-Object { [version]$_.Version } -Descending |
        Select-Object -First 1

    $filteredDependencies = $AllPackages |
        Where-Object { $_.PackageName -ne 'Microsoft.WindowsStore' -and (($_.Architecture -eq $systemArch) -or ($_.Architecture -eq 'neutral')) } |
        Group-Object { '{0}|{1}|{2}|{3}' -f $_.PackageName, $_.Architecture, $_.ResourceId, $_.PublisherId } |
        ForEach-Object { $_.Group | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1 }

    $packagesToProcess = @()
    if ($latestStorePackage) {
        $packagesToProcess += $latestStorePackage
        Write-Host "找到最新 Store 包: $($latestStorePackage.FullName)" -ForegroundColor Green
    } else {
        Write-Host "[警告] 未找到可用的 Microsoft.WindowsStore 包。" -ForegroundColor Yellow
    }
    $packagesToProcess += $filteredDependencies
    Write-Host "依赖包数量: $($filteredDependencies.Count)" -ForegroundColor Green
    Write-Host "总处理数: $($packagesToProcess.Count)" -ForegroundColor Cyan
    return $packagesToProcess
}

function Get-PackageDownloadInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Packages,
        [Parameter(Mandatory)]
        [string]$EncryptedCookieData,
        [Parameter(Mandatory)]
        [object]$SystemContext
    )

    Write-Section "步骤4：获取 URL"
    $downloadItems = @()
    foreach ($package in $Packages) {
        Write-Host "处理: $($package.FullName)"

        $fileUrlRequestPayload = New-FileUrlXmlPayload -EncryptedCookieData $EncryptedCookieData -UpdateId $package.UpdateID -RevisionNumber $package.RevisionNumber -Context $SystemContext
        $requestFileName = "03_Step3_Request_$($package.UpdateID).xml"
        $responseFileName = "03_Step3_Response_$($package.UpdateID).xml"
        Save-DebugArtifact -FileName $requestFileName -Content $fileUrlRequestPayload

        $fileUrlResponseContent = Invoke-SoapRequest -Uri "$baseUri/secured" -Payload $fileUrlRequestPayload -StepName "步骤4($($package.PackageName))" -ResponseLogName $responseFileName
        $fileUrlResponseXml = [xml]$fileUrlResponseContent
        $fileLocations = @($fileUrlResponseXml.Envelope.Body.GetExtendedUpdateInfo2Response.GetExtendedUpdateInfo2Result.FileLocations.FileLocation)
        $baseFileName = [System.IO.Path]::GetFileNameWithoutExtension($package.FileName)
        $downloadUrl = ($fileLocations | Where-Object { $_.Url -like "*$baseFileName*" } | Select-Object -First 1).Url
        if (-not $downloadUrl) {
            $downloadUrl = ($fileLocations | Select-Object -First 1).Url
        }

        if (-not $downloadUrl) {
            Write-Host "[警告] 未获取到下载地址: $($package.FileName)" -ForegroundColor Yellow
            continue
        }

        $expectedHash = $package.ExpectedHash
        if (-not $expectedHash) {
            $expectedHash = Get-ExpectedSha256FromText -Text $fileUrlResponseContent
        }

        $downloadItems += [PSCustomObject]@{
            Package      = $package
            DownloadUrl  = $downloadUrl
            ExpectedHash = $expectedHash
        }
    }
    return $downloadItems
}

function Save-PackageFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$DownloadItems,
        [Parameter(Mandatory)]
        [ValidateSet('1','2','3')]
        [string]$DownloadMode
    )

    if ($script:optNoDownload) {
        Write-Host "[提示] 已启用 -noDownload，仅解析，不下载。" -ForegroundColor Yellow
        return @()
    }

    Write-Section "步骤5：下载文件"
    $downloadFailures = @()
    $downloadedFiles = @()

    foreach ($item in $DownloadItems) {
        $package = $item.Package
        $fileExtension = [System.IO.Path]::GetExtension($package.FileName)
        $newFileName = "$($package.FullName)$fileExtension"
        $safeFileName = [System.IO.Path]::GetFileName($newFileName)
        if ($safeFileName -ne $newFileName) {
            Write-Host "[安全警告] 可疑文件名已净化: $newFileName -> $safeFileName" -ForegroundColor Red
        }
        $filePath = Join-Path $workingDir $safeFileName
        Write-Host "  -> 下载地址: $($item.DownloadUrl)" -ForegroundColor DarkGray
        Write-Host "  -> 保存到: $filePath" -ForegroundColor DarkGray

        try {
            Start-FileDownload -Url $item.DownloadUrl -OutFile $filePath -Mode $DownloadMode
            Assert-FileIntegrity -FilePath $filePath -ExpectedHash $item.ExpectedHash
            Write-Host "  -> 下载完成" -ForegroundColor Green
            $downloadedFiles += (Get-Item -LiteralPath $filePath)
        } catch {
            Write-Host "  -> 下载失败: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-AdviceFromError -Message $_.Exception.Message
            $downloadFailures += [PSCustomObject]@{
                Package = $package.FullName
                Error   = $_.Exception.Message
            }
        }
    }

    if ($downloadFailures.Count -gt 0) {
        $summary = ($downloadFailures | ForEach-Object { "$($_.Package): $($_.Error)" }) -join "; "
        throw "下载阶段存在失败项($($downloadFailures.Count)): $summary"
    }
    return $downloadedFiles
}

function Install-PackageFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$DownloadedFiles
    )

    if ($script:optNoInstall) {
        Write-Host "[提示] 已启用 -noInstall，跳过安装步骤。" -ForegroundColor Yellow
        return
    }

    Write-Section "步骤6：安装包"
    $allDownloadedFiles = @($DownloadedFiles)
    if ($allDownloadedFiles.Count -eq 0) {
        $allDownloadedFiles = @(Get-ChildItem -Path $workingDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.appx', '.msix', '.appxbundle', '.msixbundle' })
    }

    $storePackageFile = $allDownloadedFiles | Where-Object { $_.Name -like 'Microsoft.WindowsStore*' } | Sort-Object Name -Descending | Select-Object -First 1
    $dependencyFiles = $allDownloadedFiles | Where-Object { $_.Name -notlike 'Microsoft.WindowsStore*' }
    if (-not $dependencyFiles -and -not $storePackageFile) {
        Write-Host "[警告] 未找到可安装的包。" -ForegroundColor Yellow
        return
    }

    if ($storePackageFile) {
        try {
            $dependencyPaths = @($dependencyFiles | ForEach-Object { $_.FullName })
            if ($dependencyPaths.Count -gt 0) {
                Add-AppxPackage -Path $storePackageFile.FullName -DependencyPath $dependencyPaths -ForceApplicationShutdown -ErrorAction Stop
            } else {
                Add-AppxPackage -Path $storePackageFile.FullName -ForceApplicationShutdown -ErrorAction Stop
            }
            Write-Host "Microsoft Store 安装/更新完成。" -ForegroundColor Green
        } catch {
            if ($_.Exception.Message -match '0x80073D06|更高版本') {
                Write-Host "[提示] 已安装更高版本 Microsoft Store，跳过覆盖安装。" -ForegroundColor Yellow
            } else {
                Write-Host "Microsoft Store 安装失败: $($_.Exception.Message)" -ForegroundColor Red
                Write-AdviceFromError -Message $_.Exception.Message
                throw
            }
        }
    } else {
        Write-Host "[警告] 未找到 Microsoft Store 主包，仅尝试安装依赖。" -ForegroundColor Yellow
        foreach ($pkg in ($dependencyFiles | Sort-Object Name)) {
            try {
                Add-AppxPackage -Path $pkg.FullName -ErrorAction Stop
                Write-Host "  -> 依赖安装成功: $($pkg.Name)" -ForegroundColor Green
            } catch {
                Write-Host "  -> 依赖安装失败: $($pkg.Name) - $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}

function Install-Store {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('1','2','3')]
        [string]$DownloadMode
    )

    if (-not $script:optNoInstall) { Test-Admin }
    $systemContext = Get-SystemContext

    Write-Section "前置检查：商店存在性 / 服务 / 残留 / 代理"
    Test-StoreInstalled | Out-Null
    Test-Proxy | Out-Null
    Test-StoreHealth
    Test-StoreResidue

    $encryptedCookieData = Get-AuthCookie
    $allPackages = Get-PackageCatalog -EncryptedCookieData $encryptedCookieData -SystemContext $systemContext
    $targetPackages = Select-TargetPackages -AllPackages $allPackages -SystemContext $systemContext
    $downloadItems = Get-PackageDownloadInfo -Packages $targetPackages -EncryptedCookieData $encryptedCookieData -SystemContext $systemContext
    if ($script:optNoDownload) {
        # Save-PackageFiles 内部会跳过下载，这里直接返回不进入安装阶段
        Save-PackageFiles -DownloadItems $downloadItems -DownloadMode $DownloadMode | Out-Null
        return
    }
    $downloadedFiles = Save-PackageFiles -DownloadItems $downloadItems -DownloadMode $DownloadMode
    Install-PackageFiles -DownloadedFiles $downloadedFiles

    $cleanup = Read-Host "是否删除下载文件夹? (Y/N, 推荐 Y)"
    if ($cleanup -match '^[Yy]$') {
        try {
            Remove-Item -Path $workingDir -Recurse -Force -ErrorAction Stop
            Write-Host ("[OK] 已删除下载文件夹: {0}" -f $workingDir) -ForegroundColor Green
        } catch {
            Write-Host ("[!] 删除失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
        }
    }
}

function Reset-Store {
    [CmdletBinding()]
    param()

    Write-Section "微软商店修复模式"

    try {
        Write-Host "正在重置商店缓存 (WSReset)..."
        Start-Process -FilePath "wsreset.exe" -Wait -ErrorAction Stop
        Write-Host "[OK] WSReset 执行完成。" -ForegroundColor Green
    } catch {
        Write-Host "[错误] WSReset 执行失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-AdviceFromError -Message $_.Exception.Message
    }

    Test-Proxy | Out-Null
    Test-StoreHealth

    try {
        Write-Host "正在重新注册商店应用..."
        Get-Process -Name WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        $storePackages = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue
        if (-not $storePackages) {
            Write-Host "[警告] 未找到已安装商店包，无法重新注册。" -ForegroundColor Yellow
        } else {
            foreach ($storePackage in $storePackages) {
                $manifestPath = Join-Path $storePackage.InstallLocation "AppXManifest.xml"
                if (-not (Test-Path $manifestPath)) {
                    Write-Host "[警告] 跳过无效清单路径: $manifestPath" -ForegroundColor Yellow
                    continue
                }
                Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ErrorAction Stop
                Write-Host "[OK] 已重新注册: $($storePackage.PackageFullName)" -ForegroundColor Green
            }
        }
    } catch {
        Write-Host "[错误] 重新注册失败: $($_.Exception.Message)" -ForegroundColor Red
        Write-AdviceFromError -Message $_.Exception.Message
    }

    Request-RegionFix
    Write-Host "[完成] 修复操作已执行，请尝试打开商店。" -ForegroundColor Green
}

function Remove-FilesByPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [string]$Filter,
        [Parameter(Mandatory)]
        [string]$Label
    )

    $deleted = $false
    $files = Get-ChildItem -Path $Directory -File -Filter $Filter -ErrorAction SilentlyContinue
    foreach ($logFile in $files) {
        try {
            Remove-Item -Path $logFile.FullName -Force -ErrorAction Stop
            Write-Host "[OK] 已删除${Label}: $($logFile.FullName)" -ForegroundColor Green
            $deleted = $true
        } catch {
            Write-Host "[!] 删除失败: $($logFile.FullName) - $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    return $deleted
}

function Clear-Logs {
    [CmdletBinding()]
    param()

    Write-Host "正在清理日志..." -ForegroundColor Cyan
    Write-Host "清理选项："
    Write-Host "[1] 仅清理导出的日志文件 (Logs / ERROR_*.txt / AppX_*.txt)"
    Write-Host "[2] 仅清理系统 AppX 部署事件日志"
    Write-Host "[3] 两者都清理"
    Write-Host "[4] 返回"
    $sel = Read-Host "请选择 (1-4)"

    if ($sel -eq '4') { return }
    $deletedAny = $false

    if ($sel -in @('1','3')) {
        $logDirs = @($LogDirectory, (Join-Path $workingDir "Logs"), (Join-Path $PSScriptRoot "Logs")) | Select-Object -Unique
        foreach ($path in $logDirs) {
            if (Test-Path -Path $path) {
                try {
                    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                    Write-Host "[OK] 已删除日志目录: $path" -ForegroundColor Green
                    $deletedAny = $true
                } catch {
                    Write-Host "[!] 删除失败: $path - $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
        }

        foreach ($root in @($workingDir, $PSScriptRoot) | Select-Object -Unique) {
            if (-not (Test-Path -Path $root)) { continue }
            if (Remove-FilesByPattern -Directory $root -Filter "ERROR_*.txt" -Label "错误日志") { $deletedAny = $true }
            if (Remove-FilesByPattern -Directory $root -Filter "AppX_*.txt" -Label "AppX 日志") { $deletedAny = $true }
        }
    }

    if ($sel -in @('2','3')) {
        Write-Host "正在清理系统 AppX 部署事件日志..." -ForegroundColor Cyan
        foreach ($channel in @("Microsoft-Windows-AppXDeploymentServer/Operational","Microsoft-Windows-AppXDeploymentServer/Admin")) {
            try {
                wevtutil.exe cl "$channel" | Out-Null
                Write-Host "[OK] 已清理事件日志: $channel" -ForegroundColor Green
                $deletedAny = $true
            } catch {
                Write-Host "[!] 清理失败: $channel - $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if (-not $deletedAny) {
        Write-Host "[提示] 未发现需要清理的日志或清理未执行。" -ForegroundColor Yellow
    }
}

function Get-LatestAppxActivityId {
    [CmdletBinding()]
    param()

    foreach ($channel in @("Microsoft-Windows-AppXDeploymentServer/Operational","Microsoft-Windows-AppXDeploymentServer/Admin")) {
        $events = Get-WinEvent -LogName $channel -MaxEvents 200 -ErrorAction SilentlyContinue
        foreach ($evt in $events) {
            if ($evt.ActivityId -and $evt.ActivityId -ne [guid]::Empty) { return $evt.ActivityId.Guid }
            if ($evt.Message -match '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') {
                return $matches[0]
            }
        }
    }
    return $null
}

function Export-AppxLog {
    [CmdletBinding()]
    param()

    try {
        New-DirectoryIfMissing -Path $LogDirectory
        $activityId = Get-LatestAppxActivityId
        if (-not $activityId) {
            Write-Host "[提示] 未找到可用的 ActivityID（系统事件日志中没有可解析记录）。" -ForegroundColor Yellow
            return
        }

        $outFile = Join-Path $LogDirectory ("AppX_{0}.txt" -f $activityId)
        Get-AppPackageLog -ActivityID $activityId | Out-File -Encoding UTF8 -FilePath $outFile
        Write-Host "[OK] 已自动导出最新 ActivityID 的 AppX 日志: $activityId" -ForegroundColor Green
        Write-Host "[OK] AppX 部署日志已保存到: $outFile" -ForegroundColor Green
    } catch {
        Write-Host "[错误] 无法导出 AppX 部署日志: $($_.Exception.Message)" -ForegroundColor Red
        Write-AdviceFromError -Message $_.Exception.Message
    }
}

function Invoke-Safe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,
        [string]$ActionName = "操作"
    )
    try {
        Write-LogEntry -Level INFO -Message "Action start: $ActionName"
        & $Action
        Write-LogEntry -Level INFO -Message "Action done: $ActionName"
    } catch {
        $msg = $_.Exception.Message
        Write-Host "[错误] $ActionName 失败: $msg" -ForegroundColor Red
        Write-LogEntry -Level ERROR -Message "Action failed: $ActionName | $msg"
        if ($_.ScriptStackTrace) { Write-Host "[堆栈] $($_.ScriptStackTrace)" -ForegroundColor DarkGray }
        Write-AdviceFromError -Message $msg

        New-DirectoryIfMissing -Path $LogDirectory
        $errPath = Join-Path $LogDirectory ("ERROR_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".txt")
        @(
            "时间: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
            "操作: $ActionName"
            "消息: $msg"
            "类型: $($_.Exception.GetType().FullName)"
            "堆栈: $($_.ScriptStackTrace)"
            "完整异常:"
            $_.Exception.ToString()
            "内部异常:"
            $(if ($_.Exception.InnerException) { $_.Exception.InnerException.ToString() } else { "" })
        ) | Set-Content -Path $errPath -Encoding UTF8
        Write-LogEntry -Level ERROR -Message "Saved error report: $errPath"
        Write-Host "错误日志已保存到: $errPath" -ForegroundColor Yellow
        Write-Host "返回主菜单..." -ForegroundColor Yellow
    }
}

# -------- Main Menu --------
Write-Section "微软商店修复工具 (PS1) v$($script:ToolVersion)"
Get-OSInfo | Out-Null
Test-ToolUpdate
Write-Host ("工作目录: {0}" -f $workingDir) -ForegroundColor DarkGray
Write-Host ("日志目录: {0}" -f $LogDirectory) -ForegroundColor DarkGray
Write-Host ("高级选项状态: -noDownload={0}, -noInstall={1}" -f $script:optNoDownload, $script:optNoInstall) -ForegroundColor DarkGray

:mainLoop while ($true) {
    Write-Host ""
    Write-Host "[1] 安装/重装微软商店 (官方源)"
    Write-Host "[2] 修复/重置已安装商店"
    Write-Host "[3] 仅修复系统服务问题"
    Write-Host "[4] 检测当前微软商店是否存在"
    Write-Host "[5] 清理日志"
    Write-Host "[6] 导出 AppX 部署日志 (自动 ActivityID)"
    Write-Host "[7] 高级选项"
    Write-Host "[8] 退出"
    $choice = Read-Host "请选择 (1-8)"

    switch ($choice) {
        '1' {
            $mode = Get-DownloadMode
            Invoke-Safe -ActionName "安装/重装微软商店" -Action { Install-Store -DownloadMode $mode }
        }
        '2' { Invoke-Safe -ActionName "修复/重置商店" -Action { Reset-Store } }
        '3' { Invoke-Safe -ActionName "系统服务修复检测" -Action { Test-StoreHealth } }
        '4' { Invoke-Safe -ActionName "商店存在性检测" -Action { Test-StoreInstalled | Out-Null } }
        '5' { Invoke-Safe -ActionName "清理日志" -Action { Clear-Logs } }
        '6' { Invoke-Safe -ActionName "导出 AppX 日志" -Action { Export-AppxLog } }
        '7' { Show-AdvancedOptions }
        '8' { break mainLoop }
        default { Write-Host "无效选择" -ForegroundColor Yellow }
    }
}

