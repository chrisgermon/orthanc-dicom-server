; ═══════════════════════════════════════════════════════════════
; Orthanc Store-and-Forward — Inno Setup Installer Script
; ═══════════════════════════════════════════════════════════════
;
; Bundles:
;   - The official Orthanc Windows 64-bit installer (runs silently)
;   - Store-and-forward Lua script
;   - Configuration wizard pages
;   - Helper batch scripts
;
; After install, Orthanc runs as a Windows service automatically.
;
; Build:  docker run --rm -v $(pwd):/work amake/innosetup setup.iss
; ═══════════════════════════════════════════════════════════════

#define MyAppName "CrowdDICOM"
#define MyAppVersion "1.0.0"
#define OrthancInstallDir "{autopf}\Orthanc Server"

[Setup]
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=CrowdDICOM
AppPublisherURL=https://www.orthanc-server.com/
DefaultDirName={#OrthancInstallDir}
DefaultGroupName=CrowdDICOM
OutputDir=output
OutputBaseFilename=CrowdDICOM-Setup
SetupIconFile=resources\orthanc.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#MyAppName}
DisableWelcomePage=no
DisableDirPage=yes
LicenseFile=resources\license.txt
WizardImageFile=resources\wizard.bmp
WizardSmallImageFile=resources\wizard_small.bmp

[Types]
Name: "full"; Description: "Full installation (Orthanc + Store-and-Forward config)"
Name: "configonly"; Description: "Configuration only (Orthanc already installed)"

[Components]
Name: "orthanc"; Description: "Orthanc DICOM Server (official build)"; Types: full
Name: "storeforward"; Description: "Store-and-Forward configuration (required)"; Types: full configonly; Flags: fixed

[Dirs]
Name: "{app}"
Name: "{app}\Configuration"
Name: "{app}\Lua"
Name: "{app}\Logs"

[Files]
; The official Orthanc Windows installer
Source: "resources\OrthancInstaller-Win64.exe"; DestDir: "{tmp}"; Components: orthanc; Flags: ignoreversion deleteafterinstall

; Helper batch files
Source: "scripts\start-orthanc.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "scripts\stop-service.bat"; DestDir: "{app}"; Flags: ignoreversion
Source: "scripts\open-web-ui.bat"; DestDir: "{app}"; Flags: ignoreversion

; PowerShell reconfigure wizard
Source: "scripts\Configure.ps1"; DestDir: "{app}\Scripts"; Flags: ignoreversion
Source: "scripts\configure.bat"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\Open Web UI"; Filename: "{app}\open-web-ui.bat"; IconFilename: "{app}\Orthanc.ico"
Name: "{group}\Start Orthanc"; Filename: "{app}\start-orthanc.bat"
Name: "{group}\Stop Service"; Filename: "{app}\stop-service.bat"
Name: "{group}\Reconfigure"; Filename: "{app}\configure.bat"
Name: "{group}\Uninstall {#MyAppName}"; Filename: "{uninstallexe}"

[Code]

// ── Variables for custom wizard pages ───────────────────────────
var
  DicomPage: TInputQueryWizardPage;
  DestPage: TInputQueryWizardPage;
  CredPage: TInputQueryWizardPage;

// ── Create custom wizard pages ──────────────────────────────────
procedure InitializeWizard;
begin
  // Page 1: Local DICOM settings
  DicomPage := CreateInputQueryPage(wpSelectComponents,
    'Local DICOM Server',
    'Configure the local CrowdDICOM server settings',
    'Enter the AE Title and ports for this store-and-forward server.');
  DicomPage.Add('AE Title:', False);
  DicomPage.Add('DICOM Port:', False);
  DicomPage.Add('HTTP Port (Web UI):', False);
  DicomPage.Values[0] := 'STORE_FWD';
  DicomPage.Values[1] := '4242';
  DicomPage.Values[2] := '8042';

  // Page 2: Destination PACS + threshold
  DestPage := CreateInputQueryPage(DicomPage.ID,
    'Destination PACS',
    'Configure the forwarding destination',
    'Enter the connection details for the PACS that images will be forwarded to.');
  DestPage.Add('Destination AE Title:', False);
  DestPage.Add('Destination Host / IP:', False);
  DestPage.Add('Destination DICOM Port:', False);
  DestPage.Add('Disk Cleanup Threshold (%):', False);
  DestPage.Values[2] := '4242';
  DestPage.Values[3] := '70';

  // Page 3: Credentials
  CredPage := CreateInputQueryPage(DestPage.ID,
    'Web UI Credentials',
    'Set the login for the CrowdDICOM web interface',
    'These credentials protect access to the CrowdDICOM monitoring dashboard.');
  CredPage.Add('Username:', False);
  CredPage.Add('Password:', True);
  CredPage.Values[0] := 'admin';
  CredPage.Values[1] := 'orthanc';
end;

// ── Validate inputs ─────────────────────────────────────────────
function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  
  if CurPageID = DicomPage.ID then begin
    if Trim(DicomPage.Values[0]) = '' then begin
      MsgBox('Please enter an AE Title.', mbError, MB_OK);
      Result := False;
    end;
  end;

  if CurPageID = DestPage.ID then begin
    if Trim(DestPage.Values[0]) = '' then begin
      MsgBox('Please enter the destination AE Title.', mbError, MB_OK);
      Result := False;
    end else if Trim(DestPage.Values[1]) = '' then begin
      MsgBox('Please enter the destination host/IP.', mbError, MB_OK);
      Result := False;
    end;
  end;

  if CurPageID = CredPage.ID then begin
    if Trim(CredPage.Values[0]) = '' then begin
      MsgBox('Please enter a username.', mbError, MB_OK);
      Result := False;
    end else if Trim(CredPage.Values[1]) = '' then begin
      MsgBox('Please enter a password.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

// ── Wait for service to fully stop ──────────────────────────────
procedure StopOrthancService;
var
  ResultCode: Integer;
  WaitCount: Integer;
begin
  // Try to stop the service
  Exec('net', 'stop Orthanc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  
  // Wait up to 15 seconds for service to fully stop
  WaitCount := 0;
  while WaitCount < 15 do begin
    Sleep(1000);
    // Check if the service is stopped by trying to query it
    Exec('sc', 'query Orthanc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    // If sc query returns non-zero, service doesn't exist (fine)
    if ResultCode <> 0 then
      Break;
    WaitCount := WaitCount + 1;
  end;
  
  // Extra safety margin
  Sleep(2000);
end;

// ── Run the official Orthanc installer silently ─────────────────
function RunOfficialInstaller: Boolean;
var
  InstallerPath: String;
  ResultCode: Integer;
begin
  Result := True;
  InstallerPath := ExpandConstant('{tmp}\OrthancInstaller-Win64.exe');
  
  if FileExists(InstallerPath) then begin
    WizardForm.StatusLabel.Caption := 'Installing Orthanc server (this may take a minute)...';
    
    // Run the official installer silently
    // /VERYSILENT /SUPPRESSMSGBOXES - no UI
    // /NORESTART - don't reboot
    // /DIR= sets the install directory to match ours
    if not Exec(InstallerPath, 
        '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /DIR="' + ExpandConstant('{app}') + '"',
        '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then begin
      MsgBox('Failed to run the Orthanc installer. Error code: ' + IntToStr(ResultCode) + Chr(13) + Chr(10) + 'You may need to install Orthanc manually from orthanc.uclouvain.be', mbError, MB_OK);
      Result := False;
    end;
    
    // The official installer creates and starts the Orthanc service.
    // We need to stop it so we can overwrite the config.
    WizardForm.StatusLabel.Caption := 'Stopping service to apply CrowdDICOM configuration...';
    StopOrthancService;
  end;
end;

// ── Create necessary directories ────────────────────────────────
procedure CreateDirectories;
begin
  ForceDirectories(ExpandConstant('{app}\Configuration'));
  ForceDirectories(ExpandConstant('{app}\Lua'));
  ForceDirectories(ExpandConstant('{app}\Logs'));
  ForceDirectories(ExpandConstant('{app}\OrthancStorage'));
end;

// ── Generate orthanc.json ───────────────────────────────────────
procedure GenerateOrthancJson;
var
  Lines: TStringList;
  ConfigFile: String;
  StorageDir: String;
  LuaDir: String;
begin
  StorageDir := ExpandConstant('{app}\OrthancStorage');
  LuaDir := ExpandConstant('{app}\Lua');
  StringChangeEx(StorageDir, '\', '/', True);
  StringChangeEx(LuaDir, '\', '/', True);

  Lines := TStringList.Create;
  try
    Lines.Add('{');
    Lines.Add('  "Name": "CrowdDICOM",');
    Lines.Add('  "StorageDirectory": "' + StorageDir + '",');
    Lines.Add('  "IndexDirectory": "' + StorageDir + '",');
    Lines.Add('  "DicomAet": "' + Trim(DicomPage.Values[0]) + '",');
    Lines.Add('  "DicomPort": ' + Trim(DicomPage.Values[1]) + ',');
    Lines.Add('  "HttpPort": ' + Trim(DicomPage.Values[2]) + ',');
    Lines.Add('  "RemoteAccessAllowed": true,');
    Lines.Add('  "AuthenticationEnabled": true,');
    Lines.Add('  "RegisteredUsers": {');
    Lines.Add('    "' + Trim(CredPage.Values[0]) + '": "' + CredPage.Values[1] + '"');
    Lines.Add('  },');
    Lines.Add('  "DicomModalities": {');
    Lines.Add('    "destination": {');
    Lines.Add('      "AET": "' + Trim(DestPage.Values[0]) + '",');
    Lines.Add('      "Host": "' + Trim(DestPage.Values[1]) + '",');
    Lines.Add('      "Port": ' + Trim(DestPage.Values[2]));
    Lines.Add('    }');
    Lines.Add('  },');
    Lines.Add('  "LuaScripts": [');
    Lines.Add('    "' + LuaDir + '/store-and-forward.lua"');
    Lines.Add('  ],');
    Lines.Add('  "LuaHeartBeatPeriod": 60,');
    Lines.Add('  "ExecuteLuaEnabled": true,');
    Lines.Add('  "DicomAlwaysAllowStore": true,');
    Lines.Add('  "UnknownSopClassAccepted": true,');
    Lines.Add('  "StableAge": 5,');
    Lines.Add('  "SaveJobs": true,');
    Lines.Add('  "OverwriteInstances": true,');
    Lines.Add('  "JobsHistorySize": 500,');
    Lines.Add('  "ConcurrentJobs": 2,');
    Lines.Add('  "StorageCompression": false,');
    Lines.Add('  "MaximumStorageSize": 0,');
    Lines.Add('  "DicomCheckCalledAet": false,');
    Lines.Add('  "DeidentifyLogs": false');
    Lines.Add('}');

    ConfigFile := ExpandConstant('{app}\Configuration\orthanc.json');
    Lines.SaveToFile(ConfigFile);
  finally
    Lines.Free;
  end;
end;

// ── Overwrite the official orthanc-explorer-2.json with CrowdDICOM theme ──
procedure PatchOE2Config;
var
  Lines: TStringList;
  OE2File: String;
begin
  OE2File := ExpandConstant('{app}\Configuration\orthanc-explorer-2.json');
  
  Lines := TStringList.Create;
  try
    Lines.Add('{');
    Lines.Add('  "OrthancExplorer2": {');
    Lines.Add('    "IsDefaultOrthancUI": true,');
    Lines.Add('    "Theme": "dark",');
    Lines.Add('    "UiOptions": {');
    Lines.Add('      "EnableLinkToLegacyUi": false');
    Lines.Add('    }');
    Lines.Add('  }');
    Lines.Add('}');
    Lines.SaveToFile(OE2File);
  finally
    Lines.Free;
  end;
end;

// ── Generate the Lua script directly (no template patching) ─────
procedure GenerateLuaScript;
var
  Lines: TStringList;
  LuaFile: String;
  DriveLetter: String;
  Threshold: String;
  SQ: String;
  WmicLine: String;
begin
  LuaFile := ExpandConstant('{app}\Lua\store-and-forward.lua');
  DriveLetter := Copy(ExpandConstant('{app}'), 1, 1);
  Threshold := Trim(DestPage.Values[3]);
  if Threshold = '' then
    Threshold := '70';

  // Build the wmic io.popen line separately to avoid quote escaping hell
  // Target Lua output:   local handle = io.popen("wmic logicaldisk where \"DeviceID='C:'\" get FreeSpace,Size /format:csv 2>NUL")
  SQ := '''';  // a single-quote character
  WmicLine := '   local handle = io.popen("wmic logicaldisk where \"DeviceID=' + SQ + DriveLetter + ':' + SQ + '\" get FreeSpace,Size /format:csv 2>NUL")';

  Lines := TStringList.Create;
  try
    Lines.Add('-- CrowdDICOM Store-and-Forward with Disk Space Management');
    Lines.Add('-- Generated by the CrowdDICOM installer');
    Lines.Add('');
    Lines.Add('local DISK_USAGE_THRESHOLD = ' + Threshold);
    Lines.Add('local DESTINATION_MODALITY = "destination"');
    Lines.Add('');
    Lines.Add('function Initialize()');
    Lines.Add('   print("CrowdDICOM: Store-and-Forward starting, threshold: " .. DISK_USAGE_THRESHOLD .. "%")');
    Lines.Add('   local allInstances = ParseJson(RestApiGet("/instances"))');
    Lines.Add('   if #allInstances > 0 then');
    Lines.Add('      print("Re-queuing " .. #allInstances .. " instance(s) found at startup")');
    Lines.Add('      for i, instanceId in pairs(allInstances) do');
    Lines.Add('         ForwardInstance(instanceId)');
    Lines.Add('      end');
    Lines.Add('   end');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function ForwardInstance(instanceId)');
    Lines.Add('   local payload = {}');
    Lines.Add('   payload["Resources"] = { instanceId }');
    Lines.Add('   payload["Asynchronous"] = true');
    Lines.Add('   payload["Priority"] = 1');
    Lines.Add('   local result = RestApiPost("/modalities/" .. DESTINATION_MODALITY .. "/store", DumpJson(payload, false))');
    Lines.Add('   local job = ParseJson(result)');
    Lines.Add('   print("[FORWARD] Job " .. job["ID"] .. " for instance " .. instanceId)');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function OnStoredInstance(instanceId, tags, metadata, origin)');
    Lines.Add('   if origin and origin["RequestOrigin"] == "Lua" then return end');
    Lines.Add('   local pn = tags["PatientName"] or "Unknown"');
    Lines.Add('   local mod = tags["Modality"] or "?"');
    Lines.Add('   print("[RECEIVED] " .. instanceId .. " | " .. pn .. " | " .. mod)');
    Lines.Add('   ForwardInstance(instanceId)');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function OnJobFailure(jobId)');
    Lines.Add('   print("[JOB FAIL] " .. jobId)');
    Lines.Add('   local job = ParseJson(RestApiGet("/jobs/" .. jobId))');
    Lines.Add('   if job["Type"] == "DicomModalityStore" then');
    Lines.Add('      if job["ErrorCode"] == 9 then');
    Lines.Add('         print("[RETRY] Resubmitting job " .. jobId)');
    Lines.Add('         RestApiPost("/jobs/" .. jobId .. "/resubmit", "")');
    Lines.Add('      end');
    Lines.Add('   end');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function OnJobSuccess(jobId)');
    Lines.Add('   local job = ParseJson(RestApiGet("/jobs/" .. jobId))');
    Lines.Add('   if job["Type"] == "DicomModalityStore" then');
    Lines.Add('      local pr = job["Content"]["ParentResources"]');
    Lines.Add('      if pr and #pr > 0 then');
    Lines.Add('         print("[FORWARDED] " .. pr[1])');
    Lines.Add('      end');
    Lines.Add('   end');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function OnHeartBeat()');
    Lines.Add('   CleanupDiskSpace()');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function GetDiskUsagePercent()');
    Lines.Add(WmicLine);
    Lines.Add('   if handle then');
    Lines.Add('      local output = handle:read("*a")');
    Lines.Add('      handle:close()');
    Lines.Add('      for line in output:gmatch("[^\r\n]+") do');
    Lines.Add('         local node, free, size = line:match("([^,]+),([^,]+),([^,]+)")');
    Lines.Add('         if tonumber(free) and tonumber(size) then');
    Lines.Add('            local used = tonumber(size) - tonumber(free)');
    Lines.Add('            return math.floor((used / tonumber(size)) * 100)');
    Lines.Add('         end');
    Lines.Add('      end');
    Lines.Add('   end');
    Lines.Add('   return 0');
    Lines.Add('end');
    Lines.Add('');
    Lines.Add('function CleanupDiskSpace()');
    Lines.Add('   local usage = GetDiskUsagePercent()');
    Lines.Add('   if usage < DISK_USAGE_THRESHOLD then return end');
    Lines.Add('   print("[CLEANUP] Disk at " .. usage .. "%, deleting oldest study")');
    Lines.Add('   local ok, oldest = pcall(function()');
    Lines.Add('      return ParseJson(RestApiPost("/tools/find", DumpJson({');
    Lines.Add('         Level = "Study", Expand = true, Query = {},');
    Lines.Add('         OrderBy = { { Type = "Metadata", Key = "LastUpdate", Direction = "ASC" } },');
    Lines.Add('         Limit = 1');
    Lines.Add('      }, false)))');
    Lines.Add('   end)');
    Lines.Add('   if not ok or not oldest or #oldest == 0 then');
    Lines.Add('      local all = ParseJson(RestApiGet("/studies"))');
    Lines.Add('      if #all > 0 then RestApiDelete("/studies/" .. all[1]) end');
    Lines.Add('      return');
    Lines.Add('   end');
    Lines.Add('   RestApiDelete("/studies/" .. oldest[1]["ID"])');
    Lines.Add('end');

    Lines.SaveToFile(LuaFile);
  finally
    Lines.Free;
  end;
end;

// ── Configure Windows Firewall rules ────────────────────────────
procedure ConfigureFirewall;
var
  ResultCode: Integer;
  DicomPort: String;
  HttpPort: String;
begin
  DicomPort := Trim(DicomPage.Values[1]);
  HttpPort := Trim(DicomPage.Values[2]);
  
  WizardForm.StatusLabel.Caption := 'Configuring Windows Firewall...';
  
  // Remove any existing CrowdDICOM firewall rules first (in case of reinstall)
  Exec('netsh', 'advfirewall firewall delete rule name="CrowdDICOM DICOM"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  Exec('netsh', 'advfirewall firewall delete rule name="CrowdDICOM HTTP"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  
  // Add inbound rule for DICOM port (TCP)
  Exec('netsh', 'advfirewall firewall add rule name="CrowdDICOM DICOM" dir=in action=allow protocol=TCP localport=' + DicomPort, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode <> 0 then
    Log('Warning: Failed to add DICOM firewall rule for port ' + DicomPort);
  
  // Add inbound rule for HTTP port (TCP)
  Exec('netsh', 'advfirewall firewall add rule name="CrowdDICOM HTTP" dir=in action=allow protocol=TCP localport=' + HttpPort, '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode <> 0 then
    Log('Warning: Failed to add HTTP firewall rule for port ' + HttpPort);
end;

// ── Start the Orthanc service (already created by official installer) ──
procedure StartOrthancService;
var
  ResultCode: Integer;
  Retries: Integer;
begin
  WizardForm.StatusLabel.Caption := 'Starting CrowdDICOM service...';
  
  // Update the service description to CrowdDICOM
  Exec('sc', 'description Orthanc "CrowdDICOM DICOM Server"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  
  // Try to start the service with retries
  Retries := 0;
  while Retries < 3 do begin
    Exec('net', 'start Orthanc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    if ResultCode = 0 then begin
      MsgBox('CrowdDICOM is now running!' + Chr(13) + Chr(10) + Chr(13) + Chr(10) + 'Web UI: http://localhost:' + Trim(DicomPage.Values[2]) + '/' + Chr(13) + Chr(10) + 'Username: ' + Trim(CredPage.Values[0]) + Chr(13) + Chr(10) + Chr(13) + Chr(10) + 'DICOM Port: ' + Trim(DicomPage.Values[1]) + Chr(13) + Chr(10) + 'AE Title: ' + Trim(DicomPage.Values[0]) + Chr(13) + Chr(10) + 'Forwarding to: ' + Trim(DestPage.Values[0]) + '@' + Trim(DestPage.Values[1]) + ':' + Trim(DestPage.Values[2]), mbInformation, MB_OK);
      Exit;
    end;
    
    // Wait and retry
    Sleep(3000);
    Retries := Retries + 1;
  end;
  
  // All retries failed
  MsgBox('The Orthanc service could not be started.' + Chr(13) + Chr(10) + Chr(13) + Chr(10) + 'This usually means:' + Chr(13) + Chr(10) + '  - Another program is using port ' + Trim(DicomPage.Values[1]) + ' or ' + Trim(DicomPage.Values[2]) + Chr(13) + Chr(10) + '  - A firewall is blocking the ports' + Chr(13) + Chr(10) + Chr(13) + Chr(10) + 'Check the logs at:' + Chr(13) + Chr(10) + '  ' + ExpandConstant('{app}') + '\Logs\' + Chr(13) + Chr(10) + Chr(13) + Chr(10) + 'You can try starting manually:' + Chr(13) + Chr(10) + '  net start Orthanc' + Chr(13) + Chr(10) + '  or run start-orthanc.bat for console output', mbError, MB_OK);
end;

// ── Main post-install logic ─────────────────────────────────────
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    // Step 1: Stop existing service if present
    WizardForm.StatusLabel.Caption := 'Stopping existing Orthanc service...';
    StopOrthancService;
    
    // Step 2: Run the official Orthanc installer silently
    //         (it installs files AND creates + starts the service,
    //          then we stop the service inside RunOfficialInstaller)
    if WizardIsComponentSelected('orthanc') then
      RunOfficialInstaller;
    
    // Step 3: Create all necessary directories
    WizardForm.StatusLabel.Caption := 'Creating directories...';
    CreateDirectories;
    
    // Step 4: Generate our config (overwrites the official default)
    WizardForm.StatusLabel.Caption := 'Generating CrowdDICOM configuration...';
    GenerateOrthancJson;
    
    // Step 4b: Overwrite orthanc-explorer-2.json with CrowdDICOM theme
    PatchOE2Config;
    
    // Step 5: Generate the Lua script (written directly, no templates)
    WizardForm.StatusLabel.Caption := 'Generating store-and-forward script...';
    GenerateLuaScript;
    
    // Step 6: Open firewall ports for DICOM and HTTP
    ConfigureFirewall;
    
    // Step 7: Start the service with our config
    StartOrthancService;
  end;
end;

// ── Uninstall: stop and remove service ──────────────────────────
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ResultCode: Integer;
begin
  if CurUninstallStep = usUninstall then begin
    Exec('net', 'stop Orthanc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Sleep(3000);
    Exec('sc', 'delete Orthanc', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    
    // Remove firewall rules
    Exec('netsh', 'advfirewall firewall delete rule name="CrowdDICOM DICOM"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
    Exec('netsh', 'advfirewall firewall delete rule name="CrowdDICOM HTTP"', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;
