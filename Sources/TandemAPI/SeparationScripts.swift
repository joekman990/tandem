import Foundation

/// What runs on the rented GPU for `tandem separate`: a setup script that
/// installs Meta's SAM Audio into the stock RunPod PyTorch image, and the
/// separation itself. Both were worked out on real pods (October 2026); the
/// comments say what each pin and workaround is for. They're sent with every
/// job, so the pod needs nothing but the image.
enum SeparationScripts {
    static let run = #"""
#!/bin/bash
# Runs on the pod, in the job's work dir. HF_TOKEN comes from render-box --secret.
set -euo pipefail
# The image puts torch in the system Python on Ubuntu 24.04, which pip refuses to touch
# without this. The pod is thrown away after the job, so there is nothing to protect.
export HF_XET_HIGH_PERFORMANCE=1 PIP_ROOT_USER_ACTION=ignore PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True PIP_BREAK_SYSTEM_PACKAGES=1
apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg >/dev/null
python3 -m pip install -q --upgrade pip hf_transfer soundfile
# Meta's repo, pinned to the commit read on 2026-10-28. Keep the image's torch: its
# wheels match the pod's CUDA, and a reinstall would pull gigabytes for nothing.
# Hold torch, torchaudio and torchvision at the image's versions, and take torchcodec 0.9 (the
# release for torch 2.9) from PyTorch's CUDA 12.8 index: PyPI's newest torchcodec wanted
# CUDA 13 (libnvrtc.so.13) and failed to import on the first run.
python3 -m pip freeze | grep -E '^(torch|torchaudio|torchvision)==' > /tmp/pins.txt
# Meta's loader (sam_audio/model/base.py) passes proxies= and resume_download=, which
# huggingface_hub 1.0 removed; transformers 5 needs hub 1.x, so hold both back.
printf 'huggingface_hub<1.0\ntransformers<5\n' >> /tmp/pins.txt
cat /tmp/pins.txt
python3 -m pip install -q -c /tmp/pins.txt "torchcodec==0.9.*" --index-url https://download.pytorch.org/whl/cu128 --extra-index-url https://pypi.org/simple
python3 -m pip install -q -c /tmp/pins.txt "torchcodec==0.9.*" "huggingface_hub<1.0" "transformers<5" "git+https://github.com/facebookresearch/sam-audio@bb4c699" 2>&1 | tail -3
python3 -m pip freeze | grep -iE '^(torch|torchaudio|torchvision|torchcodec|transformers|huggingface.hub)=='
python3 -c "import torchcodec.decoders, sam_audio; print('sam_audio imports')"
python3 -c "import torch, torchaudio; print('torch', torch.__version__, 'cuda', torch.cuda.is_available(), torch.cuda.get_device_name(0))"
python3 separate.py "$@"
"""#

    static let separate = #"""
"""Run Meta's SAM Audio over one file for several prompts, on a CUDA pod.

Writes <out>/<name>.target.wav and <name>.residual.wav (48 kHz mono, 24-bit,
the same length as the input) and <out>/report.json.

Why it's shaped like this:
- SAM Audio was trained on clips of 30 s or less and degrades on longer ones,
  so the file goes through in 20 s windows with 5 s of overlap (the paper's
  long-form setting), crossfaded linearly in the overlaps.
- A quiet mic came back as an empty target in an earlier spike, so the input
  is lifted to -1 dBFS peak first and the stems are scaled back after.
- The model re-synthesises both stems through its codec, so they're compared
  with the input in report.json (level and how well target+residual rebuild it).
"""
import argparse, json, math, os, sys, time

import numpy as np, soundfile as sf, torch, torchaudio

p = argparse.ArgumentParser()
p.add_argument('--input', required=True)
p.add_argument('--out', required=True)
p.add_argument('--prompt', action='append', required=True, help='name=description, e.g. speech=speech')
p.add_argument('--model', default='facebook/sam-audio-large')
p.add_argument('--rerank', type=int, default=4)
p.add_argument('--no-spans', action='store_true')
p.add_argument('--window', type=float, default=20.0)
p.add_argument('--overlap', type=float, default=5.0)
p.add_argument('--start', type=float, default=0.0)
p.add_argument('--end', type=float, default=None)
a = p.parse_args()

from sam_audio import SAMAudio, SAMAudioProcessor

t0 = time.time()
dev = 'cuda'
# A 4090 pod ran out of system RAM loading everything at once (killed, exit 137). Two fixes:
# memory-map checkpoints instead of reading them whole into RAM, and leave out the ImageBind
# ranker (4.5 GB), which only scores visual prompts.
_load = torch.load
torch.load = lambda *args, **kw: _load(*args, **{'mmap': True, **kw})
# The judge ranker is another ~12 GB in fp32, and with it the 5090 (32 GB) ran out of memory
# even at one candidate. Rank with CLAP alone: the shipped ensemble weights it 5 to the judge's 1.
clap_only = {'kind': 'ensemble', 'rankers': {'clap': [{'checkpoint': None, 'kind': 'clap'}, 5.0]}}
model = SAMAudio.from_pretrained(a.model, visual_ranker=None, text_ranker=clap_only).eval().to(dev)
torch.load = _load
proc = SAMAudioProcessor.from_pretrained(a.model)
sr = proc.audio_sampling_rate
print(f'loaded {a.model} in {time.time() - t0:.0f}s, rate {sr}, text ranker {model.text_ranker is not None}, '
      f'span predictor {hasattr(model, "span_predictor")}', flush=True)

# soundfile, not torchaudio.load/save: recent torchaudio routes file I/O through torchcodec.
data, in_sr = sf.read(a.input, dtype='float32', always_2d=True)
wav = torch.from_numpy(data.mean(1)).reshape(1, -1)
if in_sr != sr:
    wav = torchaudio.functional.resample(wav, in_sr, sr)
s0 = int(a.start * sr)
s1 = wav.shape[1] if a.end is None else min(wav.shape[1], int(a.end * sr))
wav = wav[:, s0:s1]
n = wav.shape[1]
peak = wav.abs().max().item()
gain = (10 ** (-1 / 20)) / peak if peak > 0 else 1.0
x = wav * gain

win, hop = int(a.window * sr), int((a.window - a.overlap) * sr)
starts = [0] if n <= win else list(range(0, n - win, hop)) + [n - win]
fade = int(a.overlap * sr)
os.makedirs(a.out, exist_ok=True)
report = dict(input=a.input, start=a.start, end=a.end, seconds=n / sr, model=a.model, rerank=a.rerank,
              spans=not a.no_spans, window=a.window, overlap=a.overlap, input_peak=peak, prompts={})


def db(t):
    return 20 * math.log10(t.pow(2).mean().sqrt().item() + 1e-12)


# Once a window runs out of GPU memory, later windows start at the lower count
# rather than failing at the full one again (a 5090 only fits 2 for a 20 s window).
rerank = a.rerank
for spec in a.prompt:
    name, _, desc = spec.partition('=')
    t1 = time.time()
    target = torch.zeros(1, n)
    residual = torch.zeros(1, n)
    weight = torch.zeros(1, n)
    for i, s in enumerate(starts):
        seg = x[:, s:s + win]
        while True:
            try:
                batch = proc(descriptions=[desc], audios=[seg]).to(dev)
                with torch.inference_mode():
                    res = model.separate(batch, predict_spans=not a.no_spans, reranking_candidates=rerank)
                break
            except torch.cuda.OutOfMemoryError:
                torch.cuda.empty_cache()
                if rerank == 1:
                    raise
                rerank = max(1, rerank // 2)
                print(f'  out of GPU memory, reranking {rerank} candidates instead', flush=True)
        L = seg.shape[1]
        tw = res.target[0].float().cpu().reshape(1, -1)[:, :L]
        rw = res.residual[0].float().cpu().reshape(1, -1)[:, :L]
        # Linear crossfade weights: ramps in the overlaps, 1 elsewhere. Windows sum to 1.
        w = torch.ones(1, L)
        if i > 0:
            k = min(fade, L)
            w[:, :k] = torch.linspace(0, 1, k)
        if i < len(starts) - 1:
            k = min(fade, L)
            w[:, L - k:] = torch.minimum(w[:, L - k:], torch.linspace(1, 0, k))
        target[:, s:s + L] += tw[:, :L] * w
        residual[:, s:s + L] += rw[:, :L] * w
        weight[:, s:s + L] += w
        print(f'  {name}: window {i + 1}/{len(starts)} done ({time.time() - t1:.0f}s, rerank {rerank})', flush=True)
    target = target / weight.clamp_min(1e-6) / gain
    residual = residual / weight.clamp_min(1e-6) / gain
    for stem, t in (('target', target), ('residual', residual)):
        sf.write(os.path.join(a.out, f'{name}.{stem}.wav'), t.clamp(-1, 1)[0].numpy(), sr, subtype='PCM_24')
    rebuilt = target + residual
    err = wav - rebuilt
    report['prompts'][name] = dict(description=desc, seconds=round(time.time() - t1, 1),
                                   input_db=round(db(wav), 2), target_db=round(db(target), 2),
                                   residual_db=round(db(residual), 2), rebuild_snr_db=round(db(wav) - db(err), 2))
    print(f'{name}: {report["prompts"][name]}', flush=True)

report['total_seconds'] = round(time.time() - t0, 1)
report['gpu'] = torch.cuda.get_device_name(0)
report['max_gpu_memory_gb'] = round(torch.cuda.max_memory_allocated() / 1e9, 2)
json.dump(report, open(os.path.join(a.out, 'report.json'), 'w'), indent=2)
print(json.dumps(report, indent=2), flush=True)
"""#
}
