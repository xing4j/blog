$files = Get-ChildItem 'docs\posts' -Filter '*.md' | Sort-Object Name
foreach ($file in $files) {
    $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)
    $inCode = $false
    $blockLines = @()
    $blockLineNums = @()
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $l = $lines[$i]
        if ($l -match '^```') {
            if ($inCode) {
                $boxLines = $blockLines | Where-Object { $_ -match '^\+|^\|' }
                if ($boxLines -and $boxLines.Count -gt 2) {
                    $widths = $boxLines | ForEach-Object { $_.Length } | Sort-Object -Unique
                    if ($widths.Count -gt 1) {
                        $startLineNum = $blockLineNums[0]
                        Write-Host "=== $($file.Name) : block starts at file line $startLineNum ==="
                        for ($k = 0; $k -lt $blockLines.Count; $k++) {
                            $bl = $blockLines[$k]
                            if ($bl -match '^\+|^\|') {
                                Write-Host ("  ({0,3}chars) L{1}: {2}" -f $bl.Length, $blockLineNums[$k], $bl)
                            }
                        }
                        Write-Host ""
                    }
                }
                $inCode = $false; $blockLines = @(); $blockLineNums = @()
            } else { $inCode = $true }
        } elseif ($inCode) {
            $blockLines += $l
            $blockLineNums += ($i + 1)
        }
    }
}
exit 0
<# DEAD CODE BELOW - original script body replaced above #>
$blocks = @(
    @{File='2024-05-17-java-jmm-volatile.md'; Start=29},
    @{File='2024-05-27-jvm-gc-collectors.md'; Start=37},
    @{File='2024-05-27-jvm-gc-collectors.md'; Start=111},
    @{File='2024-07-28-mysql-index-btree.md'; Start=50},
    @{File='2024-07-28-mysql-index-btree.md'; Start=64},
    @{File='2024-08-22-spring-aop-proxy.md'; Start=41},
    @{File='2024-09-28-mysql-transaction-mvcc.md'; Start=32},
    @{File='2024-10-27-spring-boot-autoconfigure.md'; Start=134},
    @{File='2024-12-07-java-spi.md'; Start=15},
    @{File='2024-12-28-mysql-slow-query.md'; Start=11},
    @{File='2025-01-11-seata-distributed-transaction.md'; Start=86},
    @{File='2025-03-01-nginx-config.md'; Start=53},
    @{File='2025-03-22-java-deep-shallow-copy.md'; Start=15},
    @{File='2025-04-13-mysql-sharding.md'; Start=32},
    @{File='2025-06-27-spring-cloud-overview.md'; Start=66},
    @{File='2025-06-27-spring-cloud-overview.md'; Start=81},
    @{File='2025-06-27-spring-cloud-overview.md'; Start=98},
    @{File='2025-06-27-spring-cloud-overview.md'; Start=114},
    @{File='2025-06-27-spring-cloud-overview.md'; Start=127},
    @{File='2025-07-12-elasticsearch-inverted-index.md'; Start=49},
    @{File='2025-07-19-api-idempotency.md'; Start=398},
    @{File='2025-08-02-distributed-id.md'; Start=58},
    @{File='2025-08-02-distributed-id.md'; Start=257},
    @{File='2025-11-29-ddd-intro.md'; Start=164},
    @{File='2026-05-15-hello-world.md'; Start=19},
    @{File='2026-05-16-spring-boot-config-priority.md'; Start=157},
    @{File='2026-05-17-qiankun-micro-frontend.md'; Start=570},
    @{File='2026-05-21-java-generics-type-system.md'; Start=19},
    @{File='2026-05-22-ai-terminology-guide.md'; Start=344},
    @{File='2026-05-22-ai-terminology-guide.md'; Start=461},
    @{File='2026-05-22-sdd-ai-charter-skills.md'; Start=246},
    @{File='2026-05-24-kafka-architecture.md'; Start=27},
    @{File='2026-05-26-spring-cloud-gateway.md'; Start=47},
    @{File='2026-05-26-spring-cloud-gateway.md'; Start=78},
    @{File='2026-05-26-spring-cloud-security.md'; Start=29},
    @{File='2026-05-26-spring-cloud-tracing.md'; Start=144},
    @{File='2026-05-27-jvm-architecture.md'; Start=230},
    @{File='2026-05-27-jvm-memory-areas.md'; Start=21},
    @{File='2026-05-27-jvm-memory-areas.md'; Start=97}
)

foreach ($b in $blocks) {
    $path = "docs\posts\$($b.File)"
    $lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
    # 从 Start-2 往后找代码块（Start 是代码块内第一行的行号，1-indexed）
    # 找包含这行的代码块
    $inCode = $false
    $blockLines = @()
    $blockLineNums = @()
    $found = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i] -match '^```') {
            if ($inCode) {
                if ($blockLineNums.Count -gt 0 -and $blockLineNums[0] -eq $b.Start) {
                    $found = $true
                    break
                }
                $inCode = $false; $blockLines = @(); $blockLineNums = @()
            } else {
                $inCode = $true
            }
        } elseif ($inCode) {
            $lineNum = $i + 1  # 1-indexed
            $blockLines += $lines[$i]
            $blockLineNums += $lineNum
        }
    }
    if ($found) {
        Write-Host "=== $($b.File) (block start line $($b.Start)) ==="
        $j = 0
        foreach ($bl in $blockLines) {
            if ($bl -match '^\+|^\|') {
                Write-Host ("  L{0,4} ({1,3}): {2}" -f $blockLineNums[$j], $bl.Length, $bl)
            }
            $j++
        }
        Write-Host ""
    }
}
