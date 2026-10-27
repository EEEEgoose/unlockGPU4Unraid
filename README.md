# GPU Unlock for Unraid

English | [简体中文](README.zh-CN.md)

Unlocks the full-rate FP16/BF16 tensor throughput of the NVIDIA cards you select, before the NVIDIA driver takes
them: [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) for Ampere cards and
[nlzy/turing-unlock](https://github.com/nlzy/turing-unlock) for Turing cards. The plugin picks the right one for each
card. The NVIDIA Driver plugin still provides the driver, the container toolkit and CDI.

This plugin is built on [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) and
[nlzy/turing-unlock](https://github.com/nlzy/turing-unlock): the unlocks and the firmware generation come from
upstream. The plugin orders the boot on Unraid, records the results and provides a settings page.

## Support

Tested on (details in [docs/validation.md](docs/validation.md), in Chinese):

- Unraid 7.3.3, kernel `6.18.54-Unraid`, x86_64, NVIDIA driver 615.71.09
- Two RTX 3080 20 GB (`10de:2206`, memory-modded): unlocked at boot, with NVIDIA then driving all four cards
  (two RTX 2080 Ti in the same machine are not unlock targets)

The selectable cards are the upstreams': GeForce GA102/GA103/GA104/GA106 through gpu-unlock, and TU102/TU104/TU106
through turing-unlock. A supported PCI ID does not mean that board has been tested. Other NVIDIA cards show as not
unlockable and cannot be selected. The plugin only uses module packages built for exactly the running `uname -r`;
cards whose module has no package skip the unlock for that boot, and NVIDIA loads as usual.

**Turing support is new.** turing-unlock was published in October 2026 and its author tested it only on a Dell RTX
2080 Ti 22GB with driver 575.51.03. It has not been tested on this plugin's validation server yet. Its author warns
that tensor cores at full rate draw a lot of power and may damage the hardware: start with one card and keep a power
limit.

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

1. In the Unraid terminal, download this repository and run `repo/build/unraid-container.sh <work dir>` to get the
   module and firmware packages of gpu-unlock and turing-unlock.
2. Copy them to `config/plugins/gpu-unlock/packages/` on the flash drive.
3. Install the plugin from `https://raw.githubusercontent.com/EEEEgoose/unlockGPU4Unraid/main/gpu-unlock.plg`, with `plugin install` or by pasting the URL into
   **Plugins → Install Plugin**. The UI package is downloaded from GitHub Releases.
4. Open **Settings → Utilities → GPU Unlock**, tick the cards to unlock, set "unlock at next boot" to yes and save.
5. Power cycle the server.

The plugin starts disabled. Saving only changes the next boot; nothing is unlocked while the server runs.
Plugin updates appear under "Check for updates" on the **Plugins** page; the module package only needs a rebuild
after Unraid ships a new kernel.
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
- The modules are built from the upstreams' `GPL-2.0-only` source, gpu-unlock at commit
  `af28cbbfd3d922a659227ecfb7369adfd924cf03` and turing-unlock at commit `417f333263ff169e8f449c931b70db9dfd7b8ef4`;
  the build scripts and the source of the Unraid kernel patches are in this repository.
- The firmware contains NVIDIA binaries covered by the NVIDIA driver license, and neither upstream claims
  redistribution approval (see their `firmware/NOTICE.md`). This repository therefore **neither contains nor distributes the
  firmware**. The build generates it on your server from NVIDIA's own files, for your own use. Do not redistribute it.

## Development

```bash
bash tests/test-boot.sh
bash tests/test-status.sh
```

The tests replay the boot sequence and log parsing with stub commands; no hardware is involved. Design documents (in
Chinese) are in [docs/design/](docs/design/).

Releasing a new version:

1. Change `version` in `gpu-unlock.plg` and describe the changes in `<CHANGES>`.
2. Run `build/package.sh` and put the MD5 of `build/out/gpu-unlock-ui-<version>-x86_64-1.txz` into `md5` in
   `gpu-unlock.plg`.
3. Commit and push `main`, then create a release named after the version and attach that UI package.

The plg's `pluginURL` points at `main`, so between the push and the release, "Check for updates" already offers the
new version while its UI package cannot be downloaded yet. Create the release first, or do both steps back to back.
