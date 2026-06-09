$ToolsPath = "C:\Tools"
$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if ($currentPath -notlike "*$ToolsPath*") {
    [Environment]::SetEnvironmentVariable("PATH", "$currentPath;$ToolsPath", "User")
    Write-Host "C:\Tools added to User PATH. Please restart your terminal for the change to take effect."
} else {
    Write-Host "C:\Tools already in User PATH."
}
