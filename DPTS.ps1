# Powershell 5.1 script that implements per-application touchpad sensitivity settings.
# Requires Windows 11 Build 26027 or later

##---CREDIT---# ##---CREDIT---# ##---CREDIT---# ##---CREDIT---# 

#	This script wouldn't be possible without David Gardiner. Check out his blog that laid the foundations for all of this!
#	https://david.gardiner.net.au/2025/04/touchpad-settings

##---CREDIT---# ##---CREDIT---# ##---CREDIT---# ##---CREDIT---# 

param(
    [switch]$Settings
)

#region Configuration
$script:SettingsPath = Join-Path $PSScriptRoot "DPTSettings.json"
$script:CheckInterval = 1
#endregion

#region C# Helpers
$touchpadSource = @'
using System;
using System.Collections.Specialized;
using System.Runtime.InteropServices;

public static class TouchpadSensitivityHelper
{
    [DllImport("USER32.dll", ExactSpelling = true, EntryPoint = "SystemParametersInfoW", SetLastError = true)]
    internal static extern unsafe bool SystemParametersInfo(uint uiAction, uint uiParam, void* pvParam, uint fWinIni);

    public static void SetSensitivity(int sensitivityLevel)
    {
        const uint SPI_GETTOUCHPADPARAMETERS = 0x00AE;
        const uint SPI_SETTOUCHPADPARAMETERS = 0x00AF;
        const uint SPIF_UPDATEINIFILE = 0x01;
        const uint SPIF_SENDCHANGE = 0x02;

        unsafe
        {
            TOUCHPAD_PARAMETERS param;
            param.VersionNumber = 1;
            var size = (uint)Marshal.SizeOf(typeof(TOUCHPAD_PARAMETERS));
            
            var result = SystemParametersInfo(SPI_GETTOUCHPADPARAMETERS, size, &param, 0);
            
            if (!result)
            {
                throw new InvalidOperationException(string.Format("Failed to get touchpad parameters. Error: {0}", Marshal.GetLastWin32Error()));
            }

            param.SensitivityLevel = (TOUCHPAD_SENSITIVITY_LEVEL)sensitivityLevel;

            result = SystemParametersInfo(SPI_SETTOUCHPADPARAMETERS, size, &param, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);
            
            if (!result)
            {
                throw new InvalidOperationException(string.Format("Failed to set touchpad parameters. Error: {0}", Marshal.GetLastWin32Error()));
            }
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOUCHPAD_PARAMETERS
    {
        public uint VersionNumber;
        public uint MaxSupportedContacts;
        public LEGACY_TOUCHPAD_FEATURES LegacyTouchpadFeatures;
        private BitVector32 First;
        
        public bool TouchpadPresent
        {
            get { return First[1]; }
            set { First[1] = value; }
        }
        
        public bool LegacyTouchpadPresent
        {
            get { return First[2]; }
            set { First[2] = value; }
        }
        
        public bool ExternalMousePresent
        {
            get { return First[4]; }
            set { First[4] = value; }
        }
        
        public bool FeedbackSupported
        {
            get { return First[8]; }
            set { First[8] = value; }
        }
        
        public bool ClickForceSupported
        {
            get { return First[16]; }
            set { First[16] = value; }
        }
        
        private BitVector32 Second;
        
        public bool FeedbackEnabled
        {
            get { return Second[1]; }
            set { Second[1] = value; }
        }
        
        public bool TapEnabled
        {
            get { return Second[2]; }
            set { Second[2] = value; }
        }
        
        public bool TapAndDragEnabled
        {
            get { return Second[4]; }
            set { Second[4] = value; }
        }
        
        public bool TwoFingerTapEnabled
        {
            get { return Second[8]; }
            set { Second[8] = value; }
        }
        
        public bool RightClickZoneEnabled
        {
            get { return Second[16]; }
            set { Second[16] = value; }
        }
        
        public bool MouseAccelSettingHonored
        {
            get { return Second[32]; }
            set { Second[32] = value; }
        }
        
        public bool PanEnabled
        {
            get { return Second[64]; }
            set { Second[64] = value; }
        }
        
        public bool ZoomEnabled
        {
            get { return Second[128]; }
            set { Second[128] = value; }
        }
        
        public bool ScrollDirectionReversed
        {
            get { return Second[256]; }
            set { Second[256] = value; }
        }
        
        public TOUCHPAD_SENSITIVITY_LEVEL SensitivityLevel;
        public uint CursorSpeed;
        public uint FeedbackIntensity;
        public uint ClickForceSensitivity;
        public uint RightClickZoneWidth;
        public uint RightClickZoneHeight;
    }

    public enum LEGACY_TOUCHPAD_FEATURES : uint
    {
        LEGACY_TOUCHPAD_FEATURES_NONE = 0,
        LEGACY_TOUCHPAD_FEATURES_SYS_MOUSE_PRESENT = 1,
        LEGACY_TOUCHPAD_FEATURES_HID_MOUSE_PRESENT = 2
    }

    public enum TOUCHPAD_SENSITIVITY_LEVEL : uint
    {
        TOUCHPAD_SENSITIVITY_LEVEL_MOST_SENSITIVE = 0,
        TOUCHPAD_SENSITIVITY_LEVEL_HIGH_SENSITIVITY = 1,
        TOUCHPAD_SENSITIVITY_LEVEL_MEDIUM_SENSITIVITY = 2,
        TOUCHPAD_SENSITIVITY_LEVEL_LOW_SENSITIVITY = 3,
        TOUCHPAD_SENSITIVITY_LEVEL_LEAST_SENSITIVE = 4
    }
}
'@

$windowSource = @'
using System;
using System.Runtime.InteropServices;

public class WindowDetector
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    
    [DllImport("user32.dll")]
    public static extern int GetWindowThreadProcessId(IntPtr hWnd, out int processId);
}
'@

if (-not ([System.Management.Automation.PSTypeName]'TouchpadSensitivityHelper').Type) {
    try {
        $compilerParams = New-Object System.CodeDom.Compiler.CompilerParameters
        $compilerParams.CompilerOptions = "/unsafe"
        $compilerParams.GenerateInMemory = $true
        $compilerParams.ReferencedAssemblies.Add("System.dll") | Out-Null
        
        Add-Type -TypeDefinition $touchpadSource -Language CSharp -CompilerParameters $compilerParams
        Add-Type -TypeDefinition $windowSource -Language CSharp
    }
    catch {
        Write-Error "Failed to compile C# code: $_"
        exit 1
    }
}
#endregion

#region Helper Functions

function Load-Settings {
    if (Test-Path $script:SettingsPath) {
        try {
            $settings = Get-Content $script:SettingsPath -Raw | ConvertFrom-Json
            $appSettings = @{}
            foreach ($property in $settings.PSObject.Properties) {
                $appSettings[$property.Name] = $property.Value
            }
            return $appSettings
        }
        catch {
            Write-Warning "Failed to load settings from $script:SettingsPath. Using defaults."
        }
    }
    
    return @{
        "default" = 2
    }
}

function Save-Settings {
    param($appSettings)
    
    try {
        $appSettings | ConvertTo-Json | Set-Content $script:SettingsPath
        Write-Host "`nSettings saved to: $script:SettingsPath" -ForegroundColor White
    }
    catch {
        Write-Error "Failed to save settings: $_"
    }
}

function Get-SensitivityName {
    param($level)
    
    switch ($level) {
        0 { "Most Sensitive" }
        1 { "High Sensitivity" }
        2 { "Medium Sensitivity" }
        3 { "Low Sensitivity" }
    }
}

function Get-ValidatedNumericInput {
    param($prompt, $minValue, $maxValue)
    
    while ($true) {
        $input = Read-Host $prompt
        
        if ($input -match '^\d+$') {
            $number = [int]$input
            if ($number -ge $minValue -and $number -le $maxValue) {
                return $number
            }
        }
        
        Write-Host "Invalid input. Please enter a number between $minValue and $maxValue." -ForegroundColor Red
    }
}

function Show-SensitivityMenu {
    Write-Host "0. Most Sensitive"
    Write-Host "1. High Sensitivity"
    Write-Host "2. Medium Sensitivity"
    Write-Host "3. Low Sensitivity"
    Write-Host ""
}

#endregion

#region Menu Functions

function Invoke-AddApplication {
    param($appSettings)
    
    Write-Host "`nScanning for open windows..." -ForegroundColor Cyan
    $processes = Get-Process | Where-Object { $_.MainWindowTitle -ne "" } | 
        Select-Object Name, MainWindowTitle, Id | 
        Sort-Object Name -Unique
    
    if ($processes.Count -eq 0) {
        Write-Host "No windowed applications found. Please open some applications first." -ForegroundColor Red
        return
    }
    
    Write-Host "`n--- Open Applications ---" -ForegroundColor Yellow
    for ($i = 0; $i -lt $processes.Count; $i++) {
        $proc = $processes[$i]
        $currentSetting = if ($appSettings.ContainsKey($proc.Name)) { 
            " [Current: $(Get-SensitivityName $appSettings[$proc.Name])]" 
        } else { 
            " [Not configured]" 
        }
        Write-Host "$($i + 1). $($proc.Name) - $($proc.MainWindowTitle)$currentSetting"
    }
    Write-Host "0. Cancel"
    Write-Host ""
    
    $appChoice = Get-ValidatedNumericInput "Select an application number" 0 $processes.Count
    
    if ($appChoice -eq 0) { return }
    
    $selectedApp = $processes[$appChoice - 1].Name
    
    Write-Host "`n--- Select Sensitivity for '$selectedApp' ---" -ForegroundColor Yellow
    Show-SensitivityMenu
    
    $sensChoice = Get-ValidatedNumericInput "Select sensitivity level (0-3)" 0 3
    
    $appSettings[$selectedApp] = $sensChoice
    Save-Settings $appSettings
    Write-Host "`n'$selectedApp' set to: $(Get-SensitivityName $sensChoice)" -ForegroundColor Green
}

function Invoke-ViewSettings {
    param($appSettings)
    
    Write-Host "`n--- Current Settings ---" -ForegroundColor Yellow
    
    $apps = $appSettings.GetEnumerator() | Where-Object { $_.Key -ne "default" } | Sort-Object Key
    
    if ($apps.Count -eq 0) {
        Write-Host "No applications configured." -ForegroundColor Cyan
    }
    else {
        foreach ($app in $apps) {
            Write-Host "$($app.Key): $(Get-SensitivityName $app.Value)" -ForegroundColor Cyan
        }
    }
    
    Write-Host "`nDefault: $(Get-SensitivityName $appSettings['default'])" -ForegroundColor White
}

function Invoke-RemoveApplication {
    param($appSettings)
    
    Write-Host "`n--- Configured Applications ---" -ForegroundColor Yellow
    $apps = $appSettings.GetEnumerator() | Where-Object { $_.Key -ne "default" } | Sort-Object Key
    
    if ($apps.Count -eq 0) {
        Write-Host "No applications configured." -ForegroundColor Red
        return
    }
    
    $appList = @($apps)
    for ($i = 0; $i -lt $appList.Count; $i++) {
        Write-Host "$($i + 1). $($appList[$i].Key) - $(Get-SensitivityName $appList[$i].Value)"
    }
    Write-Host "0. Cancel"
    Write-Host ""
    
    $removeChoice = Get-ValidatedNumericInput "Select application to remove" 0 $appList.Count
    
    if ($removeChoice -eq 0) { return }
    
    $appToRemove = $appList[$removeChoice - 1].Key
    $appSettings.Remove($appToRemove)
    Save-Settings $appSettings
    Write-Host "`n'$appToRemove' removed from settings." -ForegroundColor Green
}

function Invoke-SetDefaultSensitivity {
    param($appSettings)
    
    Write-Host "`n--- Set Default Sensitivity ---" -ForegroundColor Yellow
    Write-Host "Current default: $(Get-SensitivityName $appSettings['default'])"
    Write-Host ""
    
    Show-SensitivityMenu
    
    $defaultChoice = Get-ValidatedNumericInput "Select default sensitivity level (0-3)" 0 3
    
    $appSettings["default"] = $defaultChoice
    Save-Settings $appSettings
    Write-Host "`nDefault sensitivity set to: $(Get-SensitivityName $defaultChoice)" -ForegroundColor Green
}

function Start-SettingsMode {
    Clear-Host
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host "    Script Configuration" -ForegroundColor Cyan
    Write-Host "====================================" -ForegroundColor Cyan
    Write-Host ""
    
    $appSettings = Load-Settings
    
    while ($true) {
        Write-Host "`n--- Main Menu ---" -ForegroundColor Yellow
        Write-Host "1. Add/Modify application settings"
        Write-Host "2. View current settings"
        Write-Host "3. Remove an application"
        Write-Host "4. Set default sensitivity"
        Write-Host "5. Exit"
        Write-Host ""
        
        $choice = Read-Host "Select an option (1-5)"
        
        switch ($choice) {
            "1" { Invoke-AddApplication $appSettings }
            "2" { Invoke-ViewSettings $appSettings }
            "3" { Invoke-RemoveApplication $appSettings }
            "4" { Invoke-SetDefaultSensitivity $appSettings }
            "5" { 
                Write-Host "`nExiting configuration mode..." -ForegroundColor Green
                exit 0 
            }
            default { 
                Write-Host "Invalid option. Please select 1-5." -ForegroundColor Red 
            }
        }
    }
}

#endregion

#region Monitoring Mode

function Start-MonitoringMode {
	Clear-Host
    Write-Host "Run script with -settings for initial setup" -ForegroundColor White
    Write-Host "Press Ctrl+C to stop.`n" -ForegroundColor White
    
    $appSettings = Load-Settings
    $lastProcessName = ""
    $lastSensitivity = -1
    
    Write-Host "===== Script Started Successfully =====" -ForegroundColor Cyan
    
    while ($true) {
        try {
            $hwnd = [WindowDetector]::GetForegroundWindow()
            $processId = 0
            [WindowDetector]::GetWindowThreadProcessId($hwnd, [ref]$processId) | Out-Null
            
            $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
            
            if ($process -and $process.Name -ne $lastProcessName) {
                $processName = $process.Name
                
                if ($appSettings.ContainsKey($processName)) {
                    $sensitivity = $appSettings[$processName]
                    $displayName = $processName
                }
                else {
                    $sensitivity = $appSettings["default"]
                    $displayName = "Default"
                }
                
                if ($sensitivity -ne $lastSensitivity) {
                    [TouchpadSensitivityHelper]::SetSensitivity($sensitivity)
                    
                    $sensitivityName = Get-SensitivityName $sensitivity
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $displayName | $sensitivityName" -ForegroundColor White
                    
                    $lastSensitivity = $sensitivity
                }
                
                $lastProcessName = $processName
            }
        }
        catch {
            Write-Warning "Error detecting window: $_"
        }
        
        Start-Sleep -Seconds $script:CheckInterval
    }
}

#endregion

#region Main Execution

if ($Settings) {
    Start-SettingsMode
}
else {
    Start-MonitoringMode
}

#endregion
