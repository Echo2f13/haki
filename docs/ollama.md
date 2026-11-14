# Local AI on your GPU

My server has a GTX 1050 Ti from an old gaming PC. It's 4 GB of VRAM — enough for small models at
real speed — and `ollama-gpu` turns it into a private model API for my apps and me.

## What you need

- An NVIDIA card. Old is fine: a 1050 Ti does ~35 tokens/s on a 2B model.
- VT-d (Intel) or AMD-Vi / IOMMU switched on in the BIOS.
- The card in its own IOMMU group. `haki plan ollama-gpu` checks this and tells you if it isn't.
- If the card is the host's only display, its screen goes dark once the card is passed to the VM.
  The web UI and SSH are unaffected.

## Set it up

```bash
haki plan ollama-gpu
haki install ollama-gpu      # binds the card to vfio-pci, then asks you to reboot
# reboot (web UI → node → Reboot)
haki install ollama-gpu      # creates the VM; it installs the NVIDIA driver and ollama itself
haki status ollama-gpu       # first boot takes about 10 minutes
```

The VM is Ubuntu 24.04 from the official cloud image (checksum verified), with your host's SSH keys
for user `haki` — no passwords anywhere. It starts on boot after your other VMs.

Already have an ollama VM with the card? Set `HAKI_OLLAMA_VM` to its id: it's adopted as is, and
nothing inside it is changed.

## Who can use it

ollama's API has no password: anyone who can reach port 11434 can run, download and delete
models. VMs made by `ollama-gpu` have a firewall that only lets in the addresses you allow:

```bash
haki ollama-gpu allow                  # show who's allowed
haki ollama-gpu allow 192.168.1.42     # your PC
haki ollama-gpu deny 192.168.1.42
```

The host is always allowed, so `watch` can check the API. For an adopted VM without a guest
agent, `haki ollama-gpu allow` prints the `ufw` commands to run inside it instead.

## Models

```bash
haki ollama-gpu pull gemma2:2b         # names from ollama.com/library
haki ollama-gpu models                 # size, quantization, and how much of a loaded one is on the GPU
haki ollama-gpu bench qwen2.5:7b       # tokens per second, and how it's split between GPU and CPU
haki ollama-gpu rm gemma2:2b
haki ollama-gpu gpu                    # the card, its driver, the kernel
```

What fits on 4 GB of VRAM, measured on a 1050 Ti (context 4096):

| Model size | VRAM | Speed |
|---|---|---|
| 1–2B (gemma2:2b, Q4) | 1.1–1.9 GB, all on the GPU | 33–38 tokens/s |
| 7B (qwen2.5:7b, Q4_K_M) | 3.0 GB VRAM + 2.1 GB RAM | ~10 tokens/s |

When `bench` says less than 100% is on the GPU, the rest runs on the CPU and it gets slower. Give
the VM enough RAM for that part (`HAKI_OLLAMA_RAM`): with passthrough, the VM's RAM is always
fully reserved on the host.

## Kernel updates

Passthrough can break with a new kernel. If you pin a kernel that works
(`proxmox-boot-tool kernel pin <version>`), `haki status ollama-gpu` warns when you're running a
different one. Try new kernels only when you can reach the machine's screen.
