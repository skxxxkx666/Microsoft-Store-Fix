#requires -version 5.1
<#
.SYNOPSIS
    Microsoft Store 通用安装修复工具。

.DESCRIPTION
    通过 Windows Update SOAP 接口 (MS-WUSP) 从微软官方源下载并安装 Microsoft Store，
    并提供系统诊断、服务修复、残留清理、日志管理、多下载模式等功能。

    协议参考：
    - MS-WUSP: https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-wusp
    - MSIX 打包: https://learn.microsoft.com/en-us/windows/msix/package/packaging-uwp-apps

    灵感来源：
    - ThioJoe/Windows-Sandbox-Tools (MIT License)
    - v1.4.0 起通信层实现已重构为独立代码结构，不再作为其脚本分支。

.PARAMETER DebugSaveFiles
    保存 SOAP 请求/响应 XML 与错误报告。

.PARAMETER NoInstall
    仅下载包文件，跳过安装步骤。

.PARAMETER NoDownload
    仅解析包信息，跳过下载与安装。

.EXAMPLE
    .\MicrosoftStore_Fix_v1.4.0.ps1

.EXAMPLE
    .\MicrosoftStore_Fix_v1.4.0.ps1 -NoInstall

.LINK
    https://github.com/skxxxkx666/Microsoft-Store-Fix
#>

param(
    [switch]$DebugSaveFiles,
    [switch]$NoInstall,
    [switch]$NoDownload
)

$ErrorActionPreference = 'Stop'

$script:Config = [PSCustomObject]@{
    ToolVersion       = '1.4.0'
    UpdateApi         = 'https://api.github.com/repos/skxxxkx666/Microsoft-Store-Fix/releases/latest'

    OptNoInstall      = [bool]$NoInstall
    OptNoDownload     = [bool]$NoDownload
    EnableDebug       = [bool]$DebugSaveFiles

    SoapEndpoint      = 'https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx'
    SoapHeaders       = @{ 'Content-Type' = 'application/soap+xml; charset=utf-8' }
    StoreCategoryId   = '64293252-5926-453c-9494-2d4021f1c78d'
    RequestTimeoutSec = 60

    FlightRing        = 'Retail'
    FlightBranch      = ''
    CurrentBranch     = 'ge_release'

    WorkingDir        = $null
    LogDirectory      = $null
    ToolLogPath       = $null
    BestIpCache       = @{}
}

$script:WuProductClassIds = @(
    # 基础 Windows 平台分类
    1, 2, 3, 11, 19,
    # Windows 核心组件
    2359974, 5169044, 8788830,
    # Defender / 关键更新分类
    23110993, 23110994, 54341900, 59830006, 59830007, 59830008,
    60484010, 62450018, 62450019, 62450020,
    # Windows 10/11 产品与功能分类
    98959022, 98959023, 98959024, 98959025, 98959026,
    104433538, 129905029, 130040031, 132387090, 132393049, 133399034,
    138537048, 140377312, 143747671,
    # 其他产品分类（来源：MS-WUSP 体系中的产品分类上下文）
    158941041, 158941042, 158941043, 158941044, 159123858, 159130928,
    164836897, 164847386, 164848327, 164852241, 164852246, 164852253
)

# NOTE: 不使用 #requires -RunAsAdministrator；
# 菜单中有非管理员可执行项，管理员检查在需要时按步骤执行。

#region 基础设施
function Write-LogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','DEBUG')]
        [string]$Level = 'INFO'
    )

    $entry = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    if ($script:Config.ToolLogPath) {
        try {
            $logDir = [System.IO.Path]::GetDirectoryName($script:Config.ToolLogPath)
            if (-not (Test-Path -LiteralPath $logDir)) {
                New-Item -Path $logDir -ItemType Directory -Force | Out-Null
            }
            Add-Content -Path $script:Config.ToolLogPath -Value $entry -Encoding UTF8 -ErrorAction SilentlyContinue # 日志写入失败不应打断主流程
        } catch {
            # 日志写入失败不应中断主流程
        }
    }
}

function Write-Status {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [Parameter(Mandatory)]
        [ValidateSet('OK','Warn','Error','Info','Fix','Skip','Check')]
        [string]$Level
    )

    $styleMap = @{
        OK    = @{ Prefix = '[OK]';   Color = 'Green'    ; Log = 'INFO'  }
        Warn  = @{ Prefix = '[警告]'; Color = 'Yellow'   ; Log = 'WARN'  }
        Error = @{ Prefix = '[错误]'; Color = 'Red'      ; Log = 'ERROR' }
        Info  = @{ Prefix = '[提示]'; Color = 'Cyan'     ; Log = 'INFO'  }
        Fix   = @{ Prefix = '[修复]'; Color = 'Green'    ; Log = 'INFO'  }
        Skip  = @{ Prefix = '[跳过]'; Color = 'DarkGray' ; Log = 'INFO'  }
        Check = @{ Prefix = '[检测]'; Color = 'Cyan'     ; Log = 'INFO'  }
    }

    $entry = $styleMap[$Level]
    $line = "$($entry.Prefix) $Message"
    Write-Host $line -ForegroundColor $entry.Color
    Write-LogEntry -Level $entry.Log -Message $line
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
#endregion

#region 系统诊断

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

    $ntInfo = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $product = [string]$ntInfo.ProductName
    $edition = [string]$ntInfo.EditionID
    $build = 0
    [void][int]::TryParse([string]$ntInfo.CurrentBuild, [ref]$build)

    # Windows 11 的 ProductName 在注册表中常仍显示为 Windows 10，按 Build 修正显示
    if ($build -ge 22000 -and $product -match '^Windows 10') {
        $product = $product -replace '^Windows 10', 'Windows 11'
    }

    $type = 'Normal'
    if ($product -match 'LTSC|LTSB') { $type = 'LTSC' }
    if ($product -match 'IoT' -or $edition -match 'IoT') { $type = 'IoT' }
    if ($edition -match 'EnterpriseS') { $type = 'LTSC' }

    Write-Status -Level Info -Message "系统产品: $product (Build $build)"
    Write-Status -Level Info -Message "系统 Edition: $edition"
    Write-Status -Level Info -Message "系统类型: $type"

    if ($type -eq 'Normal') {
        Write-Status -Level Warn -Message "检测到非 LTSC/IoT 版本，建议优先使用系统自带商店修复。"
    }

    return [PSCustomObject]@{
        Product = $product
        Edition = $edition
        Type    = $type
        Build   = $build
    }
}

function Test-ToolUpdate {
    [CmdletBinding()]
    param()

    try {
        $release = Invoke-RestMethod -Uri $script:Config.UpdateApi -Method Get -TimeoutSec 5 -ErrorAction Stop
        $latest = [string]$release.tag_name
        if ([string]::IsNullOrWhiteSpace($latest)) { return }
        $current = "v$($script:Config.ToolVersion)"
        if (-not [string]::Equals($latest, $current, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Status -Level Warn -Message "检测到新版本: $latest (当前: $current)"
            Write-LogEntry -Level INFO -Message "Update available: latest=$latest current=$current"
        } else {
            Write-LogEntry -Level DEBUG -Message "Already latest version: $current"
        }
    } catch {
        # 保持纯静默失败：网络受限环境不打扰用户。
    }
}

function Test-Proxy {
    [CmdletBinding()]
    param()

    $proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyEnable = (Get-ItemProperty $proxyKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable # 代理键在部分系统不存在
    $proxyServer = (Get-ItemProperty $proxyKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer # 代理键在部分系统不存在

    if ($proxyEnable -eq 1) {
        Write-Status -Level Warn -Message "系统代理已开启: $proxyServer"
        return [PSCustomObject]@{
            Enabled = $true
            Server  = $proxyServer
        }
    } else {
        Write-Status -Level OK -Message "未检测到系统代理。"
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
        Write-Status -Level Info -Message "建议：以管理员身份运行 PowerShell 后重试。"
        Write-LogEntry -Level WARN -Message "Advice: run as admin. RawError=$Message"
        return
    }
    if ($Message -match '0x80073D02') {
        Write-Status -Level Info -Message "建议：关闭 Microsoft Store / WinStore 进程后重试。"
        Write-LogEntry -Level WARN -Message "Advice: close Store process. RawError=$Message"
        return
    }
    if ($Message -match '0x80073D06|更高版本') {
        Write-Status -Level Info -Message "已安装更高版本，通常无需重复安装。"
        Write-LogEntry -Level INFO -Message "Advice: higher version already installed. RawError=$Message"
        return
    }
    if ($Message -match 'timeout|timed out|超时') {
        Write-Status -Level Info -Message "建议：检查网络/代理，或切换下载模式重试。"
        Write-LogEntry -Level WARN -Message "Advice: network/proxy check. RawError=$Message"
        return
    }
    if ($Message -match 'SSL|TLS|证书') {
        Write-Status -Level Info -Message "建议：检查系统时间、证书链、代理劫持情况。"
        Write-LogEntry -Level WARN -Message "Advice: TLS/certificate check. RawError=$Message"
        return
    }
    if ($Message -match 'not found|找不到') {
        Write-Status -Level Info -Message "建议：检查路径/文件是否存在，必要时重新下载。"
        Write-LogEntry -Level WARN -Message "Advice: path/file check. RawError=$Message"
        return
    }
    Write-Status -Level Info -Message "建议：使用菜单 [6] 导出 AppX 日志进一步排查。"
}

function Start-ServiceIfNeeded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    # 服务在不同 Windows 版本上可能不存在，静默处理后给出提示。
    $serviceObj = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue # 某些版本不存在该服务
    if ($null -eq $serviceObj) {
        Write-Status -Level Warn -Message "未找到服务 $ServiceName"
        return $false
    }
    if ($serviceObj.Status -eq 'Running') {
        Write-Status -Level OK -Message "$ServiceName 正常运行。"
        return $true
    }

    try {
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-Status -Level Fix -Message "启动服务 $ServiceName 成功"
        return $true
    } catch {
        Write-Status -Level Warn -Message "启动服务 $ServiceName 失败: $($_.Exception.Message)"
        Write-AdviceFromError -Message $_.Exception.Message
        return $false
    }
}

function Test-StoreHealth {
    [CmdletBinding()]
    param()

    Write-Status -Level Check -Message "服务状态..."
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
    $serviceResults = @()
    foreach ($serviceName in $coreServices) {
        $serviceResults += [PSCustomObject]@{
            Name = $serviceName
            Ok   = [bool](Start-ServiceIfNeeded -ServiceName $serviceName)
        }
    }

    Write-Status -Level Check -Message "Store 包/依赖..."
    $missingPackages = New-Object System.Collections.Generic.List[string]
    if (Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue) { # 允许系统无包状态
        Write-Status -Level OK -Message "Microsoft.WindowsStore 已存在。"
    } else {
        Write-Status -Level Error -Message "未检测到 Microsoft.WindowsStore 包。"
        $missingPackages.Add('Microsoft.WindowsStore') | Out-Null
    }

    if (Get-AppxPackage -Name Microsoft.StorePurchaseApp -AllUsers -ErrorAction SilentlyContinue) { # 允许系统无包状态
        Write-Status -Level OK -Message "StorePurchaseApp 正常。"
    } else {
        Write-Status -Level Warn -Message "StorePurchaseApp 缺失。"
        $missingPackages.Add('Microsoft.StorePurchaseApp') | Out-Null
    }

    if (Get-AppxPackage -Name Microsoft.DesktopAppInstaller -AllUsers -ErrorAction SilentlyContinue) { # 允许系统无包状态
        Write-Status -Level OK -Message "AppInstaller 正常。"
    } else {
        Write-Status -Level Warn -Message "AppInstaller 缺失。"
        $missingPackages.Add('Microsoft.DesktopAppInstaller') | Out-Null
    }

    $cache = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalCache'
    $cacheExists = Test-Path $cache
    if ($cacheExists) {
        Write-Status -Level OK -Message "Store 缓存目录存在。"
    } else {
        Write-Status -Level Warn -Message "Store 缓存目录不存在。"
    }
    
    Write-Status -Level Check -Message "商店相关注册表项..."
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\WS\License Validation',
        'HKLM:\SOFTWARE\Microsoft\Windows\WS\WSRefreshBannedAppsListTask',
        'HKLM:\SOFTWARE\Microsoft\Windows\PushToInstall\Registration',
        'HKLM:\SOFTWARE\Microsoft\Windows\PushToInstall\LoginCheck'
    )
    $missingRegistryPaths = New-Object System.Collections.Generic.List[string]
    foreach ($registryPath in $regPaths) {
        if (Test-Path $registryPath) {
            Write-Status -Level OK -Message $registryPath
        } else {
            Write-Status -Level Warn -Message ("缺少注册表项: {0}" -f $registryPath)
            $missingRegistryPaths.Add($registryPath) | Out-Null
        }
    }

    $userSvcPatterns = @('UnistoreSvc_*','UserDataSvc_*')
    $missingUserServicePatterns = New-Object System.Collections.Generic.List[string]
    foreach ($servicePattern in $userSvcPatterns) {
        $serviceList = Get-Service -Name $servicePattern -ErrorAction SilentlyContinue # 用户实例化服务可能不存在
        if ($null -eq $serviceList -or $serviceList.Count -eq 0) {
            Write-Status -Level Warn -Message ("未找到服务 {0}" -f $servicePattern)
            $missingUserServicePatterns.Add($servicePattern) | Out-Null
            continue
        }
        foreach ($serviceObj in $serviceList) {
            $serviceResults += [PSCustomObject]@{
                Name = $serviceObj.Name
                Ok   = [bool](Start-ServiceIfNeeded -ServiceName $serviceObj.Name)
            }
        }
    }

    $allServicesOk = (@($serviceResults | Where-Object { -not $_.Ok }).Count -eq 0)
    return [PSCustomObject]@{
        AllServicesOk            = $allServicesOk
        ServiceResults           = $serviceResults
        MissingPackages          = @($missingPackages)
        MissingRegistryPaths     = @($missingRegistryPaths)
        MissingUserServiceGroups = @($missingUserServicePatterns)
        CacheDirectoryExists     = $cacheExists
    }
}

function Repair-StoreRegistry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$MissingPaths
    )

    if ($MissingPaths.Count -eq 0) {
        Write-Status -Level OK -Message "注册表项完整，无需修复。"
        return
    }

    Write-Section "修复缺失的注册表项"
    foreach ($path in $MissingPaths) {
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -Path $path -Force -ErrorAction Stop | Out-Null
                Write-Status -Level Fix -Message "已创建注册表项: $path"
                Write-LogEntry -Level INFO -Message "Created registry key: $path"
            } else {
                Write-Status -Level OK -Message "注册表项已存在: $path"
            }
        } catch {
            Write-Status -Level Error -Message "创建注册表项失败: $path - $($_.Exception.Message)"
            Write-LogEntry -Level ERROR -Message "Failed to create registry key: $path - $($_.Exception.Message)"
            Write-AdviceFromError -Message $_.Exception.Message
        }
    }
}

function Test-StoreResidue {
    [CmdletBinding()]
    param()

    $storePkg = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue # 用于判断已安装状态，缺失不报错
    $storeDir = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe'
    $hasResidue = $false
    $cleaned = $false

    if (-not $storePkg -and (Test-Path $storeDir)) {
        $hasResidue = $true
        Write-Status -Level Warn -Message "检测到可能的商店残留目录：$storeDir"

        $choice = Read-Host "是否清理残留目录? (Y/N, 推荐 Y)"
        if ($choice -match '^[Yy]$') {
            try {
                Remove-Item -Path $storeDir -Recurse -Force -ErrorAction Stop
                $cleaned = $true
                Write-Status -Level OK -Message "已清理残留目录。"
            } catch {
                Write-Status -Level Warn -Message ("清理失败: {0}" -f $_.Exception.Message)
                Write-AdviceFromError -Message $_.Exception.Message
            }
        }
    }

    if (-not $hasResidue) {
        Write-Status -Level OK -Message "未发现可疑商店残留。"
    }
    return [PSCustomObject]@{
        HasResidue = $hasResidue
        Cleaned    = $cleaned
        ResidueDir = $(if ($hasResidue) { $storeDir } else { $null })
    }
}

function Test-StoreInstalled {
    [CmdletBinding()]
    param()

    $pkg = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue # 部分系统未安装商店
    if ($pkg) {
        $ver = ($pkg | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Status -Level OK -Message ("已检测到 Microsoft.WindowsStore，版本: {0}" -f $ver)
        return [PSCustomObject]@{
            Installed = $true
            Version   = $ver
        }
    } else {
        Write-Status -Level Warn -Message "未检测到 Microsoft.WindowsStore。"
        return [PSCustomObject]@{
            Installed = $false
            Version   = $null
        }
    }
}

function Set-StoreRegion {
    [CmdletBinding()]
    param()

    Write-Status -Level Info -Message "商店初始化失败有时与地区设置有关。"
    Write-Status -Level Info -Message "当前设置将不会自动修改区域。"
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
        Write-Status -Level Warn -Message "无效选择，未修改区域。"
        return
    }

    try {
        $geoKeyPath = "HKCU:\Control Panel\International\Geo"
        if (-not (Test-Path $geoKeyPath)) { New-Item -Path $geoKeyPath -Force | Out-Null }

        $oldNation = (Get-ItemProperty -Path $geoKeyPath -Name "Nation" -ErrorAction SilentlyContinue).Nation # 旧键可能不存在
        $oldName = (Get-ItemProperty -Path $geoKeyPath -Name "Name" -ErrorAction SilentlyContinue).Name # 旧键可能不存在
        Write-Status -Level Info -Message "备份原区域: Nation=$oldNation, Name=$oldName"

        Set-ItemProperty -Path $geoKeyPath -Name "Nation" -Value $geoMap[$choice].Nation
        Set-ItemProperty -Path $geoKeyPath -Name "Name" -Value $geoMap[$choice].Name
        Write-Status -Level OK -Message ("已修改区域为 {0}。" -f $geoMap[$choice].Label)
    } catch {
        Write-Status -Level Error -Message "区域修复失败: $($_.Exception.Message)"
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
        Write-Host ("[1] 仅解析不下载 (-noDownload): {0}" -f $(if ($script:Config.OptNoDownload) { '开启' } else { '关闭' }))
        Write-Host ("[2] 仅下载不安装 (-noInstall): {0}" -f $(if ($script:Config.OptNoInstall) { '开启' } else { '关闭' }))
        Write-Host "[3] 返回主菜单"
        $sel = Read-Host "请选择 (1-3)"
        switch ($sel) {
            '1' { $script:Config.OptNoDownload = -not $script:Config.OptNoDownload }
            '2' { $script:Config.OptNoInstall = -not $script:Config.OptNoInstall }
            '3' { return }
            default { Write-Status -Level Warn -Message "无效选择" }
        }
    }
}

#endregion

#region 下载引擎
function Resolve-BestIp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$HostName
    )

    if ($script:Config.BestIpCache.ContainsKey($HostName)) {
        return $script:Config.BestIpCache[$HostName]
    }

    try {
        $ips = Resolve-DnsName -Name $HostName -Type A -ErrorAction Stop | Select-Object -ExpandProperty IPAddress
    } catch {
        return $null
    }
    $best = $null
    $bestMs = [int]::MaxValue
    foreach ($ip in $ips) {
        $pingResult = Test-Connection -ComputerName $ip -Count 1 -ErrorAction SilentlyContinue # 屏蔽单个节点不可达异常
        if ($pingResult -and $pingResult.ResponseTime -lt $bestMs) {
            $bestMs = $pingResult.ResponseTime
            $best = $ip
        }
    }
    $script:Config.BestIpCache[$HostName] = $best
    return $best
}

function Start-FileDownloadWithProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Url,
        [Parameter(Mandatory)]
        [string]$OutFile,
        [int]$TimeoutSec = 300
    )

    $request = $null
    $response = $null
    $responseStream = $null
    $fileStream = $null
    try {
        $request = [System.Net.HttpWebRequest]::Create($Url)
        $request.Method = 'GET'
        $request.Timeout = $TimeoutSec * 1000
        $request.ReadWriteTimeout = $TimeoutSec * 1000
        $response = $request.GetResponse()
        $responseStream = $response.GetResponseStream()
        $fileStream = [System.IO.File]::Open($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

        $totalBytes = [int64]$response.ContentLength
        $downloaded = [int64]0
        $buffer = New-Object byte[] 65536
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -le 0) { break }
            $fileStream.Write($buffer, 0, $bytesRead)
            $downloaded += $bytesRead

            if ($totalBytes -gt 0) {
                $percent = [math]::Min(100, [int](($downloaded * 100) / $totalBytes))
                $statusText = ("{0:N2} MB / {1:N2} MB" -f ($downloaded / 1MB), ($totalBytes / 1MB))
                Write-Progress -Activity "下载中" -Status $statusText -PercentComplete $percent
            } else {
                $speedMbps = if ($stopwatch.Elapsed.TotalSeconds -gt 0) { ($downloaded / 1MB) / $stopwatch.Elapsed.TotalSeconds } else { 0 }
                $statusText = ("已下载 {0:N2} MB，速度 {1:N2} MB/s" -f ($downloaded / 1MB), $speedMbps)
                Write-Progress -Activity "下载中" -Status $statusText -PercentComplete -1
            }
        }
    } finally {
        if ($fileStream) { $fileStream.Dispose() }
        if ($responseStream) { $responseStream.Dispose() }
        if ($response) { $response.Dispose() }
        Write-Progress -Activity "下载中" -Completed
    }
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
                    Write-Status -Level Info -Message "最优 IP: $bestIp (TLS 安全模式下保持域名下载)"
                } else {
                    Write-Status -Level Info -Message "最优 IP: $bestIp"
                }
            }
        } catch {
            Write-Status -Level Warn -Message "节点测速失败: $($_.Exception.Message)，继续默认下载。"
        }
    }

    try {
        Start-FileDownloadWithProgress -Url $Url -OutFile $OutFile -TimeoutSec ($script:Config.RequestTimeoutSec * 5)
    } catch {
        throw "下载失败: $($_.Exception.Message)"
    }
}
#endregion

function Save-DebugArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FileName,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    if (-not $script:Config.EnableDebug) {
        return
    }
    New-DirectoryIfMissing -Path $script:Config.LogDirectory
    $targetPath = Join-Path $script:Config.LogDirectory $FileName
    [System.IO.File]::WriteAllText($targetPath, $Content, [System.Text.UTF8Encoding]::new($false))
}

#region 协议通信
function Get-SystemContext {
    [CmdletBinding()]
    param()

    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $cpuInfo = Get-CimInstance -ClassName Win32_Processor -ErrorAction SilentlyContinue | Select-Object -First 1 # 某些精简系统可能缺失类

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

    $defaultRegion = (Get-ItemProperty -Path 'HKCU:\Control Panel\International\Geo' -Name Nation -ErrorAction SilentlyContinue).Nation # Nation 键可能缺失
    if ([string]::IsNullOrWhiteSpace([string]$defaultRegion)) {
        $defaultRegion = '244'
    }

    $appVer = '1407.2503.28012.0'
    $installedStore = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue # 允许商店缺失
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

function ConvertFrom-AppxPackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FullIdentifier
    )

    # AppX 包标识符格式：
    # <Name>_<Version>_<Architecture>_<ResourceId>_<PublisherId>
    # 参考：https://learn.microsoft.com/en-us/windows/msix/package/packaging-uwp-apps
    $regex = '^(?<Name>.+?)_(?<Version>\d+\.\d+\.\d+\.\d+)_(?<Architecture>[a-zA-Z0-9]+)_(?<ResourceId>.*?)_(?<PublisherId>[a-hjkmnp-tv-z0-9]{13})$'
    if ($FullIdentifier -notmatch $regex) {
        return [PSCustomObject]@{
            PackageName  = 'Unknown'
            Version      = '0.0.0.0'
            Architecture = 'unknown'
            ResourceId   = ''
            PublisherId  = ''
        }
    }

    return [PSCustomObject]@{
        PackageName  = $matches.Name
        Version      = $matches.Version
        Architecture = $matches.Architecture.ToLowerInvariant()
        ResourceId   = $matches.ResourceId
        PublisherId  = $matches.PublisherId
    }
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
        Remove-Item -Path $FilePath -Force -ErrorAction SilentlyContinue # 校验失败后尝试清理损坏文件
        throw "文件完整性校验失败: $FilePath (预期=$ExpectedHash, 实际=$actualHash)"
    }
}

function New-DeviceAttributesPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,
        [Parameter(Mandatory)]
        [hashtable]$FlightConfig
    )

    $attributes = [ordered]@{
        BranchReadinessLevel  = 'CB'
        CurrentBranch         = $FlightConfig.CurrentBranch
        OEMModel              = 'Virtual Machine'
        FlightRing            = $FlightConfig.FlightRing
        AttrDataVer           = '321'
        InstallLanguage       = $Context.InstallLanguage
        OSUILocale            = $Context.UiLocale
        InstallationType      = 'Client'
        FlightingBranchName   = $FlightConfig.FlightBranch
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

    $pairs = foreach ($entry in $attributes.GetEnumerator()) {
        '{0}={1}' -f $entry.Key, [System.Uri]::EscapeDataString([string]$entry.Value)
    }
    return "E:{0}" -f ($pairs -join '&')
}

function New-WuSecurityHeader {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$CookieData = '',
        [switch]$IncludeTimestamp
    )

    $timestampXml = ''
    if ($IncludeTimestamp) {
        $created = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        $expires = (Get-Date).ToUniversalTime().AddMinutes(5).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        $timestampXml = "<u:Timestamp u:Id=""_0"" xmlns:u=""http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd""><u:Created>$created</u:Created><u:Expires>$expires</u:Expires></u:Timestamp>"
    }

    $cookieXml = Convert-ToXmlEscaped -Text $CookieData
    return @"
<o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
    $timestampXml
    <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
        <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user>$cookieXml</user></TicketType>
    </wuws:WindowsUpdateTicketsToken>
</o:Security>
"@
}

function New-WuSoapEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Action,
        [Parameter(Mandatory)]
        [string]$Endpoint,
        [Parameter(Mandatory)]
        [string]$BodyXml,
        [string]$SecurityXml = ''
    )

    return @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
  <s:Header>
    <a:Action s:mustUnderstand="1">$Action</a:Action>
    <a:MessageID>urn:uuid:$([Guid]::NewGuid())</a:MessageID>
    <a:To s:mustUnderstand="1">$Endpoint</a:To>
    $SecurityXml
  </s:Header>
  <s:Body>$BodyXml</s:Body>
</s:Envelope>
"@
}

function New-CookieXmlPayload {
    [CmdletBinding()]
    param()

    $bodyXml = '<GetCookie xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService" />'
    $securityXml = New-WuSecurityHeader
    return (New-WuSoapEnvelope -Action 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie' -Endpoint $script:Config.SoapEndpoint -BodyXml $bodyXml -SecurityXml $securityXml)
}

function New-FileListXmlPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncryptedCookieData,
        [Parameter(Mandatory)]
        [object]$Context
    )

    $expiration = (Get-Date).AddYears(10).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    $deviceAttributes = Convert-ToXmlEscaped -Text (New-DeviceAttributesPayload -Context $Context -FlightConfig @{
            CurrentBranch = $script:Config.CurrentBranch
            FlightRing    = $script:Config.FlightRing
            FlightBranch  = $script:Config.FlightBranch
        })
    $cookieData = Convert-ToXmlEscaped -Text $EncryptedCookieData
    $clientLang = Convert-ToXmlEscaped -Text $Context.InstallLanguage
    $localesXml = ($Context.Locales | ForEach-Object { "<string>$([System.Security.SecurityElement]::Escape($_))</string>" }) -join ''
    $installedNonLeafXml = ($script:WuProductClassIds | ForEach-Object { "<int>$_</int>" }) -join ''

    $bodyXml = @"
<SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <cookie><Expiration>$expiration</Expiration><EncryptedData>$cookieData</EncryptedData></cookie>
  <parameters>
    <ExpressQuery>false</ExpressQuery>
    <InstalledNonLeafUpdateIDs>$installedNonLeafXml</InstalledNonLeafUpdateIDs>
    <SkipSoftwareSync>false</SkipSoftwareSync>
    <NeedTwoGroupOutOfScopeUpdates>false</NeedTwoGroupOutOfScopeUpdates>
    <FilterAppCategoryIds><CategoryIdentifier><Id>$($script:Config.StoreCategoryId)</Id></CategoryIdentifier></FilterAppCategoryIds>
    <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
    <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
    <ComputerSpec/>
    <ExtendedUpdateInfoParameters><XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes><Locales>$localesXml</Locales></ExtendedUpdateInfoParameters>
    <ClientPreferredLanguages><string>$clientLang</string></ClientPreferredLanguages>
    <ProductsParameters><SyncCurrentVersionOnly>false</SyncCurrentVersionOnly><DeviceAttributes>$deviceAttributes</DeviceAttributes><CallerAttributes>Interactive=1;IsSeeker=1;</CallerAttributes><Products/></ProductsParameters>
  </parameters>
</SyncUpdates>
"@
    $securityXml = New-WuSecurityHeader -IncludeTimestamp
    return (New-WuSoapEnvelope -Action 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates' -Endpoint 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx' -BodyXml $bodyXml -SecurityXml $securityXml)
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

    $deviceAttributes = Convert-ToXmlEscaped -Text (New-DeviceAttributesPayload -Context $Context -FlightConfig @{
            CurrentBranch = $script:Config.CurrentBranch
            FlightRing    = $script:Config.FlightRing
            FlightBranch  = $script:Config.FlightBranch
        })
    $bodyXml = @"
<GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
  <updateIDs><UpdateIdentity><UpdateID>$UpdateId</UpdateID><RevisionNumber>$RevisionNumber</RevisionNumber></UpdateIdentity></updateIDs>
  <infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType></infoTypes>
  <DeviceAttributes>$deviceAttributes</DeviceAttributes>
</GetExtendedUpdateInfo2>
"@
    $securityXml = New-WuSecurityHeader -CookieData $EncryptedCookieData -IncludeTimestamp
    return (New-WuSoapEnvelope -Action 'http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2' -Endpoint 'https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured' -BodyXml $bodyXml -SecurityXml $securityXml)
}

function Invoke-WuSoapRequest {
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
        $response = Invoke-WebRequest -Uri $Uri -Method Post -Body $Payload -Headers $script:Config.SoapHeaders -UseBasicParsing -TimeoutSec $script:Config.RequestTimeoutSec -ErrorAction Stop
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
        Write-Status -Level Warn -Message "无法通过 Shell.Application 读取下载目录，使用默认路径。"
    }
    return (Join-Path $env:USERPROFILE "Downloads")
}

function Initialize-ToolRuntime {
    [CmdletBinding()]
    param()

    $userDownloadsFolder = Get-DefaultDownloadsPath
    $script:Config.WorkingDir = Join-Path -Path $userDownloadsFolder -ChildPath "MSStore Install"
    $script:Config.LogDirectory = Join-Path -Path $script:Config.WorkingDir -ChildPath "Logs"

    New-DirectoryIfMissing -Path $script:Config.WorkingDir
    if ($script:Config.EnableDebug) { New-DirectoryIfMissing -Path $script:Config.LogDirectory }
    $script:Config.ToolLogPath = Join-Path $script:Config.LogDirectory "Tool.log"
    New-DirectoryIfMissing -Path $script:Config.LogDirectory
    Write-LogEntry -Level INFO -Message "Tool started. Version=$($script:Config.ToolVersion)"
}

function Request-AuthCookie {
    [CmdletBinding()]
    param()

    Write-Section "步骤1：获取认证 Cookie"
    $cookieRequestPayload = New-CookieXmlPayload
    $cookieResponseContent = Invoke-WuSoapRequest -Uri $script:Config.SoapEndpoint -Payload $cookieRequestPayload -StepName "步骤1" -RequestLogName "01_Step1_Request.xml" -ResponseLogName "01_Step1_Response.xml"
    $cookieResponseXml = [xml]$cookieResponseContent
    $encryptedCookieData = $cookieResponseXml.Envelope.Body.GetCookieResponse.GetCookieResult.EncryptedData
    if ([string]::IsNullOrWhiteSpace($encryptedCookieData)) {
        throw "步骤1失败: 未从响应中解析到 EncryptedData。"
    }
    Write-Status -Level OK -Message "已获取 Cookie。"
    return $encryptedCookieData
}

function Request-PackageCatalog {
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
    $fileListResponseContent = Invoke-WuSoapRequest -Uri $script:Config.SoapEndpoint -Payload $fileListRequestPayload -StepName "步骤2" -ResponseLogName "02_Step2_Response.xml"

    Add-Type -AssemblyName System.Web
    $decodedContent = [System.Web.HttpUtility]::HtmlDecode($fileListResponseContent)
    $fileListResponseXml = [xml]$decodedContent

    $fileIdentityMap = @{}
    $newUpdates = @($fileListResponseXml.Envelope.Body.SyncUpdatesResponse.SyncUpdatesResult.NewUpdates.UpdateInfo)
    $allExtendedUpdates = @($fileListResponseXml.Envelope.Body.SyncUpdatesResponse.SyncUpdatesResult.ExtendedUpdateInfo.Updates.Update)

    Write-Status -Level Check -Message "正在关联更新信息"
    $downloadableUpdates = $newUpdates | Where-Object { $_.Xml.Properties.SecuredFragment }
    Write-Status -Level Info -Message "找到 $($downloadableUpdates.Count) 个可下载包（候选）"

    foreach ($update in $downloadableUpdates) {
        $lookupId = $update.ID
        $extendedInfo = $allExtendedUpdates | Where-Object { $_.ID -eq $lookupId } | Select-Object -First 1
        if (-not $extendedInfo) {
            Write-Status -Level Warn -Message "无法关联 ID $lookupId 的扩展信息，已跳过。"
            continue
        }

        $fileNode = @($extendedInfo.Xml.Files.File | Where-Object { $_.FileName -and $_.FileName -notlike "Abm_*" } | Select-Object -First 1)
        if (-not $fileNode) {
            Write-Status -Level Warn -Message "ID $lookupId 没有有效文件节点，已跳过。"
            continue
        }

        $fullIdentifier = $fileNode.GetAttribute("InstallerSpecificIdentifier")
        if ([string]::IsNullOrWhiteSpace($fullIdentifier)) {
            Write-Status -Level Warn -Message "ID $lookupId 缺少 InstallerSpecificIdentifier，已跳过。"
            continue
        }

        $identityInfo = ConvertFrom-AppxPackageIdentity -FullIdentifier $fullIdentifier
        $packageInfo = [PSCustomObject]@{
            FullName       = $fullIdentifier
            FileName       = $fileNode.FileName
            UpdateID       = [string]$update.Xml.UpdateIdentity.UpdateID
            RevisionNumber = [string]$update.Xml.UpdateIdentity.RevisionNumber
            PackageName    = $identityInfo.PackageName
            Version        = $identityInfo.Version
            Architecture   = $identityInfo.Architecture
            ResourceId     = $identityInfo.ResourceId
            PublisherId    = $identityInfo.PublisherId
            ExpectedHash   = (Get-ExpectedHashFromFileNode -FileNode $fileNode)
        }

        $fileIdentityMap[$fullIdentifier] = $packageInfo
        Write-Status -Level OK -Message "已关联: $($packageInfo.PackageName) ($($packageInfo.Architecture))"
    }

    Write-Status -Level OK -Message "关联完成，准备处理文件数: $($fileIdentityMap.Count)"
    return @($fileIdentityMap.Values)
}

#region 包管理
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
        Write-Status -Level OK -Message "找到最新 Store 包: $($latestStorePackage.FullName)"
    } else {
        Write-Status -Level Warn -Message "未找到可用的 Microsoft.WindowsStore 包。"
    }
    $packagesToProcess += $filteredDependencies
    Write-Status -Level Info -Message "依赖包数量: $($filteredDependencies.Count)"
    Write-Status -Level Info -Message "总处理数: $($packagesToProcess.Count)"
    return $packagesToProcess
}

function Request-PackageUrls {
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
        Write-Status -Level Check -Message "处理: $($package.FullName)"

        $fileUrlRequestPayload = New-FileUrlXmlPayload -EncryptedCookieData $EncryptedCookieData -UpdateId $package.UpdateID -RevisionNumber $package.RevisionNumber -Context $SystemContext
        $requestFileName = "03_Step3_Request_$($package.UpdateID).xml"
        $responseFileName = "03_Step3_Response_$($package.UpdateID).xml"
        Save-DebugArtifact -FileName $requestFileName -Content $fileUrlRequestPayload

        $fileUrlResponseContent = Invoke-WuSoapRequest -Uri "$($script:Config.SoapEndpoint)/secured" -Payload $fileUrlRequestPayload -StepName "步骤4($($package.PackageName))" -ResponseLogName $responseFileName
        $fileUrlResponseXml = [xml]$fileUrlResponseContent
        $fileLocations = @($fileUrlResponseXml.Envelope.Body.GetExtendedUpdateInfo2Response.GetExtendedUpdateInfo2Result.FileLocations.FileLocation)
        $baseFileName = [System.IO.Path]::GetFileNameWithoutExtension($package.FileName)
        $downloadUrl = ($fileLocations | Where-Object { $_.Url -like "*$baseFileName*" } | Select-Object -First 1).Url
        if (-not $downloadUrl) {
            $downloadUrl = ($fileLocations | Select-Object -First 1).Url
        }

        if (-not $downloadUrl) {
            Write-Status -Level Warn -Message "未获取到下载地址: $($package.FileName)"
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

    if ($script:Config.OptNoDownload) {
        Write-Status -Level Skip -Message "已启用 -noDownload，仅解析，不下载。"
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
            Write-Status -Level Warn -Message "可疑文件名已净化: $newFileName -> $safeFileName"
        }
        $filePath = Join-Path $script:Config.WorkingDir $safeFileName
        Write-Status -Level Info -Message "下载地址: $($item.DownloadUrl)"
        Write-Status -Level Info -Message "保存到: $filePath"

        try {
            Start-FileDownload -Url $item.DownloadUrl -OutFile $filePath -Mode $DownloadMode
            Assert-FileIntegrity -FilePath $filePath -ExpectedHash $item.ExpectedHash
            Write-Status -Level OK -Message "下载完成: $safeFileName"
            $downloadedFiles += (Get-Item -LiteralPath $filePath)
        } catch {
            Write-Status -Level Warn -Message "下载失败: $($_.Exception.Message)"
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

    if ($script:Config.OptNoInstall) {
        Write-Status -Level Skip -Message "已启用 -noInstall，跳过安装步骤。"
        return
    }

    Write-Section "步骤6：安装包"
    $allDownloadedFiles = @($DownloadedFiles)
    if ($allDownloadedFiles.Count -eq 0) {
        $allDownloadedFiles = @(Get-ChildItem -Path $script:Config.WorkingDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.appx', '.msix', '.appxbundle', '.msixbundle' }) # 下载目录可能为空
    }

    $storePackageFile = $allDownloadedFiles | Where-Object { $_.Name -like 'Microsoft.WindowsStore*' } | Sort-Object Name -Descending | Select-Object -First 1
    $dependencyFiles = $allDownloadedFiles | Where-Object { $_.Name -notlike 'Microsoft.WindowsStore*' }
    if (-not $dependencyFiles -and -not $storePackageFile) {
        Write-Status -Level Warn -Message "未找到可安装的包。"
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
            Write-Status -Level OK -Message "Microsoft Store 安装/更新完成。"
        } catch {
            if ($_.Exception.Message -match '0x80073D06|更高版本') {
                Write-Status -Level Info -Message "已安装更高版本 Microsoft Store，跳过覆盖安装。"
            } else {
                Write-Status -Level Error -Message "Microsoft Store 安装失败: $($_.Exception.Message)"
                Write-AdviceFromError -Message $_.Exception.Message
                throw
            }
        }
    } else {
        Write-Status -Level Warn -Message "未找到 Microsoft Store 主包，仅尝试安装依赖。"
        foreach ($pkg in ($dependencyFiles | Sort-Object Name)) {
            try {
                Add-AppxPackage -Path $pkg.FullName -ErrorAction Stop
                Write-Status -Level OK -Message "依赖安装成功: $($pkg.Name)"
            } catch {
                Write-Status -Level Warn -Message "依赖安装失败: $($pkg.Name) - $($_.Exception.Message)"
                Write-AdviceFromError -Message $_.Exception.Message
            }
        }
    }
}
#endregion

#region 主流程
function Install-Store {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('1','2','3')]
        [string]$DownloadMode
    )

    if (-not $script:Config.OptNoInstall) { Test-Admin }
    $systemContext = Get-SystemContext

    Write-Section "前置检查：商店存在性 / 服务 / 残留 / 代理"
    Test-StoreInstalled | Out-Null
    Test-Proxy | Out-Null
    $healthResult = Test-StoreHealth
    if ($healthResult.MissingRegistryPaths.Count -gt 0) {
        Repair-StoreRegistry -MissingPaths $healthResult.MissingRegistryPaths
    }
    $residueResult = Test-StoreResidue
    if (-not $healthResult.AllServicesOk) {
        Write-Status -Level Warn -Message "部分服务未正常运行，安装可能受影响。"
    }
    if ($residueResult.HasResidue -and -not $residueResult.Cleaned) {
        Write-Status -Level Warn -Message "检测到残留且未清理，可能影响后续安装。"
    }

    $encryptedCookieData = Request-AuthCookie
    $allPackages = Request-PackageCatalog -EncryptedCookieData $encryptedCookieData -SystemContext $systemContext
    $targetPackages = Select-TargetPackages -AllPackages $allPackages -SystemContext $systemContext
    $downloadItems = Request-PackageUrls -Packages $targetPackages -EncryptedCookieData $encryptedCookieData -SystemContext $systemContext
    if ($script:Config.OptNoDownload) {
        # Save-PackageFiles 内部会跳过下载，这里直接返回不进入安装阶段
        Save-PackageFiles -DownloadItems $downloadItems -DownloadMode $DownloadMode | Out-Null
        return
    }
    $downloadedFiles = Save-PackageFiles -DownloadItems $downloadItems -DownloadMode $DownloadMode
    Install-PackageFiles -DownloadedFiles $downloadedFiles

    $cleanup = Read-Host "是否删除下载文件夹? (Y/N, 推荐 Y)"
    if ($cleanup -match '^[Yy]$') {
        try {
            Remove-Item -Path $script:Config.WorkingDir -Recurse -Force -ErrorAction Stop
            Write-Status -Level OK -Message ("已删除下载文件夹: {0}" -f $script:Config.WorkingDir)
        } catch {
            Write-Status -Level Warn -Message ("删除失败: {0}" -f $_.Exception.Message)
            Write-AdviceFromError -Message $_.Exception.Message
        }
    }
}

#endregion
#endregion

#region 修复维护
function Reset-Store {
    [CmdletBinding()]
    param()

    Write-Section "微软商店修复模式"

    try {
        Write-Status -Level Check -Message "正在重置商店缓存 (WSReset)..."
        Start-Process -FilePath "wsreset.exe" -Wait -ErrorAction Stop
        Write-Status -Level OK -Message "WSReset 执行完成。"
    } catch {
        Write-Status -Level Error -Message "WSReset 执行失败: $($_.Exception.Message)"
        Write-AdviceFromError -Message $_.Exception.Message
    }

    Test-Proxy | Out-Null
    $healthResult = Test-StoreHealth
    if (-not $healthResult.AllServicesOk) {
        Write-Status -Level Warn -Message "部分服务未正常运行，修复效果可能受影响。"
    }

    try {
        Write-Status -Level Check -Message "正在重新注册商店应用..."
        Get-Process -Name WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue # 进程可能不存在或已退出
        $storePackages = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue # 商店可能已损坏/缺失
        if (-not $storePackages) {
            Write-Status -Level Warn -Message "未找到已安装商店包，无法重新注册。"
        } else {
            foreach ($storePackage in $storePackages) {
                $manifestPath = Join-Path $storePackage.InstallLocation "AppXManifest.xml"
                if (-not (Test-Path $manifestPath)) {
                    Write-Status -Level Warn -Message "跳过无效清单路径: $manifestPath"
                    continue
                }
                Add-AppxPackage -DisableDevelopmentMode -Register $manifestPath -ErrorAction Stop
                Write-Status -Level OK -Message "已重新注册: $($storePackage.PackageFullName)"
            }
        }
    } catch {
        Write-Status -Level Error -Message "重新注册失败: $($_.Exception.Message)"
        Write-AdviceFromError -Message $_.Exception.Message
    }

    Set-StoreRegion
    Write-Status -Level OK -Message "修复操作已执行，请尝试打开商店。"
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
    $files = Get-ChildItem -Path $Directory -File -Filter $Filter -ErrorAction SilentlyContinue # 目录可能不存在或为空
    foreach ($logFile in $files) {
        try {
            Remove-Item -Path $logFile.FullName -Force -ErrorAction Stop
            Write-Status -Level OK -Message "已删除${Label}: $($logFile.FullName)"
            $deleted = $true
        } catch {
            Write-Status -Level Warn -Message "删除失败: $($logFile.FullName) - $($_.Exception.Message)"
        }
    }
    return $deleted
}

function Clear-Logs {
    [CmdletBinding()]
    param()

    Write-Status -Level Check -Message "正在清理日志..."
    Write-Host "清理选项："
    Write-Host "[1] 仅清理导出的日志文件 (Logs / ERROR_*.txt / AppX_*.txt)"
    Write-Host "[2] 仅清理系统 AppX 部署事件日志"
    Write-Host "[3] 两者都清理"
    Write-Host "[4] 返回"
    $sel = Read-Host "请选择 (1-4)"

    if ($sel -eq '4') { return }
    $deletedAny = $false

    if ($sel -in @('1','3')) {
        $logDirs = @($script:Config.LogDirectory, (Join-Path $script:Config.WorkingDir "Logs"), (Join-Path $PSScriptRoot "Logs")) | Select-Object -Unique
        foreach ($path in $logDirs) {
            if (Test-Path -Path $path) {
                try {
                    Remove-Item -Path $path -Recurse -Force -ErrorAction Stop
                    Write-Status -Level OK -Message "已删除日志目录: $path"
                    $deletedAny = $true
                } catch {
                    Write-Status -Level Warn -Message "删除失败: $path - $($_.Exception.Message)"
                }
            }
        }

        foreach ($root in @($script:Config.WorkingDir, $PSScriptRoot) | Select-Object -Unique) {
            if (-not (Test-Path -Path $root)) { continue }
            if (Remove-FilesByPattern -Directory $root -Filter "ERROR_*.txt" -Label "错误日志") { $deletedAny = $true }
            if (Remove-FilesByPattern -Directory $root -Filter "AppX_*.txt" -Label "AppX 日志") { $deletedAny = $true }
        }
    }

    if ($sel -in @('2','3')) {
        Write-Status -Level Check -Message "正在清理系统 AppX 部署事件日志..."
        foreach ($channel in @("Microsoft-Windows-AppXDeploymentServer/Operational","Microsoft-Windows-AppXDeploymentServer/Admin")) {
            try {
                wevtutil.exe cl "$channel" | Out-Null
                Write-Status -Level OK -Message "已清理事件日志: $channel"
                $deletedAny = $true
            } catch {
                Write-Status -Level Warn -Message "清理失败: $channel - $($_.Exception.Message)"
            }
        }
    }

    if (-not $deletedAny) {
        Write-Status -Level Info -Message "未发现需要清理的日志或清理未执行。"
    }
}

function Get-LatestAppxActivityId {
    [CmdletBinding()]
    param()

    foreach ($channel in @("Microsoft-Windows-AppXDeploymentServer/Operational","Microsoft-Windows-AppXDeploymentServer/Admin")) {
        $events = Get-WinEvent -LogName $channel -MaxEvents 200 -ErrorAction SilentlyContinue # 日志通道可能不存在或权限不足
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
        New-DirectoryIfMissing -Path $script:Config.LogDirectory
        $activityId = Get-LatestAppxActivityId
        if (-not $activityId) {
            Write-Status -Level Warn -Message "未找到可用的 ActivityID（系统事件日志中没有可解析记录）。"
            return
        }

        $outFile = Join-Path $script:Config.LogDirectory ("AppX_{0}.txt" -f $activityId)
        Get-AppPackageLog -ActivityID $activityId | Out-File -Encoding UTF8 -FilePath $outFile
        Write-Status -Level OK -Message "已自动导出最新 ActivityID 的 AppX 日志: $activityId"
        Write-Status -Level OK -Message "AppX 部署日志已保存到: $outFile"
    } catch {
        Write-Status -Level Error -Message "无法导出 AppX 部署日志: $($_.Exception.Message)"
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
        Write-Status -Level Error -Message "$ActionName 失败: $msg"
        Write-LogEntry -Level ERROR -Message "Action failed: $ActionName | $msg"
        if ($_.ScriptStackTrace) { Write-Status -Level Info -Message "堆栈: $($_.ScriptStackTrace)" }
        Write-AdviceFromError -Message $msg

        New-DirectoryIfMissing -Path $script:Config.LogDirectory
        $errPath = Join-Path $script:Config.LogDirectory ("ERROR_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".txt")
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
        Write-Status -Level Warn -Message "错误日志已保存到: $errPath"
        Write-Status -Level Info -Message "返回主菜单..."
    }
}
#endregion

function Wait-ExitConfirmation {
    [CmdletBinding()]
    param(
        [string]$Prompt = "按 Enter 键退出..."
    )

    try {
        [void](Read-Host $Prompt)
        return
    } catch {
        # 部分双击/非交互场景 Read-Host 会失败，回退为短暂停留，避免窗口瞬间关闭
        try {
            Write-Host "[提示] 当前会话不可交互，10 秒后自动退出..." -ForegroundColor Yellow
            Start-Sleep -Seconds 10
        } catch {
            # 最终兜底：不再抛出二次异常
        }
    }
}

function Write-FatalError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $errorMessage = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $stack = [string]$ErrorRecord.ScriptStackTrace

    Write-Host ""
    Write-Host "==============================" -ForegroundColor DarkGray
    Write-Host "[致命错误] 脚本发生未处理异常，已中止。" -ForegroundColor Red
    Write-Host $errorMessage -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($stack)) {
        Write-Host ""
        Write-Host "堆栈信息：" -ForegroundColor Yellow
        Write-Host $stack -ForegroundColor DarkYellow
    }
    Write-Host "==============================" -ForegroundColor DarkGray

    Write-AdviceFromError -Message $errorMessage

    try {
        if (-not [string]::IsNullOrWhiteSpace([string]$script:Config.LogDirectory)) {
            New-DirectoryIfMissing -Path $script:Config.LogDirectory
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$script:Config.ToolLogPath)) {
            Write-LogEntry -Level ERROR -Message "Fatal: $errorMessage"
            if (-not [string]::IsNullOrWhiteSpace($stack)) {
                Write-LogEntry -Level ERROR -Message "Fatal stack: $stack"
            }
        } else {
            $fallbackDir = Join-Path $env:TEMP "MSStoreFix"
            New-DirectoryIfMissing -Path $fallbackDir
            $fallbackPath = Join-Path $fallbackDir "Tool_Fatal.log"
            Add-Content -Path $fallbackPath -Encoding UTF8 -Value ("[{0:yyyy-MM-dd HH:mm:ss}] Fatal: {1}" -f (Get-Date), $errorMessage)
            if (-not [string]::IsNullOrWhiteSpace($stack)) {
                Add-Content -Path $fallbackPath -Encoding UTF8 -Value ("Stack: {0}" -f $stack)
            }
            Write-Host ("[提示] 故障日志已写入: {0}" -f $fallbackPath) -ForegroundColor Yellow
        }
    } catch {
        Write-Host ("[警告] 写入故障日志失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
    }
}

function Start-MainMenu {
    [CmdletBinding()]
    param()

    Write-Section "微软商店修复工具 (PS1) v$($script:Config.ToolVersion)"
    Get-OSInfo | Out-Null
    Test-ToolUpdate
    Write-Status -Level Info -Message ("工作目录: {0}" -f $script:Config.WorkingDir)
    Write-Status -Level Info -Message ("日志目录: {0}" -f $script:Config.LogDirectory)
    Write-Status -Level Info -Message ("高级选项状态: -noDownload={0}, -noInstall={1}" -f $script:Config.OptNoDownload, $script:Config.OptNoInstall)

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
            '3' { Invoke-Safe -ActionName "系统服务修复检测" -Action { Test-StoreHealth | Out-Null } }
            '4' { Invoke-Safe -ActionName "商店存在性检测" -Action { Test-StoreInstalled | Out-Null } }
            '5' { Invoke-Safe -ActionName "清理日志" -Action { Clear-Logs } }
            '6' { Invoke-Safe -ActionName "导出 AppX 日志" -Action { Export-AppxLog } }
            '7' { Show-AdvancedOptions }
            '8' { break mainLoop }
            default { Write-Status -Level Warn -Message "无效选择" }
        }
    }
}

function Start-Tool {
    [CmdletBinding()]
    param()

    try {
        Initialize-ToolRuntime
        Start-MainMenu
    } catch {
        Write-FatalError -ErrorRecord $_
        Wait-ExitConfirmation
    }
}

function Invoke-ToolEntryPoint {
    [CmdletBinding()]
    param()

    try {
        Start-Tool
    } catch {
        Write-FatalError -ErrorRecord $_
        Wait-ExitConfirmation
    }
}

trap {
    $errorRecord = $_
    try {
        if ($errorRecord -isnot [System.Management.Automation.ErrorRecord]) {
            $errorRecord = [System.Management.Automation.ErrorRecord]::new(
                [System.Exception]::new([string]$errorRecord),
                'ScriptTerminatingError',
                [System.Management.Automation.ErrorCategory]::NotSpecified,
                $null
            )
        }
        Write-FatalError -ErrorRecord $errorRecord
    } catch {
        Write-Host "[致命错误] 脚本发生未处理异常，且错误报告失败: $($_.Exception.Message)" -ForegroundColor Red
    }

    Wait-ExitConfirmation
    break
}

Invoke-ToolEntryPoint



