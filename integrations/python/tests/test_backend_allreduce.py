"""Two-rank correctness test for the barlink torch backend (the seam vLLM and
sglang use). Run with torchrun:

    CUDA_HOME=/opt/cuda BARLINK_BAR1_NV_SOURCE=/opt/modded-p2p/build/driver-615.78.08 \
    BARLINK_BAR1_HOLD_BDF=$(cat /etc/barlink-p2p.hold-bdf) \
    torchrun --nproc_per_node=2 tests/test_backend_allreduce.py --backend barlink

Exit code 0 iff every rank's all_reduce result is bit-correct. Also prints the
achieved transport from barlink.group_states().
"""

from __future__ import annotations

import argparse
import os

import torch
import torch.distributed as dist


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="barlink")
    args = ap.parse_args()

    if args.backend == "barlink":
        import barlink

        barlink.register_backend()

    rank = int(os.environ["RANK"])
    local = int(os.environ.get("LOCAL_RANK", rank))
    world = int(os.environ["WORLD_SIZE"])
    torch.cuda.set_device(local)

    dist.init_process_group(backend=args.backend, rank=rank, world_size=world)

    bad = 0
    for size in (20_480 // 2, 1 << 20 // 2, 1 << 22 // 2):  # elements (bf16)
        x = torch.full((size,), float(rank + 1), dtype=torch.bfloat16, device=f"cuda:{local}")
        dist.all_reduce(x)
        expect = float(sum(range(1, world + 1)))
        got = x.float()
        wrong = int((got != expect).sum().item())
        bad += wrong
        if rank == 0:
            print(f"all_reduce {size*2} bytes: {'OK' if wrong == 0 else f'{wrong} wrong'} "
                  f"(expect {expect}, got {got[0].item():.1f})")

    if args.backend == "barlink":
        try:
            import barlink

            print(f"rank {rank} transport state: {barlink.group_states()}")
        except Exception as exc:  # pragma: no cover
            print(f"rank {rank} group_states unavailable: {exc}")

    dist.destroy_process_group()
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
