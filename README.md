# WinPE Repair Toolkit

Bootable WinPE toolkit (PT-BR and EN) to repair Windows: UEFI boot, BCD, SFC/DISM, profile rescue, SMART and more.

## What it is

A bootable Windows PE environment with a PowerShell menu for recovering a Windows installation that will not start. There are two ready-to-boot ISOs: one with a Portuguese menu and messages, and one with an English menu and messages. Each ISO opens directly in its language.

The kit is meant to be used as-is from WinPE. The scripts can also be opened on a full Windows install for testing, especially with simulation mode turned on.

## Features

- Twelve repair tools in a single PowerShell 5.1 menu
- UEFI boot repair with GPT detection from four sources
- A global simulation mode (**T**): destructive commands are logged as `[SIMULATION]` and are not executed
- Confirmation required (**SIM** / **YES**) before anything is written
- Safe profile extraction (a destination inside the source profile is refused)
- Registry hive backup that includes SAM and SECURITY only after a separate confirmation (default: no)
- S.M.A.R.T. checker that ignores implausible temperatures and does not list the same disk twice

## Menu

### Tools (1-12)

1. **UEFI boot repair** — Detects GPT from four sources (Get-Disk, MSFT_Disk, partition type, and the diskpart asterisk), finds the EFI System Partition, and recreates boot files with `bcdboot`.
2. **Intel RST driver injection** — Automatically detects and injects Intel RST/VMD storage drivers so WinPE can see the system disk.
3. **BCD rebuild** — Rebuilds the Boot Configuration Data with `bootrec` when it is present, otherwise with `bcdboot` / `bcdedit`. A backup can also be restored.
4. **SFC + DISM** — Runs System File Checker and DISM in sequence and writes a log.
5. **Profile extraction** — Copies AppData and favorites to a chosen destination. A destination inside the source profile is refused.
6. **Printer export** — Exports printer configuration so it can be restored later.
7. **C: root scan** — Lists non-standard folders at the root of C:. Hides `desktop.ini`, `thumbs.db`, `*.marker`, `.GamingRoot`, and empty items.
8. **Event Log (optional)** — Collects Event Log data when you want it.
9. **Registry hive backup** — Backs up registry hives. SAM and SECURITY are included only after an explicit confirmation (default: no).
10. **Offline file integrity checker** — Checks system file integrity while Windows is offline.
11. **S.M.A.R.T. checker** — Reports disk health. Implausible temperatures are marked untrusted; disks are not listed twice.
12. **Storage drivers for Windows 7** — Injects storage drivers needed to boot Windows 7.

### Extra keys

- **B** — UEFI boot repair using the CMD script (`repair-boot-uefi-en.cmd` or `reparar-boot-uefi.cmd`)
- **L** — Load a disk driver immediately with `drvload` (`.inf`)
- **A** — Advanced mode (command prompt or PowerShell). This mode does **not** ask for confirmation and does **not** honor simulation.
- **T** — Toggle simulation (dry-run) on or off
- **R** — Reboot
- **D** — Shut down
- **0** — Exit to the prompt (**Q** also exits)

## Simulation mode (T)

Turn simulation on with **T** in the menu, or start the script with `-Simulate` / `-Simular`.

When simulation is on, every destructive step is printed as `[SIMULATION]` and nothing is written to disk. Use this on the first run, especially on a machine you have not tested yet.

Example:

```cmd
powershell -NoProfile -ExecutionPolicy Bypass -File winpe_reparo_en.ps1 -Tool 11 -Simulate
```

## Download and write the ISO to a USB stick

1. Open the [Releases](https://github.com/rocaster/winpe-repair-toolkit/releases) page.
2. Download the ISO for your language:
   - `WinPE_Repair_EN.iso` — English menu and messages
   - `WinPE_Reparo_PT.iso` — Portuguese menu and messages
3. Write the ISO to a USB stick with [Rufus](https://rufus.ie/) (or a similar tool):
   - Partition scheme: **GPT**
   - Target system: **UEFI**
   - Do not use MBR/Legacy if the PC boots in UEFI mode
4. Boot the PC from the USB stick using the **UEFI:** boot entry (not the Legacy/BIOS one).
5. The menu opens automatically after WinPE starts.

## Requirements

- A UEFI PC (the UEFI boot-repair tool will refuse to run if WinPE was started in BIOS/Legacy mode)
- A USB stick large enough for the ISO (about 2 GB or more)
- The kit is intended to be run as-is inside WinPE (PowerShell 5.1 is already included)
- Optional: `smartctl.exe` in `ReparoBoot\tools` for more detailed S.M.A.R.T. output
- The ISOs include Microsoft Windows PE from the Windows ADK. Use them in accordance with Microsoft's license terms.

## Safety

- On the first test, turn **simulation (T)** on before running any tool.
- Destructive steps require you to type **SIM** (Portuguese ISO) or **YES** (English ISO) before anything is written.
- Advanced mode (**A**) does not ask for confirmation and does not respect simulation. Use it with care.
- Back up important data when you can. Boot repair and BCD rebuild can make a system unbootable if the wrong disk or partition is selected.

## Scripts in this repository

The `scripts/` folder holds the PowerShell menus, launchers, `startnet` files, and the CMD boot-repair scripts. The bootable ISOs are not stored in the Git tree; they are attached to [Releases](https://github.com/rocaster/winpe-repair-toolkit/releases).

---

> **Nota:** Existe uma versão em português deste kit (WinPE_Reparo_PT.iso, menu e mensagens em português), disponível na mesma página de Releases.
