# Mini_Attention

**16×16 全 FP16 单头 Attention**，提供 Stream Attention（OS）、SCOPE（WS）和 OS-SCOPE 三个顶层，计算 `Y = Softmax(QKᵀ / 4)V`。

## OS-SCOPE

[OS-SCOPE 顶层](rtl/os_scope_attention_fp16.sv) 在同一个 16×16 OS 阵列上执行 QKᵀ、SCNA-8 指数和 PV。每份指数既用作概率分子，又进入同一行的分母加法树。双条带共有 128 个 Left、128 个 Right，每个 PE 复用一条 FP16 FMA。以本帧第一次 QK 乘加为 t=0，第 0 行 P 在 t=69 写回，PV 在 t=120 启动。在连续供数、下游持续就绪的条件下，相邻帧每 52 拍启动一次。[电路图](docs/os_scna_pe/os_scope_pe.svg) · [详细时序与缓冲](docs/os_scna_pe/schedule.md) · [四版实验简报](docs/SCOPE_Attention_实验简报.pdf)

```sh
make os-scope                   # 顶层逐位、协议与排程检查
make os-scope SIM=verilator     # 使用第二种仿真器
make os-scope ARGS=--waves      # 查看 os-scope/attention.vcd
make os-scope-lint              # Verilator 严格 lint
make scope-compare              # 在原生公开端口复测四版
```

## SCOPE Attention

[SCOPE 顶层](rtl/scope_attention_fp16.sv) 和 Stream 使用相同的 256 位输入输出协议。它在同一块 WS 阵列上依次计算 QKᵀ、SCNA-8 指数和 PV。ACC 保存行最大值、归约分母并归一化。默认双条带每拍接收 16 个指数输入；单条带每拍接收 8 个，并在同一阵列中实例化全部三类 PE。[Standard](rtl/scope_standard_pe.sv) · [Left](rtl/scope_left_pe.sv) · [Right](rtl/scope_right_pe.sv) · [一页实验简报](docs/SCOPE_Attention_实验简报.pdf)

```sh
make scope                        # SCOPE 顶层，带背压和逐位自检
make scope STRIPS=1               # 128 Standard + 64 Left + 64 Right
make scope SIM=verilator
make scope ARGS=--waves           # 打开结果目录 scope/attention.vcd
make scope-array                  # 验证两种阵列的 QK、Exp 和 PV
make scope-lint                   # 顶层严格 lint，可选 STRIPS=1
make scope-compare                # 用相同输入比较最初基线、Stream、SCOPE 和 OS-SCOPE
```

`scope-compare` 从本地 Git 历史读取 `34559ae` 和 `7ea651a`。输出目录的 `summary.json` 给出首帧时间、稳态帧间隔、吞吐及数值误差。[SCOPE 数值和调度](PROJECT.md#scope-attention)

## Stream Attention

QKᵀ 的点积沿阵列对角线完成。每行一边保存缩放分数，一边更新在线 Softmax 的最大值和分母。行统计完成后，共享的 16 路 exp/div 同时归一化整行。流水线可以连续 16 拍接收 16 行，依次将每行的 16 个 FP16 概率写入行首缓冲。该行从左向右按 k 送出 P，V 从上边界向下传播，同一批 PE 就地累加 Y。左上方的 PE 可以在右下方仍算本帧 QKᵀ 时开始 PV。跨帧时，各 PE 算完上一帧的 Y 即可接收下一帧 QKᵀ 的首项。

Q、K、V 共用一个 256 位 ready/valid 输入口，每次握手传 16 个 FP16。每帧依次传 Q 的 16 行、K 的 16 行和 V 的 16 列，共 48 次握手。通道 k 位于 `in_data[16*k +: 16]`，在这三个阶段分别携带 Q[i,k]、K[j,k] 和 V[k,j]。双帧缓冲允许在处理当前帧时接收下一帧。输出的 16 个通道分别对应 16 列，`out_lane_valid[15:0]` 指示每组中有效的列，一帧共 31 次整组握手、256 个 FP16 字。[时序及矩阵还原](PROJECT.md#6-外部握手与-16-路输出)

以一帧首个 QKᵀ 乘加为第 0 拍，在数据连续到达且下游持续就绪时，本帧 PV 从第 36 拍开始。第 52 拍取出 Y[0,0]，同时 PE[0,0] 开始下一帧的 QKᵀ。接下来的 30 拍内，两帧在同一个阵列的不同 PE 上执行乘加。输入槽在 PV 送入最后一个边界元素后即可接收新帧。[调度与握手](PROJECT.md#5-输入双缓冲与计算调度) · [改动前后实测时间线](results/frame52_top_20261118_9myellui/matched/timeline.png)

本项目为自建课程基线。RTL 仿真结果与实际综合、时序和功耗是不同验证层级；已执行结果、版本和原始证据见 [EXPERIMENTS.md](EXPERIMENTS.md)，当前交接见 [HANDOFF.md](HANDOFF.md)。

## 开始运行

依赖 Python 3.9+、C 编译器、make，以及 Icarus Verilog（iverilog + vvp）或 Verilator。Python 代码仅使用标准库。Berkeley HardFloat 和 SoftFloat 源码随仓库提供，首次运行自动构建 SoftFloat 软件参考，无需额外下载浮点库。当前构建入口面向 little-endian Linux/macOS。

在仓库根目录执行：

```sh
make quick                       # 定向输入及协议自检
make quick ARGS=--waves          # 生成 OS 波形
make test                        # 定向、随机输入及复位/背压
make test SIM=verilator          # 第二种仿真器
make model                       # 软件模型检查
make lut-check                   # 指数 ROM 全表检查
make arithmetic                  # IEEE binary16 运算单测
make array                       # OS 矩阵乘单测
make lint                        # 当前 Attention 顶层的严格静态检查
```

Stream 顶层 `attention_fp16` 只实例化一个 OS 阵列。旧的 WS 阵列源文件与独立单测保留用于重放以往实验。

直接调用 Python 时可选择模式并指定输出目录。

```sh
python3 scripts/run.py --sim iverilog --dataflow os --random 64 --seed 20261117 \
  --outdir results/my_new_run --timeout 600
```

`--outdir` 必须是不存在的目录，防止覆盖历史证据。不传时自动生成唯一目录。向量文件保存各自行优先的 Q、K、V，共 768 个 binary16 编码。testbench 将 Q、K 各打包为 16 个行向量，将 V 打包为 16 个列向量；默认用例由 `model/vectors.py` 生成。使用 `--vectors cases.json` 可注入自定义输入，每项包含 `name`、`category`、`words`（768 个整数编码）。

在 Mac 的 VS Code 安装 Surfer，执行 `make quick ARGS=--waves`，打开终端报告的 Evidence 目录下的 `attention.vcd`。在 `dut` 下，当 `qk_step && pv_step` 为 1 时，`qk_bank == pv_bank` 是同帧重叠，两个槽号不同是跨帧重叠。对齐 `wave_slot_available` 可看背压何时阻止下一拍乘加。观察上升沿前的 `input_fire` 和 `load_count`，计数 15、31、47 分别对应接收最后一行 Q、最后一行 K、最后一列 V。在实际供数有气泡时，`v_cols_ready` 和 `pv_step` 可显示各列到达与 PV 推进的关系。对齐 `norm_issue/norm_issue_row` 和 `prob_valid/prob_row` 可看连续的归一化请求及整行返回。展开 `dut.array_core.rows[0].cols[0].pe` 观察 `step`、`a_valid_in`、`b_valid_in` 及 `acc`。观察 `out_valid`、`out_ready` 和 `out_lane_valid` 可区分结果已就绪及实际传输的时刻。`--waves-full` 递归记录内部层次，文件会显著增大；Verilator 的 `--waves` 为完整跟踪。波形和编译缓存由运行命令生成。

只看一次 Attention 时，加 `--single-frame --stalls 0 --waves`：仅运行输入列表的第一帧，保留启动复位、完整 256 字输出自检和结束后空闲检查，不追加中途复位恢复测试。用 `--vectors` 指定有变化的输入；未指定时，默认列表第一帧为全零。标量接口版本的同输入 OS / WS 历史波形与复现命令见 [单帧运行目录](results/20261118_110939_single_attention_ws_os/README.md)。默认回归仍执行全部协议与复位测试。

对刚刚在本机跑通的目录，还可翻转一位期望值，检查 scoreboard 确实拒绝错误：

```sh
python3 scripts/checker_selftest.py --run results/my_new_run \
  --outdir results/my_new_run_negative
```

该检查需要原运行的本地仿真可执行文件；仓库中的历史证据不包含编译二进制，因此新克隆后应先运行一次仿真。负向检查出现预期 `BIT MISMATCH` 才算检查器自测通过。

## 阅读代码

| 文件 | 用途 |
|---|---|
| [rtl/attention_fp16.sv](rtl/attention_fp16.sv) | 双帧缓存、QKᵀ 与 PV 调度、P 行首缓冲、输出握手 |
| [rtl/systolic_array.sv](rtl/systolic_array.sv) | 16×16 邻接互连和边界输入 |
| [rtl/fp16_pe.sv](rtl/fp16_pe.sv) | FP16 FMA、累加驻留、操作数和 valid 转发 |
| [rtl/fp16_ops.sv](rtl/fp16_ops.sv) | HardFloat binary16 算术 |
| [rtl/online_softmax16.sv](rtl/online_softmax16.sv) | 逐分数更新各行统计、共享 16 路整行归一化 |
| [rtl/fp16_prob_div.sv](rtl/fp16_prob_div.sv) | 为 FP16 归一化操作数设计的两级直接除法，按余数和商最低位做 RNE |
| [rtl/exp_fp16.hex](rtl/exp_fp16.hex) | 正确舍入的 FP16 指数 ROM 内容 |
| [rtl/files.f](rtl/files.f) | RTL 和第三方浮点源文件清单 |
| [model/attention.py](model/attention.py) | SoftFloat 逐位模型与独立 float64 数学参考 |
| [scripts/run.py](scripts/run.py) | 输入生成、编译、自检、误差统计、证据归档 |
| [tb/tb_attention.sv](tb/tb_attention.sv) | 逐位 scoreboard、气泡、背压、连续帧、复位恢复 |

[PROJECT.md](PROJECT.md) 给出完整数值契约、数据映射、舍入顺序和握手。FMA 是单次舍入操作；拆成独立乘法和加法会改变结果。Softmax 显式存储 FP16 的 P，归一化没有移到 PV 之后。

## 过往架构的测量

在 Q/K/V 均为 16 路输入、按整帧切换阵列的版本，稳态相邻帧的首个 QKᵀ 乘加相隔 85 拍。[旧顶层测量](results/cross_frame_wave_20261118_bdk_rkfs/frames.json)

再之前的版本用 256 位端口传输 V 的整列，Q、K 仍各用 256 拍，整帧需要 528 次输入握手。该接口的 PV 空闲与 PE 利用率对照使用相同的非零矩阵和输出背压规则。[V 列输入实验](results/v_column16_20261118_ioj9y7/matched/comparison.json)

此前 V 按行、每拍一个 FP16 的全 OS 版本，在 Q/K/V 已全部入槽的实测帧，从第一拍 QK 乘加计，T33–48 依次发起整行归一化，T36–51 逐行返回，T37–46 的 10 拍内不同 PE 同时执行 QK 与 PV，T53 和 T83 分别接受首末输出组。该版本普通连续输入帧的首末结果在首个输入握手后的第 755/785 拍（含首拍）。[实测展开和波形](results/online_os16_structure_20261118_150712/structure_and_timing.json)

原来采用四层加法树、提供 OS/WS 选项的基线已有两种口径的完整记录。流式全零帧的 OS 首/末结果为 755/785 拍，WS 为 772/802 拍；片上预装分别为 83/113 拍和 101/131 拍。上述数字属于此前的顶层及数值顺序。当前在线 Softmax 版的实测见 [EXPERIMENTS.md](EXPERIMENTS.md)。[历史片上时间线](results/v_overlap_20261118_120306/figures/timeline_resident.pdf) · [历史流式时间线](results/v_overlap_20261118_120306/figures/timeline_stream.pdf) · [四帧逐项对照](results/v_overlap_20261118_120306/benchmarks/comparison.json) · [旧 RTL 重放脚本](results/v_overlap_20261118_120306/benchmark.py)

## 验证标准

- 每个 RTL 输出字与软件位模型一致，输出均有限。
- 同一 FP16 输入的 float64 数学结果：逐帧 RMSE ≤ 0.06，逐元素绝对误差 ≤ 0.20。
- 验证输入气泡、输出背压、跨状态复位恢复、无需复位的连续帧和 watchdog。
- 原始输入、期望值、RTL 实际输出、逐帧统计、运行命令、版本和源码摘要留在唯一 results 目录。

检查的层级及证据说明见 [docs/verification.md](docs/verification.md)。`make lint` 输出 Verilator 警告供审阅，允许第三方兼容性警告；退出成功不等同于零警告。

软件参考采用 [Berkeley SoftFloat](https://github.com/ucb-bar/berkeley-softfloat-3)，硬件浮点运算采用 [Berkeley HardFloat Release 1](https://www.jhauser.us/arithmetic/HardFloat.html)。具体版本、许可证和本地兼容性修改见 [THIRD_PARTY.md](THIRD_PARTY.md)。
