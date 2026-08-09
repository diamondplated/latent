# Third-party models

**Latent ships no model weights.** `Resources/Models/` is empty in this repository and is
gitignored. The scripts under `scripts/` download weights from their original upstream projects
onto your machine, at your initiative, and convert them to CoreML locally.

Latent's own MIT license covers Latent's code. The weights you download are governed by their own
upstream terms. **All of them are permissive** — that is deliberate, see below.

## What each stage pulls

| Stage | Model | Upstream | License |
|---|---|---|---|
| Denoise | NAFNet-SIDD-width64 | [megvii-research/NAFNet](https://github.com/megvii-research/NAFNet) | MIT |
| Artifact removal | FBCNN (color) | [jiaxi-jiang/FBCNN](https://github.com/jiaxi-jiang/FBCNN) | Apache-2.0 |
| Upscale | Real-ESRGAN x2plus | [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) | BSD-3-Clause |
| Search | OpenCLIP ViT-B/32 | [mlfoundations/open_clip](https://github.com/mlfoundations/open_clip) | MIT |

Sharpen is a classical unsharp mask using Core Image. It needs no model and has no third-party
terms attached.

Downloads are checksum-verified before `torch.load` ever sees the file — see
[SECURITY.md](SECURITY.md). NAFNet is the exception: upstream publishes no GitHub release, so that
checkpoint is supplied by hand.

## Why there is no face restoration

Latent used to have a fifth stage, FaceRestore, built on GFPGAN. It was removed.

GFPGAN's license is Apache-2.0 **"except for the third-party components listed below"**, and those
components are not permissive: its StyleGAN2 code carries the **NVIDIA** source-code license, and
its DFDNet lineage is **CC BY-NC-SA 4.0 — NonCommercial**.

Latent never redistributed those weights, so this was a disclosure problem rather than a licensing
violation. But it made the honest answer to "can I build something commercial on this?" a
conditional one, for a stage that was the largest download of the set (~340 MB) and the only
encumbered thing in the project. Deleting it makes the answer unconditional.

The Vision-based face detection and alpha-compositing code that supported it was removed with it. If
you want face restoration back, it is in the git history — but pick weights whose terms you have
actually read.

## Weights vs. code

The licenses above are the licenses of each project's **repository**, which in these cases is the
only license each project publishes. Some ML projects license their code and their published
checkpoints under different terms and do not always say so clearly. If your use is commercial,
verify the checkpoint terms upstream rather than relying on this table.

## Attribution

If you distribute a build that includes converted weights, carry the upstream copyright and license
notices for whichever models you included. The conversion scripts stamp the model author into the
CoreML metadata (`mlmodel.author`), which is a starting point, not a substitute for the notice files.
