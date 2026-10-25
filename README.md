# GPU Unlock for Unraid

English | [简体中文](README.zh-CN.md)

Runs [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) on the Ampere cards you select, before the NVIDIA
driver takes them, to unlock their FP16/BF16 instruction issue rate. The NVIDIA Driver plugin still provides the
driver, the container toolkit and CDI.

This plugin is built on [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock): the unlock and the firmware
generation come from upstream. The plugin orders the boot on Unraid, records the results and provides a settings page.

## Support

Tested on (details in [docs/validation.md](docs/validation.md), in Chinese):

- Unraid 7.3.3, kernel `6.18.54-Unraid`, x86_64, NVIDIA driver 615.71.09
- Two RTX 3080 20 GB (`10de:2206`, memory-modded): unlocked at boot, with NVIDIA then driving all four cards
  (two RTX 2080 Ti in the same machine are not unlock targets)

The selectable cards are upstream's: GeForce GA102/GA103/GA104/GA106. A supported PCI ID does not mean that board has
been tested. Other NVIDIA cards, such as the RTX 2080 Ti, show as not unlockable and cannot be selected.
The plugin only uses a module package built for exactly the running `uname -r`; without one, it skips the unlock for
that boot and NVIDIA loads as usual.

## Measured performance

RTX 3080 20 GB, 240 W power limit, driver 615.71.09, PyTorch 2.13 / CUDA 13.0.
Dense 8192³ GEMM, FP16/BF16 with FP32 accumulation, median of 5 runs, using [bench/gemm.py](bench/gemm.py).

| Card | Precision | Unlocked | Mean SM clock | Locked peak at that clock | Gain |
|---|---|---|---|---|---|
| `cc:00.0` | FP16 | 95.74 TFLOPS | 1431 MHz | 49.8 TFLOPS | +92% |
| `cc:00.0` | BF16 | 97.68 TFLOPS | 1445 MHz | 50.3 TFLOPS | +94% |
| `cc:00.0` | TF32 | 46.00 TFLOPS | 1406 MHz | 24.5 TFLOPS | +88% |
| `cd:00.0` | FP16 | 93.81 TFLOPS | 1410 MHz | 49.1 TFLOPS | +91% |
| `cd:00.0` | BF16 | 96.68 TFLOPS | 1449 MHz | 50.4 TFLOPS | +92% |
| `cd:00.0` | TF32 | 46.21 TFLOPS | 1390 MHz | 24.2 TFLOPS | +91% |

Gain = unlocked ÷ locked peak at that clock − 1.

The locked peak is not a measurement. It is NVIDIA's published RTX 3080 figure scaled to the mean clock of the run:
GeForce FP16/BF16 with FP32 accumulation is 59.5 TFLOPS and TF32 is 29.8 TFLOPS, both at 1710 MHz.
The unlocked results exceed that ceiling and reach 94–97% of the full-rate figure.
A measured locked baseline has not been taken yet; it will replace the computed one here.

## Install

This repository does not distribute the firmware (see "Firmware and licensing" below), so you build the module and
firmware packages on your own server with Docker. The full steps are in
**[Building the module and firmware with Docker](docs/build-docker.md)**. In short:

1. In the Unraid terminal, download this repository and run `repo/build/unraid-container.sh <work dir>` to get three
   `.txz` packages.
2. Copy them to `config/plugins/gpu-unlock/packages/` on the flash drive.
3. Install `gpu-unlock.plg` with `plugin install`.
4. Open **Settings → Utilities → GPU Unlock**, tick the cards to unlock, set "unlock at next boot" to yes and save.
5. Power cycle the server.

The plugin starts disabled. Saving only changes the next boot; nothing is unlocked while the server runs.
The settings page is currently in Chinese only.

## What the results mean

| State | Meaning |
|---|---|
| Disabled | Unlock is turned off |
| Pending next boot | Enabled, but this boot has no record yet |
| Unlocked | The kernel log of this boot reports `gpu_unlock: unlocked` for the card |
| Skipped, bound to a driver | The card already had a driver when the unlock ran; it is not unbound or retried |
| Skipped | No module package for this kernel, the module failed to load, or the address is not supported; the hardware was not touched |
| Failed | The card reported a failure, shown with its reason; it is not retried |

A successful `modprobe gpu_unlock` does not mean the unlock succeeded. Each card's state comes only from the kernel log
lines that this load added and that carry the card's PCI address.

If the page says a power off is required, gpu_unlock reported that the firmware did not stop or that the card had
already been initialised. NVIDIA was then not loaded for this boot and no CDI was generated. Power the server off and
on again; a reboot is not enough.

## Disable, uninstall and recovery

- **Disable**: the next boot does not unlock, and NVIDIA loads early as before.
- **Uninstall**: removes the plugin's boot changes, files and settings.
- Neither restores the locked state right away. Power the server off to relock the cards.
- Without the web UI: delete `config/modprobe.d/gpu-unlock.conf` on the flash drive and reboot.

How the boot is ordered: [docs/boot-integration.md](docs/boot-integration.md) (in Chinese).

## Firmware and licensing

- The code in this repository (plugin, build scripts, tests) is released under [GPL-2.0](LICENSE), like upstream.
- The module is built from upstream's `GPL-2.0-only` source at commit `af28cbbfd3d922a659227ecfb7369adfd924cf03`;
  the build scripts and the source of the Unraid kernel patches are in this repository.
- The firmware contains NVIDIA binaries covered by the NVIDIA driver license, and upstream claims no redistribution
  approval (see upstream `firmware/NOTICE.md`). This repository therefore **neither contains nor distributes the
  firmware**. The build generates it on your server from NVIDIA's own files, for your own use. Do not redistribute it.

## Development

```bash
bash tests/test-boot.sh
bash tests/test-status.sh
```

The tests replay the boot sequence and log parsing with stub commands; no hardware is involved. Design documents (in
Chinese) are in [docs/design/](docs/design/).
