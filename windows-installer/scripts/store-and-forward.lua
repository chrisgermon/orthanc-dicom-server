-- CrowdDICOM Store-and-Forward with Disk Space Management
-- Threshold and drive letter are patched by the installer

local DISK_USAGE_THRESHOLD = {DISK_THRESHOLD}
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
   local sd  = tags["StudyDescription"] or ""
   print("[RECEIVED] " .. instanceId .. " | " .. pn .. " | " .. mod .. " | " .. sd)
   ForwardInstance(instanceId)
end

function OnJobFailure(jobId)
   print("[JOB FAIL] " .. jobId)
   local job = ParseJson(RestApiGet("/jobs/" .. jobId))
   if job["Type"] == "DicomModalityStore" then
      if job["ErrorCode"] == 9 then
         print("[RETRY] Resubmitting job " .. jobId)
         RestApiPost("/jobs/" .. jobId .. "/resubmit", "")
      elseif job["ErrorCode"] == -1 then
         print("[JOB FAIL] Internal error, not retrying " .. jobId)
      else
         print("[JOB FAIL] Error code " .. tostring(job["ErrorCode"]))
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
   local handle = io.popen('wmic logicaldisk where "DeviceID=\'{DRIVE_LETTER}:\'" get FreeSpace,Size /format:csv 2>NUL')
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
   print("[CLEANUP] WARNING: Could not determine disk usage")
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
      if #all > 0 then
         print("[CLEANUP] Deleting study " .. all[1])
         RestApiDelete("/studies/" .. all[1])
      end
      return
   end

   local study = oldest[1]
   local pn = "Unknown"
   if study["PatientMainDicomTags"] and study["PatientMainDicomTags"]["PatientName"] then
      pn = study["PatientMainDicomTags"]["PatientName"]
   end
   print("[CLEANUP] Deleting " .. study["ID"] .. " | " .. pn)
   RestApiDelete("/studies/" .. study["ID"])
end
