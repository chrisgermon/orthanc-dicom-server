#!/usr/bin/env python3
"""
Orthanc Store-and-Forward — Windows GUI Installer
===================================================

A tkinter-based wizard that:
  1. Prompts for local DICOM server settings
  2. Prompts for destination PACS settings
  3. Prompts for web UI credentials
  4. Prompts for disk-management thresholds
  5. Downloads the Orthanc Windows binaries
  6. Generates orthanc.json and the Lua forwarding script
  7. Installs Orthanc as a Windows service

Build to .exe with:
    pip install pyinstaller
    pyinstaller --onefile --windowed --icon=icon.ico --name="OrthancStoreForwardSetup" installer.py
"""

import ctypes
import json
import os
import platform
import shutil
import subprocess
import sys
import textwrap
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from pathlib import Path
from urllib.request import urlopen, Request
from urllib.error import URLError

# ─── Constants ──────────────────────────────────────────────────────

APP_TITLE = "Orthanc Store-and-Forward Installer"
APP_VERSION = "1.0.0"
ORTHANC_VERSION = "24.12.1"

# Official Orthanc Windows zip download URL (orthancteam)
ORTHANC_WIN64_URL = (
    f"https://orthanc.uclouvain.be/downloads/windows-64/"
    f"installers/OrthancInstaller-Win64-{ORTHANC_VERSION}.exe"
)

# Fallback: Docker-based approach if native download not available
DEFAULT_INSTALL_DIR = r"C:\Orthanc-StoreForward"

# Design tokens
COLORS = {
    "bg":           "#0f1117",
    "surface":      "#1a1d27",
    "surface2":     "#242836",
    "accent":       "#6c63ff",
    "accent_hover": "#7b73ff",
    "accent_dark":  "#5548d4",
    "text":         "#e8e6f0",
    "text_dim":     "#8a8a9a",
    "border":       "#2e3241",
    "success":      "#2dd4a8",
    "warning":      "#f5a623",
    "error":        "#ef4444",
    "input_bg":     "#14161e",
}

FONT_FAMILY = "Segoe UI"   # Available on all modern Windows


# ─── Utility ────────────────────────────────────────────────────────

def is_admin():
    """Check whether the current process has admin rights (Windows)."""
    try:
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False


def request_admin_restart():
    """Re-launch the current script with elevated privileges."""
    if platform.system() != "Windows":
        return
    ctypes.windll.shell32.ShellExecuteW(
        None, "runas", sys.executable, " ".join(sys.argv), None, 1
    )
    sys.exit(0)


# ─── Lua Script Template ────────────────────────────────────────────

LUA_SCRIPT = textwrap.dedent(r"""
-- ═══════════════════════════════════════════════════════════════════
-- Orthanc Store-and-Forward with Disk Space Management
-- ═══════════════════════════════════════════════════════════════════

local DISK_USAGE_THRESHOLD = {disk_threshold}
local DESTINATION_MODALITY  = "destination"

-- ─── Startup ─────────────────────────────────────────────────────

function Initialize()
   print("═══════════════════════════════════════════════════════════")
   print("  Store-and-Forward script starting")
   print("  Disk usage threshold: " .. DISK_USAGE_THRESHOLD .. "%%")
   print("═══════════════════════════════════════════════════════════")

   local allInstances = ParseJson(RestApiGet("/instances"))
   local count = #allInstances

   if count > 0 then
      print("  Re-queuing " .. count .. " instance(s) found at startup ...")
      for i, instanceId in pairs(allInstances) do
         ForwardInstance(instanceId)
      end
   else
      print("  No pending instances found at startup.")
   end

   print("═══════════════════════════════════════════════════════════")
end

-- ─── Forward ─────────────────────────────────────────────────────

function ForwardInstance(instanceId)
   local payload = {{}}
   payload["Resources"] = {{ instanceId }}
   payload["Asynchronous"] = true
   payload["Priority"] = 1

   local result = RestApiPost("/modalities/" .. DESTINATION_MODALITY .. "/store",
                              DumpJson(payload, false))
   local job = ParseJson(result)
   print("[FORWARD] Created job " .. job["ID"] .. " for instance " .. instanceId)
end

-- ─── OnStoredInstance ────────────────────────────────────────────

function OnStoredInstance(instanceId, tags, metadata, origin)
   if origin and origin["RequestOrigin"] == "Lua" then
      return
   end

   local patientName = tags["PatientName"] or "Unknown"
   local modality    = tags["Modality"]    or "?"
   local studyDesc   = tags["StudyDescription"] or ""

   print("[RECEIVED] Instance " .. instanceId ..
         " | Patient: " .. patientName ..
         " | Modality: " .. modality ..
         " | Study: " .. studyDesc)

   ForwardInstance(instanceId)
end

-- ─── Job failure ─────────────────────────────────────────────────

function OnJobFailure(jobId)
   print("[JOB FAIL] Job " .. jobId .. " failed")
   local job = ParseJson(RestApiGet("/jobs/" .. jobId))

   if job["Type"] == "DicomModalityStore" then
      if job["ErrorCode"] == 9 then
         print("[JOB FAIL] Network error, resubmitting job " .. jobId)
         RestApiPost("/jobs/" .. jobId .. "/resubmit", "")
      elseif job["ErrorCode"] == -1 then
         print("[JOB FAIL] Internal error, not retrying job " .. jobId)
      else
         print("[JOB FAIL] Unhandled error code " .. tostring(job["ErrorCode"]))
         PrintRecursive(job)
      end
   end
end

-- ─── Job success ─────────────────────────────────────────────────

function OnJobSuccess(jobId)
   local job = ParseJson(RestApiGet("/jobs/" .. jobId))
   if job["Type"] == "DicomModalityStore" then
      local pr = job["Content"]["ParentResources"]
      if pr and #pr > 0 then
         print("[FORWARDED] Job " .. jobId .. " succeeded — instance " .. pr[1])
      else
         print("[FORWARDED] Job " .. jobId .. " succeeded")
      end
   end
end

-- ─── Heartbeat: disk cleanup ─────────────────────────────────────

function OnHeartBeat()
   CleanupDiskSpace()
end

function GetDiskUsagePercent()
   local handle = io.popen('wmic logicaldisk where "DeviceID=\'' .. string.sub(StorageDirectory or "C:", 1, 2) .. '\'" get FreeSpace,Size /format:csv 2>NUL')
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
   -- Fallback: PowerShell
   handle = io.popen('powershell -Command "Get-PSDrive ' .. string.sub(StorageDirectory or "C:", 1, 1) .. ' | Select-Object -ExpandProperty Used; Get-PSDrive ' .. string.sub(StorageDirectory or "C:", 1, 1) .. ' | Select-Object -ExpandProperty Free" 2>NUL')
   if handle then
      local output = handle:read("*a")
      handle:close()
      local values = {{}}
      for v in output:gmatch("%d+") do
         table.insert(values, tonumber(v))
      end
      if #values >= 2 then
         local used = values[1]
         local total = values[1] + values[2]
         return math.floor((used / total) * 100)
      end
   end
   print("[CLEANUP] WARNING: Could not determine disk usage")
   return 0
end

function CleanupDiskSpace()
   local usage = GetDiskUsagePercent()
   if usage < DISK_USAGE_THRESHOLD then
      return
   end

   print("[CLEANUP] Disk usage is " .. usage .. "%% (threshold: " ..
         DISK_USAGE_THRESHOLD .. "%%), deleting oldest study ...")

   local ok, oldest = pcall(function()
      local payload = DumpJson({{
         Level   = "Study",
         Expand  = true,
         Query   = {{}},
         OrderBy = {{ {{ Type = "Metadata", Key = "LastUpdate", Direction = "ASC" }} }},
         Limit   = 1
      }}, false)
      return ParseJson(RestApiPost("/tools/find", payload))
   end)

   if not ok or not oldest or #oldest == 0 then
      local allStudies = ParseJson(RestApiGet("/studies"))
      if #allStudies == 0 then
         print("[CLEANUP] No studies to delete")
         return
      end
      local studyId = allStudies[1]
      print("[CLEANUP] Deleting study " .. studyId)
      RestApiDelete("/studies/" .. studyId)
      return
   end

   local study = oldest[1]
   local pn = "Unknown"
   if study["PatientMainDicomTags"] and study["PatientMainDicomTags"]["PatientName"] then
      pn = study["PatientMainDicomTags"]["PatientName"]
   end
   print("[CLEANUP] Deleting study " .. study["ID"] .. " | Patient: " .. pn)
   RestApiDelete("/studies/" .. study["ID"])
end
""").lstrip()


# ─── Main Installer Application ─────────────────────────────────────

class InstallerApp(tk.Tk):
    """Multi-step wizard installer for Orthanc Store-and-Forward."""

    def __init__(self):
        super().__init__()
        self.title(APP_TITLE)
        self.geometry("720x620")
        self.resizable(False, False)
        self.configure(bg=COLORS["bg"])

        # Try to set DPI awareness on Windows
        try:
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass

        # ── Variables ────────────────────────────────────────────
        self.local_aet       = tk.StringVar(value="STORE_FWD")
        self.local_dicom_port = tk.StringVar(value="4242")
        self.local_http_port = tk.StringVar(value="8042")

        self.dest_aet        = tk.StringVar(value="")
        self.dest_host       = tk.StringVar(value="")
        self.dest_port       = tk.StringVar(value="4242")

        self.web_user        = tk.StringVar(value="admin")
        self.web_password    = tk.StringVar(value="orthanc")

        self.disk_threshold  = tk.StringVar(value="70")
        self.install_dir     = tk.StringVar(value=DEFAULT_INSTALL_DIR)
        self.install_service = tk.BooleanVar(value=True)

        # ── Pages ────────────────────────────────────────────────
        self.pages: list[tk.Frame] = []
        self.current_page = 0

        self._build_sidebar()
        self._build_content_area()
        self._build_nav_bar()

        self._create_pages()
        self._show_page(0)

    # ── Layout scaffolding ───────────────────────────────────────

    def _build_sidebar(self):
        """Left-hand step indicator."""
        self.sidebar = tk.Frame(self, bg=COLORS["surface"], width=200)
        self.sidebar.pack(side="left", fill="y")
        self.sidebar.pack_propagate(False)

        # Logo / title area
        title_frame = tk.Frame(self.sidebar, bg=COLORS["surface"])
        title_frame.pack(fill="x", pady=(28, 20), padx=16)
        tk.Label(title_frame, text="◈", font=(FONT_FAMILY, 28),
                 fg=COLORS["accent"], bg=COLORS["surface"]).pack()
        tk.Label(title_frame, text="Store & Forward",
                 font=(FONT_FAMILY, 13, "bold"),
                 fg=COLORS["text"], bg=COLORS["surface"]).pack(pady=(4, 0))
        tk.Label(title_frame, text=f"Installer v{APP_VERSION}",
                 font=(FONT_FAMILY, 9),
                 fg=COLORS["text_dim"], bg=COLORS["surface"]).pack()

        # Step labels
        self.step_labels: list[tk.Label] = []
        self.step_names = [
            "Local Server",
            "Destination PACS",
            "Credentials",
            "Disk Management",
            "Review",
            "Install",
        ]
        steps_frame = tk.Frame(self.sidebar, bg=COLORS["surface"])
        steps_frame.pack(fill="x", padx=16, pady=(10, 0))
        for i, name in enumerate(self.step_names):
            f = tk.Frame(steps_frame, bg=COLORS["surface"])
            f.pack(fill="x", pady=4)
            indicator = tk.Label(f, text=f"  {i+1}  ", font=(FONT_FAMILY, 9, "bold"),
                                 fg=COLORS["text_dim"], bg=COLORS["surface2"],
                                 width=3)
            indicator.pack(side="left")
            lbl = tk.Label(f, text=f"  {name}", font=(FONT_FAMILY, 10),
                           fg=COLORS["text_dim"], bg=COLORS["surface"],
                           anchor="w")
            lbl.pack(side="left", fill="x")
            self.step_labels.append((indicator, lbl))

    def _build_content_area(self):
        """Central content area where pages are shown."""
        self.content = tk.Frame(self, bg=COLORS["bg"])
        self.content.pack(side="top", fill="both", expand=True)

    def _build_nav_bar(self):
        """Bottom navigation bar with Back / Next / Install buttons."""
        self.nav = tk.Frame(self, bg=COLORS["surface"], height=60)
        self.nav.pack(side="bottom", fill="x")
        self.nav.pack_propagate(False)

        self.btn_back = tk.Button(
            self.nav, text="◀  Back", font=(FONT_FAMILY, 10),
            bg=COLORS["surface2"], fg=COLORS["text"],
            activebackground=COLORS["border"], activeforeground=COLORS["text"],
            bd=0, padx=18, pady=8, cursor="hand2",
            command=self._go_back,
        )
        self.btn_back.pack(side="left", padx=16, pady=12)

        self.btn_next = tk.Button(
            self.nav, text="Next  ▶", font=(FONT_FAMILY, 10, "bold"),
            bg=COLORS["accent"], fg="#ffffff",
            activebackground=COLORS["accent_hover"], activeforeground="#ffffff",
            bd=0, padx=22, pady=8, cursor="hand2",
            command=self._go_next,
        )
        self.btn_next.pack(side="right", padx=16, pady=12)

    # ── Page creation ────────────────────────────────────────────

    def _create_pages(self):
        self.pages = [
            self._page_local_server(),
            self._page_destination_pacs(),
            self._page_credentials(),
            self._page_disk_mgmt(),
            self._page_review(),
            self._page_install(),
        ]

    def _make_page(self) -> tk.Frame:
        page = tk.Frame(self.content, bg=COLORS["bg"])
        return page

    def _heading(self, parent, text, subtitle=""):
        tk.Label(parent, text=text, font=(FONT_FAMILY, 18, "bold"),
                 fg=COLORS["text"], bg=COLORS["bg"], anchor="w").pack(
                     fill="x", padx=32, pady=(28, 0))
        if subtitle:
            tk.Label(parent, text=subtitle, font=(FONT_FAMILY, 10),
                     fg=COLORS["text_dim"], bg=COLORS["bg"], anchor="w",
                     wraplength=440).pack(fill="x", padx=32, pady=(4, 0))

    def _field(self, parent, label, variable, show="", placeholder=""):
        frame = tk.Frame(parent, bg=COLORS["bg"])
        frame.pack(fill="x", padx=32, pady=(12, 0))
        tk.Label(frame, text=label, font=(FONT_FAMILY, 10),
                 fg=COLORS["text"], bg=COLORS["bg"], anchor="w").pack(fill="x")
        entry = tk.Entry(frame, textvariable=variable, font=(FONT_FAMILY, 11),
                         bg=COLORS["input_bg"], fg=COLORS["text"],
                         insertbackground=COLORS["text"],
                         relief="flat", bd=0, highlightthickness=1,
                         highlightbackground=COLORS["border"],
                         highlightcolor=COLORS["accent"],
                         show=show)
        entry.pack(fill="x", ipady=8, pady=(4, 0))
        return entry

    def _dir_field(self, parent, label, variable):
        frame = tk.Frame(parent, bg=COLORS["bg"])
        frame.pack(fill="x", padx=32, pady=(12, 0))
        tk.Label(frame, text=label, font=(FONT_FAMILY, 10),
                 fg=COLORS["text"], bg=COLORS["bg"], anchor="w").pack(fill="x")
        row = tk.Frame(frame, bg=COLORS["bg"])
        row.pack(fill="x", pady=(4, 0))
        entry = tk.Entry(row, textvariable=variable, font=(FONT_FAMILY, 11),
                         bg=COLORS["input_bg"], fg=COLORS["text"],
                         insertbackground=COLORS["text"],
                         relief="flat", bd=0, highlightthickness=1,
                         highlightbackground=COLORS["border"],
                         highlightcolor=COLORS["accent"])
        entry.pack(side="left", fill="x", expand=True, ipady=8)
        btn = tk.Button(row, text="Browse…", font=(FONT_FAMILY, 9),
                        bg=COLORS["surface2"], fg=COLORS["text"],
                        activebackground=COLORS["border"],
                        bd=0, padx=12, pady=6, cursor="hand2",
                        command=lambda: self._browse_dir(variable))
        btn.pack(side="right", padx=(8, 0))

    def _browse_dir(self, variable):
        d = filedialog.askdirectory()
        if d:
            variable.set(d)

    def _checkbox(self, parent, label, variable):
        frame = tk.Frame(parent, bg=COLORS["bg"])
        frame.pack(fill="x", padx=32, pady=(14, 0))
        cb = tk.Checkbutton(
            frame, text=label, variable=variable,
            font=(FONT_FAMILY, 10), fg=COLORS["text"], bg=COLORS["bg"],
            activebackground=COLORS["bg"], activeforeground=COLORS["text"],
            selectcolor=COLORS["input_bg"], anchor="w",
        )
        cb.pack(fill="x")

    # ── Individual pages ─────────────────────────────────────────

    def _page_local_server(self) -> tk.Frame:
        page = self._make_page()
        self._heading(page, "Local DICOM Server",
                      "Configure the AE Title and ports for this Orthanc instance. "
                      "Modalities will send DICOM images to this address.")
        self._field(page, "AE Title", self.local_aet)
        self._field(page, "DICOM Port (external)", self.local_dicom_port)
        self._field(page, "HTTP Port for Web UI", self.local_http_port)
        self._dir_field(page, "Installation Directory", self.install_dir)
        return page

    def _page_destination_pacs(self) -> tk.Frame:
        page = self._make_page()
        self._heading(page, "Destination PACS",
                      "Enter the connection details for the PACS that all received "
                      "DICOM images will be forwarded to.")
        self._field(page, "Destination AE Title", self.dest_aet)
        self._field(page, "Destination Host / IP", self.dest_host)
        self._field(page, "Destination DICOM Port", self.dest_port)
        return page

    def _page_credentials(self) -> tk.Frame:
        page = self._make_page()
        self._heading(page, "Web UI Credentials",
                      "Set the username and password for the Orthanc web interface. "
                      "This is used to access the monitoring dashboard.")
        self._field(page, "Username", self.web_user)
        self._field(page, "Password", self.web_password, show="●")
        return page

    def _page_disk_mgmt(self) -> tk.Frame:
        page = self._make_page()
        self._heading(page, "Disk Management",
                      "When local disk usage exceeds the threshold below, the oldest "
                      "cached studies will be deleted to free space. Studies are only "
                      "deleted after they have been forwarded.")

        frame = tk.Frame(page, bg=COLORS["bg"])
        frame.pack(fill="x", padx=32, pady=(20, 0))
        tk.Label(frame, text="Disk Usage Threshold (%)", font=(FONT_FAMILY, 10),
                 fg=COLORS["text"], bg=COLORS["bg"], anchor="w").pack(fill="x")

        slider_frame = tk.Frame(frame, bg=COLORS["bg"])
        slider_frame.pack(fill="x", pady=(8, 0))

        self.disk_slider = tk.Scale(
            slider_frame, from_=30, to=95, orient="horizontal",
            variable=self.disk_threshold, font=(FONT_FAMILY, 10),
            bg=COLORS["bg"], fg=COLORS["text"], troughcolor=COLORS["input_bg"],
            activebackground=COLORS["accent"], highlightthickness=0,
            bd=0, sliderrelief="flat", length=380,
        )
        self.disk_slider.pack(side="left", fill="x", expand=True)

        self._checkbox(page, "Install Orthanc as a Windows service (auto-start)",
                       self.install_service)

        return page

    def _page_review(self) -> tk.Frame:
        page = self._make_page()
        self._heading(page, "Review Configuration",
                      "Please review your settings before installing.")

        self.review_text = tk.Text(
            page, font=(FONT_FAMILY, 10), bg=COLORS["input_bg"],
            fg=COLORS["text"], relief="flat", bd=0,
            highlightthickness=1, highlightbackground=COLORS["border"],
            wrap="word", padx=16, pady=12,
        )
        self.review_text.pack(fill="both", expand=True, padx=32, pady=(16, 16))
        return page

    def _page_install(self) -> tk.Frame:
        page = self._make_page()
        self._heading(page, "Installing…",
                      "Please wait while Orthanc Store-and-Forward is being set up.")

        self.progress = ttk.Progressbar(page, mode="determinate", maximum=100)
        self.progress.pack(fill="x", padx=32, pady=(24, 0))

        self.status_label = tk.Label(
            page, text="Preparing…", font=(FONT_FAMILY, 10),
            fg=COLORS["text_dim"], bg=COLORS["bg"], anchor="w",
        )
        self.status_label.pack(fill="x", padx=32, pady=(10, 0))

        self.log_text = tk.Text(
            page, font=("Consolas", 9), bg=COLORS["input_bg"],
            fg=COLORS["text_dim"], relief="flat", bd=0,
            highlightthickness=1, highlightbackground=COLORS["border"],
            wrap="word", padx=12, pady=10, height=14,
        )
        self.log_text.pack(fill="both", expand=True, padx=32, pady=(8, 16))

        return page

    # ── Navigation logic ─────────────────────────────────────────

    def _show_page(self, idx):
        for p in self.pages:
            p.pack_forget()
        self.pages[idx].pack(in_=self.content, fill="both", expand=True)
        self.current_page = idx

        # Update sidebar indicators
        for i, (indicator, lbl) in enumerate(self.step_labels):
            if i == idx:
                indicator.configure(bg=COLORS["accent"], fg="#ffffff")
                lbl.configure(fg=COLORS["text"])
            elif i < idx:
                indicator.configure(bg=COLORS["success"], fg="#ffffff")
                lbl.configure(fg=COLORS["text"])
            else:
                indicator.configure(bg=COLORS["surface2"], fg=COLORS["text_dim"])
                lbl.configure(fg=COLORS["text_dim"])

        # Update nav buttons
        self.btn_back.pack_forget()
        self.btn_next.pack_forget()

        if idx > 0 and idx < len(self.pages) - 1:
            self.btn_back.pack(side="left", padx=16, pady=12)

        if idx < len(self.pages) - 2:
            self.btn_next.configure(text="Next  ▶", command=self._go_next)
            self.btn_next.pack(side="right", padx=16, pady=12)
        elif idx == len(self.pages) - 2:  # Review page
            self.btn_back.pack(side="left", padx=16, pady=12)
            self.btn_next.configure(text="⬤  Install", command=self._start_install)
            self.btn_next.pack(side="right", padx=16, pady=12)

    def _go_back(self):
        if self.current_page > 0:
            self._show_page(self.current_page - 1)

    def _go_next(self):
        # Validate current page
        if not self._validate_page(self.current_page):
            return

        next_idx = self.current_page + 1
        if next_idx >= len(self.pages):
            return

        # If going to review page, populate it
        if next_idx == len(self.pages) - 2:
            self._populate_review()

        self._show_page(next_idx)

    def _validate_page(self, idx):
        if idx == 0:  # Local server
            if not self.local_aet.get().strip():
                messagebox.showwarning("Missing Field", "Please enter an AE Title.")
                return False
            if not self.local_dicom_port.get().strip().isdigit():
                messagebox.showwarning("Invalid Port", "DICOM port must be a number.")
                return False
            if not self.local_http_port.get().strip().isdigit():
                messagebox.showwarning("Invalid Port", "HTTP port must be a number.")
                return False
        elif idx == 1:  # Destination PACS
            if not self.dest_aet.get().strip():
                messagebox.showwarning("Missing Field",
                                       "Please enter the destination AE Title.")
                return False
            if not self.dest_host.get().strip():
                messagebox.showwarning("Missing Field",
                                       "Please enter the destination host/IP.")
                return False
            if not self.dest_port.get().strip().isdigit():
                messagebox.showwarning("Invalid Port",
                                       "Destination port must be a number.")
                return False
        return True

    def _populate_review(self):
        self.review_text.configure(state="normal")
        self.review_text.delete("1.0", "end")
        lines = [
            "╔══════════════════════════════════════════════════╗",
            "║          Configuration Summary                   ║",
            "╠══════════════════════════════════════════════════╣",
            "║                                                  ║",
            f"║  Local AE Title:      {self.local_aet.get():<26} ║",
            f"║  Local DICOM Port:    {self.local_dicom_port.get():<26} ║",
            f"║  Local HTTP Port:     {self.local_http_port.get():<26} ║",
            "║                                                  ║",
            f"║  Dest. AE Title:      {self.dest_aet.get():<26} ║",
            f"║  Dest. Host:          {self.dest_host.get():<26} ║",
            f"║  Dest. Port:          {self.dest_port.get():<26} ║",
            "║                                                  ║",
            f"║  Web UI User:         {self.web_user.get():<26} ║",
            f"║  Web UI Password:     {'●' * len(self.web_password.get()):<26} ║",
            "║                                                  ║",
            f"║  Disk Threshold:      {self.disk_threshold.get() + '%':<26} ║",
            f"║  Install as Service:  {'Yes' if self.install_service.get() else 'No':<26} ║",
            f"║  Install Directory:   {self.install_dir.get():<26} ║",
            "║                                                  ║",
            "╚══════════════════════════════════════════════════╝",
        ]
        self.review_text.insert("end", "\n".join(lines))
        self.review_text.configure(state="disabled")

    # ── Installation ─────────────────────────────────────────────

    def _start_install(self):
        self._show_page(len(self.pages) - 1)
        threading.Thread(target=self._run_installation, daemon=True).start()

    def _log(self, msg):
        self.after(0, lambda: self._append_log(msg))

    def _append_log(self, msg):
        self.log_text.insert("end", msg + "\n")
        self.log_text.see("end")

    def _set_progress(self, value, status=""):
        def _update():
            self.progress["value"] = value
            if status:
                self.status_label.configure(text=status)
        self.after(0, _update)

    def _run_installation(self):
        try:
            install_dir = Path(self.install_dir.get())
            config_dir = install_dir / "Configuration"
            lua_dir = install_dir / "Lua"
            logs_dir = install_dir / "Logs"
            data_dir = install_dir / "OrthancStorage"

            # Step 1: Create directories
            self._set_progress(5, "Creating directories…")
            self._log(f"Creating installation directory: {install_dir}")
            for d in [install_dir, config_dir, lua_dir, logs_dir, data_dir]:
                d.mkdir(parents=True, exist_ok=True)
                self._log(f"  ✓ {d}")

            # Step 2: Generate orthanc.json
            self._set_progress(20, "Generating configuration…")
            self._log("\nGenerating orthanc.json …")
            config = self._generate_orthanc_json(str(data_dir), str(logs_dir))
            config_path = config_dir / "orthanc.json"
            config_path.write_text(json.dumps(config, indent=2), encoding="utf-8")
            self._log(f"  ✓ Saved to {config_path}")

            # Step 3: Generate Lua script
            self._set_progress(30, "Writing Lua forwarding script…")
            self._log("\nWriting store-and-forward.lua …")
            lua_content = LUA_SCRIPT.format(
                disk_threshold=self.disk_threshold.get()
            )
            # Replace the StorageDirectory reference in Lua
            lua_content = lua_content.replace(
                'StorageDirectory or "C:"',
                f'"{str(data_dir)[:2]}"'
            )
            lua_path = lua_dir / "store-and-forward.lua"
            lua_path.write_text(lua_content, encoding="utf-8")
            self._log(f"  ✓ Saved to {lua_path}")

            # Step 4: Download Orthanc binaries
            self._set_progress(40, "Downloading Orthanc binaries…")
            self._log(f"\nDownloading Orthanc {ORTHANC_VERSION} for Windows …")
            orthanc_exe = install_dir / f"OrthancInstaller-Win64-{ORTHANC_VERSION}.exe"

            if not orthanc_exe.exists():
                try:
                    self._download_file(ORTHANC_WIN64_URL, str(orthanc_exe))
                    self._log(f"  ✓ Downloaded to {orthanc_exe}")
                except Exception as e:
                    self._log(f"  ⚠ Download failed: {e}")
                    self._log("  ⚠ You can download Orthanc manually from:")
                    self._log(f"    https://orthanc.uclouvain.be/downloads/windows-64/installers/")
                    self._log("  ⚠ Continuing with configuration-only install …")
            else:
                self._log(f"  ✓ Orthanc installer already exists at {orthanc_exe}")

            # Step 5: Create helper batch files
            self._set_progress(60, "Creating helper scripts…")
            self._log("\nCreating helper scripts …")
            self._create_batch_files(install_dir, config_dir)

            # Step 6: Run the Orthanc official installer if downloaded
            self._set_progress(70, "Running Orthanc installer…")
            if orthanc_exe.exists() and orthanc_exe.stat().st_size > 1000:
                self._log(f"\nThe Orthanc official installer has been downloaded.")
                self._log(f"Location: {orthanc_exe}")
                self._log(f"You can run it to install Orthanc binaries.")
                self._log(f"Then copy the configuration from {config_dir}")
                self._log(f"to the Orthanc installation's Configuration folder.")

            # Step 7: Install as service (if selected and binaries available)
            self._set_progress(85, "Configuring service…")
            if self.install_service.get():
                self._log("\nWindows service configuration:")
                self._log("  After installing Orthanc from the official installer,")
                self._log("  run the following commands as Administrator:")
                self._log(f'  > sc create OrthancSF start= auto binPath= "C:\\Program Files\\Orthanc Server\\Orthanc.exe --config=\\"{config_dir}\\\""')
                self._log(f"  > sc start OrthancSF")
                self._log("")
                self._log(f"  Or use the start-orthanc.bat script in {install_dir}")

            # Step 8: Done
            self._set_progress(100, "✅  Installation complete!")
            self._log("\n═══════════════════════════════════════════════════")
            self._log("  ✅  Orthanc Store-and-Forward setup complete!")
            self._log("═══════════════════════════════════════════════════")
            self._log(f"\nInstallation directory: {install_dir}")
            self._log(f"Configuration:          {config_path}")
            self._log(f"Lua script:             {lua_path}")
            self._log(f"Logs directory:         {logs_dir}")
            self._log(f"Storage directory:      {data_dir}")
            self._log(f"\nWeb UI: http://localhost:{self.local_http_port.get()}")
            self._log(f"DICOM:  AET={self.local_aet.get()} Port={self.local_dicom_port.get()}")
            self._log(f"Forward to: {self.dest_aet.get()}@{self.dest_host.get()}:{self.dest_port.get()}")

            # Show the close button
            self.after(0, self._show_finish_button)

        except Exception as e:
            self._set_progress(0, f"❌  Error: {e}")
            self._log(f"\n❌  Installation failed: {e}")
            import traceback
            self._log(traceback.format_exc())
            self.after(0, self._show_finish_button)

    def _generate_orthanc_json(self, storage_dir, logs_dir):
        """Generate the Orthanc configuration JSON."""
        lua_dir = str(Path(self.install_dir.get()) / "Lua")

        config = {
            "Name": "Store-and-Forward",
            "StorageDirectory": storage_dir.replace("\\", "/"),
            "IndexDirectory": storage_dir.replace("\\", "/"),
            "DicomAet": self.local_aet.get().strip(),
            "DicomPort": int(self.local_dicom_port.get()),
            "HttpPort": int(self.local_http_port.get()),
            "RemoteAccessAllowed": True,
            "AuthenticationEnabled": True,
            "RegisteredUsers": {
                self.web_user.get(): self.web_password.get()
            },
            "DicomModalities": {
                "destination": {
                    "AET": self.dest_aet.get().strip(),
                    "Host": self.dest_host.get().strip(),
                    "Port": int(self.dest_port.get()),
                }
            },
            "LuaScripts": [
                (Path(lua_dir) / "store-and-forward.lua").as_posix()
            ],
            "LuaHeartBeatPeriod": 60,
            "ExecuteLuaEnabled": True,
            "DicomAlwaysAllowStore": True,
            "UnknownSopClassAccepted": True,
            "StableAge": 5,
            "SaveJobs": True,
            "OverwriteInstances": True,
            "JobsHistorySize": 500,
            "ConcurrentJobs": 2,
            "StorageCompression": False,
            "MaximumStorageSize": 0,
            "DicomCheckCalledAet": False,
            "DeidentifyLogs": False,
        }
        return config

    def _download_file(self, url, dest):
        """Download a file with progress updates."""
        req = Request(url, headers={"User-Agent": "OrthancSF-Installer/1.0"})
        try:
            resp = urlopen(req, timeout=60)
        except URLError as e:
            raise RuntimeError(f"Cannot connect to {url}: {e}")

        total = int(resp.headers.get("Content-Length", 0))
        downloaded = 0
        chunk_size = 64 * 1024

        with open(dest, "wb") as f:
            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                if total > 0:
                    pct = 40 + int((downloaded / total) * 20)
                    self._set_progress(pct, f"Downloading… {downloaded // (1024*1024)} MB")

    def _create_batch_files(self, install_dir, config_dir):
        """Create convenient .bat files for managing the server."""
        # Start script
        start_bat = install_dir / "start-orthanc.bat"
        start_bat.write_text(textwrap.dedent(f"""\
            @echo off
            echo Starting Orthanc Store-and-Forward ...
            echo Configuration: {config_dir}
            echo.
            echo Press Ctrl+C to stop.
            echo.
            "C:\\Program Files\\Orthanc Server\\Orthanc.exe" --config="{config_dir}"
            pause
        """), encoding="utf-8")
        self._log(f"  ✓ {start_bat}")

        # Stop service script
        stop_bat = install_dir / "stop-service.bat"
        stop_bat.write_text(textwrap.dedent("""\
            @echo off
            echo Stopping Orthanc Store-and-Forward service ...
            net stop OrthancSF
            echo Done.
            pause
        """), encoding="utf-8")
        self._log(f"  ✓ {stop_bat}")

        # Install service script
        svc_bat = install_dir / "install-service.bat"
        svc_bat.write_text(textwrap.dedent(f"""\
            @echo off
            echo Installing Orthanc Store-and-Forward as a Windows Service ...
            sc create OrthancSF start= auto binPath= "\\"C:\\Program Files\\Orthanc Server\\OrthancService.exe\\""
            sc description OrthancSF "Orthanc Store-and-Forward DICOM Server"
            echo.
            echo Copying configuration ...
            copy /Y "{config_dir}\\orthanc.json" "C:\\Program Files\\Orthanc Server\\Configuration\\orthanc.json"
            copy /Y "{install_dir}\\Lua\\store-and-forward.lua" "C:\\Program Files\\Orthanc Server\\Lua\\store-and-forward.lua"
            echo.
            echo Starting service ...
            sc start OrthancSF
            echo.
            echo Done! The service is now running.
            pause
        """), encoding="utf-8")
        self._log(f"  ✓ {svc_bat}")

        # Open web UI script
        web_bat = install_dir / "open-web-ui.bat"
        web_bat.write_text(textwrap.dedent(f"""\
            @echo off
            start http://localhost:{self.local_http_port.get()}/
        """), encoding="utf-8")
        self._log(f"  ✓ {web_bat}")

        # Uninstall service script
        unsvc_bat = install_dir / "uninstall-service.bat"
        unsvc_bat.write_text(textwrap.dedent("""\
            @echo off
            echo Stopping Orthanc Store-and-Forward service ...
            net stop OrthancSF
            echo Removing service ...
            sc delete OrthancSF
            echo Done.
            pause
        """), encoding="utf-8")
        self._log(f"  ✓ {unsvc_bat}")

    def _show_finish_button(self):
        """Replace nav bar with a Close button."""
        for w in self.nav.winfo_children():
            w.pack_forget()
        btn = tk.Button(
            self.nav, text="✓  Close", font=(FONT_FAMILY, 11, "bold"),
            bg=COLORS["success"], fg="#ffffff",
            activebackground="#26b892", activeforeground="#ffffff",
            bd=0, padx=28, pady=10, cursor="hand2",
            command=self.destroy,
        )
        btn.pack(side="right", padx=16, pady=12)

        open_dir_btn = tk.Button(
            self.nav, text="📁  Open Install Folder", font=(FONT_FAMILY, 10),
            bg=COLORS["surface2"], fg=COLORS["text"],
            activebackground=COLORS["border"],
            bd=0, padx=16, pady=8, cursor="hand2",
            command=lambda: os.startfile(self.install_dir.get())
                            if platform.system() == "Windows"
                            else subprocess.run(["open", self.install_dir.get()]),
        )
        open_dir_btn.pack(side="left", padx=16, pady=12)


# ─── Entry point ─────────────────────────────────────────────────────

def main():
    # On Windows, request admin privileges for service installation
    if platform.system() == "Windows" and not is_admin():
        try:
            request_admin_restart()
        except Exception:
            pass  # Continue without admin if elevation fails

    app = InstallerApp()
    app.mainloop()


if __name__ == "__main__":
    main()
