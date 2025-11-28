#refactored rollback logic to guard against chain hops

#created a setting for Masters. 



$script:Config = [PSCustomObject]@{
	# Default Configuration #
	# Current settings preserve save-states for the last 5 in-game hours, in 5 minute increments.
	# Checkpoints on 32 render distance use ~ 150 MB of disk space each when exploring new terrain with Elytra.
	# Checkpoints on 12 render distance use ~ 80 MB of disk space each under similar circumstances. 
	
	# Use the in-script settings menu to edit these options #
	# Changes made here are only used on first-run.         #
	# "reset to default" values can be found on line 490	#

    SavesFolder             = "$env:APPDATA\.minecraft\saves"
    CheckpointsFolder       = "$PSSCRIPTROOT\Checkpoints"
    Masters 				= "$PSSCRIPTROOT\Masters"
    PreRollbackCopies		= "$PSSCRIPTROOT\Masters"
	MaxFullBackups          = 2
    MaxChainLength     		= 30
    MinBackupInterval 		= 300
}

# State Tracking
$script:SessionStartTime = $null
$script:LastCheckpointTime = $null
$script:SizeCache = @{}

$ConfigPath = Join-Path $PSSCRIPTROOT 'config.xml'
$CachePath = Join-Path $PSSCRIPTROOT 'cache.xml'

#
function Load-CSharp {
        # --- C# to help hasten file operations ---\
    $csharpCode = @"
using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

public class FastCopy {
    
    public static long GetDirectorySize(string dirPath)
    {
        if (!Directory.Exists(dirPath)) return 0;
        long total = 0;
        try {
            var files = Directory.EnumerateFiles(dirPath, "*", SearchOption.AllDirectories);
            Parallel.ForEach(files, file => {
                if (Path.GetFileName(file) != "session.lock") {
                    try { Interlocked.Add(ref total, new FileInfo(file).Length); } catch {}
                }
            });
        } catch {}
        return total;
    }

    public class CopyResult {
        public int CopiedFiles = 0;
        public int SkippedFiles = 0;
        public long TotalSize = 0;
    }

    public static CopyResult IncrementalCopy(
        string sourceDir, 
        string destDir, 
        string[] referencePaths) // CHANGED: Now accepts a simple array of paths
    {
        var result = new CopyResult();
        if (!Directory.Exists(sourceDir)) return result;

        var files = Directory.GetFiles(sourceDir, "*", SearchOption.AllDirectories);
        
        Parallel.ForEach(files, file => {
            if (Path.GetFileName(file) == "session.lock") return;
            
            var srcInfo = new FileInfo(file);
            string relativePath = file.Substring(sourceDir.Length + 1);
            
            // Default to copying unless we find a match
            bool shouldCopy = true;
            
            // Check against previous backups in the chain
            if (referencePaths != null) {
                foreach (var refDir in referencePaths) {
                    string checkPath = Path.Combine(refDir, relativePath);
                    var refInfo = new FileInfo(checkPath);
                    
                    // If found and matches exactly, skip copy
                    if (refInfo.Exists && 
                        srcInfo.LastWriteTime == refInfo.LastWriteTime && 
                        srcInfo.Length == refInfo.Length) {
                        shouldCopy = false;
                        break; 
                    }
                }
            }
            
            if (shouldCopy) {
                string destFile = Path.Combine(destDir, relativePath);
                try {
                    // Ensure directory exists (CreateDirectory is thread-safe enough for this)
                    Directory.CreateDirectory(Path.GetDirectoryName(destFile));
                    
                    srcInfo.CopyTo(destFile, true);
                    
                    Interlocked.Increment(ref result.CopiedFiles);
                    Interlocked.Add(ref result.TotalSize, srcInfo.Length);
                } catch (Exception ex) {
                    Console.WriteLine("[Error] " + relativePath + ": " + ex.Message);
                }
            } else {
                Interlocked.Increment(ref result.SkippedFiles);
            }
        });
        
        return result;
    }

    public static CopyResult FullCopy(string sourceDir, string destDir)
    {
        // FullCopy is just IncrementalCopy with no references to check
        return IncrementalCopy(sourceDir, destDir, new string[0]);
    }

    public static void OptimizedRollback(string[] sourceDirs, string destDir)
    {
        // 1. Build Map Sequentially (Order matters: Oldest -> Newest overwrite)
        var fileMap = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        
        foreach (var dir in sourceDirs)
        {
            if (!Directory.Exists(dir)) continue;
            var files = Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories);
            foreach (var file in files)
            {
                string relative = file.Substring(dir.Length + 1);
                fileMap[relative] = file;
            }
        }


        // 2. Copy in Parallel
        Parallel.ForEach(fileMap, kvp => {
            string relativePath = kvp.Key;
            string sourceFile = kvp.Value;
            string destFile = Path.Combine(destDir, relativePath);

            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(destFile));
                File.Copy(sourceFile, destFile, true);
            }
            catch (Exception ex)
            {
                Console.WriteLine("Warning: Could not copy " + relativePath + " - " + ex.Message);
            }
        });
		
    }
}
"@
    try {
        Add-Type -TypeDefinition $csharpCode -Language CSharp
    } catch {
        # Ignore if already loaded
    }
}

#
function Load-SizeCache {
    if (Test-Path $CachePath) {
        try {
            $data = Import-Clixml -Path $CachePath -ErrorAction Stop
            if ($data -is [hashtable]) {
                $script:SizeCache = $data
            } else {
                $script:SizeCache = @{}
            }
        } catch {
            $script:SizeCache = @{}
        }
    } else {
        $script:SizeCache = @{}
    }
}

#
function Save-SizeCache {
    if (-not $script:SizeCache) { $script:SizeCache = @{} }
    $dir = Split-Path $CachePath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $script:SizeCache | Export-Clixml -Path $CachePath -Force
}

#
function Ensure-WorldSizeCache {
    param(
        [string]$WorldName,
        [string]$WorldPath,
        [string]$BackupPath
    )

    if (-not $script:SizeCache.ContainsKey($WorldName)) {
        # 1. World Size
        $worldSize = [FastCopy]::GetDirectorySize($WorldPath)
        
        # 2. Regular Checkpoints Size
        $backupSize = if (Test-Path $BackupPath) {
            [FastCopy]::GetDirectorySize($BackupPath)
        } else {
            0L
        }

        # 3. Master Checkpoints Size (Consolidated)
        $masterRoot = $script:Config.Masters

        if (Test-Path $masterRoot) {
            $pattern = "${WorldName}_Master_*"
            $masterRoots = Get-ChildItem -Path $masterRoot -Directory -Filter $pattern
            foreach ($mf in $masterRoots) {
                # Reuse cache if available to speed up menu
                $mKey = "MasterBackup_$($mf.Name)"
                if ($script:SizeCache.ContainsKey($mKey)) {
                    $backupSize += $script:SizeCache[$mKey]
                } else {
                    $mSize = [FastCopy]::GetDirectorySize($mf.FullName)
                    $script:SizeCache[$mKey] = $mSize
                    $backupSize += $mSize
                }
            }
        }

        $script:SizeCache[$WorldName] = [PSCustomObject]@{
            WorldSizeBytes  = $worldSize
            BackupSizeBytes = $backupSize
            LastUpdated     = Get-Date
        }
        Save-SizeCache
    }
}

#
function Get-CachedWorldSizes {
    param([string]$WorldName)
    if ($script:SizeCache.ContainsKey($WorldName)) {
        return $script:SizeCache[$WorldName]
    }
    return $null
}

#
function Update-SizeCacheForWorld {
    param(
        [string]$WorldPath,
        [string]$BackupPath
    )

    $worldName = Split-Path $WorldPath -Leaf
    if (-not $script:SizeCache) { $script:SizeCache = @{} }

    # 1. World Size
    $worldSize = [FastCopy]::GetDirectorySize($WorldPath)
    
    # 2. Regular Checkpoints Size
    $backupSize = if (Test-Path $BackupPath) {
        [FastCopy]::GetDirectorySize($BackupPath)
    } else {
        0L
    }

    # 3. Master Checkpoints Size (Consolidated)
    $masterRoot = $script:Config.Masters

    if (Test-Path $masterRoot) {
        $pattern = "${worldName}_Master_*"
        $masterRoots = Get-ChildItem -Path $masterRoot -Directory -Filter $pattern
        foreach ($mf in $masterRoots) {
            # For an "Update" we force-recalculate master sizes to be safe, 
            # or we could trust the cache key. Trusting key is faster.
            $mKey = "MasterBackup_$($mf.Name)"
            if ($script:SizeCache.ContainsKey($mKey)) {
                $backupSize += $script:SizeCache[$mKey]
            } else {
                $mSize = [FastCopy]::GetDirectorySize($mf.FullName)
                $script:SizeCache[$mKey] = $mSize
                $backupSize += $mSize
            }
        }
    }

    $script:SizeCache[$worldName] = [PSCustomObject]@{
        WorldSizeBytes  = $worldSize
        BackupSizeBytes = $backupSize
        LastUpdated     = Get-Date
    }
    Save-SizeCache
}
#
function Get-FormattedSize {
    param($Bytes)
    if ($Bytes -gt 1GB) {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    } elseif ($Bytes -gt 1MB) {
        return "{0:N2} MB" -f ($Bytes / 1MB)
    } else {
        return "{0:N2} KB" -f ($Bytes / 1KB)
    }
}


# --- CONFIGURATION ---

function Get-Metadata {
    param($Path)
    if (Test-Path $Path) {
        try {
            $data = Import-Clixml -Path $Path -ErrorAction Stop
            if ($data) { 
                # Initialize new fields if missing (for existing metadata)
                if (-not $data.PSObject.Properties['CurrentCheckpointId']) {
                    $latest = $data.Checkpoints | Sort-Object Timestamp -Descending | Select-Object -First 1
                    $data | Add-Member -NotePropertyName 'CurrentCheckpointId' -NotePropertyValue $latest.CheckpointId -Force
                }
                if (-not $data.PSObject.Properties['Generation']) {
                    $data | Add-Member -NotePropertyName 'Generation' -NotePropertyValue 1 -Force
                }
                return $data 
            }
        } catch {
            Write-Warning "Metadata corrupted at $Path. Starting fresh."
        }
    }
    return [PSCustomObject]@{ 
        Checkpoints = @()
        CurrentCheckpointId = $null
        Generation = 1
    }
}

function Save-Metadata {
    param($Data, $Path)
    $Data | Export-Clixml -Path $Path -Force
}

function Load-Config {
    if (Test-Path $ConfigPath) {
        try {
            $loaded = Import-Clixml -Path $ConfigPath -ErrorAction Stop
            if ($loaded) {
                foreach ($prop in $script:Config.PSObject.Properties) {
                    if ($null -ne $loaded.($prop.Name)) { $prop.Value = $loaded.($prop.Name) }
                }
                return
            }
        } catch {
            Write-Warning "Config file corrupted. Will prompt for new settings."
        }
    }
    
    
    $response = Read-Host "Use default settings? (y/n)"
    if ($response -eq 'n' -or $response -eq 'N') {
        Edit-ConfigInteractive
    } else {
        Write-Host "Using default settings." -ForegroundColor Green
        Save-Config
    }
}

function Save-Config {
    $dir = Split-Path $ConfigPath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script:Config | Export-Clixml -Path $ConfigPath -Force
    clear-host
}

function Edit-ConfigInteractive {
    $continue = $true
    
    while ($continue) {
        clear-host
        Write-Host "=== Edit Configuration Settings ===" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "[1] SavesFolder            : $($script:Config.SavesFolder)" -ForegroundColor White
        Write-Host "[2] CheckpointsFolder      : $($script:Config.CheckpointsFolder)" -ForegroundColor White
        Write-Host "[3] Masters folder         : $($script:Config.Masters)" -ForegroundColor White
		Write-Host "[4] MaxFullBackups         : $($script:Config.MaxFullBackups)" -ForegroundColor White
        Write-Host "[5] MaxChainLength         : $($script:Config.MaxChainLength)" -ForegroundColor White																									   
        Write-Host "[6] MinBackupInterval      : $($script:Config.MinBackupInterval) seconds" -ForegroundColor White
        Write-Host ""
        Write-Host "[q] Save and Return" -ForegroundColor Green
        Write-Host ""
        
        $choice = Read-Host "Select setting to edit (1-6)"
        
        switch ($choice) {
            '1' {
                Write-Host "`nCurrent: $($script:Config.SavesFolder)" -ForegroundColor DarkGray
                $input = Read-Host "Enter new Minecraft Saves Folder Path (or press ENTER to cancel)"
                if (![string]::IsNullOrWhiteSpace($input)) { 
                    $script:Config.SavesFolder = $input
                }
            }
            '2' {
                Write-Host "`nCurrent: $($script:Config.CheckpointsFolder)" -ForegroundColor DarkGray
                $input = Read-Host "Enter new Checkpoints Folder Path (or press ENTER to cancel)"
                if (![string]::IsNullOrWhiteSpace($input)) { 
                    $script:Config.CheckpointsFolder = $input
                }
            }
			'3' {
				Write-Host "`nCurrent: $($script:Config.Masters)" -ForegroundColor DarkGray
                Write-Host "`nEnter new Masters path:" -ForegroundColor DarkGray
                $input = Read-Host "Enter new Max Full Backup Chains (or press ENTER to cancel)"
                if (-not [string]::IsNullOrWhiteSpace($input)) {
                    $script:Config.Masters = $input
                }
            }
            '4' {
                Write-Host "`nCurrent: $($script:Config.MaxFullBackups)" -ForegroundColor DarkGray
                Write-Host "(How many full backup chains to keep)" -ForegroundColor DarkGray
                $input = Read-Host "Enter new Max Full Backup Chains (or press ENTER to cancel)"
                if ($input -match '^\d+$') { 
                    $script:Config.MaxFullBackups = [int]$input
                }
                elseif (![string]::IsNullOrWhiteSpace($input)) {
                    Write-Host "Invalid input. Must be a number." -ForegroundColor Red
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
                }
            }
            '5' {
                Write-Host "`nCurrent: $($script:Config.MaxChainLength)" -ForegroundColor DarkGray
                Write-Host "(Max incremental backups before forcing new full backup)" -ForegroundColor DarkGray
                $input = Read-Host "Enter new Max Chain Length (or press ENTER to cancel)"
                if ($input -match '^\d+$') { 
                    $script:Config.MaxChainLength = [int]$input
                }
                elseif (![string]::IsNullOrWhiteSpace($input)) {
                    Write-Host "Invalid input. Must be a number." -ForegroundColor Red
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
                }
            }
            '6' {
                Write-Host "`nCurrent: $($script:Config.MinBackupInterval) seconds" -ForegroundColor DarkGray
                Write-Host "(Minimum time between backups)" -ForegroundColor DarkGray
                $input = Read-Host "Enter new Min Backup Interval in seconds (or press ENTER to cancel)"
                if ($input -match '^\d+$') { 
                    $script:Config.MinBackupInterval = [int]$input
                }
                elseif (![string]::IsNullOrWhiteSpace($input)) {
                    Write-Host "Invalid input. Must be a number." -ForegroundColor Red
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
                }
            }
            'q' {
                Write-Host "`nSaving configuration..." -ForegroundColor Yellow
                Save-Config
                $continue = $false
            }
            default {
                Write-Host "`nInvalid choice. Please select 1-6." -ForegroundColor Red
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
            }
        }
    }
}

function Show-CurrentSettings {
    clear-host
    Write-Host "=== Current Configuration ===" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "SavesFolder        : $($script:Config.SavesFolder)" -ForegroundColor White
    Write-Host "CheckpointsFolder  : $($script:Config.CheckpointsFolder)" -ForegroundColor White
    Write-Host "Masters folder     : $($script:Config.Masters)" -ForegroundColor White
	Write-Host "MaxFullBackups     : $($script:Config.MaxFullBackups)" -ForegroundColor White
	Write-Host "MaxChainLength     : $($script:Config.MaxChainLength)" -ForegroundColor White																							 
    Write-Host "MinBackupInterval  : $($script:Config.MinBackupInterval) seconds" -ForegroundColor White
    Write-Host ""
	Write-Host "=== Config File Location: ===" -ForegroundColor Cyan
    Write-Host "$ConfigPath" -ForegroundColor White
    Write-Host ""
}

function Start-SettingsMenu {
    while ($true) {
        Show-CurrentSettings
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "[1] Edit Settings" -ForegroundColor White
        Write-Host "[2] Reset to Defaults" -ForegroundColor White
		Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "[q] Go back" -ForegroundColor Yellow
        Write-Host ""
        
        $choice = Read-Host "Option"
        
        switch ($choice) {
            '1' {
                Edit-ConfigInteractive
            }
            '2' {
                $confirm = Read-Host "Reset all settings to defaults? (y/n)"
                if ($confirm -eq 'y' -or $confirm -eq 'Y') {
                    $script:Config.SavesFolder = "$env:APPDATA\.minecraft\saves"
                    $script:Config.CheckpointsFolder = "$PSSCRIPTROOT\Checkpoints"
                    $script:Config.MaxFullBackups = 2
                    $script:Config.MaxChainLength = 30													 
                    $script:Config.MinBackupInterval = 300
                    Save-Config
                    Write-Host "Settings reset to defaults." -ForegroundColor Green
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
                }
            }
            'q' {
                return
            }
            default {
                Write-Host "Invalid choice. Please try again." -ForegroundColor Red
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
            }
        }
    }
}


# --- BACKUP LOGIC ---


function New-Checkpoint {
    param(
        [string]$WorldPath,
        [string]$BackupPath,
        [string]$MetadataPath,
        [switch]$Silent
    )
    
    $now = Get-Date
    $checkpointId = "CP_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    $destCpPath = Join-Path $BackupPath $checkpointId
    
    $metadata = Get-Metadata -Path $MetadataPath
    
    # DECISION LOGIC: Full vs Incremental (based on CurrentCheckpointId)
    $backupType = "Full"
    $parentId = $null
    $chainIndex = 0
    
    # Find the current head checkpoint (where the world actually is)
    $currentHead = $null
    if ($metadata.CurrentCheckpointId) {
        $currentHead = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $metadata.CurrentCheckpointId } | Select-Object -First 1
    }
    
    if ($currentHead) {
        # Walk back to find the root Full backup of current chain
        $rootFull = $currentHead
        $temp = $currentHead
        while ($temp) {
            if ($temp.Type -eq "Full") {
                $rootFull = $temp
                break
            }
            if ($temp.ParentId) {
                $temp = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $temp.ParentId } | Select-Object -First 1
            } else {
                break
            }
        }
        
        # Check if we should do incremental
        if ($rootFull -and ($now.Date -eq $rootFull.Timestamp.Date) -and ($currentHead.ChainIndex -lt $script:Config.MaxChainLength)) {
            $backupType = "Incremental"
            $parentId = $currentHead.CheckpointId
            $chainIndex = $currentHead.ChainIndex + 1
        }
    }

    # --- BUILD REFERENCE CHAIN FROM CURRENT HEAD ---
    $referencePaths = @() 
    
    if ($backupType -eq "Incremental" -and $currentHead) {
        # Walk from current head back to root, building the reference chain
        $temp = $currentHead
        while ($temp) {
            $referencePaths += Join-Path $BackupPath $temp.CheckpointId
            if ($temp.Type -eq "Full") {
                break
            }
            if ($temp.ParentId) {
                $temp = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $temp.ParentId } | Select-Object -First 1
            } else {
                break
            }
        }
    }

    # USE FASTCOPY CLASS
    if ($backupType -eq "Full") {
        $result = [FastCopy]::FullCopy($WorldPath, $destCpPath)
    } else {
        $result = [FastCopy]::IncrementalCopy($WorldPath, $destCpPath, [string[]]$referencePaths)
    }
    
    # CHECK FOR EMPTY INCREMENTAL
    if ($backupType -eq "Incremental" -and $result.CopiedFiles -eq 0) {
        if (Test-Path $destCpPath) { Remove-Item -Path $destCpPath -Recurse -Force }
        if (-not $Silent) {
            Write-Host "No changes detected. Skipping empty incremental backup." -ForegroundColor DarkGray
        }
        return $null
    }

    # PRINT STATS
    if (-not $Silent) {
        $timeDisplay = $now.ToString("HH:mm:ss")
        $typeDisplay = if ($backupType -eq "Full") { "Full Backup" } else { "Checkpoint" }
        
        Write-Host ""
        Write-Host "[$timeDisplay] $typeDisplay (#$chainIndex in chain)" -ForegroundColor DarkGray
        
        $sizeMB = [math]::Round($result.TotalSize / 1MB, 2)
        Write-Host "Changed: $($result.CopiedFiles) | Skipped: $($result.SkippedFiles) | Size: ${sizeMB} MB" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    }

    $checkpointInfo = [PSCustomObject]@{
        CheckpointId = $checkpointId
        Timestamp    = $now
        Type         = $backupType
        ParentId     = $parentId
        ChainIndex   = $chainIndex
        Generation   = $metadata.Generation
        FileCount    = $result.CopiedFiles
        SkippedCount = $result.SkippedFiles
        TotalSize    = $result.TotalSize
    }
    
    $metadata.Checkpoints = @($metadata.Checkpoints) + @($checkpointInfo)
    
    # UPDATE CURRENT HEAD to this new checkpoint
    $metadata.CurrentCheckpointId = $checkpointId
    
    # CLEANUP LOGIC
    $fullBackups = $metadata.Checkpoints | Where-Object { $_.Type -eq "Full" } | Sort-Object Timestamp
    if ($fullBackups.Count -gt $script:Config.MaxFullBackups) {
        $keeperTimestamp = $fullBackups[1].Timestamp
        $toDelete = $metadata.Checkpoints | Where-Object { $_.Timestamp -lt $keeperTimestamp }
        foreach ($cp in $toDelete) {
            $p = Join-Path $BackupPath $cp.CheckpointId
            if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        }
        $metadata.Checkpoints = $metadata.Checkpoints | Where-Object { $_.Timestamp -ge $keeperTimestamp }
    }
    
    Save-Metadata -Data $metadata -Path $MetadataPath
    
    Update-SizeCacheForWorld -WorldPath $WorldPath -BackupPath $BackupPath

    return $checkpointInfo
}

function Show-WorldSelectionMenu {
    try {
        $w = Get-ChildItem $script:Config.SavesFolder -Directory -ErrorAction Stop
    } catch {
        $w = @() # Treat error (like folder missing) as "0 worlds found"
    }																				  
    if ($w.Count -eq 0) {
         Write-Warning "No worlds found in $($script:Config.SavesFolder)"
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
         return
    }

    while ($true) {
        clear-host
        Write-Host "Select World:" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray

        $maxNameLength = ($w | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum

        $i = 0
        foreach ($world in $w) {
            $entry = Get-CachedWorldSizes -WorldName $world.Name
            if ($entry) {
                $sizeDisplay = Get-FormattedSize $entry.WorldSizeBytes
            } else {
                $sizeDisplay = "Unknown"
            }

            $paddedName = $world.Name.PadRight($maxNameLength + 5)

            Write-Host "[$i] " -NoNewline -ForegroundColor White
            Write-Host $paddedName -NoNewline -ForegroundColor White
            Write-Host $sizeDisplay -ForegroundColor Yellow
            $i++
        }

        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "[q] Back to Main Menu" -ForegroundColor Yellow
        Write-Host ""
        $sel = Read-Host "Option"
        
        if ($sel -eq 'q' -or $sel -eq 'Q') { return }

        if ($sel -match '^\d+$' -and [int]$sel -lt $w.Count) {
            $selectedWorld = $w[[int]$sel]
            $worldPath = $selectedWorld.FullName
            $backupPath = Join-Path $script:Config.CheckpointsFolder $selectedWorld.Name
            $metadataPath = Join-Path $backupPath "_checkpoints.xml"

            if (-not (Test-Path $backupPath)) {
                New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
            }

            Ensure-WorldSizeCache -WorldName $selectedWorld.Name -WorldPath $worldPath -BackupPath $backupPath

            Show-WorldDetailsScreen -WorldName $selectedWorld.Name -WorldPath $worldPath -BackupPath $backupPath -MetadataPath $metadataPath
            
        }
    }
}

function Show-WorldDetailsScreen {
    param(
        [string]$WorldName,
        [string]$WorldPath,
        [string]$BackupPath,
        [string]$MetadataPath
    )
    
    
    while ($true) {
		 $entry = Get-CachedWorldSizes -WorldName $WorldName
        if ($entry) {
            $worldSizeDisplay = Get-FormattedSize $entry.WorldSizeBytes
            $backupSizeDisplay = if ($entry.BackupSizeBytes -gt 0) {
                Get-FormattedSize $entry.BackupSizeBytes
            } else {
                "No backups"
            }
        } else {
            $worldSizeDisplay = "Unknown"
            $backupSizeDisplay = "No backups"
        }
        clear-host
        # Get last checkpoint
        $metadata = Get-Metadata -Path $MetadataPath
        $lastCheckpoint = $metadata.Checkpoints | Sort-Object Timestamp -Descending | Select-Object -First 1
        
        # Define column widths for alignment
        $col1Width = 15 # World Name
        $col2Width = 15 # World Size
        $col3Width = 16 # Backup Size (Increased slightly to spacing)
        
        # 1. Header
        Write-Host "Selected World     World          Backups         Last Checkpoint" -ForegroundColor Cyan
        Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray
        
        # 2. Row 1: World Info (Left Side)
        Write-Host "[X] " -NoNewline -ForegroundColor White
        Write-Host $WorldName.PadRight($col1Width) -NoNewline -ForegroundColor White
        Write-Host $worldSizeDisplay.PadRight($col2Width) -NoNewline -ForegroundColor Yellow
        Write-Host $backupSizeDisplay.PadRight($col3Width) -NoNewline -ForegroundColor Yellow
        
        # 3. Row 1 & 2: Checkpoint Info (Right Side)
        if ($lastCheckpoint) {
            $col = if ($lastCheckpoint.Type -eq "Full") { "White" } else { "White" }
            $sizeMB = [math]::Round($lastCheckpoint.TotalSize / 1MB, 2)
            $timeDisplay = $lastCheckpoint.Timestamp.ToString("HH:mm:ss")
            
            # Print Header (continues on same line as World Info)
            Write-Host "[$timeDisplay] Checkpoint (#$($lastCheckpoint.ChainIndex + 1) in chain)" -ForegroundColor $col
            
            # Calculate indentation for the second line
            # Length = "[X] " (4) + Name + WorldSize + BackupSize
            $indentLength = 4 + $col1Width + $col2Width + $col3Width
            $indent = " " * $indentLength
            
            # Print Details (on new line, indented)
            Write-Host "${indent}Changed: $($lastCheckpoint.FileCount) | Skipped: $($lastCheckpoint.SkippedCount) | Size: $sizeMB MB" -ForegroundColor $col
        } else {
            Write-Host "No checkpoints" -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "----------------------------------------------------------------------------------------------------" -ForegroundColor DarkGray

        
        Write-Host "[1] Start Auto-Saving" -ForegroundColor White
        Write-Host "[2] Force-save Checkpoint" -ForegroundColor White
        Write-Host "[3] Rollback World" -ForegroundColor White
        Write-Host "[4] Merge Checkpoints" -ForegroundColor White
		Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
		Write-Host "[q] Go back" -ForegroundColor Yellow
        Write-Host ""
        
        $choice = Read-Host "Option"
        
        switch ($choice) {
            '1' {
                Start-Monitor -WorldName $WorldName -ShowDetailsAfter
            }
            '2' {
				Write-Host "Creating checkpoint"
                $checkpoint = New-Checkpoint -WorldPath $WorldPath -BackupPath $BackupPath -MetadataPath $MetadataPath
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
                if ($checkpoint) {
                }
            }
            '3' {
                Start-RollbackMode -WorldName $WorldName
            }
                        '4' {
                Consolidate-Checkpoints -WorldName $WorldName -WorldPath $WorldPath -BackupPath $BackupPath -MetadataPath $MetadataPath
            }
			'q' {
                return
            }
        }
    }
}

function Start-Monitor {
    param(
        [string]$WorldName,
        [switch]$ShowDetailsAfter
    )
    
    $wp = Join-Path $script:Config.SavesFolder $WorldName
    $bp = Join-Path $script:Config.CheckpointsFolder $WorldName
    $mp = Join-Path $bp "_checkpoints.xml"
    
    if (-not (Test-Path $bp)) { New-Item -ItemType Directory -Path $bp -Force | Out-Null }
    
    # Reset session checkpoints
    $script:SessionCheckpoints = @()
    
    # Draw header ONCE
    clear-host
    
    # Calculate sizes
    Ensure-WorldSizeCache -WorldName $WorldName -WorldPath $wp -BackupPath $bp
    $entry = Get-CachedWorldSizes -WorldName $WorldName

    $worldSizeDisplay = if ($entry) { Get-FormattedSize $entry.WorldSizeBytes } else { "Unknown" }
    $backupSizeDisplay = if ($entry -and $entry.BackupSizeBytes -gt 0) {
        Get-FormattedSize $entry.BackupSizeBytes
    } else {
        "No backups"
    }
    
    Write-Host "Auto-Saving:     Minecraft:       Checkpoints:" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[X] " -NoNewline -ForegroundColor White
    Write-Host $WorldName.PadRight(15) -NoNewline -ForegroundColor White
    Write-Host $worldSizeDisplay.PadRight(15) -NoNewline -ForegroundColor Yellow
    Write-Host $backupSizeDisplay -ForegroundColor Yellow
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[q] Stop" -ForegroundColor Yellow    
    Write-Host ""
    
    # Check for level.dat change to detect Minecraft auto-saves.
	# Minecraft writes real-time updates to .mca files, 
	# Using this logic protects us from corrupting chunks by copying them while Minecraft is writing to them.
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = $wp
    $watcher.Filter = "level.dat"           # Watch specific file only
    $watcher.IncludeSubdirectories = $false # No need to scan deep folders
    $watcher.EnableRaisingEvents = $true
    $watcher.InternalBufferSize = 65536     # Max buffer 
    
    $pendingChanges = $false

    try {
        while ($true) {
            # Check for keyboard input (non-blocking)
            if ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)
                
                if ($key.Key -eq 'Q') {
                    return
                }
            }
            
            # Wait for any file change to level.dat
            # Timeout set to 5ms so we can keep checking for 'Q' key press
            $result = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 5)
            
            if (-not $result.TimedOut) {
                # Note: Since we set .Filter = "level.dat", $result.Name will always be "level.dat"
                $pendingChanges = $true
            }

            # If we have pending changes, check if enough time has passed to save
            if ($pendingChanges) {
                $secSince = if ($script:LastCheckpointTime) { ((Get-Date) - $script:LastCheckpointTime).TotalSeconds } else { 9999 }
                
                if ($secSince -gt $script:Config.MinBackupInterval) {
                    $checkpoint = New-Checkpoint -WorldPath $wp -BackupPath $bp -MetadataPath $mp
                    if ($checkpoint) {
                        $script:SessionCheckpoints += $checkpoint
                        $script:LastCheckpointTime = Get-Date
                        
                        # Reset pending flag only after a successful save
                        $pendingChanges = $false
                    }
                }
            }
        }
    } finally {
        # Cleanup watcher when user quits or error occurs
        $watcher.Dispose()
    }
}


# --- ROLLBACK LOGIC ---


function Consolidate-Checkpoints {
    param(
        [string]$WorldName,
        [string]$WorldPath,
        [string]$BackupPath,
        [string]$MetadataPath
    )

    Clear-Host
    $metadata = Get-Metadata -Path $MetadataPath
    if ($metadata.Checkpoints.Count -eq 1) {
        Write-Host "Make more checkpoints." -ForegroundColor Red
        Write-Host "Press any key to return"
        [Console]::ReadKey() | Out-Null
        return
    }

    # --- SELECT CHECKPOINT ---
    # (Reuse your existing display logic which is good)
    $sorted = $metadata.Checkpoints | Sort-Object Timestamp 
    $maxIndex = $sorted.Count
    
    Write-Host "Checkpoint History for: $WorldName" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    
    # --- BUILD ACTIVE BRANCH ID LIST (For Color Coding) ---
    $activeBranchIds = @()
    $temp = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $metadata.CurrentCheckpointId } | Select-Object -First 1
    while ($temp) {
        $activeBranchIds += $temp.CheckpointId
        if ($temp.ParentId) {
            $temp = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $temp.ParentId } | Select-Object -First 1
        } else { break }
    }

    for ($i = 0; $i -lt $maxIndex; $i++) {
        $cp = $sorted[$i]
        $num = $i + 1
        
        $t = $cp.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
        
        # Size Calc logic (simplified for brevity, same as yours)
        $sizeMB = "0.00"
        if ($script:SizeCache.ContainsKey($cp.CheckpointId)) {
            $sizeMB = [math]::Round($script:SizeCache[$cp.CheckpointId] / 1MB, 2)
        } elseif (Test-Path (Join-Path $BackupPath $cp.CheckpointId)) {
            $sizeMB = [math]::Round([FastCopy]::GetDirectorySize((Join-Path $BackupPath $cp.CheckpointId)) / 1MB, 2)
        }
        
        # Color Logic
        if ($activeBranchIds -contains $cp.CheckpointId) {
            $col = if ($cp.Type -eq 'Full') { "White" } else { "White" }
            #$prefix = ""
        } else {
            $col = "DarkGray"
            #$prefix = "(!)"
        }

        $typeDisplay = if ($cp.Type -eq "Full") { "Full" } else { "Partial" }
        Write-Host "$prefix[$num] $t [$typeDisplay] - ${sizeMB}MB" -ForegroundColor $col
    }
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    
    $selection = Read-Host "Select # to consolidate UP TO (or 'q' to cancel)"
    if ($selection -eq 'q') { return }
    
    try {
        $index = [int]$selection - 1
        if ($index -lt 0 -or $index -ge $maxIndex) { throw "Invalid range" }
        $targetCP = $sorted[$index]
    } catch {
        Write-Warning "Invalid selection."
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
        return
    }

    # --- PREPARE CHAIN ---
    $chain = @()
    $current = $targetCP
    do {
        $chain += $current
        if ($current.Type -eq 'Full') { break }
        if ($current.ParentId) {
            $current = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $current.ParentId } | Select-Object -First 1
        } else { $current = $null }
    } while ($current)
    [array]::Reverse($chain)
    
    if ($chain.Count -eq 0) {
        Write-Warning "Error: Could not determine backup chain."
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
        return
    }

    # --- DISPLAY CONSOLIDATION PLAN (UPDATED VISUALS) ---
    Clear-Host
    Write-Host "`nConsolidation Plan for {$WorldName}:" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    
    foreach ($step in $chain) {
        # Find original menu index for consistent numbering
        $menuIndex = 0
        for ($k = 0; $k -lt $sorted.Count; $k++) {
            if ($sorted[$k].CheckpointId -eq $step.CheckpointId) {
                $menuIndex = $k + 1
                break
            }
        }
        $marker = if ($menuIndex -gt 0) { "[$menuIndex]" } else { "[?]" }
        
        $t = $step.Timestamp.ToString("MM/dd/yyyy HH:mm:ss")
        $action = if ($step.Type -eq 'Full') { "Merge Full" } else { "Merge Incremental" }
        
        Write-Host "$marker $action ($t)" -ForegroundColor Yellow
    }
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    
    $response = Read-Host "Type 'y' to confirm, 'q' to cancel"
    if ($response -ne 'y') { return }

    # --- OPTIONAL: ASK TO DELETE HISTORY ---
    Write-Host ""
    Write-Host "Do you want to CLEAR the existing backup history for this world after consolidation?" -ForegroundColor Red
    Write-Host "(This will delete all checkpoints and leave only the new Master Backup)" -ForegroundColor DarkGray
    $delResponse = Read-Host "Type 'y' to delete history, or Enter to keep it"
    
    $deleteChain = $false
    if ($delResponse -eq 'y') {
        Write-Host "WARNING: This is permanent!" -ForegroundColor Red
        $confirm = Read-Host "Type 'CONFIRM' to proceed with deletion"
        if ($confirm -eq 'CONFIRM') { $deleteChain = $true }
    }

    # --- EXECUTE CONSOLIDATION ---
    $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $masterName = "$($WorldName)_Master_$timestamp"
    $masterRoot = $script:Config.Masters

    $destPath = Join-Path $masterRoot $masterName

    if (-not (Test-Path $masterRoot)) { New-Item -ItemType Directory -Path $masterRoot -Force | Out-Null }
    
    Write-Host "`nConsolidating to: $masterName" -ForegroundColor Cyan
    
    $sourcePaths = @()
    foreach ($step in $chain) {
        $sourcePaths += Join-Path $BackupPath $step.CheckpointId
    }

    try {
        [FastCopy]::OptimizedRollback($sourcePaths, $destPath)
        Write-Host "Consolidation Complete!" -ForegroundColor Green
        
        # Update Caches
        $newSize = [FastCopy]::GetDirectorySize($destPath)
        $script:SizeCache["MasterBackup_$($masterName)"] = $newSize
        Save-SizeCache
        
            if ($deleteChain) {
        Write-Host "Clearing old backup history..." -ForegroundColor Yellow

        # Delete all checkpoint folders but keep the world backup folder itself
        Get-ChildItem -Path $BackupPath -Force |
            Where-Object { $_.Name -ne '_checkpoints.xml' } |
            Remove-Item -Recurse -Force

        # Reset metadata to empty, but keep the file
        $metadata.Checkpoints = @()
        $metadata.CurrentCheckpointId = $null
        $metadata.Generation = 1
        Save-Metadata -Data $metadata -Path $MetadataPath

        Write-Host "History cleared." -ForegroundColor Green
    }

        
    } catch {
        Write-Error "Consolidation failed: $_"
    }
    
    Update-SizeCacheForWorld -WorldPath $WorldPath -BackupPath $BackupPath
    Write-Host "`nPress any key to return..."
    [Console]::ReadKey() | Out-Null
}

function Start-RollbackMode {
    param([string]$WorldName)
    
    # Always called from World Details screen with a WorldName
    $worldPath = Join-Path $script:Config.SavesFolder $WorldName
    $backupPath = Join-Path $script:Config.CheckpointsFolder $WorldName
    $metaPath = Join-Path $backupPath "_checkpoints.xml"
    
    Show-RollbackScreen -WorldName $WorldName -WorldPath $worldPath -BackupPath $backupPath -MetadataPath $metaPath
}

function Show-RollbackScreen {
    param(
        [string]$WorldName,
        [string]$WorldPath,
        [string]$BackupPath,
        [string]$MetadataPath
    )
    
    # Ensure metadata path exists
    $metadata = if (Test-Path $MetadataPath) { Get-Metadata -Path $MetadataPath } else { [PSCustomObject]@{ Checkpoints = @() } }
    $sorted = @($metadata.Checkpoints | Sort-Object Timestamp)
    
    # --- SCAN FOR MASTER CHECKPOINTS (Once at start) ---
    $masterRoot = $script:Config.Masters

    $masterBackups = @()
    if (Test-Path $masterRoot) {
        $pattern = "$($WorldName)_Master_*"
        $folders = Get-ChildItem -Path $masterRoot -Directory -Filter $pattern
        $cacheUpdated = $false

        foreach ($f in $folders) {
            if ($f.Name -match "_(\d{8}-\d{6})$") {
                $tsStr = $matches[1]
                try {
                    $ts = [DateTime]::ParseExact($tsStr, "yyyyMMdd-HHmmss", $null)
                    $cacheKey = "MasterBackup_$($f.Name)"
                    
                    if ($script:SizeCache.ContainsKey($cacheKey)) {
                        $sizeBytes = $script:SizeCache[$cacheKey]
                    } else {
                        $sizeBytes = [FastCopy]::GetDirectorySize($f.FullName)
                        $script:SizeCache[$cacheKey] = $sizeBytes
                        $cacheUpdated = $true
                    }
                    
                    $masterBackups += [PSCustomObject]@{
                        Type         = "Master"
                        Timestamp    = $ts
                        TotalSize    = $sizeBytes
                        FullName     = $f.FullName
                        Name         = $f.Name
                        CheckpointId = "M_INTERNAL" # Dummy ID for logic compatibility
                    }
                } catch {}
            }
        }
        if ($cacheUpdated) { Save-SizeCache }
        $masterBackups = @($masterBackups | Sort-Object Timestamp -Descending)
    }

    $loadedCheckpointIds = @()

    while ($true) {
        Clear-Host
        Write-Host "Checkpoint History for: $WorldName" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        
        # 1. DISPLAY MASTER BACKUPS
        $mIndex = 1
        foreach ($mb in $masterBackups) {
            $t = $mb.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            $sizeMB = [math]::Round($mb.TotalSize / 1MB, 2)
            Write-Host "[M$mIndex] $t [CONSOLIDATED] - ${sizeMB}MB" -ForegroundColor Magenta
            $mIndex++
        }
        
        if ($masterBackups.Count -gt 0) {
             Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        }

        # 2. DISPLAY STANDARD CHECKPOINTS
        # Build Active Branch IDs
        $activeBranchIds = @()
        $temp = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $metadata.CurrentCheckpointId } | Select-Object -First 1
        while ($temp) {
            $activeBranchIds += $temp.CheckpointId
            if ($temp.ParentId) {
                $temp = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $temp.ParentId } | Select-Object -First 1
            } else { break }
        }

        for ($j=0; $j -lt $sorted.Count; $j++) {
            $cp = $sorted[$j]
            $idx = $j + 1
            
            $t = $cp.Timestamp.ToString("yyyy-MM-dd HH:mm:ss")
            $sizeMB = [math]::Round($cp.TotalSize / 1MB, 2)
            $typeDisplay = if ($cp.Type -eq "Full") { "Full" } else { "Partial" }
            $genDisplay = if ($cp.PSObject.Properties['Generation']) { " [Gen $($cp.Generation)]" } else { "" }
            $prefix = if ($loadedCheckpointIds -contains $cp.CheckpointId) { "*LOADED* " } else { "" }
            
            # Color Coding
            if ($activeBranchIds -contains $cp.CheckpointId) {
                $col = "White" 
            } else {
                $col = "DarkGray"
                #$prefix = "(!)" + $prefix
            }
            
            Write-Host "$prefix[$idx] $t [$typeDisplay]$genDisplay - ${sizeMB}MB" -ForegroundColor $col
        }

        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        Write-Host "[q] Go back" -ForegroundColor Yellow
        Write-Host ""
        
        $selection = Read-Host "Option"
        if ($selection -eq 'q') { return }

        # --- INPUT PARSING & CHAIN BUILDING ---
        $restoreChain = @()
        $isMasterRestore = $false
        $selectedTarget = $null

        # MASTER BACKUP SELECTION
        if ($selection -match "^M(\d+)$") {
            $idx = [int]$matches[1] - 1
            $mbArray = @($masterBackups)
            if ($idx -ge 0 -and $idx -lt $mbArray.Count) {
                $selectedTarget = $mbArray[$idx]

                $isMasterRestore = $true
                # Chain is just the master folder itself
                $restoreChain = @($selectedTarget)
            } else {
                Write-Warning "Invalid Master ID."
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null; continue
            }
        }
        # B) STANDARD CHECKPOINT SELECTION
        elseif ($selection -match "^\d+$") {
            try {
                $idx = [int]$selection - 1
                if ($idx -ge 0 -and $idx -lt $sorted.Count) {
                    $selectedTarget = $sorted[$idx]
                    
                    # Trace parents back to root
                    $current = $selectedTarget
                    do {
                        $restoreChain += $current
                        if ($current.Type -eq 'Full') { break }
                        if ($current.ParentId) {
                            $current = $metadata.Checkpoints | Where-Object { $_.CheckpointId -eq $current.ParentId } | Select-Object -First 1
                        } else { $current = $null }
                    } while ($current)
                    [array]::Reverse($restoreChain)

                    # Validate Chain
                    if ($restoreChain[0].Type -ne "Full") {
                        Write-Error "Broken Chain! Root backup missing."
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
                    }
                } else { throw "Out of range" }
            } catch {
                Write-Warning "Invalid selection."
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
            }
        }
        else {
            Write-Warning "Invalid input."
				Write-Host "Press any key to continue"
				[Console]::ReadKey() | Out-Null
        }

        # --- CONFIRMATION & PLAN DISPLAY ---
        Clear-Host
        Write-Host "Rollback Plan for ${WorldName}:" -ForegroundColor Cyan
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        
        if ($isMasterRestore) {
            Write-Host "[*] RESTORE CONSOLIDATED BACKUP ($($selectedTarget.Timestamp))" -ForegroundColor Magenta
        } else {
            foreach ($step in $restoreChain) {
                # Find original menu index for display consistency
                $menuIdx = 0
                for ($k=0; $k -lt $sorted.Count; $k++) {
                    if ($sorted[$k].CheckpointId -eq $step.CheckpointId) { $menuIdx = $k + 1; break }
                }
                $marker = if ($menuIdx -gt 0) { "[$menuIdx]" } else { "[?]" }
                Write-Host "$marker Apply $($step.Type) ($($step.Timestamp))" -ForegroundColor Yellow
            }
        }
        Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
        
        $confirm = Read-Host "Type 'y' to confirm, 'q' to cancel"
        if ($confirm -ne 'y') { continue }

        # --- EXECUTE RESTORE ---
        
        # 1. Backup Current World (Trash/Safety)
        $trashDest = Helper-BackupCurrentWorld -WorldName $WorldName -WorldPath $WorldPath
        if ($trashDest -eq 'CANCEL') { continue }

        # 2. Wipe & Restore
        New-Item -ItemType Directory -Path $WorldPath -Force | Out-Null
        
        if ($isMasterRestore) {
            Write-Host "Restoring Master Backup..." -ForegroundColor Cyan
            [FastCopy]::OptimizedRollback(@($selectedTarget.FullName), $WorldPath)
        } else {
            Write-Host "Restoring Checkpoint Chain..." -ForegroundColor Cyan
            $sourcePaths = $restoreChain | ForEach-Object { Join-Path $BackupPath $_.CheckpointId }
            [FastCopy]::OptimizedRollback($sourcePaths, $WorldPath)
        }

        # 3. Post-Restore Cleanup & Metadata Update
        Helper-CleanupTrash -TrashPath $trashDest
        Update-SizeCacheForWorld -WorldPath $WorldPath -BackupPath $BackupPath
        
        if (-not $isMasterRestore) {
            $loadedCheckpointIds = @($selectedTarget.CheckpointId)
            $metadata.CurrentCheckpointId = $selectedTarget.CheckpointId
            $metadata.Generation++
            Save-Metadata -Data $metadata -Path $MetadataPath
        }

        Write-Host "Rollback Complete!" -ForegroundColor Green
        Write-Host "Press any key to continue..."
        [Console]::ReadKey() | Out-Null
    }
}



# --- HELPER FUNCTIONS ---


function Helper-BackupCurrentWorld {
    param($WorldName, $WorldPath)
    
    $rollbackBackupsPath = Join-Path $PSSCRIPTROOT "RollBackups"
    if (-not (Test-Path $rollbackBackupsPath)) { New-Item -ItemType Directory -Path $rollbackBackupsPath -Force | Out-Null }
    
    $trashPath = Join-Path $rollbackBackupsPath ".Trash"
    if (-not (Test-Path $trashPath)) { $t = New-Item -ItemType Directory -Path $trashPath -Force; $t.Attributes = 'Hidden' }

    clear-host
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "Backup current state of '$WorldName' before rolling back?" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[y] Yes" -ForegroundColor White
    Write-Host "[n] No" -ForegroundColor White
    Write-Host "[q] Cancel" -ForegroundColor Yellow
    Write-Host ""
    
    $ans = Read-Host "Option"
    
    if ($ans -eq 'q') { return 'CANCEL' }
    
    if ($ans -eq 'y') {
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $dest = Join-Path $rollbackBackupsPath "${WorldName}_${ts}"
        Write-Host "Backing up to $dest..." -ForegroundColor DarkGray
        Move-Item -Path $WorldPath -Destination $dest -Force
        return $null # No trash needed
    } else {
        # Move to trash temporarily
        $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
        $trashDest = Join-Path $trashPath "${WorldName}_DELETED_${ts}"
        Move-Item -Path $WorldPath -Destination $trashDest -Force
        return $trashDest
    }
}

function Helper-CleanupTrash {
    param($TrashPath)
    if ($TrashPath) {
        Start-Job -ScriptBlock { 
            param($p) 
            Start-Sleep -Seconds 2 
            Remove-Item -Path $p -Recurse -Force -ErrorAction SilentlyContinue 
        } -ArgumentList $TrashPath | Out-Null
    }
}


# --- SCRIPT GO BRRRR ---
Load-CSharp
Load-Config
Load-SizeCache
Ensure-WorldSizeCache
while ($true) {
	# Set window title
	$Host.UI.RawUI.WindowTitle = "Better Auto-Save"
    clear-host
    Write-Host "Better Auto-Save" -ForegroundColor Cyan
	Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "[1] World Selection" -ForegroundColor White
    Write-Host "[2] Settings" -ForegroundColor White
    Write-Host "[q] Quit" -ForegroundColor Yellow
    Write-Host "--------------------------------------------------" -ForegroundColor DarkGray
    
    $c = Read-Host "Option"
    
    if ($c -eq 'q') { exit }
    if ($c -eq '2') { Start-SettingsMenu }
    if ($c -eq '1') { Show-WorldSelectionMenu }
}
