<# 
.SYNOPSIS
    CrowdDICOM — Configuration Wizard
.DESCRIPTION
    Interactive PowerShell wizard that configures CrowdDICOM (Orthanc) for 
    store-and-forward operation with disk space management.
    Run this after the installer has placed the files.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ─── CrowdDICOM Design Tokens ──────────────────────────────────────
$BG = [System.Drawing.Color]::FromArgb(18, 14, 30)       # #120E1E
$Surface = [System.Drawing.Color]::FromArgb(30, 24, 50)       # #1E1832
$Surface2 = [System.Drawing.Color]::FromArgb(42, 34, 68)       # #2A2244
$Purple = [System.Drawing.Color]::FromArgb(91, 61, 143)      # #5B3D8F
$PurpleLt = [System.Drawing.Color]::FromArgb(123, 91, 175)     # #7B5BAF
$Blue = [System.Drawing.Color]::FromArgb(43, 124, 229)     # #2B7CE5
$Teal = [System.Drawing.Color]::FromArgb(44, 197, 160)     # #2CC5A0
$LightBlue = [System.Drawing.Color]::FromArgb(135, 206, 235)    # #87CEEB
$TextClr = [System.Drawing.Color]::FromArgb(232, 230, 240)    # #E8E6F0
$TextDim = [System.Drawing.Color]::FromArgb(160, 155, 180)    # #A09BB4
$InputBg = [System.Drawing.Color]::FromArgb(22, 18, 36)       # #161224
$Border = [System.Drawing.Color]::FromArgb(62, 50, 90)       # #3E325A
$Success = [System.Drawing.Color]::FromArgb(44, 197, 160)     # #2CC5A0

$FontName = "Segoe UI"

# ─── Helper: Create styled label ──────────────────────────────────
function New-StyledLabel {
   param($Text, $X, $Y, $Width, $Height, $Size = 10, $Bold = $false, $Color = $TextClr)
   $lbl = New-Object System.Windows.Forms.Label
   $lbl.Text = $Text
   $lbl.Location = [System.Drawing.Point]::new($X, $Y)
   $lbl.Size = [System.Drawing.Size]::new($Width, $Height)
   $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
   $lbl.Font = New-Object System.Drawing.Font($FontName, $Size, $style)
   $lbl.ForeColor = $Color
   $lbl.BackColor = $BG
   return $lbl
}

# ─── Helper: Create styled textbox ────────────────────────────────
function New-StyledTextBox {
   param($Text, $X, $Y, $Width, $IsPassword = $false)
   $tb = New-Object System.Windows.Forms.TextBox
   $tb.Text = $Text
   $tb.Location = [System.Drawing.Point]::new($X, $Y)
   $tb.Size = [System.Drawing.Size]::new($Width, 30)
   $tb.Font = New-Object System.Drawing.Font($FontName, 11)
   $tb.BackColor = $InputBg
   $tb.ForeColor = $TextClr
   $tb.BorderStyle = "FixedSingle"
   if ($IsPassword) { $tb.UseSystemPasswordChar = $true }
   return $tb
}

# ─── Helper: Create styled button ─────────────────────────────────
function New-StyledButton {
   param($Text, $X, $Y, $Width = 120, $Height = 36, $Primary = $false)
   $btn = New-Object System.Windows.Forms.Button
   $btn.Text = $Text
   $btn.Location = [System.Drawing.Point]::new($X, $Y)
   $btn.Size = [System.Drawing.Size]::new($Width, $Height)
   $btn.Font = New-Object System.Drawing.Font($FontName, 10, [System.Drawing.FontStyle]::Bold)
   $btn.FlatStyle = "Flat"
   $btn.FlatAppearance.BorderSize = 0
   $btn.Cursor = "Hand"
   if ($Primary) {
      $btn.BackColor = $Purple
      $btn.ForeColor = [System.Drawing.Color]::White
   }
   else {
      $btn.BackColor = $Surface2
      $btn.ForeColor = $TextClr
   }
   return $btn
}

# ═══════════════════════════════════════════════════════════════════
#  MAIN FORM
# ═══════════════════════════════════════════════════════════════════

$form = New-Object System.Windows.Forms.Form
$form.Text = "CrowdDICOM — Configuration"
$form.Size = [System.Drawing.Size]::new(620, 580)
$form.StartPosition = "CenterScreen"
$form.BackColor = $BG
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font($FontName, 10)

# ─── Header ───────────────────────────────────────────────────────
$header = New-Object System.Windows.Forms.Panel
$header.Size = [System.Drawing.Size]::new(620, 70)
$header.Location = [System.Drawing.Point]::new(0, 0)
$header.BackColor = $Surface

$logoLbl = New-StyledLabel "◈  CrowdDICOM Configuration" 20 15 560 40 16 $true
$logoLbl.ForeColor = $LightBlue
$logoLbl.BackColor = $Surface
$header.Controls.Add($logoLbl)

$subtitleLbl = New-StyledLabel "Store-and-Forward DICOM Gateway" 42 42 400 20 9 $false $TextDim
$subtitleLbl.BackColor = $Surface
$header.Controls.Add($subtitleLbl)
$form.Controls.Add($header)

# ─── Local Server Section ─────────────────────────────────────────
$sectionLocal = New-StyledLabel "LOCAL DICOM SERVER" 30 85 300 20 9 $true $Teal
$form.Controls.Add($sectionLocal)

$form.Controls.Add((New-StyledLabel "AE Title" 30 115 200 20))
$tbAET = New-StyledTextBox "STORE_FWD" 30 138 250
$form.Controls.Add($tbAET)

$form.Controls.Add((New-StyledLabel "DICOM Port" 310 115 120 20))
$tbDicomPort = New-StyledTextBox "4242" 310 138 120
$form.Controls.Add($tbDicomPort)

$form.Controls.Add((New-StyledLabel "HTTP Port (Web UI)" 460 115 130 20))
$tbHttpPort = New-StyledTextBox "8042" 460 138 120
$form.Controls.Add($tbHttpPort)

# ─── Destination PACS Section ─────────────────────────────────────
$sectionDest = New-StyledLabel "DESTINATION PACS" 30 185 300 20 9 $true $Blue
$form.Controls.Add($sectionDest)

$form.Controls.Add((New-StyledLabel "AE Title" 30 215 200 20))
$tbDestAET = New-StyledTextBox "" 30 238 200
$form.Controls.Add($tbDestAET)

$form.Controls.Add((New-StyledLabel "Host / IP Address" 260 215 200 20))
$tbDestHost = New-StyledTextBox "" 260 238 200
$form.Controls.Add($tbDestHost)

$form.Controls.Add((New-StyledLabel "Port" 490 215 90 20))
$tbDestPort = New-StyledTextBox "4242" 490 238 90
$form.Controls.Add($tbDestPort)

# ─── Credentials Section ─────────────────────────────────────────
$sectionCred = New-StyledLabel "WEB UI CREDENTIALS" 30 285 300 20 9 $true $Purple
$form.Controls.Add($sectionCred)

$form.Controls.Add((New-StyledLabel "Username" 30 315 200 20))
$tbUser = New-StyledTextBox "admin" 30 338 200
$form.Controls.Add($tbUser)

$form.Controls.Add((New-StyledLabel "Password" 260 315 200 20))
$tbPass = New-StyledTextBox "orthanc" 260 338 200 $true
$form.Controls.Add($tbPass)

# ─── Disk Management Section ─────────────────────────────────────
$sectionDisk = New-StyledLabel "DISK MANAGEMENT" 30 385 300 20 9 $true $LightBlue
$form.Controls.Add($sectionDisk)

$form.Controls.Add((New-StyledLabel "Cleanup when disk usage exceeds:" 30 415 300 20))
$tbThreshold = New-StyledTextBox "70" 340 412 50
$form.Controls.Add($tbThreshold)
$form.Controls.Add((New-StyledLabel "%" 395 415 30 20))

$form.Controls.Add((New-StyledLabel "Oldest studies are deleted first to free space." 30 445 500 20 9 $false $TextDim))

# ─── Buttons ─────────────────────────────────────────────────────
$btnCancel = New-StyledButton "Cancel" 350 490 110 38
$btnCancel.Add_Click({ $form.Close() })
$form.Controls.Add($btnCancel)

$btnInstall = New-StyledButton "▶  Apply && Start" 470 490 130 38 $true
$form.Controls.Add($btnInstall)

# ─── Install Handler ─────────────────────────────────────────────
$btnInstall.Add_Click({
      # Validate
      if ([string]::IsNullOrWhiteSpace($tbAET.Text)) {
         [System.Windows.Forms.MessageBox]::Show("Please enter a local AE Title.", "Validation", "OK", "Warning")
         return
      }
      if ([string]::IsNullOrWhiteSpace($tbDestAET.Text)) {
         [System.Windows.Forms.MessageBox]::Show("Please enter the destination AE Title.", "Validation", "OK", "Warning")
         return
      }
      if ([string]::IsNullOrWhiteSpace($tbDestHost.Text)) {
         [System.Windows.Forms.MessageBox]::Show("Please enter the destination host/IP.", "Validation", "OK", "Warning")
         return
      }

      $installDir = Split-Path -Parent $PSScriptRoot
      if (-not $installDir) { $installDir = $PSScriptRoot }

      $configDir = Join-Path $installDir "Configuration"
      $luaDir = Join-Path $installDir "Lua"
      $logsDir = Join-Path $installDir "Logs"
      $storageDir = Join-Path $installDir "OrthancStorage"

      # Create directories
      @($configDir, $luaDir, $logsDir, $storageDir) | ForEach-Object {
         if (-not (Test-Path $_)) { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
      }

      # ── Generate orthanc.json ────────────────────────────────────
      $config = @{
         Name                    = "CrowdDICOM"
         StorageDirectory        = $storageDir -replace '\\', '/'
         IndexDirectory          = $storageDir -replace '\\', '/'
         DicomAet                = $tbAET.Text.Trim()
         DicomPort               = [int]$tbDicomPort.Text
         HttpPort                = [int]$tbHttpPort.Text
         RemoteAccessAllowed     = $true
         AuthenticationEnabled   = $true
         RegisteredUsers         = @{ $tbUser.Text = $tbPass.Text }
         DicomModalities         = @{
            destination = @{
               AET  = $tbDestAET.Text.Trim()
               Host = $tbDestHost.Text.Trim()
               Port = [int]$tbDestPort.Text
            }
         }
         LuaScripts              = @( (Join-Path $luaDir "store-and-forward.lua") -replace '\\', '/' )
         OrthancExplorer2        = @{
            IsDefaultOrthancUI = $true
            Theme              = "dark"
            UiOptions          = @{
               EnableLinkToLegacyUi = $false
            }
         }
         LuaHeartBeatPeriod      = 60
         ExecuteLuaEnabled       = $true
         DicomAlwaysAllowStore   = $true
         UnknownSopClassAccepted = $true
         StableAge               = 5
         SaveJobs                = $true
         OverwriteInstances      = $true
         JobsHistorySize         = 500
         ConcurrentJobs          = 2
         StorageCompression      = $false
         MaximumStorageSize      = 0
         DicomCheckCalledAet     = $false
         DeidentifyLogs          = $false
      }

      $configJson = $config | ConvertTo-Json -Depth 4
      Set-Content -Path (Join-Path $configDir "orthanc.json") -Value $configJson -Encoding UTF8

      # ── Generate Lua script ──────────────────────────────────────
      $driveLetter = $storageDir.Substring(0, 1)
      $threshold = $tbThreshold.Text

      $luaScript = @"
-- CrowdDICOM Store-and-Forward with Disk Space Management
-- Auto-generated by the CrowdDICOM configuration wizard

local DISK_USAGE_THRESHOLD = $threshold
local DESTINATION_MODALITY = "destination"

function Initialize()
   print("CrowdDICOM: Store-and-Forward starting, threshold: " .. DISK_USAGE_THRESHOLD .. "%")
   local allInstances = ParseJson(RestApiGet("/instances"))
   if #allInstances > 0 then
      print("Re-queuing " .. #allInstances .. " instance(s) found at startup")
      for i, instanceId in pairs(allInstances) do
         ForwardInstance(instanceId)
      end
   end
end

function ForwardInstance(instanceId)
   local payload = {}
   payload["Resources"] = { instanceId }
   payload["Asynchronous"] = true
   payload["Priority"] = 1
   local result = RestApiPost("/modalities/" .. DESTINATION_MODALITY .. "/store", DumpJson(payload, false))
   local job = ParseJson(result)
   print("[FORWARD] Job " .. job["ID"] .. " for instance " .. instanceId)
end

function OnStoredInstance(instanceId, tags, metadata, origin)
   if origin and origin["RequestOrigin"] == "Lua" then return end
   local pn = tags["PatientName"] or "Unknown"
   local mod = tags["Modality"] or "?"
   print("[RECEIVED] " .. instanceId .. " | " .. pn .. " | " .. mod)
   ForwardInstance(instanceId)
end

function OnJobFailure(jobId)
   print("[JOB FAIL] " .. jobId)
   local job = ParseJson(RestApiGet("/jobs/" .. jobId))
   if job["Type"] == "DicomModalityStore" then
      if job["ErrorCode"] == 9 then
         print("[RETRY] Resubmitting job " .. jobId)
         RestApiPost("/jobs/" .. jobId .. "/resubmit", "")
      end
   end
end

function OnJobSuccess(jobId)
   local job = ParseJson(RestApiGet("/jobs/" .. jobId))
   if job["Type"] == "DicomModalityStore" then
      local pr = job["Content"]["ParentResources"]
      if pr and #pr > 0 then
         print("[FORWARDED] " .. pr[1])
      end
   end
end

function OnHeartBeat()
   CleanupDiskSpace()
end

function GetDiskUsagePercent()
   local handle = io.popen('wmic logicaldisk where "DeviceID=''$driveLetter'':'' " get FreeSpace,Size /format:csv 2>NUL')
   if handle then
      local output = handle:read("*a")
      handle:close()
      for line in output:gmatch("[^\r\n]+") do
         local node, free, size = line:match("([^,]+),([^,]+),([^,]+)")
         if tonumber(free) and tonumber(size) then
            local used = tonumber(size) - tonumber(free)
            return math.floor((used / tonumber(size)) * 100)
         end
      end
   end
   return 0
end

function CleanupDiskSpace()
   local usage = GetDiskUsagePercent()
   if usage < DISK_USAGE_THRESHOLD then return end
   print("[CLEANUP] Disk at " .. usage .. "%, deleting oldest study")
   local ok, oldest = pcall(function()
      return ParseJson(RestApiPost("/tools/find", DumpJson({
         Level = "Study", Expand = true, Query = {},
         OrderBy = { { Type = "Metadata", Key = "LastUpdate", Direction = "ASC" } },
         Limit = 1
      }, false)))
   end)
   if not ok or not oldest or #oldest == 0 then
      local all = ParseJson(RestApiGet("/studies"))
      if #all > 0 then RestApiDelete("/studies/" .. all[1]) end
      return
   end
   RestApiDelete("/studies/" .. oldest[1]["ID"])
end
"@

      Set-Content -Path (Join-Path $luaDir "store-and-forward.lua") -Value $luaScript -Encoding UTF8

      # ── Summary ──────────────────────────────────────────────────
      $msg = @"
CrowdDICOM configuration saved!

  Local AE Title:    $($tbAET.Text)
  DICOM Port:        $($tbDicomPort.Text)
  HTTP Port:         $($tbHttpPort.Text)
  Destination:       $($tbDestAET.Text)@$($tbDestHost.Text):$($tbDestPort.Text)
  Disk Threshold:    $($tbThreshold.Text)%
  Config File:       $(Join-Path $configDir "orthanc.json")

The CrowdDICOM service will now be restarted with the new configuration.
"@

      [System.Windows.Forms.MessageBox]::Show($msg, "CrowdDICOM — Configuration Complete", "OK", "Information")

      # Try to restart the Orthanc service
      try {
         $svc = Get-Service -Name "Orthanc*" -ErrorAction SilentlyContinue | Select-Object -First 1
         if ($svc) {
            Restart-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
         }
      }
      catch { }

      $form.Close()
   })

# ─── Show form ────────────────────────────────────────────────────
[void]$form.ShowDialog()
