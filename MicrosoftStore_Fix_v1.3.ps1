#requires -version 5.1
<#!
Microsoft Store Fix Tool (PS1) v1.3
- Based on ThioJoe's Windows-Sandbox-Tools script (Install-Microsoft-Store.ps1)
- Adapted for normal Windows use (no Sandbox check)
#>

param(
    [switch]$debugSaveFiles,
    [switch]$noInstall,
    [switch]$noDownload
)

$ErrorActionPreference = 'Stop'
$optNoInstall = [bool]$noInstall
$optNoDownload = [bool]$noDownload

function Write-Section($text) {
    Write-Host ""
    Write-Host "==============================" -ForegroundColor DarkGray
    Write-Host $text -ForegroundColor Cyan
    Write-Host "==============================" -ForegroundColor DarkGray
}

function Test-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "[!] 请以管理员身份运行此脚本。" -ForegroundColor Yellow
        Read-Host "按 Enter 退出"
        exit 1
    }
}

function Get-OSInfo {
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
}

function Test-Proxy {
    $proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyEnable = (Get-ItemProperty $proxyKey -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $proxyServer = (Get-ItemProperty $proxyKey -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer

    if ($proxyEnable -eq 1) {
        Write-Host "[警告] 系统代理已开启: $proxyServer" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] 未检测到系统代理。" -ForegroundColor Green
    }
}

function Test-StoreHealth {
    Write-Host "[检测] 服务状态..."
    foreach ($svc in @('wuauserv','bits','AppXSvc','ClipSVC','CryptSvc','RpcEptMapper','DcomLaunch','RpcSs','MpsSvc','BFE')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $s) { Write-Host "[警告] 未找到服务 $svc" -ForegroundColor Yellow; continue }
        if ($s.Status -ne 'Running') {
            try { Start-Service -Name $svc -ErrorAction Stop; Write-Host "[修复] 启动服务 $svc 成功" -ForegroundColor Green } catch { Write-Host "[!] 启动服务 $svc 失败: $($_.Exception.Message)" -ForegroundColor Yellow }
        } else {
            Write-Host "[OK] $svc 正常运行。" -ForegroundColor Green
        }
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
    if (Test-Path $cache) { Write-Host "[OK] Store 缓存目录存在。" -ForegroundColor Green } else { Write-Host "[警告] Store 缓存目录不存在。" -ForegroundColor Yellow }
    
    Write-Host "[检测] 商店相关注册表项..."
    $regPaths = @(
        'HKLM:\\SOFTWARE\\Microsoft\\Windows\\WS\\License Validation',
        'HKLM:\\SOFTWARE\\Microsoft\\Windows\\WS\\WSRefreshBannedAppsListTask',
        'HKLM:\\SOFTWARE\\Microsoft\\Windows\\PushToInstall\\Registration',
        'HKLM:\\SOFTWARE\\Microsoft\\Windows\\PushToInstall\\LoginCheck'
    )
    foreach ($rp in $regPaths) {
        if (Test-Path $rp) {
            Write-Host ("[OK] {0}" -f $rp) -ForegroundColor Green
        } else {
            Write-Host ("[警告] 缺少注册表项: {0}" -f $rp) -ForegroundColor Yellow
        }
    }

    Write-Host "[检测] 商店相关服务..."
    $svcList = @('InstallService','StorSvc','TokenBroker')
    foreach ($svc in $svcList) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($null -eq $s) { Write-Host "[警告] 未找到服务 $svc" -ForegroundColor Yellow; continue }
        if ($s.Status -ne 'Running') {
            try { Start-Service -Name $svc -ErrorAction Stop; Write-Host "[修复] 启动服务 $svc 成功" -ForegroundColor Green } catch { Write-Host "[!] 启动服务 $svc 失败: $($_.Exception.Message)" -ForegroundColor Yellow }
        } else {
            Write-Host "[OK] $svc 正常运行。" -ForegroundColor Green
        }
    }

    $userSvcPatterns = @('UnistoreSvc_*','UserDataSvc_*')
    foreach ($pat in $userSvcPatterns) {
        $list = Get-Service -Name $pat -ErrorAction SilentlyContinue
        if ($null -eq $list -or $list.Count -eq 0) {
            Write-Host ("[警告] 未找到服务 {0}" -f $pat) -ForegroundColor Yellow
            continue
        }
        foreach ($s in $list) {
            if ($s.Status -ne 'Running') {
                try { Start-Service -Name $s.Name -ErrorAction Stop; Write-Host ("[修复] 启动服务 {0} 成功" -f $s.Name) -ForegroundColor Green } catch { Write-Host ("[!] 启动服务 {0} 失败: {1}" -f $s.Name, $($_.Exception.Message)) -ForegroundColor Yellow }
            } else {
                Write-Host ("[OK] {0} 正常运行。" -f $s.Name) -ForegroundColor Green
            }
        }
    }
}

function Test-StoreResidue {
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
            }
        }
    }

    if (-not $hasResidue) {
        Write-Host "[OK] 未发现可疑商店残留。" -ForegroundColor Green
    }
}

function Test-StoreInstalled {
    $pkg = Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers -ErrorAction SilentlyContinue
    if ($pkg) {
        $ver = ($pkg | Sort-Object Version -Descending | Select-Object -First 1).Version
        Write-Host ("[OK] 已检测到 Microsoft.WindowsStore，版本: {0}" -f $ver) -ForegroundColor Green
    } else {
        Write-Host "[警告] 未检测到 Microsoft.WindowsStore。" -ForegroundColor Yellow
    }
}

function Request-RegionFix {
    Write-Host "[提示] 商店初始化失败有时与地区设置有关。" -ForegroundColor Yellow
    Write-Host "当前设置将不会自动修改区域。" -ForegroundColor Yellow
    Write-Host "可选区域: [1] US  [2] CN  [3] HK  [4] TW  [5] JP  [0] 不修改"
    $choice = Read-Host "请选择 (0-5)"
    if ($choice -eq '0' -or [string]::IsNullOrWhiteSpace($choice)) { return }

    $geoMap = @{
        '1' = @{ Nation = '244'; Name = 'US'; Label = 'US' }
        '2' = @{ Nation = '45';  Name = 'CN'; Label = 'CN' }
        '3' = @{ Nation = '104'; Name = 'HK'; Label = 'HK' }
        '4' = @{ Nation = '237'; Name = 'TW'; Label = 'TW' }
        '5' = @{ Nation = '122'; Name = 'JP'; Label = 'JP' }
    }

    if (-not $geoMap.ContainsKey($choice)) {
        Write-Host "[提示] 无效选择，未修改区域。" -ForegroundColor Yellow
        return
    }

    try {
        $geoKeyPath = "HKCU:\Control Panel\International\Geo"
        if (-not (Test-Path $geoKeyPath)) { New-Item -Path $geoKeyPath -Force | Out-Null }
        Set-ItemProperty -Path $geoKeyPath -Name "Nation" -Value $geoMap[$choice].Nation
        Set-ItemProperty -Path $geoKeyPath -Name "Name" -Value $geoMap[$choice].Name
        Write-Host ("[OK] 已修改区域为 {0}。" -f $geoMap[$choice].Label) -ForegroundColor Green
    } catch {
        Write-Host "[错误] 区域修复失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Get-DownloadMode {
    Write-Host ""
    Write-Host "下载加速模式："
    Write-Host "[1] 默认（不更改，允许系统代理/加速器）"
    Write-Host "[2] 使用 BITS 下载"
    Write-Host "[3] 解析最优 CDN 节点并强制指向 IP（可能因 HTTPS 证书失败）"
    $mode = Read-Host "请选择 (1-3)"
    if ($mode -notin @('1','2','3')) { $mode = '1' }
    return $mode
}

function Show-AdvancedOptions {
    Write-Host ""
    Write-Host "高级选项（交互式开关）"
    Write-Host ("[1] 仅解析不下载 (-noDownload): {0}" -f $(if ($optNoDownload) { '开启' } else { '关闭' }))
    Write-Host ("[2] 仅下载不安装 (-noInstall): {0}" -f $(if ($optNoInstall) { '开启' } else { '关闭' }))
    Write-Host "[3] 返回主菜单"
    $sel = Read-Host "请选择 (1-3)"
    switch ($sel) {
        '1' { $optNoDownload = -not $optNoDownload }
        '2' { $optNoInstall = -not $optNoInstall }
        default { }
    }
}

function Resolve-BestIp {
    param([string]$HostName)
    try {
        $ips = Resolve-DnsName -Name $HostName -Type A -ErrorAction Stop | Select-Object -ExpandProperty IPAddress
    } catch {
        return $null
    }
    $best = $null
    $bestMs = [int]::MaxValue
    foreach ($ip in $ips) {
        $r = Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue
        if ($r) {
            $t = (Test-Connection -ComputerName $ip -Count 1 -ErrorAction SilentlyContinue | Select-Object -First 1).ResponseTime
            if ($t -lt $bestMs) { $bestMs = $t; $best = $ip }
        }
    }
    return $best
}

function Start-FileDownload {
    param(
        [string]$Url,
        [string]$OutFile,
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
                Write-Host "  -> 最优 IP: $bestIp (Host: $targetHost)" -ForegroundColor Yellow
                $handler = New-Object System.Net.Http.HttpClientHandler
                $handler.ServerCertificateCustomValidationCallback = { $true }
                $client = New-Object System.Net.Http.HttpClient($handler)
                $req = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $Url)
                $req.Headers.Host = $targetHost
                $req.RequestUri = [System.Uri]::new(($Url -replace [regex]::Escape($targetHost), $bestIp))
                $response = $client.SendAsync($req).Result
                if (-not $response.IsSuccessStatusCode) { throw "HTTP $($response.StatusCode)" }
                $bytes = $response.Content.ReadAsByteArrayAsync().Result
                [System.IO.File]::WriteAllBytes($OutFile, $bytes)
                $client.Dispose()
                return
            }
        } catch {
            Write-Host "  -> 强制 IP 下载失败，回退默认下载。" -ForegroundColor Yellow
        }
    }

    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

# --- Templates from ThioJoe script ---
$cookieXmlTemplate = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
    <s:Header>
        <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetCookie</a:Action>
        <a:MessageID>urn:uuid:$(New-Guid)</a:MessageID>
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

$fileListXmlTemplate = @"
<s:Envelope xmlns:a="http://www.w3.org/2005/08/addressing" xmlns:s="http://www.w3.org/2003/05/soap-envelope">
    <s:Header>
        <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/SyncUpdates</a:Action>
        <a:MessageID>urn:uuid:$(New-Guid)</a:MessageID>
        <a:To s:mustUnderstand="1">https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx</a:To>
        <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
            <Timestamp xmlns="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
                <Created>$((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))</Created>
                <Expires>$((Get-Date).AddMinutes(5).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))</Expires>
            </Timestamp>
            <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
                <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user/></TicketType>
            </wuws:WindowsUpdateTicketsToken>
        </o:Security>
    </s:Header>
    <s:Body>
        <SyncUpdates xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
            <cookie>
                <Expiration>$((Get-Date).AddYears(10).ToUniversalTime().ToString('u').Replace(' ','T'))</Expiration>
                <EncryptedData>{0}</EncryptedData>
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
                    <CategoryIdentifier><Id>{1}</Id></CategoryIdentifier>
                </FilterAppCategoryIds>
                <TreatAppCategoryIdsAsInstalled>true</TreatAppCategoryIdsAsInstalled>
                <AlsoPerformRegularSync>false</AlsoPerformRegularSync>
                <ComputerSpec/>
                <ExtendedUpdateInfoParameters>
                    <XmlUpdateFragmentTypes><XmlUpdateFragmentType>Extended</XmlUpdateFragmentType></XmlUpdateFragmentTypes>
                    <Locales><string>en-US</string><string>en</string></Locales>
                </ExtendedUpdateInfoParameters>
                <ClientPreferredLanguages><string>en-US</string></ClientPreferredLanguages>
                <ProductsParameters>
                    <SyncCurrentVersionOnly>false</SyncCurrentVersionOnly>
                    <DeviceAttributes>E:BranchReadinessLevel=CB&amp;CurrentBranch={2}&amp;OEMModel=Virtual%20Machine&amp;FlightRing={3}&amp;AttrDataVer=321&amp;InstallLanguage=en-US&amp;OSUILocale=en-US&amp;InstallationType=Client&amp;FlightingBranchName={4}&amp;OSSkuId=48&amp;App=WU_STORE&amp;ProcessorManufacturer=GenuineIntel&amp;OEMName_Uncleaned=Microsoft%20Corporation&amp;AppVer=1407.2503.28012.0&amp;OSArchitecture=AMD64&amp;IsFlightingEnabled=1&amp;TelemetryLevel=1&amp;DefaultUserRegion=39070&amp;WuClientVer=1310.2503.26012.0&amp;OSVersion=10.0.26100.3915&amp;DeviceFamily=Windows.Desktop</DeviceAttributes>
                    <CallerAttributes>Interactive=1;IsSeeker=1;</CallerAttributes>
                    <Products/>
                </ProductsParameters>
            </parameters>
        </SyncUpdates>
    </s:Body>
</s:Envelope>
"@

$fileUrlXmlTemplate = @"
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">
    <s:Header>
        <a:Action s:mustUnderstand="1">http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService/GetExtendedUpdateInfo2</a:Action>
        <a:MessageID>urn:uuid:$(New-Guid)</a:MessageID>
        <a:To s:mustUnderstand="1">https://fe3cr.delivery.mp.microsoft.com/ClientWebService/client.asmx/secured</a:To>
        <o:Security s:mustUnderstand="1" xmlns:o="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd">
            <u:Timestamp u:Id="_0" xmlns:u="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">
                <u:Created>$((Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))</u:Created>
                <u:Expires>$((Get-Date).AddMinutes(5).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))</u:Expires>
            </u:Timestamp>
            <wuws:WindowsUpdateTicketsToken wsu:id="ClientMSA" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd" xmlns:wuws="http://schemas.microsoft.com/msus/2014/10/WindowsUpdateAuthorization">
                <TicketType Name="MSA" Version="1.0" Policy="MBI_SSL"><user>{0}</user></TicketType>
            </wuws:WindowsUpdateTicketsToken>
        </o:Security>
    </s:Header>
    <s:Body>
        <GetExtendedUpdateInfo2 xmlns="http://www.microsoft.com/SoftwareDistribution/Server/ClientWebService">
            <updateIDs><UpdateIdentity><UpdateID>{1}</UpdateID><RevisionNumber>{2}</RevisionNumber></UpdateIdentity></updateIDs>
            <infoTypes><XmlUpdateFragmentType>FileUrl</XmlUpdateFragmentType></infoTypes>
            <DeviceAttributes>E:BranchReadinessLevel=CB&amp;CurrentBranch={3}&amp;OEMModel=Virtual%20Machine&amp;FlightRing={4}&amp;AttrDataVer=321&amp;InstallLanguage=en-US&amp;OSUILocale=en-US&amp;InstallationType=Client&amp;FlightingBranchName={5}&amp;OSSkuId=48&amp;App=WU_STORE&amp;ProcessorManufacturer=GenuineIntel&amp;OEMName_Uncleaned=Microsoft%20Corporation&amp;AppVer=1407.2503.28012.0&amp;OSArchitecture=AMD64&amp;IsFlightingEnabled=1&amp;TelemetryLevel=1&amp;DefaultUserRegion=39070&amp;WuClientVer=1310.2503.26012.0&amp;OSVersion=10.0.26100.3915&amp;DeviceFamily=Windows.Desktop</DeviceAttributes>
        </GetExtendedUpdateInfo2>
    </s:Body>
</s:Envelope>
"@

# --- Script Execution ---
$headers = @{ "Content-Type" = "application/soap+xml; charset=utf-8" }
$baseUri = "https://fe3.delivery.mp.microsoft.com/ClientWebService/client.asmx"
$userDownloadsFolder = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path
$workingDir = Join-Path -Path $userDownloadsFolder -ChildPath "MSStore Install"
$LogDirectory = Join-Path -Path $workingDir -ChildPath "Logs"

if (-not (Test-Path -Path $workingDir)) { New-Item -Path $workingDir -ItemType Directory -Force | Out-Null }
if ($debugSaveFiles -and -not (Test-Path -Path $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }

$storeCategoryId = "64293252-5926-453c-9494-2d4021f1c78d"
$flightRing = "Retail"
$flightingBranchName = ""
$currentBranch = "ge_release"

function Install-Store {
    param([string]$DownloadMode)

    Write-Section "前置检查：商店存在性 / 服务 / 残留"
    Test-StoreInstalled
    Test-StoreHealth
    Test-StoreResidue

    Write-Section "步骤1：获取认证 Cookie"
    $cookieRequestPayload = $cookieXmlTemplate
    if ($debugSaveFiles) { $cookieRequestPayload | Set-Content -Path (Join-Path $LogDirectory "01_Step1_Request.xml") }

    $cookieResponse = Invoke-WebRequest -Uri $baseUri -Method Post -Body $cookieRequestPayload -Headers $headers -UseBasicParsing
    if ($debugSaveFiles) { $cookieResponse.Content | Set-Content -Path (Join-Path $LogDirectory "01_Step1_Response.xml") }

    $cookieResponseXml = [xml]$cookieResponse.Content
    $encryptedCookieData = $cookieResponseXml.Envelope.Body.GetCookieResponse.GetCookieResult.EncryptedData
    Write-Host "成功：已获取 Cookie。" -ForegroundColor Green

    Write-Section "步骤2：获取文件列表"
    $fileListRequestPayload = $fileListXmlTemplate -f $encryptedCookieData, $storeCategoryId, $currentBranch, $flightRing, $flightingBranchName
    if ($debugSaveFiles) { [System.IO.File]::WriteAllText((Join-Path $LogDirectory "02_Step2_Request.xml"), $fileListRequestPayload, [System.Text.UTF8Encoding]::new($false)) }

    $fileListResponse = Invoke-WebRequest -Uri $baseUri -Method Post -Body $fileListRequestPayload -Headers $headers -UseBasicParsing
    if ($debugSaveFiles) { $fileListResponse.Content | Set-Content -Path (Join-Path $LogDirectory "02_Step2_Response.xml") }

    Add-Type -AssemblyName System.Web
    $decodedContent = [System.Web.HttpUtility]::HtmlDecode($fileListResponse.Content)
    $fileListResponseXml = [xml]$decodedContent

    $fileIdentityMap = @{}
    $newUpdates = $fileListResponseXml.Envelope.Body.SyncUpdatesResponse.SyncUpdatesResult.NewUpdates.UpdateInfo
    $allExtendedUpdates = $fileListResponseXml.Envelope.Body.SyncUpdatesResponse.SyncUpdatesResult.ExtendedUpdateInfo.Updates.Update

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

        $fileNode = $extendedInfo.Xml.Files.File | Where-Object { $_.FileName -and $_.FileName -notlike "Abm_*" } | Select-Object -First 1
        if (-not $fileNode) {
            Write-Host "[警告] ID $lookupId 没有有效文件节点，已跳过。" -ForegroundColor Yellow
            continue
        }

        $fileName = $fileNode.FileName
        $updateGuid = $update.Xml.UpdateIdentity.UpdateID
        $revNum = $update.Xml.UpdateIdentity.RevisionNumber
        $fullIdentifier = $fileNode.GetAttribute("InstallerSpecificIdentifier")

        $regex = "^(?<Name>.+?)_(?<Version>\d+\.\d+\.\d+\.\d+)_(?<Architecture>[a-zA-Z0-9]+)_(?<ResourceId>.*?)_(?<PublisherId>[a-hjkmnp-tv-z0-9]{13})$"
        $packageInfo = [PSCustomObject]@{
            FullName       = $fullIdentifier
            FileName       = $fileName
            UpdateID       = $updateGuid
            RevisionNumber = $revNum
        }

        if ($fullIdentifier -match $regex) {
            $packageInfo | Add-Member -MemberType NoteProperty -Name "PackageName" -Value $matches.Name
            $packageInfo | Add-Member -MemberType NoteProperty -Name "Version" -Value $matches.Version
            $packageInfo | Add-Member -MemberType NoteProperty -Name "Architecture" -Value $matches.Architecture
            $packageInfo | Add-Member -MemberType NoteProperty -Name "ResourceId" -Value $matches.ResourceId
            $packageInfo | Add-Member -MemberType NoteProperty -Name "PublisherId" -Value $matches.PublisherId
        } else {
            $packageInfo | Add-Member -MemberType NoteProperty -Name "PackageName" -Value "Unknown"
            $packageInfo | Add-Member -MemberType NoteProperty -Name "Architecture" -Value "unknown"
        }

        $fileIdentityMap[$fullIdentifier] = $packageInfo
        Write-Host "  -> 已关联: $($packageInfo.PackageName) ($($packageInfo.Architecture))" -ForegroundColor Green
    }

    Write-Host "--- 关联完成 ---" -ForegroundColor Magenta
    Write-Host "准备下载文件数: $($fileIdentityMap.Count)" -ForegroundColor Green

    Write-Section "步骤3：筛选适配包"
    $systemArch = switch ($env:PROCESSOR_ARCHITECTURE) {
        "AMD64" { "x64" }
        "ARM64" { "arm64" }
        "x86"   { "x86" }
        default { "unknown" }
    }
    if ($systemArch -eq "unknown") { throw "Unknown architecture: $($env:PROCESSOR_ARCHITECTURE)" }

    $latestStorePackage = $fileIdentityMap.Values | Where-Object { $_.PackageName -eq 'Microsoft.WindowsStore' } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    $filteredDependencies = $fileIdentityMap.Values | Where-Object { $_.PackageName -ne 'Microsoft.WindowsStore' -and (($_.Architecture -eq $systemArch) -or ($_.Architecture -eq 'neutral')) }

    $packagesToDownload = @()
    if ($latestStorePackage) {
        $packagesToDownload += $latestStorePackage
        Write-Host "找到最新 Store 包: $($latestStorePackage.FullName)" -ForegroundColor Green
    } else {
        Write-Host "[警告] 未找到 Microsoft.WindowsStore 包。" -ForegroundColor Yellow
    }

    $packagesToDownload += $filteredDependencies
    Write-Host "依赖包数量: $($filteredDependencies.Count)" -ForegroundColor Green
    Write-Host "总下载数: $($packagesToDownload.Count)" -ForegroundColor Cyan

    Write-Section "步骤4：获取 URL 并下载"
    $originalPref = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'

    foreach ($package in $packagesToDownload) {
        Write-Host "处理: $($package.FullName)"

        $fileUrlRequestPayload = $fileUrlXmlTemplate -f $encryptedCookieData, $package.UpdateID, $package.RevisionNumber, $currentBranch, $flightRing, $flightingBranchName
        if ($debugSaveFiles) { [System.IO.File]::WriteAllText((Join-Path $LogDirectory "03_Step3_Request_${($package.UpdateID)}.xml"), $fileUrlRequestPayload, [System.Text.UTF8Encoding]::new($false)) }

        $fileUrlResponse = Invoke-WebRequest -Uri "$baseUri/secured" -Method Post -Body $fileUrlRequestPayload -Headers $headers -UseBasicParsing
        if ($debugSaveFiles) { $fileUrlResponse.Content | Set-Content -Path (Join-Path $LogDirectory "03_Step3_Response_${($package.UpdateID)}.xml") }

        $fileUrlResponseXml = [xml]$fileUrlResponse.Content
        $fileLocations = $fileUrlResponseXml.Envelope.Body.GetExtendedUpdateInfo2Response.GetExtendedUpdateInfo2Result.FileLocations.FileLocation
        $baseFileName = [System.IO.Path]::GetFileNameWithoutExtension($package.FileName)
        $downloadUrl = ($fileLocations | Where-Object { $_.Url -like "*$baseFileName*" }).Url

        if (-not $downloadUrl) {
            Write-Host "[警告] 未获取到下载地址: $($package.FileName)" -ForegroundColor Yellow
            continue
        }

        if ($optNoDownload) {
            Write-Host "[跳过] -noDownload 已启用，跳过下载。" -ForegroundColor Yellow
            continue
        }

        $fileExtension = [System.IO.Path]::GetExtension($package.FileName)
        $newFileName = "$($package.FullName)$($fileExtension)"
        $filePath = Join-Path $workingDir $newFileName

        Write-Host "  -> 下载地址: $downloadUrl" -ForegroundColor DarkGray
        Write-Host "  -> 保存到: $filePath" -ForegroundColor DarkGray

        Start-FileDownload -Url $downloadUrl -OutFile $filePath -Mode $DownloadMode
        Write-Host "  -> 下载完成" -ForegroundColor Green
    }

    $ProgressPreference = $originalPref

    if ($optNoDownload) {
        Write-Host "[提示] 已启用 -noDownload，仅解析，不下载。" -ForegroundColor Yellow
        return
    }

    if ($optNoInstall) {
        Write-Host "[提示] 已启用 -noInstall，跳过安装步骤。" -ForegroundColor Yellow
        return
    }

    Write-Section "步骤5：安装包"
    Test-Admin

    $dependencyInstallOrder = @('Microsoft.VCLibs','Microsoft.NET.Native.Framework','Microsoft.NET.Native.Runtime','Microsoft.UI.Xaml')
    $allDownloadedFiles = Get-ChildItem -Path $workingDir -File | Where-Object { $_.Extension -in '.appx', '.msix', '.appxbundle', '.msixbundle' }
    $storePackageFile = $allDownloadedFiles | Where-Object { $_.Name -like 'Microsoft.WindowsStore*' } | Select-Object -First 1
    $dependencyFiles = $allDownloadedFiles | Where-Object { $_.Name -notlike 'Microsoft.WindowsStore*' }

    if (-not $dependencyFiles -and -not $storePackageFile) {
        Write-Host "[警告] 未找到可安装的包。" -ForegroundColor Yellow
        return
    }

    Write-Host "开始安装依赖包..."
    foreach ($baseName in $dependencyInstallOrder) {
        $packagesInGroup = $dependencyFiles | Where-Object { $_.Name -like "$baseName*" } | Sort-Object Name
        foreach ($pkg in $packagesInGroup) {
            Write-Host "  -> 安装: $($pkg.Name)"
            try { Add-AppxPackage -Path $pkg.FullName; Write-Host "     成功" -ForegroundColor Green }
            catch { Write-Host "     失败: $($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }

    if ($storePackageFile) {
        Write-Host "安装主应用包..."
        try { Add-AppxPackage -Path $storePackageFile.FullName; Write-Host "     Microsoft Store 安装/更新完成。" -ForegroundColor Green }
        catch { Write-Host "     失败: $($_.Exception.Message)" -ForegroundColor Yellow }
    } else {
        Write-Host "[警告] 未找到 Microsoft Store 主包。" -ForegroundColor Yellow
    }

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
    Write-Host "正在重置商店缓存 (WSReset)..."
    Start-Process -FilePath "wsreset.exe" -Wait
    Test-Proxy
    Test-StoreHealth
    Write-Host "正在重新注册商店应用..."
    Get-Process -Name WinStore.App -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-AppxPackage -Name Microsoft.WindowsStore -AllUsers | ForEach-Object { Add-AppxPackage -DisableDevelopmentMode -Register ($_.InstallLocation + '\AppXManifest.xml') }
    Request-RegionFix
}

function Clear-Logs {
    Write-Host "正在清理日志..." -ForegroundColor Cyan

    Write-Host "清理选项："
    Write-Host "[1] 仅清理导出的日志文件 (Logs / ERROR_*.txt / AppX_*.txt)"
    Write-Host "[2] 仅清理系统 AppX 部署事件日志"
    Write-Host "[3] 两者都清理"
    Write-Host "[4] 返回"
    $sel = Read-Host "请选择 (1-4)"

    if ($sel -eq '4') { return }

    $deletedAny = $false

    if ($sel -eq '1' -or $sel -eq '3') {
        $logPaths = @()
        if ($LogDirectory) { $logPaths += $LogDirectory }

        # 兼容旧版本日志目录（同一下载目录下）
        $legacyLogDir = Join-Path -Path $workingDir -ChildPath "Logs"
        if ($legacyLogDir -ne $LogDirectory) { $logPaths += $legacyLogDir }

        $logPaths = $logPaths | Select-Object -Unique
        Write-Host ("将检查日志目录: {0}" -f ($logPaths -join " , ")) -ForegroundColor DarkGray

        foreach ($p in $logPaths) {
            if (Test-Path -Path $p) {
                try {
                    Remove-Item -Path $p -Recurse -Force -ErrorAction Stop
                    Write-Host ("[OK] 已删除日志目录: {0}" -f $p) -ForegroundColor Green
                    $deletedAny = $true
                } catch {
                    Write-Host ("[!] 删除失败: {0} - {1}" -f $p, $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }

        # 兼容错误日志直接落在工作目录的情况
        $errFiles = Get-ChildItem -Path $workingDir -File -Filter "ERROR_*.txt" -ErrorAction SilentlyContinue
        if ($errFiles) {
            foreach ($f in $errFiles) {
                try {
                    Remove-Item -Path $f.FullName -Force -ErrorAction Stop
                    Write-Host ("[OK] 已删除错误日志: {0}" -f $f.FullName) -ForegroundColor Green
                    $deletedAny = $true
                } catch {
                    Write-Host ("[!] 删除失败: {0} - {1}" -f $f.FullName, $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }

        # 清理导出的 AppX 部署日志
        $appxLogs = Get-ChildItem -Path $workingDir -File -Filter "AppX_*.txt" -ErrorAction SilentlyContinue
        if ($appxLogs) {
            foreach ($f in $appxLogs) {
                try {
                    Remove-Item -Path $f.FullName -Force -ErrorAction Stop
                    Write-Host ("[OK] 已删除 AppX 部署日志: {0}" -f $f.FullName) -ForegroundColor Green
                    $deletedAny = $true
                } catch {
                    Write-Host ("[!] 删除失败: {0} - {1}" -f $f.FullName, $_.Exception.Message) -ForegroundColor Yellow
                }
            }
        }
    }

    if ($sel -eq '2' -or $sel -eq '3') {
        Write-Host "正在清理系统 AppX 部署事件日志..." -ForegroundColor Cyan
        $channels = @(
            "Microsoft-Windows-AppXDeploymentServer/Operational",
            "Microsoft-Windows-AppXDeploymentServer/Admin"
        )
        foreach ($ch in $channels) {
            try {
                wevtutil.exe cl "$ch" | Out-Null
                Write-Host ("[OK] 已清理事件日志: {0}" -f $ch) -ForegroundColor Green
                $deletedAny = $true
            } catch {
                Write-Host ("[!] 清理失败: {0} - {1}" -f $ch, $_.Exception.Message) -ForegroundColor Yellow
            }
        }
    }

    if (-not $deletedAny) {
        Write-Host "[提示] 未发现需要清理的日志或清理未执行。" -ForegroundColor Yellow
    }
}

function Export-AppxLog {
    try {
        if (-not (Test-Path -Path $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }

        # 自动从系统事件日志中获取最近的 ActivityID
        $evt = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-AppXDeploymentServer/Operational'
            Level   = 2
        } -MaxEvents 1 -ErrorAction SilentlyContinue

        if (-not $evt -or -not $evt.ActivityId) {
            Write-Host "[提示] 未找到可用的 ActivityID（系统事件日志为空或无错误事件）。" -ForegroundColor Yellow
            return
        }

        $activityId = $evt.ActivityId.Guid
        $outFile = Join-Path $LogDirectory ("AppX_{0}.txt" -f $activityId)
        Get-AppPackageLog -ActivityID $activityId | Out-File -Encoding UTF8 -FilePath $outFile
        Write-Host ("[OK] 已自动导出最新 ActivityID 的 AppX 日志: {0}" -f $activityId) -ForegroundColor Green
        Write-Host ("[OK] AppX 部署日志已保存到: {0}" -f $outFile) -ForegroundColor Green
    } catch {
        Write-Host ("[错误] 无法导出 AppX 部署日志: {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

function Invoke-Safe {
    param([scriptblock]$Action)
    try {
        & $Action
    } catch {
        Write-Host "[错误] $($_.Exception.Message)" -ForegroundColor Red
        $errPath = $null
        if ($debugSaveFiles) {
            if (-not (Test-Path -Path $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }
            $errPath = Join-Path $LogDirectory ("ERROR_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".txt")
            $_.Exception.ToString() | Set-Content -Path $errPath
        }
        if ($errPath) { Write-Host "错误日志已保存到: $errPath" -ForegroundColor Yellow }
        Write-Host "返回主菜单..." -ForegroundColor Yellow
    }
}

# -------- Main Menu --------
Write-Section "微软商店修复工具 (PS1) v1.3"
Get-OSInfo
Write-Host ("日志目录: {0}" -f $LogDirectory) -ForegroundColor DarkGray
Write-Host ("高级选项状态: -noDownload={0}, -noInstall={1}" -f $optNoDownload, $optNoInstall) -ForegroundColor DarkGray

while ($true) {
    Write-Host ""
    Write-Host "[1] 安装/重装微软商店 (官方源)"
    Write-Host "[2] 修复/重置已安装商店"
    Write-Host "[3] 仅修复系统服务问题"
    Write-Host "[4] 检测当前微软商店是否存在"
    Write-Host "[5] 清理日志"
    Write-Host "[6] 导出 AppX 部署日志 (ActivityID)"
    Write-Host "[7] 高级选项"
    Write-Host "[8] 退出"
    $choice = Read-Host "请选择 (1-8)"

    switch ($choice) {
        '1' {
            $mode = Get-DownloadMode
            Invoke-Safe { Install-Store -DownloadMode $mode }
        }
        '2' { Invoke-Safe { Reset-Store } }
        '3' { Invoke-Safe { Test-StoreHealth } }
        '4' { Invoke-Safe { Test-StoreInstalled } }
        '5' { Invoke-Safe { Clear-Logs } }
        '6' { Invoke-Safe { Export-AppxLog } }
        '7' { Show-AdvancedOptions }
        '8' { break }
        default { Write-Host "无效选择" -ForegroundColor Yellow }
    }
}

