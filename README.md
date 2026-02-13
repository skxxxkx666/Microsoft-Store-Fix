# Microsoft Store Fix Tool (PS1)

本项目提供一个基于官方 Windows Update 接口下载并安装 Microsoft Store 的 PowerShell 脚本，包含服务检测、残留清理、日志导出、下载模式选择等功能。  
This project provides a PowerShell script that downloads and installs Microsoft Store via official Windows Update APIs, with service checks, residue cleanup, log export, and download mode selection.

## 功能亮点 / Features
- 官方源下载（WU SOAP 接口） / Official source download (WU SOAP)
- 安装前服务检测与修复 / Pre-install service checks and fixes
- 残留目录检测与可选清理 / Residue detection and optional cleanup
- 代理检测 / Proxy detection
- 可选地区修复（US / CN / HK / TW / JP） / Optional region fix (US / CN / HK / TW / JP)
- 下载模式选择：默认 / BITS / 最优节点测速 / Download modes: default / BITS / best node probe
- 完整日志与错误导出 / Full logging and error export

## 运行要求 / Requirements
- Windows 10/11
- PowerShell 5.1+ (built-in)
- 管理员权限 / Administrator privileges

## 快速开始 / Quick Start

> ⚠️ **请勿直接双击或右键"使用 PowerShell 运行"**，否则会闪退。  
> ⚠️ **Do NOT double-click or use "Run with PowerShell"** from the right-click menu — the window will close immediately.

以 **管理员身份** 打开 PowerShell 终端，输入以下命令运行：  
Open PowerShell **as Administrator** and run:

```powershell
powershell -ExecutionPolicy Bypass -NoExit -File "C:\完整路径\MicrosoftStore_Fix_v1.3.1.ps1"
```

或者先 cd 到脚本所在目录再运行 / Or cd to the script directory first:

```powershell
cd "C:\完整路径"
Set-ExecutionPolicy Bypass -Scope Process -Force
.\MicrosoftStore_Fix_v1.3.1.ps1
```

## 参数 / Arguments
- `-debugSaveFiles` 保存请求/响应 XML 与错误日志 / Save request/response XML and error logs
- `-noDownload` 仅解析包，不下载 / Parse only, no download
- `-noInstall` 仅下载，不安装 / Download only, no install

## 日志位置 / Logs
默认目录 / Default:
`%USERPROFILE%\Downloads\MSStore Install\Logs`

## 发布校验 / Release Hash
- `MicrosoftStore_Fix_v1.3.1.ps1`  
  SHA256: `3E77AB169DF39095DE3E24D31BEBFCB755002E5A426478FD01FF489B1127F1D2`

## 免责声明 / Disclaimer
本工具会修改系统服务状态、注册表与安装 Appx 包，请在了解风险后使用。  
This tool modifies system services, registry entries, and installs Appx packages. Use at your own risk.

## 致谢与来源说明 / Acknowledgements & Source
本项目的下载与解析逻辑参考了 ThioJoe 的脚本：  
This project’s download and parsing logic is based on ThioJoe’s script:  
https://github.com/ThioJoe/Windows-Sandbox-Tools

本项目对其逻辑进行了本地化与功能增强，包括菜单化操作、日志导出、服务检测、残留清理、下载模式选择等。  
This project extends and localizes the original logic with menu-driven flow, log export, service checks, residue cleanup, and download mode options.
