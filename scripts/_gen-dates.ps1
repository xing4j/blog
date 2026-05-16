$queueJson = Get-Content "d:\code\github\blog\scripts\post-queue.json" -Raw -Encoding UTF8 | ConvertFrom-Json

$seed = 2024516
$rng = [System.Random]::new($seed)

$startDate = [datetime]"2024-05-17"
$endDate   = [datetime]"2026-05-15"
$totalDays = ($endDate - $startDate).Days
$count = $queueJson.Count

$rawDates = @()
for ($i = 0; $i -lt $count; $i++) {
    $progress  = if ($count -gt 1) { $i / ($count - 1) } else { 0 }
    $baseDays  = [int]($progress * $totalDays)
    $jitter    = $rng.Next(-6, 7)
    $dayOffset = [Math]::Max(0, [Math]::Min($totalDays, $baseDays + $jitter))
    $rawDates += $startDate.AddDays($dayOffset)
}

$finalDates = @()
foreach ($date in $rawDates) {
    if ($rng.Next(10) -lt 7) {
        $dow = [int]$date.DayOfWeek
        if ($dow -ne 0 -and $dow -ne 6) {
            if ($dow -le 3) {
                $date = if ($rng.Next(2) -eq 0) { $date.AddDays(-$dow) } else { $date.AddDays(6 - $dow) }
            } else {
                $date = $date.AddDays(6 - $dow)
            }
        }
    }
    $finalDates += $date
}

$weekendCount = ($finalDates | Where-Object { $_.DayOfWeek -in @('Saturday','Sunday') }).Count
Write-Host "Total $count articles  Weekend: $weekendCount  Weekday: $($count - $weekendCount)"
Write-Host ""
Write-Host "No.   Date         Tag  Day  Category        Title"
Write-Host "---   ----------   ---  ---  --------        -----"

for ($i = 0; $i -lt $count; $i++) {
    $d   = $finalDates[$i]
    $dow = [int]$d.DayOfWeek
    $dowName = @('Sun','Mon','Tue','Wed','Thu','Fri','Sat')[$dow]
    $tag = if ($dow -eq 0 -or $dow -eq 6) { "[W]" } else { "   " }
    $title = $queueJson[$i].title
    if ($title.Length -gt 22) { $title = $title.Substring(0,22) }
    $cat = $queueJson[$i].category
    $newDate = $d.ToString("yyyy-MM-dd")
    $num = ($i+1).ToString().PadLeft(3)
    $out = $num + ".  " + $newDate + "  " + $tag + " " + $dowName + "  " + $cat + "  " + $title
    Write-Host $out
}
