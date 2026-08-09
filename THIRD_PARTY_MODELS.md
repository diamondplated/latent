# Third-party models

**Latent ships no model weights.** `Resources/Models/` is empty in this repository and is
gitignored. The scripts under `scripts/` download weights from their original upstream projects
onto your machine, at your initiative, and convert them to CoreML locally.

That means Latent's own MIT license covers Latent's code only. The weights you download are
governed by their own upstream terms, and **those terms are not all the same**. If you are building
something commercial on top of this, read this page before you ship.

## What each stage pulls

| Stage | Model | Upstream | Code license |
|---|---|---|---|
| Denoise | NAFNet-SIDD-width64 | [megvii-research/NAFNet](https://github.com/megvii-research/NAFNet) | MIT |
| Artifact removal | FBCNN (color) | [jiaxi-jiang/FBCNN](https://github.com/jiaxi-jiang/FBCNN) | Apache-2.0 |
| Upscale | Real-ESRGAN x2plus | [xinntao/Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN) | BSD-3-Clause |
| Face restore | GFPGAN v1.4 | [TencentARC/GFPGAN](https://github.com/TencentARC/GFPGAN) | Apache-2.0 **with carve-outs — see below** |
| Search | OpenCLIP ViT-B/32 | [mlfoundations/open_clip](https://github.com/mlfoundations/open_clip) | MIT |

Sharpen is a classical unsharp mask using Core Image. It needs no model and has no third-party
terms attached.

## The one that needs care: GFPGAN

GFPGAN's own license text states that it is Apache-2.0 **"except for the third-party components
listed below"**, and those components are not permissive:

- **StyleGAN2** — carries the **NVIDIA** source-code license.
- **DFDNet** — carries **Creative Commons Attribution-NonCommercial-ShareAlike 4.0**, which is
  explicitly **non-commercial**.

So the FaceRestore stage's weights have a lineage that includes non-commercial-licensed work.
Latent does not redistribute those weights and takes no position on how far that lineage reaches
into a converted `.mlpackage` — that is a question for your own legal review, not for a README.
What this project can do is make sure you know before you run the script.

**If you need a cleanly-licensed build:** skip `scripts/convert_gfpgan.py`. The stage degrades
gracefully — with no model present, FaceRestore fast-paths to identity and the rest of the pipeline
is unaffected. Every other stage above is permissively licensed.

## Weights vs. code

The licenses in the table are the licenses of each project's **repository**, which in most of these
cases is the only license the project publishes. Some ML projects license their code and their
published checkpoints under different terms, and not all of them say so clearly. If your use is
commercial, verify the checkpoint terms upstream rather than relying on this table.

## Attribution

If you distribute a build that includes converted weights, carry the upstream copyright and license
notices for whichever models you included. The conversion scripts already stamp the model author
into the CoreML metadata (`mlmodel.author`), which is a starting point, not a substitute for the
notice files.
