# Creates "Claude Usage" shortcuts on the Desktop and in the Startup folder.
$ws  = New-Object -ComObject WScript.Shell
$vbs = Join-Path $PSScriptRoot 'start-widget.vbs'
foreach ($dir in [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('Startup')) {
    $s = $ws.CreateShortcut((Join-Path $dir 'Claude Usage.lnk'))
    $s.TargetPath = 'wscript.exe'
    $s.Arguments = "`"$vbs`""
    $s.WorkingDirectory = $PSScriptRoot
    $s.IconLocation = 'imageres.dll,-1024'
    $s.Save()
    $s.FullName
}
