![Hero Screenshot](https://online.kevintobler.ch/projectimages/DockAMP-Banner.jpg)

# DockAMP for macOS

[![Download DockAMP](https://img.shields.io/badge/Download-DockAMP-blue)](https://github.com/KeepCoolCH/DockAMP/releases/tag/V.1.0)

**DockAMP** is a macOS app to manage webserver/PHP/database-containers in Docker.
Version **1.0** – developed by **Kevin Tobler** 🌐 [www.kevintobler.ch](https://www.kevintobler.ch)

---

## 🔄 Changelog

### 🆕 Version 1.x
- **1.0**
  - First Release
  - Docker-based web stack manager for macOS
  - Apache or Nginx per server with configurable ports and document root
  - Dynamic PHP version selection and advanced PHP settings
  - Database modes: none, global shared database, dedicated per-server database
  - Server lifecycle controls: start, stop, restart, update images, reset Web/PHP
  - Proxy Manager integration (start/stop/restart, image update, auto-start)
  - Menu bar integration with server status list and bulk actions
  - Quick database actions (Sequel Pro/Ace, phpMyAdmin)
  - Persistent per-server and database configuration files in `~/Documents/DockAMP/`

---

## 🚀 Features

### Core
- Apache or Nginx per server
- Dynamic PHP version list from Docker Hub (with local fallback)
- Database support: MySQL, MariaDB, PostgreSQL
- Per-server start, stop, restart
- Global actions: start/restart/stop all servers
- Server auto-start on app launch
- Right-click server actions: duplicate and delete
- Automatic next free port assignment for new/duplicated servers

### Database modes
- No database
- Global shared database container
- Dedicated database container per server
- Automatic DB/user provisioning for enabled database mode
- Optional auto-stop of global DB when no global server is still active
- Dedicated DB container stops with its server

### Proxy Manager
- Built-in Nginx Proxy Manager integration
- Start / Stop / Restart
- Update proxy manager image
- Auto-start with app option
- HTTP/HTTPS/Admin ports configurable
- Named volumes or host-path persistence

### PHP / Web stack
- Extensive PHP settings (performance, errors, sessions, OPcache, directives)
- Optional extension/tool toggles with custom PHP runtime image build
- Web server settings for Apache and Nginx
- Update images for the current server stack
- Reset Web/PHP containers from image defaults
- Additional bind mounts (with add/remove rows and read-only toggle)

### UX and control
- Menu bar app with server list and status dots
- Menu bar actions: open app, start/restart/stop all, quit
- Main window only in Dock when visible; menu bar mode when closed
- Live activity indicator for long-running actions

### Logs and quick actions
- Container logs for web, PHP, database
- Quick DB actions:
  - Open in Sequel Pro/Ace
  - Open in phpMyAdmin (starts container automatically)
- phpMyAdmin auto-stops when no database container is running

---

## 📸 Screenshots

![Screenshot](https://online.kevintobler.ch/projectimages/DockAMPV1-overview.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/DockAMPV1-webserver.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/DockAMPV1-php.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/DockAMPV1-database.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/DockAMPV1-logs.png)  
![Screenshot](https://online.kevintobler.ch/projectimages/DockAMPV1-proxymanager.png)  

---

## ⚙️ Requirements
- macOS 14.6 Sonoma or newer
- Docker Desktop or OrbStack (OrbStack recommended for faster network speed)

---

## 🔧 Installation

[![Download DockAMP](https://img.shields.io/badge/Download-DockAMP-blue)](https://github.com/KeepCoolCH/DockAMP/releases/tag/V.1.0)

1. Install Docker Desktop or OrbStack (OrbStack recommended for faster network speed).
2. Open DockAMP.app

---

## 🧩 Usage

### Create a server
1. Open DockAMP.app
2. Click `+` (or use `File -> New Server...`)
3. Configure server name, web server, PHP version, ports, and document root
4. Choose database mode (`No Database`, `Global Database`, `Dedicated Container`)
5. Save/create

### Start and manage
- Use `Start`, `Stop`, `Restart` in the server detail header
- Use `Update Images` to pull latest images for the selected stack
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

## 📝 Notes
- Credentials are stored in JSON config files
- Custom PHP runtime images are tagged and reused by signature
- On server removal, related containers/resources are cleaned up (including dedicated DB containers)

---

## 🧑‍💻 Developer

**Kevin Tobler**  
🌐 [www.kevintobler.ch](https://www.kevintobler.ch)  

---

## 📜 License

This project is licensed under the **MIT License** – feel free to use, modify, and distribute.
