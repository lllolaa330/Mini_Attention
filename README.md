# Mini_Attention

**16×16 全 FP16 注意力脉动阵列，支持输出驻留（OS）和权重驻留（WS），包含 Softmax 和逐位自检。**

计算 `Y = Softmax(QKᵀ / 4)V`，Q、K、V、Y 均为 16×16。每种配置均用同一个 256 PE 阵列先执行 QKᵀ，再执行 PV。OS 将部分和保存在 PE，WS 将右矩阵元素保存在 PE。16 个 Softmax 单元并行处理 16 行。每行用四层 FP16 加法树计算分母，再用 16 个迭代除法器并行求概率。输入输出及每次算术结果均为 IEEE binary16，RNE 舍入并支持次正规数。

输入仍以每拍一个 FP16 字传输。Q 和 K 收齐即启动 QKᵀ，Softmax 与后续 V 的接收可重叠。双缓冲支持同时接收下一帧。**输出接口现为 16 列并行**：`out_data[255:0]`、`out_lane_valid[15:0]` 和整组 ready/valid。第 j 路携带第 j 列，每帧 31 次握手共 256 个 FP16 字。旧的 16-bit 行优先接收端需按新接口适配。[时序及还原方法](PROJECT.md#6-外部握手与-16-路输出)

本项目为自建课程基线。RTL 仿真结果与实际综合、时序和功耗是不同验证层级；已执行结果、版本和原始证据见 [EXPERIMENTS.md](EXPERIMENTS.md)，当前交接见 [HANDOFF.md](HANDOFF.md)。

## 开始运行

依赖 Python 3.9+、C 编译器、make，以及 Icarus Verilog（iverilog + vvp）或 Verilator。Python 代码仅使用标准库。Berkeley HardFloat 和 SoftFloat 源码随仓库提供，首次运行自动构建 SoftFloat 软件参考，无需额外下载浮点库。当前构建入口面向 little-endian Linux/macOS。

在仓库根目录执行：

```sh
make quick                       # OS（默认）
make quick DATAFLOW=ws           # WS，使用相同的 FP16 软件模型
make quick DATAFLOW=ws ARGS=--waves  # 在 Evidence 目录生成 WS 波形
make test                        # 定向 + 随机输入、协议/复位自检
make test SIM=verilator           # 第二种仿真器
make model                       # 软件模型检查
make lut-check                   # 指数 ROM 全表检查
make arithmetic                  # FMA / 加减 / 乘 / 除与 SoftFloat 比较
make array DATAFLOW=ws           # 单独检查 WS 阵列
make lint DATAFLOW=ws            # 检查 WS 的 RTL 展开配置
```

顶层参数 `USE_WS` 在编译或综合时选择阵列，只展开一种结构。已有顶层实例默认使用 OS。选择 WS 可写作 `attention_fp16 #(.USE_WS(1'b1)) dut (...);`。

直接调用 Python 时可选择模式并指定输出目录。

```sh
python3 scripts/run.py --sim iverilog --dataflow ws --random 64 --seed 20261117 \
  --outdir results/my_new_run --timeout 600
```

`--outdir` 必须是不存在的目录，防止覆盖历史证据。不传时自动生成唯一目录。输入包括各自行优先的 Q、K、V 共 768 个 binary16 编码；默认用例由 `model/vectors.py` 生成。使用 `--vectors cases.json` 可注入自定义输入，每项包含 `name`、`category`、`words`（768 个整数编码）。

Mac/VS Code 波形入门：安装 Surfer 扩展后执行 `make quick ARGS="--waves"`，在终端最后显示的 Evidence 目录打开 `attention.vcd`。默认 Icarus 仿真记录顶层控制、第 0 行 Softmax（`dut.parallel_softmax[0].sm`）以及 PE[0,0]、[0,1]、[1,0]、[15,15] 的本地接口。展开 `dut.array_impl.array_core.rows[0].cols[0].pe`，在 OS 下观察 `acc`，在 WS 下观察 `weight`、`a_in`、`psum_out` 和 `psum_valid_out`。使用 `--waves-full` 可递归记录全部浮点内部信号，文件会显著变大。Verilator 忽略 `$dumpvars` 的层次深度/选择，使用它运行 `--waves` 时仍为完整跟踪。波形和编译缓存不纳入 Git。

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
| [rtl/attention_fp16.sv](rtl/attention_fp16.sv) | 顶层输入缓存、两轮阵列调度、P 缓存、输出握手 |
| [rtl/systolic_array.sv](rtl/systolic_array.sv) | 16×16 邻接互连和边界输入 |
| [rtl/fp16_pe.sv](rtl/fp16_pe.sv) | FP16 FMA、累加驻留、操作数和 valid 转发 |
| [rtl/ws_systolic_array.sv](rtl/ws_systolic_array.sv) | WS 装权、部分和链路及阵列底部写回 |
| [rtl/fp16_ws_pe.sv](rtl/fp16_ws_pe.sv) | WS 的驻留权重寄存器与 FP16 FMA |
| [rtl/fp16_ops.sv](rtl/fp16_ops.sv) | HardFloat binary16 包装：FMA、加减、乘、除 |
| [rtl/softmax_fp16.sv](rtl/softmax_fp16.sv) | 单行缩放、减行最大值、exp、树形求和、并行归一化 |
| [rtl/exp_fp16.hex](rtl/exp_fp16.hex) | 正确舍入的 FP16 指数 ROM 内容 |
| [rtl/files.f](rtl/files.f) | RTL 和第三方浮点源文件清单 |
| [model/attention.py](model/attention.py) | SoftFloat 逐位模型与独立 float64 数学参考 |
| [scripts/run.py](scripts/run.py) | 输入生成、编译、自检、误差统计、证据归档 |
| [tb/tb_attention.sv](tb/tb_attention.sv) | 逐位 scoreboard、气泡、背压、连续帧、复位恢复 |

[PROJECT.md](PROJECT.md) 给出完整数值契约、数据映射、舍入顺序和握手。FMA 是单次舍入操作；拆成独立乘法和加法会改变结果。Softmax 显式存储 FP16 的 P，归一化没有移到 PV 之后。

## 阵列时序

| 每次 16×16 矩阵乘 | OS | WS |
|---|---|---|
| PE 内驻留值 | 输出 C[i,j] 的部分和 | 右矩阵元素 B[k,j] |
| 启动与计算 | 清零后运行 46 拍 | 清零后装权 16 拍，运行 47 拍（含最后的写回） |
| 结果位置 | 256 个 PE 的累加器 | 阵列底部按列写入 16×16 结果缓存 |

两种实现的每个输出都从 FP16 的 +0 开始，按 k 递增做 16 次融合乘加。整帧测量包括输入、清零、Softmax、输出及握手停顿，各阶段允许重叠。仿真周期与综合频率、面积、功耗需要分别测量。

## 验证标准

- 每个 RTL 输出字与软件位模型一致，输出均有限。
- 同一 FP16 输入的 float64 数学结果：逐帧 RMSE ≤ 0.06，逐元素绝对误差 ≤ 0.20。
- 验证输入气泡、输出背压、跨状态复位恢复、无需复位的连续帧和 watchdog。
- 原始输入、期望值、RTL 实际输出、逐帧统计、运行命令、版本和源码摘要留在唯一 results 目录。

检查的层级及证据说明见 [docs/verification.md](docs/verification.md)。`make lint` 输出 Verilator 警告供审阅，允许第三方兼容性警告；退出成功不等同于零警告。

软件参考采用 [Berkeley SoftFloat](https://github.com/ucb-bar/berkeley-softfloat-3)，硬件浮点运算采用 [Berkeley HardFloat Release 1](https://www.jhauser.us/arithmetic/HardFloat.html)。具体版本、许可证和本地兼容性修改见 [THIRD_PARTY.md](THIRD_PARTY.md)。
