# HSS — Modular Multi-Room Audio Ecosystem

HSS is an automated, Raspberry Pi-powered multi-room audio architecture designed to deliver synchronized high-fidelity sound distribution across independent speaker nodes. Built on top of proven open-source audio engines like Snapcast, Shairport-Sync, and Librespot, the system transforms single-board computers into intelligent audio hubs and active satellite receivers.

The project features an automated Go-based build pipeline that compiles modular shell components, systemd unit configurations, and embedded Python scripts into unified, self-contained deployment installers.

---

## Architecture Overview

The ecosystem is divided into two distinct system roles, each tailored to specific hardware and operational tasks.

| Role | Binary Output | Description | Primary Features |
|---|---|---|---|
| **Hub** | `hub_setup.sh` | Central Audio Distribution Server | Snapserver, AirPlay 2 (Shairport-Sync), Spotify Connect (Librespot), Wi-Fi Provisioning Portal, ADS1015/1115 Hardware Volume Control |
| **Speaker** | `speaker_setup.sh` | Synchronized Audio Satellite Node | Snapclient, Systemd Auto-Resume, Optimized ALSA Audio Routing |

---

## Build System & Code Generation

Rather than managing massive, monolithic shell scripts, HSS utilizes a custom Go build tool located in `build.go`. This tool allows developers to write clean, modular source files with IDE syntax highlighting for Python and systemd unit files.

### Custom Compiler Directives

Source files in `src/` use special directives to instruct the compiler:

* `# @include modules/<file>.sh` recursively pulls in modular shell code and automatically hoists global environment variables to the top of the final script.
* `# @embed_file <relative_source> <absolute_target>` extracts raw text files (such as systemd services or Python scripts) and wraps them inside protected heredoc blocks in the generated installer.

### Watch Mode & Automatic Debouncing

The Go compiler includes a file watcher that monitors the source tree for modifications. Upon detecting a file save, it waits through a 5-second debounce window to consolidate rapid edits before verifying syntax via `bash -n` and outputting a fresh executable script to the `dist/` directory.

---

## Project Structure

```text
.
├── Makefile                # Command shortcuts for building and watching targets
├── build.go                # Custom Go compiler engine
├── go.mod                  # Go module definition
├── setup.sh                # Helper script to install Go (via apt or official tarball)
├── hub/
│   ├── dist/               # Compiled output scripts (e.g., hub_setup.sh)
│   ├── enclosure/          # 3D printed enclosure files
│   └── src/
│       ├── main.sh         # Main execution entrypoint for the Hub
│       ├── modules/        # Modular bash functions
│       ├── scripts/        # Embedded Python tools (Wi-Fi portal, volume control)
│       └── services/       # Embedded systemd unit files
└── speaker/
    ├── dist/               # Compiled output scripts (e.g., speaker_setup.sh)
    ├── enclosure/          # 3D printed enclosure files
    └── src/
        ├── main.sh         # Main execution entrypoint for Satellite Speakers
        ├── modules/        # Modular bash functions
        └── services/       # Embedded systemd unit files
```

---

## Getting Started

### Prerequisites

Building HSS requires a Linux environment with Go 1.22 or higher installed. You can set up the build environment automatically using the included setup helper.

```bash
chmod +x setup.sh
./setup.sh
```

### Compiling Target Scripts

You can build individual target installers using standard Go commands or the provided Makefile.

```bash
# Build the Hub installer script
make hub

# Build the Speaker satellite installer script
make speaker

# Compile the standalone builder binary
make build
```

### Active Development (Watch Mode)

To start the auto-rebuilding daemon during active coding sessions, execute the watch command for your target.

```bash
# Watch the Hub source directory with 5s debounce
make watch-hub

# Watch the Speaker source directory with 5s debounce
make watch-speaker
```

---

## Deployment

Once compiled, transfer the resulting script from the `dist/` folder to your target Raspberry Pi and run it with root privileges.

```bash
sudo bash hub/dist/hub_setup.sh
```

The installer runs interactively by default, prompting for system hostnames, Wi-Fi credentials, and optional CPU performance tweaks. To run unattended deployments, pass the `-y` flag.

```bash
sudo bash speaker/dist/speaker_setup.sh -y
```

---

## Hardware & 3D Printed Enclosures

HSS extends beyond software into custom physical loudspeaker design. The repository hosts parametric CAD source files and print-ready models designed specifically for high-performance compact audio drivers, such as Full-Range Assisted Subwoofer (FAST) setups pairing Dayton Audio drivers (e.g., ND65-8 and TCP115/DCS165) with 3D-printed enclosures.

### CAD Source Formats

All hardware files are organized within dedicated speaker directories according to a file type:

* **OpenSCAD (`.scad`)**: Fully parametric source models allowing customization of internal cabinet volumes, port tuning frequencies, wall thicknesses, and driver cutout dimensions.
* **3MF (`.3mf`)**: Production-ready manufacturing files containing optimized print orientation, modifier zones, seam placement, and material profiles (PETG / TPU).
* **STL (`.stl`)**: Standard triangulated mesh geometries for universal slicer compatibility.

---

## License

This project is open-source and available under the MIT License.