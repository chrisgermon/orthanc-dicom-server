# CrowdDICOM — Store-and-Forward DICOM Gateway

A pre-configured Orthanc DICOM server branded as **CrowdDICOM** that receives, stores, logs, and automatically forwards all DICOM images to a destination PACS. It includes automatic disk space management — when the drive reaches 70% full, the oldest studies are deleted to free space.

## Architecture

```
┌─────────────┐     DICOM C-STORE      ┌─────────────────────┐     DICOM C-STORE      ┌──────────────┐
│  Modality   │ ─────────────────────── │    CrowdDICOM       │ ─────────────────────── │  Dest. PACS  │
│  (CT/MR/etc)│    AET / Port           │    (This Server)    │    Forwarding           │              │
└─────────────┘                         └─────────────────────┘                         └──────────────┘
                                             │
                                             │ Local cache until
                                             │ 70% disk usage
                                             ▼
                                        ┌──────────┐
                                        │  Storage  │
                                        │  Volume   │
                                        └──────────┘
```

## Features

- **Auto-forward**: Every received DICOM instance is automatically forwarded to the configured destination PACS
- **Robust retry**: Failed forwarding jobs are automatically retried on network errors
- **Disk space management**: Oldest studies are deleted when disk usage exceeds 70%
- **Full logging**: All DICOM operations are logged to a mapped volume with de-identification disabled
- **Startup recovery**: On restart, any instances that haven't been forwarded are re-queued
- **Web UI**: Orthanc Explorer 2 with CrowdDICOM dark theme for monitoring and manual operations
- **Health checks**: Built-in container health check for monitoring

## Prerequisites

### Docker (Linux / macOS)
- Docker & Docker Compose installed
- Network access between this server and your destination PACS

### Windows .exe Installer
- Python 3.8+ (only needed to build the .exe — end users don't need Python)
- Network access between this server and your destination PACS

---

## Option A: Docker Quick Start (Linux / macOS)

### 1. Run the installer

```bash
./install.sh
```

The installer will prompt you for:

| Setting | Description | Example |
|---------|-------------|---------|
| **Local AE Title** | The DICOM AE Title for this server | `STORE_FWD` |
| **Local DICOM Port** | The DICOM port this server listens on | `4242` |
| **Local HTTP Port** | The HTTP port for the web UI | `8042` |
| **Destination AE Title** | The AE Title of your destination PACS | `DEST_PACS` |
| **Destination Host** | The IP/hostname of your destination PACS | `192.168.1.100` |
| **Destination Port** | The DICOM port of your destination PACS | `4242` |
| **Web UI Username** | Username for the Orthanc web UI | `admin` |
| **Web UI Password** | Password for the Orthanc web UI | `orthanc` |
| **Disk Usage Threshold** | Max disk usage percentage before cleanup | `70` |

### 2. Start the server

```bash
docker compose up -d
```

### 3. Verify it's running

- **Web UI**: Open `http://<server-ip>:<http-port>` in your browser
- **DICOM Echo**: Use your modality or a tool like `echoscu` to verify DICOM connectivity:
  ```bash
  echoscu -aec <AE_TITLE> <server-ip> <dicom-port>
  ```

### 4. Configure your modality

On your CT/MR/etc scanner, add a new DICOM destination:
- **AE Title**: The AE Title you configured (e.g. `STORE_FWD`)
- **IP Address**: The IP address of this server
- **Port**: The DICOM port you configured (e.g. `4242`)

---

## Option B: Windows .exe Installer

A native Windows installer built with **Inno Setup** (the same tool used by the official Orthanc installer). The `.exe` includes a wizard that prompts for all DICOM settings, then generates the configuration files and helper scripts.

### Building the .exe (from macOS or Linux)

```bash
cd windows-installer
./build-on-mac.sh
```

This uses Docker (`amake/innosetup`) to cross-compile and produces:

```
output/CrowdDICOM-Setup.exe  (≈ 193 MB)
```

Copy this single file to any Windows machine to install.

### Building on Windows

If building directly on Windows, install [Inno Setup 6](https://jrsoftware.org/isinfo.php) and compile `setup.iss`.

### What the installer does

The wizard prompts for:

1. **Local DICOM Server** — AE Title, DICOM port, HTTP port
2. **Destination PACS** — AE Title, host/IP, port, disk cleanup threshold
3. **Web UI Credentials** — Username and password

Then it:
- Installs files to `C:\Program Files\Orthanc Store-and-Forward`
- Generates `orthanc.json` with your settings
- Patches the Lua script with your disk threshold
- Creates Start Menu shortcuts
- Optionally launches the PowerShell config wizard for future reconfiguration

### After installation

| File | Purpose |
|------|---------|
| `Configuration\orthanc.json` | Generated Orthanc config |
| `Lua\store-and-forward.lua` | Forwarding + disk cleanup script |
| `start-orthanc.bat` | Run Orthanc in foreground |
| `install-service.bat` | Install as a Windows service |
| `stop-service.bat` | Stop the Windows service |
| `uninstall-service.bat` | Remove the Windows service |
| `open-web-ui.bat` | Open the web UI in your browser |
| `configure.bat` | Re-run the configuration wizard |

---

## File Structure

```
orthanc-store-and-forward/
├── README.md                    # This file
├── install.sh                   # Docker: Interactive installer script
├── .env                         # Docker: Generated config (after install)
├── docker-compose.yml           # Docker: Service definition
├── lua/
│   └── store-and-forward.lua    # Auto-forward + disk cleanup logic
└── windows-installer/
    ├── setup.iss                # Inno Setup installer script
    ├── build-on-mac.sh          # Build .exe from macOS via Docker
    ├── build.bat                # Build .exe on Windows directly
    ├── scripts/
    │   ├── store-and-forward.lua  # Template Lua script
    │   ├── Configure.ps1          # PowerShell config wizard
    │   ├── start-orthanc.bat      # Helper scripts
    │   ├── install-service.bat
    │   ├── stop-service.bat
    │   ├── uninstall-service.bat
    │   ├── open-web-ui.bat
    │   └── configure.bat
    └── resources/
        ├── orthanc.ico          # Application icon
        ├── license.txt          # License agreement
        ├── wizard.bmp           # Installer sidebar image
        └── wizard_small.bmp     # Installer header image
```

## Logs

Logs are written to a `logs/` directory (created at startup) on the host, mapped into the container. You can tail them with:

```bash
tail -f logs/Orthanc.log
```

## Monitoring

### Web UI

Access the Orthanc Explorer 2 web interface at `http://<server-ip>:<http-port>`.

### Disk Usage

The Lua script checks disk usage every 60 seconds. When usage exceeds the configured threshold, it deletes the oldest study. You can monitor this in the logs.

### Jobs

You can monitor forwarding jobs via the REST API:

```bash
curl -u admin:orthanc http://localhost:8042/jobs?expand
```

## Reconfiguring

To change settings after initial setup:

1. Re-run `./install.sh` (it will overwrite the `.env` file)
2. Restart: `docker compose down && docker compose up -d`

## Stopping

```bash
docker compose down
```

To also remove the stored data:

```bash
docker compose down -v
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Modality can't connect | Check firewall rules for the DICOM port. Verify AE Title matches exactly. |
| Forwarding fails | Check network connectivity to the destination PACS. Review `logs/Orthanc.log`. |
| Disk fills up quickly | Lower the disk usage threshold or add more storage. |
| Container won't start | Run `docker compose logs` to see startup errors. |
| Web UI inaccessible | Verify the HTTP port isn't blocked and the container is healthy. |
