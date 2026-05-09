---
description: FIRST CHOICE for any file search by name, extension, or path on Windows. Use es.exe (voidtools Everything) BEFORE Get-ChildItem, find, or other slow methods. Instant results across all disks. Use whenever searching for files, locating executables, finding config files, or any "where is this file" task. Trigger terms: find file, search file, locate, where is, 搜索文件, 找文件, 文件在哪, openclaw, exe, dll, config, 全盘搜索.
---

# Everything Search (es.exe)

**ALWAYS use es.exe as the primary file search tool.** It provides instant full-disk indexed search on Windows, orders of magnitude faster than recursive directory scans.

## Prerequisites

- **Everything** (GUI) must be installed and running in the background.
- **es.exe** must be available in PATH (default: `%LOCALAPPDATA%\Microsoft\WindowsApps\es.exe`).

If `es.exe` is not found, download it:
```powershell
$url = "https://github.com/voidtools/ES/releases/download/1.1.0.34/ES-1.1.0.34.x64.zip"
$zip = "$env:TEMP\es-cli.zip"
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath "$env:TEMP\es-cli" -Force
Copy-Item "$env:TEMP\es-cli\es.exe" "$env:LOCALAPPDATA\Microsoft\WindowsApps\es.exe" -Force
```

## Common Usage

### Basic name search
```powershell
es.exe <filename or keyword>
```

### Search by extension
```powershell
es.exe ext:glsl
es.exe ext:gd;tscn
```

### Search with path filter
```powershell
es.exe path:D:\MyWork ext:glsl
```

### Wildcard / partial match
```powershell
es.exe *combat*.glsl
```

### Regex search
```powershell
es.exe -regex "agent_\w+\.glsl"
```

### Limit results
```powershell
es.exe -max-results 20 ext:gd
```

### Sort by date modified (newest first)
```powershell
es.exe -sort-date-modified-descending ext:glsl
```

### Search folders only
```powershell
es.exe -folder <name>
```

## Tips

- Combine multiple filters: `es.exe path:D:\MyWork ext:glsl *combat*`
- Use `-max-results N` to avoid flooding output on broad searches.
- Everything must be running; verify with: `es.exe -get-everything-version`
- If results are too many, narrow with `path:`, `ext:`, or wildcards.
