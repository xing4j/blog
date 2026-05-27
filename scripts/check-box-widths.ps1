$files = Get-ChildItem 'docs\posts' -Filter '*.md' | Sort-Object Name
$issues = @()
foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)
    $inCode = $false
    $blockLines = @()
    $blockStart = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if ($l -match '^```') {
            if ($inCode) {
                $hasBox = $blockLines | Where-Object { $_ -match '^\+[-=+]|^\| ' }
                if ($hasBox -and $blockLines.Count -gt 2) {
                    $boxLines = $blockLines | Where-Object { $_ -match '^\+|^\|' }
                    if ($boxLines.Count -gt 0) {
                        $widths = $boxLines | ForEach-Object { $_.Length }
                        $unique = $widths | Sort-Object -Unique
                        if ($unique.Count -gt 1) {
                            $issues += [PSCustomObject]@{
                                File   = $file.Name
                                Line   = $blockStart
                                Widths = ($unique -join ', ')
                                Count  = $boxLines.Count
                            }
                        }
                    }
                }
                $inCode = $false; $blockLines = @()
            } else {
                $inCode = $true; $blockStart = $i + 1; $blockLines = @()
            }
        } elseif ($inCode) { $blockLines += $l }
    }
}
if ($issues.Count -eq 0) { Write-Host 'No issues found' }
else { $issues | Format-Table -AutoSize }
