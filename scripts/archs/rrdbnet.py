"""RRDBNet — the Real-ESRGAN / ESRGAN generator architecture.

Vendored from BasicSR (https://github.com/XPixelGroup/BasicSR), Apache-2.0,
files `basicsr/archs/rrdbnet_arch.py` and the three helpers this needs from
`basicsr/archs/arch_util.py`. Copyright 2018-2022 BasicSR Authors.

Why vendored instead of `pip install basicsr`:

  * BasicSR 1.4.2 imports `torchvision.transforms.functional_tensor`, which
    torchvision removed. That makes the package unimportable on any torch new
    enough to carry the fix for CVE-2025-32434 — the `torch.load` RCE that the
    conversion scripts are directly exposed to. BasicSR is unmaintained, so
    that will not be fixed upstream.
  * It is also the subject of an unpatched advisory of its own.
  * It pulled in torchvision, opencv, scipy, tensorboard and more to supply
    ~150 lines of `nn.Module`.

Layer names and forward() are byte-for-byte upstream. They have to be: the
published Real-ESRGAN checkpoints are loaded with `strict=True`, so any rename
or restructure fails loudly rather than silently producing a wrong model.
"""
from __future__ import annotations

import torch
from torch import nn as nn
from torch.nn import functional as F
from torch.nn import init as init
from torch.nn.modules.batchnorm import _BatchNorm


@torch.no_grad()
def default_init_weights(module_list, scale=1, bias_fill=0, **kwargs):
    """Initialize network weights.

    Kept for fidelity with upstream even though every parameter is overwritten
    by `load_state_dict` moments later — a module that constructs differently
    from upstream is a debugging trap for whoever comes next.
    """
    if not isinstance(module_list, list):
        module_list = [module_list]
    for module in module_list:
        for m in module.modules():
            if isinstance(m, nn.Conv2d):
                init.kaiming_normal_(m.weight, **kwargs)
                m.weight.data *= scale
                if m.bias is not None:
                    m.bias.data.fill_(bias_fill)
            elif isinstance(m, nn.Linear):
                init.kaiming_normal_(m.weight, **kwargs)
                m.weight.data *= scale
                if m.bias is not None:
                    m.bias.data.fill_(bias_fill)
            elif isinstance(m, _BatchNorm):
                init.constant_(m.weight, 1)
                if m.bias is not None:
                    m.bias.data.fill_(bias_fill)


def make_layer(basic_block, num_basic_block, **kwarg):
    """Stack `num_basic_block` copies of `basic_block` into an nn.Sequential."""
    layers = []
    for _ in range(num_basic_block):
        layers.append(basic_block(**kwarg))
    return nn.Sequential(*layers)


def pixel_unshuffle(x, scale):
    """Inverse of pixel shuffle: trade spatial size for channels.

    Upstream hand-rolls this as view -> permute -> reshape, which builds a
    **rank-6** intermediate. Core ML only supports rank <= 5, so converting
    RRDBNet at scale=2 or scale=1 dies with:

        Core ML only supports tensors with rank <= 5. Layer
        "x_view_cast_fp16", with type "reshape", outputs a rank 6 tensor.

    torch has had a native pixel_unshuffle since 1.8 that coremltools lowers
    to a supported op. It is bit-identical to the manual version — verified
    with torch.equal across scales 2 and 4 and several shapes — so this is a
    conversion fix, not a numerical change.
    """
    return F.pixel_unshuffle(x, scale)


class ResidualDenseBlock(nn.Module):
    """Residual Dense Block, used inside RRDB."""

    def __init__(self, num_feat=64, num_grow_ch=32):
        super(ResidualDenseBlock, self).__init__()
        self.conv1 = nn.Conv2d(num_feat, num_grow_ch, 3, 1, 1)
        self.conv2 = nn.Conv2d(num_feat + num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv3 = nn.Conv2d(num_feat + 2 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv4 = nn.Conv2d(num_feat + 3 * num_grow_ch, num_grow_ch, 3, 1, 1)
        self.conv5 = nn.Conv2d(num_feat + 4 * num_grow_ch, num_feat, 3, 1, 1)

        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

        default_init_weights([self.conv1, self.conv2, self.conv3, self.conv4, self.conv5], 0.1)

    def forward(self, x):
        x1 = self.lrelu(self.conv1(x))
        x2 = self.lrelu(self.conv2(torch.cat((x, x1), 1)))
        x3 = self.lrelu(self.conv3(torch.cat((x, x1, x2), 1)))
        x4 = self.lrelu(self.conv4(torch.cat((x, x1, x2, x3), 1)))
        x5 = self.conv5(torch.cat((x, x1, x2, x3, x4), 1))
        # Empirically, upstream scales the residual by 0.2 for better performance.
        return x5 * 0.2 + x


class RRDB(nn.Module):
    """Residual in Residual Dense Block."""

    def __init__(self, num_feat, num_grow_ch=32):
        super(RRDB, self).__init__()
        self.rdb1 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb2 = ResidualDenseBlock(num_feat, num_grow_ch)
        self.rdb3 = ResidualDenseBlock(num_feat, num_grow_ch)

    def forward(self, x):
        out = self.rdb1(x)
        out = self.rdb2(out)
        out = self.rdb3(out)
        return out * 0.2 + x


class RRDBNet(nn.Module):
    """ESRGAN / Real-ESRGAN generator.

    For scale 2 and 1 the input is pixel-unshuffled first, reducing spatial
    size and growing channels before the main trunk — which is why `num_in_ch`
    is multiplied below rather than being what the first conv actually sees.
    """

    def __init__(self, num_in_ch, num_out_ch, scale=4, num_feat=64, num_block=23, num_grow_ch=32):
        super(RRDBNet, self).__init__()
        self.scale = scale
        if scale == 2:
            num_in_ch = num_in_ch * 4
        elif scale == 1:
            num_in_ch = num_in_ch * 16
        self.conv_first = nn.Conv2d(num_in_ch, num_feat, 3, 1, 1)
        self.body = make_layer(RRDB, num_block, num_feat=num_feat, num_grow_ch=num_grow_ch)
        self.conv_body = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        # upsample
        self.conv_up1 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_up2 = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_hr = nn.Conv2d(num_feat, num_feat, 3, 1, 1)
        self.conv_last = nn.Conv2d(num_feat, num_out_ch, 3, 1, 1)

        self.lrelu = nn.LeakyReLU(negative_slope=0.2, inplace=True)

    def forward(self, x):
        if self.scale == 2:
            feat = pixel_unshuffle(x, scale=2)
        elif self.scale == 1:
            feat = pixel_unshuffle(x, scale=4)
        else:
            feat = x
        feat = self.conv_first(feat)
        body_feat = self.conv_body(self.body(feat))
        feat = feat + body_feat
        # upsample
        feat = self.lrelu(self.conv_up1(F.interpolate(feat, scale_factor=2, mode='nearest')))
        feat = self.lrelu(self.conv_up2(F.interpolate(feat, scale_factor=2, mode='nearest')))
        out = self.conv_last(self.lrelu(self.conv_hr(feat)))
        return out
