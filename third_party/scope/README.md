# SCOPE SCNA-8 Exp coefficients

Mini_Attention uses 16 binary16 numerical coefficients derived from the
public MICRO 2026 SCOPE artifact by Chenyu Zhang, Chenxi Xu, Jiaxiang Zou,
Yonghao Chen and Xinyu Chen. The coefficient source is the 1,910-byte
Exp8 checkpoint at commit `ce29d63a5380e0990b97d4f919126e99db3e1978`.
[Checkpoint](https://github.com/CLab-HKUST-GZ/SCOPE-MICRO26-AE/blob/ce29d63a5380e0990b97d4f919126e99db3e1978/end2endacc/PINNacle/pinn/sw/attn/d8/best_mlp1_scalar_expo_8.pth)
· [Author inference code](https://github.com/CLab-HKUST-GZ/SCOPE-MICRO26-AE/blob/ce29d63a5380e0990b97d4f919126e99db3e1978/end2endacc/PINNacle/pinn/sw/attn/d8/pinn_d8.py)
· [Upstream licensing notice](LICENSE)

The checkpoint SHA-256 is `9d3d346ace40c3b37415127d326834aafa868bfb8da016f0de30299ad8cd071a`.
Mini_Attention exponentiates the three raw parameter vectors, fuses each
positive output weight into its affine coefficients per Equation 2, then
rounds the fused pair once to IEEE binary16. To verify the constants from
the original checkpoint, run the following in the project root.

```sh
python3 scripts/gen_scope_exp.py --check --checkpoint /path/to/best_mlp1_scalar_expo_8.pth
```

The upstream CC BY 4.0 notice covers first-party code and documentation and
excludes model weights from relicensing. The source checkpoint remains in
the authors' repository. Normal simulation uses the local fused constants.
