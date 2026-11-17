# Mini_Attention

**16×16 全 FP16 Output Stationary 脉动阵列注意力 baseline，包含 Softmax 和逐位自检仿真。**

计算 `Y = Softmax(QKᵀ / 4)V`，Q、K、V、Y 均为 16×16。256 个 PE 各保存一个 FP16 累加值；同一阵列先执行 QKᵀ，再执行 PV。Softmax 单元逐行复用浮点乘法、减法、加法、指数 ROM 和迭代除法器。输入输出及每次算术结果均为 IEEE binary16，RNE 舍入并支持次正规数。

本项目为自建课程基线。RTL 仿真结果与实际综合、时序和功耗是不同验证层级；已执行结果、版本和原始证据见 [EXPERIMENTS.md](EXPERIMENTS.md)，当前交接见 [HANDOFF.md](HANDOFF.md)。

## 开始运行

依赖 Python 3.9+、C 编译器、make，以及 Icarus Verilog（iverilog + vvp）或 Verilator。Python 代码仅使用标准库。Berkeley HardFloat 和 SoftFloat 源码随仓库提供，首次运行自动构建 SoftFloat 软件参考，无需额外下载浮点库。当前构建入口面向 little-endian Linux/macOS。

在仓库根目录执行：

```sh
make quick                       # 较小规模完整仿真
make test                        # 定向 + 随机输入、协议/复位自检
make test SIM=verilator           # 第二种仿真器
make model                       # 软件模型检查
make lut-check                   # 指数 ROM 全表检查
make arithmetic                  # FMA / 加减 / 乘 / 除与 SoftFloat 比较
python3 scripts/run_array.py --size 16   # 阵列错拍、hold、clear 和复位
```

更改参数及输出路径：

```sh
python3 scripts/run.py --sim iverilog --random 64 --seed 20261117 \
  --outdir results/my_new_run --timeout 600
```

`--outdir` 必须是不存在的目录，防止覆盖历史证据。不传时自动生成唯一目录。输入包括各自行优先的 Q、K、V 共 768 个 binary16 编码；默认用例由 `model/vectors.py` 生成。使用 `--vectors cases.json` 可注入自定义输入，每项包含 `name`、`category`、`words`（768 个整数编码）。

Mac/VS Code 波形入门：安装 Surfer 扩展后执行 `make quick ARGS="--waves"`，在终端最后显示的 Evidence 目录打开 `attention.vcd`。默认 Icarus 仿真记录顶层控制、Softmax 以及 PE[0,0]、[0,1]、[1,0]、[15,15] 的本地接口和累加值，便于查看错拍传播。使用 `--waves-full` 可递归记录全部浮点内部信号，文件会显著变大。Verilator 忽略 `$dumpvars` 的层次深度/选择，使用它运行 `--waves` 时仍为完整跟踪。波形和编译缓存不纳入 Git。

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
| [rtl/fp16_ops.sv](rtl/fp16_ops.sv) | HardFloat binary16 包装：FMA、加减、乘、除 |
| [rtl/softmax_fp16.sv](rtl/softmax_fp16.sv) | 缩放、减行最大值、exp、分母累加、逐元素归一化 |
| [rtl/exp_fp16.hex](rtl/exp_fp16.hex) | 正确舍入的 FP16 指数 ROM 内容 |
| [rtl/files.f](rtl/files.f) | RTL 和第三方浮点源文件清单 |
| [model/attention.py](model/attention.py) | SoftFloat 逐位模型与独立 float64 数学参考 |
| [scripts/run.py](scripts/run.py) | 输入生成、编译、自检、误差统计、证据归档 |
| [tb/tb_attention.sv](tb/tb_attention.sv) | 逐位 scoreboard、气泡、背压、连续帧、复位恢复 |

[PROJECT.md](PROJECT.md) 给出完整数值契约、数据映射、舍入顺序和握手。FMA 是单次舍入操作；拆成独立乘法和加法会改变结果。Softmax 显式存储 FP16 的 P，归一化没有移到 PV 之后。

## 阵列时序

左侧第 i 行延迟 i 步，上侧第 j 列延迟 j 步。相同内积索引 k 在 `t=k+i+j` 相遇；每轮 16 项点积需要 46 个有效逻辑步。当前 FMA 是组合电路，每步更新一次 FP16 累加值。完整任务还包括 768 字装载、清零、16 行 Softmax、256 字输出及握手停顿。

**46 步不是完整任务时延，也不是任何目标器件已经闭合时序的证明。** 输入数组使用异步读，ROM 和数组在目标平台上的存储映射需要综合确认。本项目没有在说明中假定某个最高频率、DSP/BRAM 数量或功耗。

## 验证标准

- 每个 RTL 输出字与软件位模型一致，输出均有限。
- 同一 FP16 输入的 float64 数学结果：逐帧 RMSE ≤ 0.06，逐元素绝对误差 ≤ 0.20。
- 验证输入气泡、输出背压、跨状态复位恢复、无需复位的连续帧和 watchdog。
- 原始输入、期望值、RTL 实际输出、逐帧统计、运行命令、版本和源码摘要留在唯一 results 目录。

检查的层级及证据说明见 [docs/verification.md](docs/verification.md)。`make lint` 输出 Verilator 警告供审阅，允许第三方兼容性警告；退出成功不等同于零警告。

软件参考采用 [Berkeley SoftFloat](https://github.com/ucb-bar/berkeley-softfloat-3)，硬件浮点运算采用 [Berkeley HardFloat Release 1](https://www.jhauser.us/arithmetic/HardFloat.html)。具体版本、许可证和本地兼容性修改见 [THIRD_PARTY.md](THIRD_PARTY.md)。
