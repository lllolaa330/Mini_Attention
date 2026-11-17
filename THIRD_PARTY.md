# 第三方源代码与来源

本仓库保留第三方文件内的原始版权和许可声明。项目专用 RTL 和测试环境不应被误认为以下作者提供或认可的完整注意力实现。

## Berkeley HardFloat Release 1

- 作者：John R. Hauser；版权所有：The Regents of the University of California。
- 官方主页：https://www.jhauser.us/arithmetic/HardFloat.html
- 官方文档：https://www.jhauser.us/arithmetic/HardFloat-1/doc/HardFloat-Verilog.html
- 下载源：https://www.jhauser.us/arithmetic/HardFloat-1.zip
- 下载日期：2026-11-17（Asia/Shanghai）。
- 原始 zip SHA-256：`6b3757c9fbfa2230c6a2b84605e39372cb589dd7500e979c4f0b8ecc8a03b14b`。
- 本地目录：`third_party/HardFloat-1/`。
- 许可证：[COPYING.txt](third_party/HardFloat-1/COPYING.txt)，三条款 BSD 风格。
- 配置：`expWidth=5`、`sigWidth=11`、`8086-SSE` specialization、RNE、tininess after rounding。标准 binary16 通过 `fNToRecFN`/`recFNToFN` 在运算器边界转换。

兼容性修改：`source/divSqrtRecFN_small.v` 删除重复的 `wire sqrtOpOut;` 声明，端口已经声明为输出 wire。此修改仅解决 SystemVerilog 编译时重复声明，不改动算术或控制逻辑；文件中保留修改注释。编译文件清单见 `rtl/files.f`。

早期考察过的 `bsg-external/HardFloat` fork 需要额外 BSG 模块，因此未作为项目依赖。该探索性本地克隆通过 `.gitignore` 排除，正式 RTL 引用官方 Release 1。

## Berkeley SoftFloat

- 作者：John R. Hauser；版权所有：The Regents of the University of California。
- 仓库：https://github.com/ucb-bar/berkeley-softfloat-3
- 固定版本：`07ebd29db0cfb55723a79fbbffe99103ef38e305`（Release 3e 系列）。
- 本地源码：`third_party/softfloat_source/`，保留 upstream `source/` 内容。
- 许可证：[SOFTFLOAT_LICENSE.txt](third_party/SOFTFLOAT_LICENSE.txt)，三条款 BSD 风格。
- `scripts/softfloat_build/Makefile`、`platform.h` 取自该版本的 `build/Linux-x86_64-GCC/`。运行脚本提供实际 source 路径、编译器和共享库构建参数；构建目录名称不代表在 macOS 上生成 x86 代码。
- 位模型调用 `f16_mulAdd`、`f16_add`、`f16_sub`、`f16_mul`、`f16_div`，采用与 RTL 相同的 RNE 和次正规数语义。Python/C 桥接层属于本项目。

## 阵列设计参考

本项目脉动阵列实现采用标准输出驻留数据流：操作数向右/向下传播，partial sum 保留在 PE 内，边界按行列索引错拍。设计时查看过 [TRANSFORMER-ATTENTION-ACCELERATOR 的定点 qk_systolic.sv](https://github.com/Abhinav-Avasarala/TRANSFORMER-ATTENTION-ACCELERATOR/blob/3054e9a5324da438a78937049f656abc413c2750/src/qk_systolic.sv)，本仓库未复制该仓库 RTL；本项目的 FP16 算术和 Softmax 数值契约以 PROJECT.md 为准。
