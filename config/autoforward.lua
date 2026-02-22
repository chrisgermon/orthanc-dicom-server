-- Crowd Image Management - Auto-routing engine
-- Reads rules from /var/lib/orthanc/routing-rules.json
-- Rules are managed via the admin page
-- Storage watermark: auto-deletes oldest studies when disk exceeds threshold

ROUTING_RULES = {}
ROUTING_LOG_PATH = "/var/lib/orthanc/routing-log.json"
ROUTING_LOG_MAX = 500

function AppendRoutingLog(studyId, ruleName, destination, status, errorMsg, callingAet, calledAet, studyDesc, studyModality)
  -- Read existing log
  local entries = {}
  local f = io.open(ROUTING_LOG_PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(ParseJson, content)
    if ok and parsed then entries = parsed end
  end

  -- Append new entry
  table.insert(entries, {
    study = studyId,
    rule = ruleName or "",
    dest = destination,
    time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
    status = status or "sent",
    error = errorMsg or "",
    callingAet = callingAet or "",
    calledAet = calledAet or "",
    description = studyDesc or "",
    modality = studyModality or ""
  })

  -- Cap at max entries (remove oldest)
  while #entries > ROUTING_LOG_MAX do
    table.remove(entries, 1)
  end

  -- Serialize and write back
  local parts = {}
  for _, e in ipairs(entries) do
    local item = '{"study":' .. QuoteJson(e.study) ..
      ',"rule":' .. QuoteJson(e.rule) ..
      ',"dest":' .. QuoteJson(e.dest) ..
      ',"time":' .. QuoteJson(e.time) ..
      ',"status":' .. QuoteJson(e.status or "sent") ..
      ',"error":' .. QuoteJson(e.error or "") ..
      ',"callingAet":' .. QuoteJson(e.callingAet or "") ..
      ',"calledAet":' .. QuoteJson(e.calledAet or "") ..
      ',"description":' .. QuoteJson(e.description or "") ..
      ',"modality":' .. QuoteJson(e.modality or "") .. '}'
    table.insert(parts, item)
  end

  local out = io.open(ROUTING_LOG_PATH, "w")
  if out then
    out:write("[\n" .. table.concat(parts, ",\n") .. "\n]")
    out:close()
  end
end

function LoadRoutingRules()
  local f = io.open("/var/lib/orthanc/routing-rules.json", "r")
  if not f then
    print("No routing-rules.json found, auto-routing disabled")
    ROUTING_RULES = {}
    return
  end
  local content = f:read("*a")
  f:close()

  local ok, rules = pcall(ParseJson, content)
  if ok and rules then
    ROUTING_RULES = rules
    print("Loaded " .. #ROUTING_RULES .. " routing rule(s)")
  else
    print("Failed to parse routing-rules.json")
    ROUTING_RULES = {}
  end
end

function SaveRoutingRules()
  local f = io.open("/var/lib/orthanc/routing-rules.json", "w")
  if not f then
    print("Cannot write routing-rules.json")
    return false
  end
  local parts = {}
  for _, rule in ipairs(ROUTING_RULES) do
    local entry = '{"name":' .. QuoteJson(rule.name or "") ..
      ',"enabled":' .. (rule.enabled and 'true' or 'false') ..
      ',"destination":' .. QuoteJson(rule.destination or "") ..
      ',"filterModality":' .. QuoteJson(rule.filterModality or "") ..
      ',"filterDescription":' .. QuoteJson(rule.filterDescription or "") ..
      ',"filterCallingAet":' .. QuoteJson(rule.filterCallingAet or "") ..
      ',"filterCalledAet":' .. QuoteJson(rule.filterCalledAet or "") .. '}'
    table.insert(parts, entry)
  end
  f:write("[" .. table.concat(parts, ",") .. "]")
  f:close()
  print("Saved " .. #ROUTING_RULES .. " routing rule(s)")
  return true
end

function QuoteJson(s)
  if s == nil then return '""' end
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  return '"' .. s .. '"'
end

function MatchesFilter(value, filter)
  if not filter or filter == "" then return true end
  if not value then return false end
  local lv = string.lower(value)
  local lf = string.lower(filter)
  lf = lf:gsub("%%", "%%%%")
  lf = lf:gsub("%.", "%%.")
  lf = lf:gsub("%*", ".*")
  return string.find(lv, lf) ~= nil
end

STORAGE_SETTINGS_PATH = "/var/lib/orthanc/storage-settings.json"

function LoadStorageSettings()
  local f = io.open(STORAGE_SETTINGS_PATH, "r")
  if not f then return { watermarkPercent = 0 } end
  local content = f:read("*a")
  f:close()
  local ok, settings = pcall(ParseJson, content)
  if ok and settings then return settings end
  return { watermarkPercent = 0 }
end

function GetDiskUsagePercent()
  local handle = io.popen("df -P /var/lib/orthanc/db 2>/dev/null | tail -1 | awk '{print $5}'")
  if not handle then return nil end
  local result = handle:read("*a")
  handle:close()
  if not result then return nil end
  local pct = result:match("(%d+)")
  if pct then return tonumber(pct) end
  return nil
end

function CheckStorageWatermark()
  local settings = LoadStorageSettings()
  local watermark = tonumber(settings.watermarkPercent) or 0
  if watermark <= 0 then return end

  local diskUsage = GetDiskUsagePercent()
  if not diskUsage then
    print("Storage watermark: could not read disk usage")
    return
  end

  if diskUsage <= watermark then return end

  print("Storage watermark: disk at " .. diskUsage .. "%, watermark is " .. watermark .. "%, cleaning up")

  local deleted = 0
  local maxDeletions = 50

  while diskUsage > watermark and deleted < maxDeletions do
    local ok, studies = pcall(function()
      return ParseJson(RestApiGet("/studies?expand&limit=1&since=0"))
    end)
    if not ok or not studies or #studies == 0 then
      print("Storage watermark: no more studies to delete")
      break
    end

    local oldest = studies[1]
    local patientName = ""
    if oldest.PatientMainDicomTags and oldest.PatientMainDicomTags.PatientName then
      patientName = oldest.PatientMainDicomTags.PatientName
    end
    print("Storage watermark: deleting oldest study " .. oldest.ID .. " (" .. patientName .. ") to free space")

    local delOk, delErr = pcall(RestApiDelete, "/studies/" .. oldest.ID)
    if not delOk then
      print("Storage watermark: failed to delete study " .. oldest.ID .. ": " .. tostring(delErr))
      break
    end

    deleted = deleted + 1
    diskUsage = GetDiskUsagePercent()
    if not diskUsage then
      print("Storage watermark: could not re-check disk usage, stopping")
      break
    end
  end

  if deleted > 0 then
    print("Storage watermark: deleted " .. deleted .. " study(ies), disk now at " .. (diskUsage or "?") .. "%")
  end
end

function OnStableStudy(studyId, tags, metadata)
  -- Check storage watermark first
  CheckStorageWatermark()

  if #ROUTING_RULES == 0 then return end

  local study = ParseJson(RestApiGet("/studies/" .. studyId))
  if not study then return end

  local mainTags = study.MainDicomTags or {}
  local modality = mainTags.ModalitiesInStudy or ""
  local description = mainTags.StudyDescription or ""

  local callingAet = ""
  if metadata and metadata.CallingAet then
    callingAet = metadata.CallingAet
  end

  local calledAet = ""
  if metadata and metadata.CalledAet then
    calledAet = metadata.CalledAet
  end

  for _, rule in ipairs(ROUTING_RULES) do
    if rule.enabled then
      local match = true
      if not MatchesFilter(modality, rule.filterModality) then match = false end
      if not MatchesFilter(description, rule.filterDescription) then match = false end
      if not MatchesFilter(callingAet, rule.filterCallingAet) then match = false end
      if not MatchesFilter(calledAet, rule.filterCalledAet) then match = false end

      if match and rule.destination and rule.destination ~= "" then
        print("Auto-routing study " .. studyId .. " to " .. rule.destination .. " (rule: " .. (rule.name or "?") .. ")")
        local ok, err = pcall(function()
          RestApiPost("/modalities/" .. rule.destination .. "/store", '{"Resources":["' .. studyId .. '"],"Asynchronous":true}')
        end)
        if ok then
          AppendRoutingLog(studyId, rule.name, rule.destination, "sent", "", callingAet, calledAet, description, modality)
        else
          print("Auto-routing failed for " .. studyId .. ": " .. tostring(err))
          AppendRoutingLog(studyId, rule.name, rule.destination, "failed", tostring(err), callingAet, calledAet, description, modality)
        end
      end
    end
  end
end

-- Load rules on startup
LoadRoutingRules()
