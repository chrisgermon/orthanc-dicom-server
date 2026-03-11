-- ═══════════════════════════════════════════════════════════════════
-- CrowdDICOM — Store-and-Forward with Disk Space Management
-- ═══════════════════════════════════════════════════════════════════
--
-- This Lua script:
--   1. Forwards every received DICOM instance to the 'destination' modality
--   2. On startup, re-queues any instances not yet forwarded
--   3. Retries failed forwarding jobs on network errors
--   4. Periodically checks disk usage and deletes oldest studies
--      when the configured threshold is exceeded
--
-- Requirements:
--   - Orthanc 1.12.5+ (for ExtendedFind / OrderBy support)
--   - A DicomModality named 'destination' must be configured
--   - DISK_THRESHOLD environment variable (default 70)
--   - LuaHeartBeatPeriod should be set (recommended: 60)
-- ═══════════════════════════════════════════════════════════════════

-- ─── Configuration ───────────────────────────────────────────────

-- Read disk threshold from environment variable, default to 70%
local DISK_USAGE_THRESHOLD = tonumber(os.getenv("DISK_THRESHOLD") or "70")

-- Name of the modality target (must match docker-compose DicomModalities key)
local DESTINATION_MODALITY = "destination"

-- ─── Startup: re-queue anything that's still in local storage ────

function Initialize()
   print("═══════════════════════════════════════════════════════════")
   print("  CrowdDICOM Store-and-Forward starting")
   print("  Disk usage threshold: " .. DISK_USAGE_THRESHOLD .. "%")
   print("═══════════════════════════════════════════════════════════")

   -- Forward every instance currently in Orthanc
   -- (These may have been received while forwarding was down)
   local allInstances = ParseJson(RestApiGet("/instances"))
   local count = #allInstances

   if count > 0 then
      print("  Re-queuing " .. count .. " instance(s) found at startup …")
      for i, instanceId in pairs(allInstances) do
         ForwardInstance(instanceId)
      end
   else
      print("  No pending instances found at startup.")
   end

   print("═══════════════════════════════════════════════════════════")
end

-- ─── Forward a single instance to the destination ────────────────

function ForwardInstance(instanceId)
   local payload = {}
   payload["Resources"] = { instanceId }
   payload["Asynchronous"] = true
   payload["Priority"] = 1

   local result = RestApiPost("/modalities/" .. DESTINATION_MODALITY .. "/store",
                              DumpJson(payload, false))
   local job = ParseJson(result)

   print("[FORWARD] Created job " .. job["ID"] ..
         " for instance " .. instanceId)
end

-- ─── OnStoredInstance: forward every new instance ────────────────

function OnStoredInstance(instanceId, tags, metadata, origin)
   -- Avoid re-forwarding instances uploaded by our own Lua script
   if origin and origin["RequestOrigin"] == "Lua" then
      return
   end

   -- Log the received instance
   local patientName = tags["PatientName"] or "Unknown"
   local modality    = tags["Modality"]    or "?"
   local studyDesc   = tags["StudyDescription"] or ""

   print("[RECEIVED] Instance " .. instanceId ..
         " | Patient: " .. patientName ..
         " | Modality: " .. modality ..
         " | Study: " .. studyDesc)

   ForwardInstance(instanceId)
end

-- ─── Job failure: retry on network errors ────────────────────────

function OnJobFailure(jobId)
   print("[JOB FAIL] Job " .. jobId .. " failed")

   local job = ParseJson(RestApiGet("/jobs/" .. jobId))

   if job["Type"] == "DicomModalityStore" then
      local errorCode = job["ErrorCode"]

      if errorCode == 9 then
         -- Error 9 = network protocol error → retry
         print("[JOB FAIL] Network error (code 9), resubmitting job " .. jobId)
         RestApiPost("/jobs/" .. jobId .. "/resubmit", "")

      elseif errorCode == -1 then
         -- Internal error (e.g. instance deleted before job ran)
         print("[JOB FAIL] Internal error (code -1), not retrying job " .. jobId)

      else
         print("[JOB FAIL] Unhandled error code " .. tostring(errorCode) ..
               " for job " .. jobId)
         PrintRecursive(job)
      end
   end
end

-- ─── Job success: log it ─────────────────────────────────────────

function OnJobSuccess(jobId)
   local job = ParseJson(RestApiGet("/jobs/" .. jobId))

   if job["Type"] == "DicomModalityStore" then
      local parentResources = job["Content"]["ParentResources"]
      if parentResources and #parentResources > 0 then
         print("[FORWARDED] Job " .. jobId ..
               " succeeded — instance " .. parentResources[1] ..
               " delivered to " .. DESTINATION_MODALITY)
      else
         print("[FORWARDED] Job " .. jobId .. " succeeded")
      end
   end
end

-- ─── Heartbeat: disk usage cleanup every LuaHeartBeatPeriod ──────

function OnHeartBeat()
   CleanupDiskSpace()
end

-- ─── Disk space management ───────────────────────────────────────

function GetDiskUsagePercent()
   -- Use the Orthanc statistics endpoint + system info to compute
   -- actual filesystem usage via /proc or df
   -- For Docker containers with a named volume this is the best approach:
   local handle = io.popen("df --output=pcent /var/lib/orthanc/db 2>/dev/null | tail -1 | tr -d ' %'")
   if handle then
      local result = handle:read("*a")
      handle:close()
      local percent = tonumber(result)
      if percent then
         return percent
      end
   end

   -- Fallback: try macOS-style df
   handle = io.popen("df -k /var/lib/orthanc/db 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%'")
   if handle then
      local result = handle:read("*a")
      handle:close()
      local percent = tonumber(result)
      if percent then
         return percent
      end
   end

   print("[CLEANUP] WARNING: Could not determine disk usage, skipping cleanup")
   return 0
end

function CleanupDiskSpace()
   local usage = GetDiskUsagePercent()

   if usage < DISK_USAGE_THRESHOLD then
      return  -- nothing to do
   end

   print("[CLEANUP] Disk usage is " .. usage .. "% (threshold: " ..
         DISK_USAGE_THRESHOLD .. "%), deleting oldest study …")

   -- Use ExtendedFind to get the oldest study by LastUpdate metadata
   local findPayload = DumpJson({
      Level   = "Study",
      Expand  = true,
      Query   = {},
      OrderBy = {
         { Type = "Metadata", Key = "LastUpdate", Direction = "ASC" }
      },
      Limit   = 1
   }, false)

   local ok, oldest = pcall(function()
      return ParseJson(RestApiPost("/tools/find", findPayload))
   end)

   if not ok or not oldest or #oldest == 0 then
      -- Fallback for older Orthanc versions without ExtendedFind
      print("[CLEANUP] ExtendedFind not available, using fallback method …")
      local allStudies = ParseJson(RestApiGet("/studies"))
      if #allStudies == 0 then
         print("[CLEANUP] No studies to delete")
         return
      end
      -- Just delete the first one (oldest by insertion order for SQLite)
      local studyId = allStudies[1]
      local studyInfo = ParseJson(RestApiGet("/studies/" .. studyId))
      local patientName = studyInfo["PatientMainDicomTags"]["PatientName"] or "Unknown"
      print("[CLEANUP] Deleting study " .. studyId ..
            " | Patient: " .. patientName)
      RestApiDelete("/studies/" .. studyId)
      return
   end

   local study = oldest[1]
   local patientName = "Unknown"
   if study["PatientMainDicomTags"] and study["PatientMainDicomTags"]["PatientName"] then
      patientName = study["PatientMainDicomTags"]["PatientName"]
   end
   local lastUpdate = study["LastUpdate"] or "?"

   print("[CLEANUP] Deleting study " .. study["ID"] ..
         " | Patient: " .. patientName ..
         " | LastUpdate: " .. lastUpdate)

   RestApiDelete("/studies/" .. study["ID"])
end
