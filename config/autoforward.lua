-- Crowd Image Management - Auto-routing engine
-- Reads rules from /var/lib/orthanc/routing-rules.json
-- Rules are managed via the admin page
-- Supports both "push" (OnStableStudy) and "poll" (periodic PACS query) rules
-- Storage watermark: auto-deletes oldest studies when disk exceeds threshold
-- Traffic events: logs study metadata for the AI routing agent

ROUTING_RULES = {}
ROUTING_LOG_PATH = "/var/lib/orthanc/routing-log.json"
ROUTING_LOG_MAX = 500
POLL_SENT_CACHE = {} -- { "ruleHash:seriesUID" = true } for dedup
POLL_LAST_RUN = {} -- { ruleIndex = timestamp } for scheduling
TRAFFIC_EVENTS_PATH = "/var/lib/orthanc/traffic-events.json"
TRAFFIC_EVENTS_MAX = 1000

-- ════════════════════════════════════════════════
--  JSON Helpers
-- ════════════════════════════════════════════════

function QuoteJson(s)
  if s == nil then return '""' end
  s = tostring(s)
  s = s:gsub('\\', '\\\\')
  s = s:gsub('"', '\\"')
  s = s:gsub('\n', '\\n')
  return '"' .. s .. '"'
end

function BoolJson(b)
  if b then return 'true' else return 'false' end
end

-- ════════════════════════════════════════════════
--  Routing Log (persistent)
-- ════════════════════════════════════════════════

function AppendRoutingLog(studyId, ruleName, destination, status, errorMsg, callingAet, calledAet, studyDesc, studyModality, seriesUid, ruleType, sendLevel, seriesDesc)
  local entries = {}
  local f = io.open(ROUTING_LOG_PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(ParseJson, content)
    if ok and parsed then entries = parsed end
  end

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
    modality = studyModality or "",
    seriesUid = seriesUid or "",
    ruleType = ruleType or "push",
    sendLevel = sendLevel or "study",
    seriesDesc = seriesDesc or ""
  })

  while #entries > ROUTING_LOG_MAX do
    table.remove(entries, 1)
  end

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
      ',"modality":' .. QuoteJson(e.modality or "") ..
      ',"seriesUid":' .. QuoteJson(e.seriesUid or "") ..
      ',"ruleType":' .. QuoteJson(e.ruleType or "push") ..
      ',"sendLevel":' .. QuoteJson(e.sendLevel or "study") ..
      ',"seriesDesc":' .. QuoteJson(e.seriesDesc or "") .. '}'
    table.insert(parts, item)
  end

  local out = io.open(ROUTING_LOG_PATH, "w")
  if out then
    out:write("[\n" .. table.concat(parts, ",\n") .. "\n]")
    out:close()
  end
end

-- ════════════════════════════════════════════════
--  Routing Rules (save/load)
-- ════════════════════════════════════════════════

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

  -- Build dedup cache from existing log
  RebuildPollSentCache()
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
      ',"enabled":' .. BoolJson(rule.enabled) ..
      ',"type":' .. QuoteJson(rule.type or "push") ..
      ',"destination":' .. QuoteJson(rule.destination or "") ..
      ',"source":' .. QuoteJson(rule.source or "") ..
      ',"pollIntervalMinutes":' .. tostring(tonumber(rule.pollIntervalMinutes) or 5) ..
      ',"sendLevel":' .. QuoteJson(rule.sendLevel or "study") ..
      ',"filterModality":' .. QuoteJson(rule.filterModality or "") ..
      ',"filterStudyDescription":' .. QuoteJson(rule.filterStudyDescription or rule.filterDescription or "") ..
      ',"filterSeriesDescription":' .. QuoteJson(rule.filterSeriesDescription or "") ..
      ',"filterCallingAet":' .. QuoteJson(rule.filterCallingAet or "") ..
      ',"filterCalledAet":' .. QuoteJson(rule.filterCalledAet or "") ..
      ',"filterDateRange":' .. QuoteJson(rule.filterDateRange or "") ..
      ',"deleteAfterSend":' .. BoolJson(rule.deleteAfterSend) .. '}'
    table.insert(parts, entry)
  end
  f:write("[" .. table.concat(parts, ",") .. "]")
  f:close()
  print("Saved " .. #ROUTING_RULES .. " routing rule(s)")
  return true
end

-- ════════════════════════════════════════════════
--  Pattern Matching
-- ════════════════════════════════════════════════

function MatchesFilter(value, filter)
  if not filter or filter == "" then return true end
  if not value then return false end
  local negate = false
  local pattern = filter
  if pattern:sub(1, 1) == "!" then
    negate = true
    pattern = pattern:sub(2)
  end
  if pattern == "" then return true end
  local lv = string.lower(value)
  local lf = string.lower(pattern)
  lf = lf:gsub("%%", "%%%%")
  lf = lf:gsub("%.", "%%.")
  lf = lf:gsub("%*", ".*")
  local found = string.find(lv, lf) ~= nil
  if negate then return not found end
  return found
end

-- ════════════════════════════════════════════════
--  Date Range Helper
-- ════════════════════════════════════════════════

function GetDateRangeQuery(filterDateRange)
  if not filterDateRange or filterDateRange == "" then return "" end
  local today = os.date("!%Y%m%d")
  if filterDateRange == "today" then
    return today .. "-" .. today
  end
  local days = 0
  if filterDateRange == "yesterday" then days = 1
  elseif filterDateRange == "7days" then days = 7
  elseif filterDateRange == "30days" then days = 30
  elseif filterDateRange == "90days" then days = 90
  else return "" end
  local startTime = os.time() - (days * 86400)
  local startDate = os.date("!%Y%m%d", startTime)
  return startDate .. "-" .. today
end

-- ════════════════════════════════════════════════
--  Dedup Cache
-- ════════════════════════════════════════════════

function RebuildPollSentCache()
  POLL_SENT_CACHE = {}
  local f = io.open(ROUTING_LOG_PATH, "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  local ok, entries = pcall(ParseJson, content)
  if not ok or not entries then return end
  for _, e in ipairs(entries) do
    if e.seriesUid and e.seriesUid ~= "" and e.status == "sent" then
      local key = (e.rule or "") .. ":" .. (e.dest or "") .. ":" .. e.seriesUid
      POLL_SENT_CACHE[key] = true
    end
    -- Also track study-level sends
    if e.study and e.study ~= "" and e.status == "sent" and (not e.seriesUid or e.seriesUid == "") then
      local key = (e.rule or "") .. ":" .. (e.dest or "") .. ":study:" .. e.study
      POLL_SENT_CACHE[key] = true
    end
  end
end

function IsAlreadySent(ruleName, destination, uid, level)
  local key
  if level == "series" then
    key = ruleName .. ":" .. destination .. ":" .. uid
  else
    key = ruleName .. ":" .. destination .. ":study:" .. uid
  end
  return POLL_SENT_CACHE[key] == true
end

function MarkAsSent(ruleName, destination, uid, level)
  local key
  if level == "series" then
    key = ruleName .. ":" .. destination .. ":" .. uid
  else
    key = ruleName .. ":" .. destination .. ":study:" .. uid
  end
  POLL_SENT_CACHE[key] = true
end

-- ════════════════════════════════════════════════
--  Storage Watermark
-- ════════════════════════════════════════════════

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

-- ════════════════════════════════════════════════
--  Traffic Event Logger (for AI routing agent)
-- ════════════════════════════════════════════════

function AppendTrafficEvent(studyUid, patientName, patientId, modality, studyDescription, callingAet, calledAet, numSeries, numInstances)
  local events = {}
  local f = io.open(TRAFFIC_EVENTS_PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, parsed = pcall(ParseJson, content)
    if ok and parsed then events = parsed end
  end

  table.insert(events, {
    time = os.date("!%Y-%m-%dT%H:%M:%S") .. "Z",
    studyUid = studyUid or "",
    patientName = patientName or "",
    patientId = patientId or "",
    modality = modality or "",
    studyDescription = studyDescription or "",
    callingAet = callingAet or "",
    calledAet = calledAet or "",
    numSeries = numSeries or 0,
    numInstances = numInstances or 0
  })

  while #events > TRAFFIC_EVENTS_MAX do
    table.remove(events, 1)
  end

  local parts = {}
  for _, e in ipairs(events) do
    local item = '{"time":' .. QuoteJson(e.time) ..
      ',"studyUid":' .. QuoteJson(e.studyUid) ..
      ',"patientName":' .. QuoteJson(e.patientName) ..
      ',"patientId":' .. QuoteJson(e.patientId) ..
      ',"modality":' .. QuoteJson(e.modality) ..
      ',"studyDescription":' .. QuoteJson(e.studyDescription) ..
      ',"callingAet":' .. QuoteJson(e.callingAet) ..
      ',"calledAet":' .. QuoteJson(e.calledAet) ..
      ',"numSeries":' .. tostring(e.numSeries or 0) ..
      ',"numInstances":' .. tostring(e.numInstances or 0) .. '}'
    table.insert(parts, item)
  end

  local out = io.open(TRAFFIC_EVENTS_PATH, "w")
  if out then
    out:write("[\n" .. table.concat(parts, ",\n") .. "\n]")
    out:close()
  end
end

-- ════════════════════════════════════════════════
--  PUSH Rules: OnStableStudy handler
-- ════════════════════════════════════════════════

function OnStableStudy(studyId, tags, metadata)
  CheckStorageWatermark()

  local study = ParseJson(RestApiGet("/studies/" .. studyId))
  if not study then return end

  local mainTags = study.MainDicomTags or {}
  local modality = mainTags.ModalitiesInStudy or ""
  local studyDesc = mainTags.StudyDescription or ""
  local studyUid = mainTags.StudyInstanceUID or ""

  -- Fetch CallingAet/CalledAet from instance metadata
  local callingAet = ""
  local calledAet = ""
  local instances = study.Instances or {}
  if #instances > 0 then
    local ok, instMeta = pcall(function()
      return ParseJson(RestApiGet("/instances/" .. instances[1] .. "/metadata?expand"))
    end)
    if ok and instMeta then
      callingAet = instMeta.RemoteAET or ""
      calledAet = instMeta.CalledAET or ""
    end
  end

  -- Patient info
  local patientTags = study.PatientMainDicomTags or {}
  local patientName = patientTags.PatientName or ""
  local patientId = patientTags.PatientID or ""

  -- Log traffic event for AI agent
  local numSeries = study.Series and #study.Series or 0
  local numInstances = #instances
  pcall(AppendTrafficEvent, studyUid, patientName, patientId, modality, studyDesc, callingAet, calledAet, numSeries, numInstances)

  if #ROUTING_RULES == 0 then return end

  for _, rule in ipairs(ROUTING_RULES) do
    -- Only process push rules (or backward-compat rules with no type)
    local ruleType = rule.type or "push"
    if ruleType ~= "push" then goto continue_push end

    if rule.enabled then
      local match = true
      if not MatchesFilter(modality, rule.filterModality) then match = false end
      -- Support both old filterDescription and new filterStudyDescription
      local descFilter = rule.filterStudyDescription or rule.filterDescription or ""
      if not MatchesFilter(studyDesc, descFilter) then match = false end
      if not MatchesFilter(callingAet, rule.filterCallingAet) then match = false end
      if not MatchesFilter(calledAet, rule.filterCalledAet) then match = false end

      if match and rule.destination and rule.destination ~= "" then
        local sendLevel = rule.sendLevel or "study"

        if sendLevel == "series" then
          -- Series-level send for push rules
          SendMatchingSeriesFromStudy(studyId, study, rule, callingAet, calledAet)
        else
          -- Study-level send (original behavior)
          print("Auto-routing study " .. studyId .. " to " .. rule.destination .. " (rule: " .. (rule.name or "?") .. ")")
          local ok, result = pcall(function()
            return RestApiPost("/modalities/" .. rule.destination .. "/store", studyId)
          end)
          if ok then
            AppendRoutingLog(studyId, rule.name, rule.destination, "sent", "", callingAet, calledAet, studyDesc, modality, "", "push", "study", "")
            print("Auto-routing sent study " .. studyId .. " to " .. rule.destination)
          else
            print("Auto-routing failed for " .. studyId .. ": " .. tostring(result))
            AppendRoutingLog(studyId, rule.name, rule.destination, "failed", tostring(result), callingAet, calledAet, studyDesc, modality, "", "push", "study", "")
          end

          -- Delete after send if configured
          if ok and rule.deleteAfterSend then
            pcall(RestApiDelete, "/studies/" .. studyId)
            print("Deleted study " .. studyId .. " after send (rule: " .. (rule.name or "?") .. ")")
          end
        end
      end
    end

    ::continue_push::
  end
end

-- Get slice thickness from a series (reads from first instance's DICOM tags)
function GetSeriesSliceThickness(series)
  local instances = series.Instances or {}
  if #instances == 0 then return nil end

  local ok, tags = pcall(function()
    return ParseJson(RestApiGet("/instances/" .. instances[1] .. "/simplified-tags"))
  end)

  if ok and tags then
    local thickness = tags.SliceThickness
    if thickness then
      return tonumber(thickness)
    end
  end
  return nil
end

-- Match slice thickness against a filter like "<2", "<=1.5", ">3", ">=0.5", "=1.0"
function MatchesSliceThickness(thickness, filter)
  if not thickness then return false end  -- No slice thickness = no match when filter is set
  if not filter or filter == "" then return true end

  -- Parse operator and value
  local operator, value
  if filter:sub(1, 2) == "<=" then
    operator = "<="
    value = tonumber(filter:sub(3))
  elseif filter:sub(1, 2) == ">=" then
    operator = ">="
    value = tonumber(filter:sub(3))
  elseif filter:sub(1, 1) == "<" then
    operator = "<"
    value = tonumber(filter:sub(2))
  elseif filter:sub(1, 1) == ">" then
    operator = ">"
    value = tonumber(filter:sub(2))
  elseif filter:sub(1, 1) == "=" then
    operator = "="
    value = tonumber(filter:sub(2))
  else
    -- Assume it's just a number meaning "less than or equal"
    operator = "<="
    value = tonumber(filter)
  end

  if not value then return true end  -- Invalid filter value = pass through

  if operator == "<" then return thickness < value
  elseif operator == "<=" then return thickness <= value
  elseif operator == ">" then return thickness > value
  elseif operator == ">=" then return thickness >= value
  elseif operator == "=" then return math.abs(thickness - value) < 0.01
  end
  return true
end

-- Send matching series from a study (for push rules with series-level)
function SendMatchingSeriesFromStudy(studyId, study, rule, callingAet, calledAet)
  local seriesList = study.Series or {}
  local studyDesc = (study.MainDicomTags or {}).StudyDescription or ""
  local modality = (study.MainDicomTags or {}).ModalitiesInStudy or ""

  for _, seriesId in ipairs(seriesList) do
    local ok, series = pcall(function()
      return ParseJson(RestApiGet("/series/" .. seriesId))
    end)
    if ok and series then
      local seriesTags = series.MainDicomTags or {}
      local seriesDesc = seriesTags.SeriesDescription or ""
      local seriesMod = seriesTags.Modality or ""
      local seriesUid = seriesTags.SeriesInstanceUID or ""

      -- Check series description filter
      local seriesMatch = true
      if rule.filterSeriesDescription and rule.filterSeriesDescription ~= "" then
        if not MatchesFilter(seriesDesc, rule.filterSeriesDescription) then
          seriesMatch = false
        end
      end

      -- If rule has modality filter and it's series-level, filter on series modality
      if rule.filterModality and rule.filterModality ~= "" then
        if not MatchesFilter(seriesMod, rule.filterModality) then
          seriesMatch = false
        end
      end

      -- Check slice thickness filter
      if seriesMatch and rule.filterSliceThickness and rule.filterSliceThickness ~= "" then
        local sliceThickness = GetSeriesSliceThickness(series)
        if not MatchesSliceThickness(sliceThickness, rule.filterSliceThickness) then
          seriesMatch = false
        end
      end

      if seriesMatch then
        -- Check dedup
        if IsAlreadySent(rule.name or "", rule.destination, seriesUid, "series") then
          print("Series " .. seriesUid .. " already sent by rule " .. (rule.name or "?") .. ", skipping")
        else
          print("Auto-routing series " .. seriesId .. " (" .. seriesDesc .. ") to " .. rule.destination .. " (rule: " .. (rule.name or "?") .. ")")
          local sendOk, sendResult = pcall(function()
            return RestApiPost("/modalities/" .. rule.destination .. "/store", seriesId)
          end)
          if sendOk then
            MarkAsSent(rule.name or "", rule.destination, seriesUid, "series")
            AppendRoutingLog(studyId, rule.name, rule.destination, "sent", "", callingAet, calledAet, studyDesc, seriesMod, seriesUid, "push", "series", seriesDesc)
            print("Auto-routing sent series " .. seriesId .. " to " .. rule.destination)
          else
            print("Auto-routing series failed for " .. seriesId .. ": " .. tostring(sendResult))
            AppendRoutingLog(studyId, rule.name, rule.destination, "failed", tostring(sendResult), callingAet, calledAet, studyDesc, seriesMod, seriesUid, "push", "series", seriesDesc)
          end

          -- Delete series after send if configured
          if sendOk and rule.deleteAfterSend then
            pcall(RestApiDelete, "/series/" .. seriesId)
            print("Deleted series " .. seriesId .. " after send (rule: " .. (rule.name or "?") .. ")")
          end
        end
      end
    end
  end
end

-- ════════════════════════════════════════════════
--  POLL Rules: Periodic PACS Query Engine
-- ════════════════════════════════════════════════

POLL_TIMER_INTERVAL = 60  -- Check every 60 seconds if any poll rule needs to run

function RunPollRule(rule, ruleIndex)
  if not rule.source or rule.source == "" then
    print("Poll rule '" .. (rule.name or "?") .. "' has no source modality configured, skipping")
    return
  end
  if not rule.destination or rule.destination == "" then
    print("Poll rule '" .. (rule.name or "?") .. "' has no destination configured, skipping")
    return
  end

  print("=== Poll rule '" .. (rule.name or "?") .. "' starting: query " .. rule.source .. " ===")

  -- Build C-FIND query
  local query = {}
  query["StudyDescription"] = ""
  query["ModalitiesInStudy"] = ""
  query["StudyInstanceUID"] = ""
  query["PatientName"] = ""
  query["PatientID"] = ""
  query["AccessionNumber"] = ""

  -- Apply modality filter to query (server-side filter)
  if rule.filterModality and rule.filterModality ~= "" and not rule.filterModality:find("!") then
    query["ModalitiesInStudy"] = rule.filterModality
  end

  -- Apply study description filter to query
  local descFilter = rule.filterStudyDescription or rule.filterDescription or ""
  if descFilter ~= "" and not descFilter:find("!") then
    query["StudyDescription"] = descFilter
  end

  -- Apply date range
  local dateRange = GetDateRangeQuery(rule.filterDateRange or "")
  if dateRange ~= "" then
    query["StudyDate"] = dateRange
  end

  -- Execute C-FIND at study level
  local queryBody = {
    Level = "Study",
    Query = query
  }

  local queryOk, queryResult = pcall(function()
    return ParseJson(RestApiPost("/modalities/" .. rule.source .. "/query", DumpJson(queryBody)))
  end)

  if not queryOk or not queryResult then
    print("Poll rule '" .. (rule.name or "?") .. "': C-FIND query failed: " .. tostring(queryResult))
    return
  end

  local queryId = queryResult.ID
  if not queryId then
    print("Poll rule '" .. (rule.name or "?") .. "': C-FIND returned no query ID")
    return
  end

  -- Get answers
  local answersOk, answers = pcall(function()
    return ParseJson(RestApiGet("/queries/" .. queryId .. "/answers"))
  end)

  if not answersOk or not answers then
    print("Poll rule '" .. (rule.name or "?") .. "': Failed to get query answers")
    return
  end

  print("Poll rule '" .. (rule.name or "?") .. "': Found " .. #answers .. " study matches")

  local sendLevel = rule.sendLevel or "study"

  for _, answerIndex in ipairs(answers) do
    -- Get the answer content (DICOM tags)
    local ansOk, ansContent = pcall(function()
      return ParseJson(RestApiGet("/queries/" .. queryId .. "/answers/" .. answerIndex .. "/content"))
    end)

    if ansOk and ansContent then
      local studyUid = ansContent["0020,000d"] or ansContent["StudyInstanceUID"] or ""
      local studyDescription = ansContent["0008,1030"] or ansContent["StudyDescription"] or ""
      local patientName = ansContent["0010,0010"] or ansContent["PatientName"] or ""
      local studyModality = ansContent["0008,0061"] or ansContent["ModalitiesInStudy"] or ""

      -- Apply local filters that C-FIND may not support well (negation, complex wildcards)
      local match = true
      if rule.filterModality and rule.filterModality:find("!") then
        if not MatchesFilter(studyModality, rule.filterModality) then match = false end
      end
      if descFilter:find("!") then
        if not MatchesFilter(studyDescription, descFilter) then match = false end
      end

      if match then
        if sendLevel == "series" then
          -- Need to do a series-level query for this study
          PollProcessStudySeries(rule, queryId, answerIndex, studyUid, studyDescription, patientName, studyModality)
        else
          -- Study-level: C-MOVE the whole study
          if IsAlreadySent(rule.name or "", rule.destination, studyUid, "study") then
            -- Already sent, skip
          else
            print("Poll: Retrieving study " .. studyUid .. " (" .. patientName .. ") from " .. rule.source)
            local moveOk, moveResult = pcall(function()
              return RestApiPost("/queries/" .. queryId .. "/answers/" .. answerIndex .. "/retrieve",
                ParseJson(RestApiGet("/system")).DicomAet or "ORTHANC")
            end)

            if moveOk then
              -- Wait briefly for the study to arrive
              local localStudyId = WaitForStudy(studyUid, 30)
              if localStudyId then
                -- Forward to destination
                print("Poll: Forwarding study " .. studyUid .. " to " .. rule.destination)
                local fwdOk, fwdErr = pcall(function()
                  return RestApiPost("/modalities/" .. rule.destination .. "/store", localStudyId)
                end)
                if fwdOk then
                  MarkAsSent(rule.name or "", rule.destination, studyUid, "study")
                  AppendRoutingLog(localStudyId, rule.name, rule.destination, "sent", "", rule.source, "", studyDescription, studyModality, "", "poll", "study", "")
                  print("Poll: Sent study " .. studyUid .. " to " .. rule.destination)
                  -- Delete after send
                  if rule.deleteAfterSend then
                    pcall(RestApiDelete, "/studies/" .. localStudyId)
                    print("Poll: Deleted local copy of study " .. studyUid)
                  end
                else
                  AppendRoutingLog(localStudyId or studyUid, rule.name, rule.destination, "failed", tostring(fwdErr), rule.source, "", studyDescription, studyModality, "", "poll", "study", "")
                  print("Poll: Failed to forward study " .. studyUid .. ": " .. tostring(fwdErr))
                end
              else
                print("Poll: Study " .. studyUid .. " did not arrive within timeout")
                AppendRoutingLog(studyUid, rule.name, rule.destination, "failed", "Study did not arrive after C-MOVE", rule.source, "", studyDescription, studyModality, "", "poll", "study", "")
              end
            else
              print("Poll: C-MOVE failed for study " .. studyUid .. ": " .. tostring(moveResult))
              AppendRoutingLog(studyUid, rule.name, rule.destination, "failed", "C-MOVE failed: " .. tostring(moveResult), rule.source, "", studyDescription, studyModality, "", "poll", "study", "")
            end
          end
        end
      end
    end
  end

  print("=== Poll rule '" .. (rule.name or "?") .. "' complete ===")
end

-- Process series within a study for poll rules with series-level routing
function PollProcessStudySeries(rule, studyQueryId, studyAnswerIndex, studyUid, studyDescription, patientName, studyModality)
  -- Do a series-level C-FIND for this study
  local seriesQuery = {
    Level = "Series",
    Query = {
      StudyInstanceUID = studyUid,
      SeriesDescription = "",
      SeriesInstanceUID = "",
      Modality = "",
      NumberOfSeriesRelatedInstances = ""
    }
  }

  -- Apply series description filter to the C-FIND query
  if rule.filterSeriesDescription and rule.filterSeriesDescription ~= "" and not rule.filterSeriesDescription:find("!") then
    seriesQuery.Query.SeriesDescription = rule.filterSeriesDescription
  end

  -- Apply modality filter at series level
  if rule.filterModality and rule.filterModality ~= "" and not rule.filterModality:find("!") then
    seriesQuery.Query.Modality = rule.filterModality
  end

  local sqOk, sqResult = pcall(function()
    return ParseJson(RestApiPost("/modalities/" .. rule.source .. "/query", DumpJson(seriesQuery)))
  end)

  if not sqOk or not sqResult then
    print("Poll: Series query failed for study " .. studyUid .. ": " .. tostring(sqResult))
    return
  end

  local sqId = sqResult.ID
  if not sqId then return end

  local saOk, seriesAnswers = pcall(function()
    return ParseJson(RestApiGet("/queries/" .. sqId .. "/answers"))
  end)

  if not saOk or not seriesAnswers then return end

  print("Poll: Study " .. studyUid .. " has " .. #seriesAnswers .. " matching series")

  for _, seriesIdx in ipairs(seriesAnswers) do
    local scOk, seriesContent = pcall(function()
      return ParseJson(RestApiGet("/queries/" .. sqId .. "/answers/" .. seriesIdx .. "/content"))
    end)

    if scOk and seriesContent then
      local seriesUid = seriesContent["0020,000e"] or seriesContent["SeriesInstanceUID"] or ""
      local seriesDesc = seriesContent["0008,103e"] or seriesContent["SeriesDescription"] or ""
      local seriesMod = seriesContent["0008,0060"] or seriesContent["Modality"] or ""

      -- Apply local filters (negation patterns)
      local seriesMatch = true
      if rule.filterSeriesDescription and rule.filterSeriesDescription:find("!") then
        if not MatchesFilter(seriesDesc, rule.filterSeriesDescription) then seriesMatch = false end
      end
      if rule.filterModality and rule.filterModality:find("!") then
        if not MatchesFilter(seriesMod, rule.filterModality) then seriesMatch = false end
      end

      if seriesMatch and seriesUid ~= "" then
        -- Check dedup
        if IsAlreadySent(rule.name or "", rule.destination, seriesUid, "series") then
          -- Already sent, skip silently
        else
          print("Poll: Retrieving series " .. seriesUid .. " (" .. seriesDesc .. ") from " .. rule.source)

          -- C-MOVE the series
          local moveOk, moveResult = pcall(function()
            return RestApiPost("/queries/" .. sqId .. "/answers/" .. seriesIdx .. "/retrieve",
              ParseJson(RestApiGet("/system")).DicomAet or "ORTHANC")
          end)

          if moveOk then
            -- Wait for series to arrive locally
            local localSeriesId = WaitForSeries(seriesUid, 60)
            if localSeriesId then
              -- Forward to destination
              print("Poll: Forwarding series " .. seriesUid .. " to " .. rule.destination)
              local fwdOk, fwdErr = pcall(function()
                return RestApiPost("/modalities/" .. rule.destination .. "/store", localSeriesId)
              end)
              if fwdOk then
                MarkAsSent(rule.name or "", rule.destination, seriesUid, "series")
                AppendRoutingLog(studyUid, rule.name, rule.destination, "sent", "", rule.source, "", studyDescription, seriesMod, seriesUid, "poll", "series", seriesDesc)
                print("Poll: Sent series " .. seriesUid .. " to " .. rule.destination)
                -- Delete series after send
                if rule.deleteAfterSend then
                  pcall(RestApiDelete, "/series/" .. localSeriesId)
                  print("Poll: Deleted local series " .. seriesUid)
                end
              else
                AppendRoutingLog(studyUid, rule.name, rule.destination, "failed", tostring(fwdErr), rule.source, "", studyDescription, seriesMod, seriesUid, "poll", "series", seriesDesc)
                print("Poll: Failed to forward series " .. seriesUid .. ": " .. tostring(fwdErr))
              end
            else
              print("Poll: Series " .. seriesUid .. " did not arrive within timeout")
              AppendRoutingLog(studyUid, rule.name, rule.destination, "failed", "Series did not arrive after C-MOVE", rule.source, "", studyDescription, seriesMod, seriesUid, "poll", "series", seriesDesc)
            end
          else
            print("Poll: C-MOVE failed for series " .. seriesUid .. ": " .. tostring(moveResult))
          end
        end
      end
    end
  end
end

-- Wait for a study to arrive locally by StudyInstanceUID
function WaitForStudy(studyInstanceUid, timeoutSecs)
  local elapsed = 0
  local checkInterval = 2
  while elapsed < timeoutSecs do
    local ok, result = pcall(function()
      return ParseJson(RestApiPost("/tools/find", DumpJson({
        Level = "Study",
        Query = { StudyInstanceUID = studyInstanceUid },
        Expand = false
      })))
    end)
    if ok and result and #result > 0 then
      return result[1]
    end
    os.execute("sleep " .. checkInterval)
    elapsed = elapsed + checkInterval
  end
  return nil
end

-- Wait for a series to arrive locally by SeriesInstanceUID
function WaitForSeries(seriesInstanceUid, timeoutSecs)
  local elapsed = 0
  local checkInterval = 2
  while elapsed < timeoutSecs do
    local ok, result = pcall(function()
      return ParseJson(RestApiPost("/tools/find", DumpJson({
        Level = "Series",
        Query = { SeriesInstanceUID = seriesInstanceUid },
        Expand = false
      })))
    end)
    if ok and result and #result > 0 then
      return result[1]
    end
    os.execute("sleep " .. checkInterval)
    elapsed = elapsed + checkInterval
  end
  return nil
end

-- ════════════════════════════════════════════════
--  Poll Timer / Scheduler
-- ════════════════════════════════════════════════

function CheckPollRules()
  local now = os.time()
  for i, rule in ipairs(ROUTING_RULES) do
    local ruleType = rule.type or "push"
    if ruleType == "poll" and rule.enabled then
      local interval = (tonumber(rule.pollIntervalMinutes) or 5) * 60
      local lastRun = POLL_LAST_RUN[i] or 0
      if (now - lastRun) >= interval then
        POLL_LAST_RUN[i] = now
        -- Run the poll rule
        local ok, err = pcall(RunPollRule, rule, i)
        if not ok then
          print("Poll rule '" .. (rule.name or "?") .. "' error: " .. tostring(err))
        end
      end
    end
  end
end

-- Manual trigger for a specific poll rule (called from admin UI via Lua script execution)
function RunPollRuleByName(name)
  for i, rule in ipairs(ROUTING_RULES) do
    if rule.name == name and (rule.type or "push") == "poll" then
      print("Manual trigger for poll rule: " .. name)
      POLL_LAST_RUN[i] = os.time()
      local ok, err = pcall(RunPollRule, rule, i)
      if not ok then
        print("ERROR: " .. tostring(err))
      else
        print("OK: Poll rule completed")
      end
      return
    end
  end
  print("ERROR: Poll rule not found: " .. name)
end

-- Get poll status for all rules (called from admin UI)
function GetPollStatus()
  local result = {}
  local now = os.time()
  for i, rule in ipairs(ROUTING_RULES) do
    if (rule.type or "push") == "poll" then
      local lastRun = POLL_LAST_RUN[i] or 0
      local interval = (tonumber(rule.pollIntervalMinutes) or 5) * 60
      local nextRun = 0
      if lastRun > 0 then
        nextRun = lastRun + interval - now
        if nextRun < 0 then nextRun = 0 end
      end
      table.insert(result, {
        name = rule.name or "",
        lastRun = lastRun > 0 and os.date("!%Y-%m-%dT%H:%M:%SZ", lastRun) or "",
        nextRunSecs = nextRun,
        intervalMinutes = tonumber(rule.pollIntervalMinutes) or 5
      })
    end
  end
  print(DumpJson(result))
end

-- ════════════════════════════════════════════════
--  Initialize
-- ════════════════════════════════════════════════

LoadRoutingRules()

-- Start the poll timer if any poll rules exist
function HasPollRules()
  for _, rule in ipairs(ROUTING_RULES) do
    if (rule.type or "push") == "poll" and rule.enabled then
      return true
    end
  end
  return false
end

-- OnHeartBeat: Orthanc calls this periodically (configured via LuaHeartBeatPeriod)
-- We use it to check if any poll rules need to run
function OnHeartBeat()
  CheckPollRules()
end

print("Auto-routing engine initialized with " .. #ROUTING_RULES .. " rule(s)")
if HasPollRules() then
  print("Poll rules detected - poll timer active via OnHeartBeat")
end
