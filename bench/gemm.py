#!/usr/bin/env python3
"""Dense square GEMM throughput on one GPU, for before/after unlock comparison.

FP16 and BF16 inputs accumulate in FP32 (reduced-precision reductions off);
TF32 is FP32 inputs with TF32 tensor cores. Each sample times ITERS matmuls;
the median of SAMPLES is reported, with mean power and SM clock while timing.

usage: python3 gemm.py [N] [SAMPLES] [ITERS]
"""
import statistics
import sys
import threading
import time

import pynvml
import torch

N = int(sys.argv[1]) if len(sys.argv) > 1 else 8192
SAMPLES = int(sys.argv[2]) if len(sys.argv) > 2 else 5
ITERS = int(sys.argv[3]) if len(sys.argv) > 3 else 20

torch.backends.cuda.matmul.allow_fp16_reduced_precision_reduction = False
torch.backends.cuda.matmul.allow_bf16_reduced_precision_reduction = False


class Sampler(threading.Thread):
    """Samples board power (W) and SM clock (MHz) every 50 ms."""

    def __init__(self, handle):
        super().__init__(daemon=True)
        self.handle, self.power, self.clock, self.running = handle, [], [], True

    def run(self):
        while self.running:
            self.power.append(pynvml.nvmlDeviceGetPowerUsage(self.handle) / 1000)
            self.clock.append(pynvml.nvmlDeviceGetClockInfo(self.handle, pynvml.NVML_CLOCK_SM))
            time.sleep(0.05)


def bench(name, dtype, tf32, handle):
    torch.backends.cuda.matmul.allow_tf32 = tf32
    a = torch.randn(N, N, device="cuda", dtype=dtype)
    b = torch.randn(N, N, device="cuda", dtype=dtype)
    for _ in range(10):
        a @ b
    torch.cuda.synchronize()
    sampler = Sampler(handle)
    sampler.start()
    results = []
    for _ in range(SAMPLES):
        start, end = torch.cuda.Event(enable_timing=True), torch.cuda.Event(enable_timing=True)
        start.record()
        for _ in range(ITERS):
            a @ b
        end.record()
        torch.cuda.synchronize()
        results.append(2 * N**3 * ITERS / (start.elapsed_time(end) / 1000) / 1e12)
    sampler.running = False
    sampler.join()
    print(f"{name:5s} {statistics.median(results):7.2f} TFLOPS  "
          f"(min {min(results):.2f}, max {max(results):.2f})  "
          f"power {statistics.mean(sampler.power):5.1f} W  sm {statistics.mean(sampler.clock):5.0f} MHz",
          flush=True)


def main():
    pynvml.nvmlInit()
    # CUDA_VISIBLE_DEVICES / --gpus exposes exactly one card; match it in NVML by UUID.
    uuid = "GPU-" + str(torch.cuda.get_device_properties(0).uuid)
    handle = pynvml.nvmlDeviceGetHandleByUUID(uuid)
    pci = pynvml.nvmlDeviceGetPciInfo(handle).busId
    pci = pci.decode() if isinstance(pci, bytes) else pci
    print(f"{torch.cuda.get_device_name(0)}  {pci}  {uuid}")
    print(f"driver {pynvml.nvmlSystemGetDriverVersion()}  torch {torch.__version__}  cuda {torch.version.cuda}  "
          f"power limit {pynvml.nvmlDeviceGetPowerManagementLimit(handle) / 1000:.0f} W  N={N} samples={SAMPLES} iters={ITERS}")
    bench("FP16", torch.float16, False, handle)
    bench("BF16", torch.bfloat16, False, handle)
    bench("TF32", torch.float32, True, handle)


if __name__ == "__main__":
    main()
