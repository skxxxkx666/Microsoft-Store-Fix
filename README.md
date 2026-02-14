# Microsoft Store Fix Tool (PS1)

本项目提供一个基于官方 Windows Update 接口下载并安装 Microsoft Store 的 PowerShell 脚本，包含服务检测、注册表修复、残留清理、日志导出、下载模式选择等功能。  
This project provides a PowerShell script that downloads and installs Microsoft Store via official Windows Update APIs, with service checks, registry repair, residue cleanup, log export, and download mode selection.

## 功能亮点 / Features
- 官方源下载（WU SOAP 接口） / Official source download (WU SOAP)
- 安装前服务检测与修复 / Pre-install service checks and fixes
- 商店相关注册表检测与自动修复 / Store registry detection and auto-repair
- 残留目录检测与可选清理 / Residue detection and optional cleanup
- 代理检测 / Proxy detection
- Windows 10/11 自动识别 / Windows 10/11 auto-detection
- 可选地区修复（US / CN / HK / TW / JP） / Optional region fix (US / CN / HK / TW / JP)
- 下载模式选择：默认 / BITS / 最优节点测速 / Download modes: default / BITS / best node probe
- 三重崩溃保护与完整错误诊断 / Triple crash protection and full error diagnostics
- 完整日志与错误导出 / Full logging and error export

## 运行要求 / Requirements
- Windows 10/11 (LTSC / IoT 优先)
- PowerShell 5.1+ (built-in)
- 管理员权限 / Administrator privileges

## 快速开始 / Quick Start

> ⚠️ **请勿直接双击或右键"使用 PowerShell 运行"**，否则会闪退。  
> ⚠️ **Do NOT double-click or use "Run with PowerShell"** from the right-click menu — the window will close immediately.

以 **管理员身份** 打开 PowerShell 终端，输入以下命令运行：  
Open PowerShell **as Administrator** and run:

```powershell
powershell -ExecutionPolicy Bypass -NoExit -File "C:\完整路径\MicrosoftStore_Fix_v1.4.0.ps1"
```

或者先 cd 到脚本所在目录再运行 / Or cd to the script directory first:

```powershell
cd "C:\完整路径"
Set-ExecutionPolicy Bypass -Scope Process -Force
.\MicrosoftStore_Fix_v1.4.0.ps1
```

## 参数 / Arguments
| 参数 | 说明 |
|------|------|
| `-DebugSaveFiles` | 保存请求/响应 XML 与错误日志 / Save request/response XML and error logs |
| `-NoDownload` | 仅解析包，不下载 / Parse only, no download |
| `-NoInstall` | 仅下载，不安装 / Download only, no install |

## 日志位置 / Logs
默认目录 / Default:
`%USERPROFILE%\Downloads\MSStore Install\Logs`

## 发布校验 / Release Hash
| 文件 | SHA256 |
|------|--------|
| `MicrosoftStore_Fix_v1.4.0.ps1` | `6E36E54F61B841D8C0CC520240619C252AB26CF17BC05EA578949C6A264A11AF` |

## 免责声明 / Disclaimer
本工具会修改系统服务状态、注册表与安装 Appx 包，请在了解风险后使用。  
This tool modifies system services, registry entries, and installs Appx packages. Use at your own risk.

## 致谢与来源说明 / Acknowledgements & Source
本项目的下载与解析逻辑参考了 ThioJoe 的脚本：  
This project's download and parsing logic is based on ThioJoe's script:  
https://github.com/ThioJoe/Windows-Sandbox-Tools

v1.4.0 起通信层实现已重构为独立代码结构，不再作为其脚本分支。  
Since v1.4.0, the communication layer has been rewritten as an independent codebase and is no longer a fork of the original script.
