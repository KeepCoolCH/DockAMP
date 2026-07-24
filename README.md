![Hero Screenshot](images/DockAMP-Banner.jpg)

# 🐳 DockAMP Docker image or separate macOS app

**DockAMP** is a Docker image with a responsive web interface to manage official Apache/Nginx, PHP, MySQL/MariaDB/PostgeSQL and proxy containers in Docker - also available as a macOS app.
Docker version **1.2** | macOS version **1.2** | developed by **Kevin Tobler** 🌐 [www.kevintobler.ch](https://www.kevintobler.ch)

---

🐳 The Docker version can run on any Docker-compatible environment. The image includes support for both `linux/amd64` and `linux/arm64`.

[![Download DockAMP Docker image keepcoolch/dockamp:latest](https://img.shields.io/badge/Download-DockAMP_Docker_image-blue)](https://hub.docker.com/r/keepcoolch/dockamp)

🍎 The macOS version supports Docker Desktop and OrbStack (macOS 14.6 Sonoma or newer)

[![Download DockAMP app for macOS](https://img.shields.io/badge/Download-DockAMP_macOS_app-blue)](https://github.com/KeepCoolCH/DockAMP/releases/tag/V.1.2)

---

## 🐳 Docker version

### 🚀 Main features of the Docker version

- Browser-based management interface in English and German
- Apache or Nginx for each server
- Automatic PHP version discovery with legacy PHP versions available
- Advanced PHP, Apache, and Nginx configuration with structured dropdowns for common values
- Apache and Nginx security header controls for X-Frame-Options, Referrer-Policy, CSP, and related directives
- MySQL, MariaDB, and PostgreSQL
- Shared global or dedicated per-server database containers
- Automatic database image and data migration checks
- Nginx Proxy Manager integration
- phpMyAdmin integration
- Adminer integration for PostgreSQL databases
- SQL dump exports
- Container logs and status overview
- Live visitor overview with active request paths and per-server traffic speed
- Automatic free web-port selection starting above DockAMP's own port
- CPU and memory limits based on the available Docker host resources
- Docker volumes or host paths for persistent storage
- Initial setup can detect and choose Docker volumes or host mounts for `/data` and `/sites`
- Separate storage handling for DockAMP configuration and website/runtime files
- Storage migration between Docker volumes and host mounts where supported
- Host folder browser for document roots, host mounts, additional server mounts, and backup targets
- Folder creation and safer folder deletion dialogs in folder browser views
- Website file browser for document roots and additional mounts
- Upload files or whole folders directly through the browser
- Rename, copy, move, delete, and download website files or folders
- Download folders as compressed archives
- Webserver permission checks for document roots and additional mounts, with a repair action for safe read and traversal permissions
- Global image update checker for DockAMP-managed images, including DockAMP itself, web servers, PHP runtimes, database tools, proxy, Adminer, phpMyAdmin, and helper images
- DockAMP-managed unused image cleanup
- DockAMP-managed unused volume overview with individual delete actions
- User login and account management
- Automatic container restart and auto-start options
- Backup and restore support for Docker volumes and host-mounted storage paths
- Backup selection for DockAMP config, sites/runtime files, mounted web paths, dedicated databases, global database, and Proxy Manager data
- Optional restore selection per backup archive plus backup download as a compressed archive
- DockAMP automatically exports Docker Compose files so your containers can be started without DockAMP if needed.

### Linux and NAS

The following command stores DockAMP configuration and website data in named Docker volumes:

```bash
docker run -d \
  --name dockamp \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v dockamp_data:/data \
  -v dockamp_sites:/sites \
  --add-host host.docker.internal:host-gateway \
  keepcoolch/dockamp:latest
```

When using a persistent host-mount:

```bash
docker run -d \
  --name dockamp \
  --restart unless-stopped \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v /volume1/path-to-folder/data:/data \
  -v /volume1/path-to-folder/sites:/sites \
  -e DOCKAMP_DATA_HOST_PATH=/volume1/path-to-folder/data \
  -e DOCKAMP_SITES_HOST_PATH=/volume1/path-to-folder/sites \
  --add-host host.docker.internal:host-gateway \
  keepcoolch/dockamp:latest
```

This is also the recommended starting point for Docker-capable NAS systems.
The Docker socket may need to be selected through the NAS Docker Manager.

### macOS with Docker Desktop

```bash
docker run -d \
  --name dockamp \
  --restart unless-stopped \
  -p 8080:8080 \
  -v "$HOME/.docker/run/docker.sock:/var/run/docker.sock" \
  -v dockamp_data:/data \
  -v dockamp_sites:/sites \
  --add-host host.docker.internal:host-gateway \
  keepcoolch/dockamp:latest
```

Host directories selected later as document roots must be shared with Docker
Desktop under `Settings -> Resources -> File Sharing`.

### macOS with OrbStack

```bash
docker run -d \
  --name dockamp \
  --restart unless-stopped \
  -p 8080:8080 \
  -v "$HOME/.orbstack/run/docker.sock:/var/run/docker.sock" \
  -v dockamp_data:/data \
  -v dockamp_sites:/sites \
  --add-host host.docker.internal:host-gateway \
  keepcoolch/dockamp:latest
```

### Docker Compose

Create a `compose.yaml` file with docker volumes:

```yaml
services:
  dockamp:
    image: keepcoolch/dockamp:latest
    container_name: dockamp
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - dockamp_data:/data
      - dockamp_sites:/sites
    extra_hosts:
      - "host.docker.internal:host-gateway"

volumes:
  dockamp_data:
  dockamp_sites:
```

When using a persistent host-mount:

```yaml
services:
  dockamp:
    image: keepcoolch/dockamp:latest
    container_name: dockamp
    restart: unless-stopped
    ports:
      - "8080:8080"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /volume1/path-to-folder/data:/data
      - /volume1/path-to-folder/sites:/sites
    environment:
      - DOCKAMP_DATA_HOST_PATH=/volume1/path-to-folder/data
      - DOCKAMP_SITES_HOST_PATH=/volume1/path-to-folder/sites
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

Start DockAMP:

```bash
docker compose up -d
```

On macOS, replace `/var/run/docker.sock` in the Compose file with:

```text
${HOME}/.docker/run/docker.sock
```

For OrbStack use:

```text
${HOME}/.orbstack/run/docker.sock
```

### How to open the dashboard:

After startup, open:

```text
http://localhost:8080
```

On a remote server or NAS, replace `localhost` with the IP address or hostname of the Docker host. The first visit opens the administrator account setup.

### Using host directories

Individual server document roots can also point to absolute paths on the Docker host. Those paths must be accessible to the Docker daemon.

DockAMP includes a host folder browser for supported Docker environments. It can help select document roots, storage paths, and additional mounts from host paths that are visible to the Docker daemon.

### Persistent data

- `/data`: DockAMP configuration, users, sessions, application state, generated runtime configuration, and compose export
- `/sites`: website files
- Database and Proxy Manager data: separate named volumes by default

During the first setup, DockAMP shows the detected storage method for `/data` and `/sites` and lets you keep Docker volumes or switch to host mounts. The same storage areas can also be adjusted later from the Storage page.

### Updates

You can update DockAMP directly from the dashboard, so there's no need to run manual update commands in the terminal.

### Notes

> [!IMPORTANT]
> DockAMP requires access to the Docker socket because it creates and manages
> other containers. Access to `docker.sock` effectively grants Docker host
> administration privileges. Only expose DockAMP on trusted networks and use
> a strong administrator password.

## 📸 Screenshots Docker version

![Screenshot](images/DockAMPV122-start.png)  
![Screenshot](images/DockAMPV122-newserver.png)  
![Screenshot](images/DockAMPV122-overview.png)  
![Screenshot](images/DockAMPV122-webserver.png)  
![Screenshot](images/DockAMPV122-php.png)  
![Screenshot](images/DockAMPV122-database.png)  
![Screenshot](images/DockAMPV122-logs.png)  
![Screenshot](images/DockAMPV122-update.png)  
![Screenshot](images/DockAMPV122-databasemanager.png)  
![Screenshot](images/DockAMPV122-proxymanager.png)  
![Screenshot](images/DockAMPV122-storage.png)  
![Screenshot](images/DockAMPV122-testsite.png)  

---

## 🍎 macOS version

### 🚀 Main features of the macOS version

#### Core
- Apache or Nginx per server
- Dynamic PHP version list from Docker Hub (with local fallback)
- Database support: MySQL, MariaDB, PostgreSQL
- Per-server start, stop, restart
- Global actions: start/restart/stop all servers
- Server auto-start on app launch
- Right-click server actions: duplicate and delete
- Automatic next free web-port assignment starting at `8081`
- Server list shows the configured web port next to web server and PHP version

#### Database modes
- No database
- Global shared database container
- Dedicated database container per server
- Automatic DB/user provisioning for enabled database mode
- Stored database credentials can be changed and reused by DockAMP runtime config
- Optional auto-stop of global DB when no global server is still active
- Dedicated DB container stops with its server

#### Proxy Manager
- Built-in Nginx Proxy Manager integration
- Start / Stop / Restart
- Auto-start with app option
- HTTP/HTTPS/Admin ports configurable
- Named volumes or host-path persistence
- Internal or external Proxy Manager mode
- External Proxy Manager admin host can be opened from DockAMP

#### PHP / Web stack
- Extensive PHP settings (performance, errors, sessions, OPcache, directives)
- Optional extension/tool toggles with custom PHP runtime image build
- Web server settings for Apache and Nginx
- Reset Web/PHP containers from image defaults
- Additional bind mounts (with add/remove rows and read-only toggle)
- Finder folder picker for document roots and additional host roots
- Container path browser for additional mounts through a temporary helper container

#### Maintenance, images, and storage
- Separate Image Update Center for DockAMP-managed Docker images
- System Maintenance window for Backup & Restore, Recovery Compose Export, unused images, and unused volumes
- Unused dangling image overview with individual delete actions
- Unused Docker volume overview with individual delete actions
- Backup and restore for DockAMP configuration, website document roots, and database SQL dumps
- Automatic backups with manual, daily, weekly, and monthly intervals
- Recovery Compose Export writes `docker-compose.yml`, per-server YAMLs, global database/proxy YAMLs, README, and manifest files to `~/Documents/DockAMP/compose-export`
- Recovery Compose Export updates automatically when server, global database, or Proxy Manager settings are saved

#### UX and control
- Menu bar app with server list and status dots
- Menu bar actions: open app, start/restart/stop all, quit
- Main window only in Dock when visible; menu bar mode when closed
- Live activity indicator for long-running actions
- Toolbar buttons for Maintenance, Image Update Center, Proxy Manager, Live Visitors, Container Center, and Compose YAMLs

#### Logs and quick actions
- Container logs for web, PHP, database
- Container Center for DockAMP-managed and other Docker containers
- Container Center actions for start, stop, restart, delete, logs, and published-port opening
- Live Visitors view with active request paths and per-server traffic speed, refreshed every second
- Quick DB actions:
  - Open in Sequel Pro/Ace
  - Open in phpMyAdmin (starts container automatically)
- phpMyAdmin auto-stops when no database container is running

#### Compose YAMLs
- Compose YAML Center for saved Docker Compose YAML files
- Import, create, edit, copy, rename, delete, and run saved Compose YAMLs
- Simple single-container Compose YAMLs are started as plain `docker run` containers instead of Compose stacks
- Docker Run converter creates a saved Compose YAML from a `docker run` command

### Notes

> [!IMPORTANT]
> DockAMP requires access to the Docker socket because it creates and manages
> other containers. Access to `docker.sock` effectively grants Docker host
> administration privileges.

## 📸 Screenshots macOS version

![Screenshot](images/DockAMPV1-overview.png)  
![Screenshot](images/DockAMPV1-webserver.png)  
![Screenshot](images/DockAMPV1-php.png)  
![Screenshot](images/DockAMPV1-database.png)  
![Screenshot](images/DockAMPV1-logs.png)  
![Screenshot](images/DockAMPV1-proxymanager.png)  

## 🎬 Watch DockAMP macOS version in action

[![DockAMP macOS Demo](images/DockAMP-Banner.jpg)](https://www.youtube.com/watch?v=Dn9WTGD_WnE)

## ⚙️ Requirements
- macOS 14.6 Sonoma or newer
- Docker Desktop or OrbStack (OrbStack recommended for faster network speed)

## 🔧 Installation

[![Download DockAMP app for macOS](https://img.shields.io/badge/Download-DockAMP_macOS_app-blue)](https://github.com/KeepCoolCH/DockAMP/releases/tag/V.1.2)

1. Install Docker Desktop or OrbStack (OrbStack recommended for faster network speed).
2. Open DockAMP.app

## 🧩 Usage

### Create a server
1. Open DockAMP.app
2. Click `+` (or use `File -> New Server...`)
3. Configure server name, web server, PHP version, ports, and document root
4. Choose database mode (`No Database`, `Global Database`, `Dedicated Container`)
5. Save/create

### Start and manage
- Use `Start`, `Stop`, `Restart` in the server detail header
- Use `Reset Web/PHP` to recreate only web and PHP containers from image defaults

### Database connection
For DB tools use:
- Host: `host.docker.internal`
- Port: shown in the Database tab
- Database/user/password: from server database settings

Inside containers, service names/network aliases are used automatically by DockAMP runtime config.

## 💾 Persistence
DockAMP stores configuration JSON files under `~/Documents/DockAMP/`:

- `servers/<server-id>.json` (server settings)
- `databases/global_database.json` (global DB settings + shared entries)
- `databases/<server-id>.json` (dedicated DB server entries)
- Proxy Manager settings in the DockAMP app directory (managed by `ProxyManagerStore`)
- Custom PHP runtime images are tagged and reused by signature
- On server removal, related containers/resources are cleaned up (including dedicated DB containers)

---

## 🧑‍💻 Developer

**Kevin Tobler**  
🌐 [www.kevintobler.ch](https://www.kevintobler.ch)  
