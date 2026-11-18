# 验证记录

## 2026-11-18 Q、K 整行输入

同一 256 位 ready/valid 口每次握手传 16 个 FP16，依次为 16 行 Q、16 行 K、16 列 V，每帧从 528 次输入握手降至 48 次。Q[i,k] 与 K[j,k] 各在所属行的通道 k 接收，第 j 个上边界按 k 读取 K[j,k] 参与 QKᵀ。测试平台按旧格式读取三块行优先矩阵，从阵列两条输入边独立核对 Q/K 的行号和 k。种子为 20261117。[修改前的顶层](results/qkv_row16_20261118_m8jjyw1p/before/rtl/attention_fp16.sv) · [接口契约](PROJECT.md)

Icarus 12.0 运行 `make test`，41 帧的 10,496 个 P 和 10,496 个 Y 分别与软件模型逐位一致。覆盖 11 次复位、双帧槽满时顶住上游、1,852 拍输入气泡，以及连续 2,500 拍的定向输出背压。最大逐帧 RMSE 0.00165280，最大逐元素绝对误差 0.00800302。另运行 `make lint`，顶层通过严格检查。[Icarus 自检与精度](results/qkv_row16_20261118_m8jjyw1p/icarus_stalls/summary.json) · [严格 lint](results/lint_os_20261118_155935/manifest.json)

对非零输入 `random_uniform_001`，用 `--single-frame --stalls 0 --waves` 生成波形，按上升沿前的有效握手核对全部 48 拍、768 个输入字及两个帧内边界。把首个 Q 握手计为第 1 拍，Q、K、V 分别占第 1–16、17–32、33–48 拍，第 86 拍接受首组输出，第 116 拍接受末组输出。上一版在相同输入上为 566/596 拍。[新版 VCD](results/qkv_row16_20261118_m8jjyw1p/single_wave/attention.vcd) · [握手实测](results/qkv_row16_20261118_m8jjyw1p/wave_check.json) · [上一版非零输入记录](results/20261118_153545_os_iverilog_seed20261117_57187/per_frame.csv)

Verilator 5.044 运行相同的 41 帧带背压回归，通过相同的逐位和精度检查。两个模拟器的原始输出（含周期）、逐帧统计及双金标分别逐字节一致。首次 Verilator 构建时，生成器拆开测试平台的 fork/join 协程，生成的 C++ 无法访问同步变量；为此仅在该测试平台的 Verilator 构建中设置 `--output-split-cfuncs 0`。[双模拟器核对](results/qkv_row16_20261118_m8jjyw1p/cross_sim.json) · [最终 Verilator 记录](results/qkv_row16_verilator_20261118_03/manifest.json) · [首次 C++ 编译日志](results/qkv_row16_verilator_20261118_01/tb_attention_compile.log)

两版在 Verilator 上以同一组 25 帧连续供数，下游持续 ready。上一版每两帧的首输入、首输出、末输出间隔均为 528 拍。新版相邻首输入间隔依次为 48、68，随后 22 个间隔均为 85 拍。24 个相邻首输出间隔和 24 个相邻末输出间隔均为 85 拍。从第 3 帧起，以该帧首个输入握手计为第 1 拍，含双缓冲排队的首组/末组输出延迟为 140/170 拍。按相邻末输出间隔折算的稳态吞吐量为上版的 528/85 ≈ 6.21 倍，单位为帧/时钟周期。以上为 RTL 仿真计数。[逐帧周期](results/qkv_row16_20261118_m8jjyw1p/timing/frames.csv) · [输入与时序对照](results/qkv_row16_20261118_m8jjyw1p/timing/comparison.json)

## 2026-11-18 每拍一列 V 的 OS 阵列

以修改前实际工作区为基线，封存两版 RTL。顶层将 `in_data` 加宽到 256 位；Q/K 各 256 拍使用低 16 位，V 使用 16 拍，拍 j 的通道 k 传输 V[k,j]。每列在两个帧槽各有一份独立列缓存；第 j 列在逻辑步 t 读取行号 k=t−j，同一列只向该列的顶部 PE 送数。软件数值模型与输出协议沿用此前实现。

在相同非零矩阵 `random_uniform_001` 上测量两个版本。输入持续供数，分别保持输出持续就绪或在同一输出组阻塞 12 拍。每个 PE 的有效 FMA 由 VCD 上升沿前的局部 step 和两个 valid 统计。端点计入周期；PV 窗口从首个至末个 PV 乘加，计算窗口从首个 QK 至末个 PV 乘加。

| 接收条件 | PV 闲置拍，旧→新 | PV 窗口拍数 | PE 利用率，PV 窗口 | PE 利用率，计算窗口 | 从首个输入到末个输出 |
|---|---:|---:|---:|---:|---:|
| 持续 ready | 189→0 | 235→46 | 6.81%→34.78% | 11.81%→39.02% | 785→596 拍 |
| 同组阻塞 12 拍 | 200→11 | 246→57 | 6.50%→28.07% | 11.35%→34.41% | 797→608 拍 |

每个坐标均执行 16 个 QK 和 16 个 PV 乘加。PV 有效推进均为 46 步；两组实验的旧版各有 189 拍缺 V，新版均为零。带背压时两版均因输出缓冲被占满停 11 拍。首个输入握手起算，两版首个 PV 乘加均在第 550 拍，首组输出握手由 755 提前到 566 拍。[波形比较](results/v_column16_20261118_ioj9y7/matched/comparison.json) · [每个 PE 的明细](results/v_column16_20261118_ioj9y7/matched/per_pe.csv) · [测试夹具](results/v_column16_20261118_ioj9y7/tb_matched.sv)

运行 `make test ARGS=--waves` 和 `make test SIM=verilator`，种子 20261117。Icarus 12.0 和 Verilator 5.044 各自通过 41 帧，10,496 个 P 和 10,496 个 Y 均逐位一致。覆盖 11 次复位、连续 2,500 拍输出背压、输入等待时数据保持、第 8 列缺数和随后恢复；检查每次实际注入的 V[k,j]。相同帧的输入、双金标、实际输出（含周期）及逐帧统计在两个模拟器上相同。另运行 `make regression SIM=verilator`，97 帧的 24,832 个 P 和 24,832 个 Y 通过；最大逐帧 RMSE 为 0.00181428，最大逐元素绝对误差为 0.00800302。`make lint` 严格检查通过。上述拍数为 RTL 仿真结果，面积和最高频率尚待综合评估。[41 帧 Icarus](results/20261118_153545_os_iverilog_seed20261117_57186/summary.json) · [41 帧 Verilator](results/20261118_153540_os_verilator_seed20261117_53973/summary.json) · [97 帧回归](results/20261118_153604_os_verilator_seed20261117_66136/summary.json) · [逐字节核验](results/v_column16_20261118_ioj9y7/regression_audit.json) · [严格 lint](results/lint_os_20261118_153500/manifest.json)

## 逐 PE 运算利用率（2026-11-18，标量 V 版本）

从 Icarus 波形的上升沿前读取 `tb_attention.pe_mac[16*i+j]`，有效条件为本地 step 及两个操作数 valid。完整帧每个坐标实测 32 次乘加，共 8,192 次。以首个 QK MAC 到末个 PV MAC 为共同窗口（含两端），run 40 的 256 个位置各为 32/82，run 0 各为 32/271。run 0 从首个输入到末个输出握手时各为 32/785。逐坐标首末活动拍另见 [CSV](results/pe_utilization_20261118_719dIk/per_pe.csv)。

复算命令为 `python3 results/pe_utilization_20261118_719dIk/count_pe.py results/20261118_150420_os_iverilog_seed20261117_21540 --frames 0 40 --output /tmp/mini_attention_pe_util_new.csv`，输出路径需尚未存在。该分析重用已有波形。

## 2026-11-18 全 OS 阵列与逐拍整行 FP16 归一化

端到端比较来自当前的独立 SoftFloat 位模型，在线分母按顺序递推，指数表、FP16 乘、加和直接除法按各自边界舍入。前一版使用树形分母，两版 P 在某些输入上有真实位差；独立 float64 数学定义沿用原函数。输入槽和 16 列对角线输出协议沿用此前实现。以下运行均基于本机 macOS arm64，种子 20261117；主回归含 17 个定向输入与 8 个随机输入、额外的背压及恢复帧。

| 操作 | 结果 | 证据 |
|---|---|---|
| `make test ARGS=--waves`，Icarus 12.0 | 41 帧，10,496 个 P 和 10,496 个 Y 分别逐字一致 | [摘要](results/20261118_150420_os_iverilog_seed20261117_21540/summary.json) |
| `make test SIM=verilator`，Verilator 5.044 | 同一批 41 帧通过，实际输出含握手拍号及逐帧统计与 Icarus 一致 | [逐帧](results/20261118_150418_os_verilator_seed20261117_20938/per_frame.csv) · [跨模拟器审计及 P/Y 翻位负向自检](results/online_os16_cross_sim_20261118_150418/summary.json) |
| `make regression SIM=verilator` | 17 个定向和 64 个随机输入，附加协议/恢复用例后共 97 帧、24,832 个 P 和 24,832 个 Y 逐位一致；最大逐帧 RMSE 0.00181428、最大逐元素绝对误差 0.00800302 | [扩展回归](results/20261118_150551_os_verilator_seed20261117_35081/summary.json) |
| `make lint` | 唯一的全 OS Attention 顶层严格 lint 通过 | [运行清单](results/lint_os_20261118_150420/manifest.json) |
| `python3 scripts/run_prob_div.py` 及独立归一化模块检查 | 144,942 个直接除法向量；128 行共 2,048 个概率逐位一致，含次正规、流水气泡及清帧 | [除法](results/prob_div_20261118_145901/manifest.json) · [整行归一化](results/online_softmax16_20261118_145909/manifest.json) |
| `make quick ARGS="--single-frame --waves --stalls 0 --vectors results/20261118_110939_single_attention_ws_os/single_input.json"` | 一帧非零输入，256 P 和 256 Y 通过 | [逐帧结果](results/20261118_150420_os_iverilog_seed20261117_21541/per_frame.csv) · [波形](results/20261118_150420_os_iverilog_seed20261117_21541/attention.vcd) |

每个模拟器均有 11 次复位，覆盖输入气泡 16,235 拍、输出阻塞 7,432 拍（含连续 2,500 拍）、缺 V 及排队帧复位。与 float64 参考比较，41 帧中的最大逐帧 RMSE 为 0.001652797，最大逐元素绝对误差为 0.008003024。每帧独立检查 256 个 PE 的实际使能及输入 valid，每个 PE 恰接受 16 个 QK 和 16 个 PV 项；16 行 P 的发出、返回均连续且有序。此前版本的期望字或计时不能用作当前判据。

| 实际信号，首个 QK 乘加为 T1 | 流式，无停顿，第 0 帧 | 启动时 Q/K/V 完整，第 40 帧 |
|---|---:|---:|
| QK 乘加窗口 | T1–46 | T1–46 |
| 16 行归一化请求 / 返回 | T33–48 / T36–51 | T33–48 / T36–51 |
| 首个 PV 乘加 | T37 | T37 |
| 不同 PE 同时执行 QK、PV 的拍数 | 3 | 10 |
| 首组 / 末组输出握手 | T242 / T272 | T53 / T83 |

从两份 Icarus 展开文件独立数到 1 块 OS 阵列、256 个 OS PE 和 256 个阵列 FMA、1 个归一化模块及其 16 个流水除法器。该顶层的 WS 阵列与 WS PE 计数均为零。两个示例窗口的每个 PE 有效位、QK/PV 同拍事件、归一化和输出握手均经 VCD 直接复核。[展开与波形证据](results/online_os16_structure_20261118_150712/structure_and_timing.json)

第 40 帧经正常输入端口进入第二槽，由上一帧的输出背压确保派发时 Q/K/V 全部在片上，派发后下游持续 ready。若将清阵列沿计为第 1 拍，其首末输出为 54/84 拍。流式第 0 帧从首个 Q 输入握手计为 755/785 拍，下一帧首个 Q 握手间隔为 768 拍。以上是 RTL 时钟计数；尚无综合、布局布线、STA 或功耗实测。

旧源码快照、首次 lint 的无符号常量比较告警和各次运行均保留。最终实现将本地逻辑步与对角线偏移的差映射为 FP16 内积项索引，严格 lint 已用最终源码重跑。

## 2026-11-18 接收 V 与 PV 重叠

参照版本为 `4172ffe` 的双帧缓存、按列输出 RTL。两版保持相同的 16×16 FP16 阵列规模、Softmax、输入输出格式和舍入顺序。四个固定输入分别为全零、单位阵转置探针、随机位模式和均匀随机；软件重新生成了 1,024 个期望字。Icarus 12.0 对两个版本、两种数据流和两种计时口径共运行 32 帧，逐一核对输出掩码、帧尾和 8,192 个 FP16 字。[逐帧输出与延迟比较](results/v_overlap_20261118_120306/benchmarks/comparison.json) · [夹具校验](results/v_overlap_20261118_120306/fixture_verification.json) · [重放命令](docs/verification.md)

| 下游持续 ready，拍数含首尾 | 首组，优化前 → 后 | 末组，优化前 → 后 |
|---|---:|---:|
| 流式 OS，4 帧 | 786 → 755 | 816 → 785 |
| 流式 WS，4 帧 | 803 → 772 | 833 → 802 |
| 片上预装 OS，全零帧 | 83 → 83 | 113 → 113 |
| 片上预装 WS，全零帧 | 117 → 101 | 147 → 131 |

流式从首个 Q 输入握手计，4 帧连续无气泡，3 个输入启动间隔均为 768 拍。片上对各帧单独预装，从核心执行 CLEAR_QK 的上升沿计，包含 WS 从片上缓冲向 PE 装 K 的时间。其他 3 帧的片上首末组都比零帧多 1 拍。首组只含 Y[0,0]，末组握手时已交付 256 字。[片上实测时间线](results/v_overlap_20261118_120306/figures/timeline_resident.pdf) · [流式实测时间线](results/v_overlap_20261118_120306/figures/timeline_stream.pdf) · [逐拍数据与绘图入口](results/v_overlap_20261118_120306/figures/README.md)

流式全零帧中，OS 在第 579 拍首次推进 PV，第 755 拍送出首组；最后一个 V 字在第 768 拍握手。WS 在 Softmax 期间装好 V 的前 5 行，第 596 拍首次推进 PV，第 769 拍装最后一行，第 772 拍送出首组。PV 阶段跨度均为 206 拍，含 OS 的 46 个有效推进步与 160 个缺数等待拍，或 WS 的 47 个有效推进步与 159 个等待拍。片上 WS 在第 65–80 拍装 16 行 V，每次写均与 Softmax 重叠。拍数来自 RTL 仿真，频率、面积、功耗和存储器映射尚待综合评估。

### 背压和复位自检

运行 `make test ARGS=--waves`、`make test DATAFLOW=ws ARGS=--waves`，另运行 `make test SIM=verilator` 与 `make test DATAFLOW=ws SIM=verilator`。种子 20261117，17 个定向输入加 8 个随机输入，再运行长背压、半张 V 后暂停、连续帧及复位恢复用例。Icarus 12.0 与 Verilator 5.044 分别得到以下结果。

| 数据流 | 完成帧 / 逐位一致 FP16 字 | 复位次数 | 输出被阻拍数 | 收完 V 前的 PV 实际推进步（累计） | Softmax 期间 V 行写入（累计） |
|---|---:|---:|---:|---:|---:|
| OS | 47 / 12,032 | 17 | 6,865 | 919 | — |
| WS | 49 / 12,544 | 19 | 6,917 | 720 | 153 |

两种模式均覆盖连续 2,500 拍输出背压、输入气泡与输出受阻同时出现、PV 缺 V 时复位和两帧槽已占用时复位。WS 还覆盖装入三行 V 后复位。与独立 float64 数学模型相比，最大逐帧 RMSE 为 0.001136984，最大逐元素绝对误差为 0.003790716。Icarus 的紧凑 VCD 与对应 summary 同目录。[OS Icarus](results/20261118_121751_os_iverilog_seed20261117_23777/summary.json) · [WS Icarus](results/20261118_121751_ws_iverilog_seed20261117_23781/summary.json) · [OS Verilator](results/20261118_121751_os_verilator_seed20261117_23780/summary.json) · [WS Verilator](results/20261118_121751_ws_verilator_seed20261117_23779/summary.json)

同一数据流在两个模拟器中的输入、期望、全部实际字及其握手拍号、逐帧统计均逐字节一致。额外在两个最终 Verilator 可执行文件上分别翻转第一个 FP16 期望值的低位，scoreboard 均在第一个输出坐标报错。[源码与双模拟器审计](results/v_overlap_20261118_120306/verification_audit.json) · [OS 负向自检](results/v_overlap_20261118_120306/checker_negative_os/summary.json) · [WS 负向自检](results/v_overlap_20261118_120306/checker_negative_ws/summary.json) · [最终计时复核](results/v_overlap_20261118_120306/probe_recheck.json)

WS 阵列级自检另比较了移位与定址写权，16×16 各 2,048 字、2×2 各 32 字一致；包含暂停期间写权、写权与推进同拍和旧权参与同拍 FMA。两个顶层参数的 Verilator 严格 lint 通过。跨模拟器联调时，将 WS 行写观察信号提升到稳定的顶层路径以解决 Verilator 的同名 generate 层次绑定错误，保留了原失败记录并用最终源复验。[阵列结果](results/ws_direct_array16_20261118/coverage.json) · [OS lint](results/lint_os_20261118_121751/manifest.json) · [WS lint](results/lint_ws_20261118_121751/manifest.json)

## 2026-11-18 流水时间线（本次 V 优化前）

从本节下方流式回归的两份 Icarus VCD 提取第 0 帧（全零、连续输入、无背压），按上升沿前信号识别数据传输并核对逐帧日志。以首个输入握手为第 1 拍，OS 在 786–816 拍输出，WS 在 803–833 拍输出，下一帧均于第 769 拍开始输入。图中 Softmax 包含启动拍至顶层收齐各行概率，内部相位另记在 JSON 中。此次使用已有仿真结果。进入 `results/stream_timeline_20261118` 后依次执行 `python3 extract_timeline.py` 与 `python3 plot_timeline.py` 即可重生成（绘图需要 Matplotlib 和中文字体）。[时间线 PDF](results/stream_timeline_20261118/mini_attention_timeline.pdf) · [带来源的周期数据](results/stream_timeline_20261118/timeline.json)

## 2026-11-18 双帧缓存与 PV 按列输出

测量前封存了实际工作区中使用标量输出的 RTL。Icarus 12.0 在相同的 25 帧（17 个定向、8 个随机，种子 20261117）上分别执行旧版及新版 OS、WS。输入持续有效，每拍最多一个 FP16 字；接收端持续就绪。四次运行的 6,400 个 FP16 输出重排后逐位相同。[测量命令、源码快照和运行记录](results/pingpong_baseline_20261118_112657/README.md) · [汇总](results/pingpong_baseline_20261118_112657/comparison.json)

| 实现 | 首组输出延迟（拍） | 末组输出延迟（拍） | 输入帧间隔（拍） | 平均输入帧间隔（拍） |
|---|---:|---:|---:|---:|
| 原 OS | 881–882 | 1,136–1,137 | 1,136–1,137 | 1,136.46 |
| 流式 OS | 786 | 816 | 768 | 768 |
| 原 WS | 915–916 | 1,170–1,171 | 1,170–1,171 | 1,170.46 |
| 流式 WS | 803 | 833 | 768 | 768 |

每帧延迟从首个输入握手算至对应输出握手，包含首尾两拍；帧间隔取相邻帧首次输入握手周期之差，共 24 个间隔。四项改动共同影响结果：接收 V 时执行 QKᵀ/Softmax、双帧输入缓存、PV 与结果输出重叠、输出从 16 bit 增宽至 16 路。每时钟可接收的帧数分别为旧 OS 的 1.48 倍、旧 WS 的 1.52 倍。未测综合频率、面积或功耗。

在本次无停顿输入下，第一轮 WS 装权和写回的额外时间包含在接收 V 的窗口内。流式 WS 的整帧延迟比流式 OS 多出的 17 拍来自 PV 的 16 拍装权和 1 拍底部写回。两种配置都可以用 31 个连续握手传完结果。

**带背压的端到端回归**使用 `make test ARGS=--waves` 及 `make test DATAFLOW=ws ARGS=--waves`。Python 3.9.6 与 Icarus 12.0 的实际运行如下。每种模式都包含首组持续阻塞 2,500 拍、在不同对角线暂停、双槽满时阻挡第三帧、清除排队帧的中途复位、输入气泡和随后恢复。

| 配置 | 逐位通过的帧 / FP16 字 | 复位 | 输出背压周期 | 下一帧输入与本帧输出同拍握手 |
|---|---:|---:|---:|---:|
| [OS](results/20261118_113652_os_iverilog_seed20261117_65508/summary.json) | 45 / 11,520 | 17 | 6,563 | 525 |
| [WS](results/20261118_113652_ws_iverilog_seed20261117_65509/summary.json) | 47 / 12,032 | 19 | 6,702 | 532 |

每个受检帧的首次输出握手都发生在 RUN_PV 阶段。两模式的最大逐帧 RMSE 为 0.00113698，最大绝对误差为 0.00379072。每份清单记录源摘要、工具版本和命令；同目录含按握手周期记录的 actual.txt、逐帧统计及本地 VCD。`make lint` 和 `make lint DATAFLOW=ws` 均通过 Verilator 5.044 的严格检查。[OS lint](results/lint_os_20261118_113350/strict.log) · [WS lint](results/lint_ws_20261118_113420/strict.log)

在 Verilator 5.044 上分别运行 `make test SIM=verilator`、`make test SIM=verilator DATAFLOW=ws`。OS 45 帧、WS 47 帧再次通过。逐数据流比较两种仿真器的 actual.txt、summary.json 和 per_frame.csv，三个文件分别逐字节相同，包括所有握手周期与背压覆盖计数。[Verilator OS](results/20261118_113938_os_verilator_seed20261117_81111/summary.json) · [Verilator WS](results/20261118_113740_ws_verilator_seed20261117_72625/summary.json)

使用旧单帧波形的非零输入，流式 OS 的 `--single-frame --stalls 0 --waves` 独立通过 1 帧和 1 次启动复位，实测 816 拍。翻转期望值第一个字的最低位后，新的逐列 scoreboard 正确报告第一个输出不匹配。[单帧运行](results/20261118_113905_os_iverilog_seed20261117_76992/summary.json) · [负向自检](results/stream_checker_negative_20261118/summary.json)

## 2026-11-18 单次完整 WS / OS Attention 波形

为单次观察增加 `scripts/run.py --single-frame` 与 testbench `SINGLE_FRAME`（默认关闭）；仅取第一组输入，不追加中途复位/恢复帧，保留逐位、精度、握手、超时及结束后空闲检查。默认完整回归入口保留。RTL 和数值模型未修改。

使用同一组 `random_uniform_001`（seed=20261117）输入，Icarus 12.0、Python 3.9.6，`--single-frame --stalls 0 --waves`。WS / OS 各通过 1 帧、256 字；各一次启动复位、一次 done，无输入气泡或输出背压。端到端仿真周期分别为 **1171 / 1137**。两模式输出逐位一致，均与 SoftFloat 逐位匹配；RMSE 0.000668248795，最大绝对误差 0.00249899501。ROM 检查、7 项模型单测通过。

直接解析两份 VCD，确认各 768 次输入握手、256 次输出握手、1 次 done、1 次启动复位，阶段次序完整。全部运行源码摘要与快照、运行后工作区逐项一致。此次未重新运行完整复位/背压回归，不将单帧证据描述为新增协议覆盖验证。

[波形、阶段时间、精确复现命令与源码快照索引](results/20261118_110939_single_attention_ws_os/README.md) · [VCD 直接检查](results/20261118_110939_single_attention_ws_os/wave_inspection.json)。两份 VCD 分别在该目录的 `ws/attention.vcd` 与 `os/attention.vcd`，大型波形仍被 Git 忽略。新增入口及记录在本地，未提交或推送。

## 2026-11-18 可选的 OS / WS 阵列

基于本地 16 行并行 Softmax，在同一个顶层用 `USE_WS` 展开一种 16×16 阵列。下列两次端到端测试使用 Icarus 12.0、Python 3.9.6、种子 20261117、17 个定向输入和 8 个随机输入。两份输入文件和软件期望文件逐字节相同。

| 运行命令 | 结果 | 原始证据 |
|---|---|---|
| `make test` | OS 通过，39 帧，9,984 个 FP16 输出，15 次复位 | [逐帧统计](results/20261118_090958_os_iverilog_seed20261117_75209/summary.json) |
| `make test DATAFLOW=ws ARGS=--waves` | WS 通过，41 帧，10,496 个 FP16 输出，17 次复位 | [逐帧统计](results/20261118_090858_ws_iverilog_seed20261117_69194/summary.json) · [仿真日志](results/20261118_090858_ws_iverilog_seed20261117_69194/simulation.log) |
| `make array DATAFLOW=ws` 与 `make array DATAFLOW=ws ARGS="--size 2"` | 16×16 的 8 组矩阵共 2,048 个输出，2×2 共 32 个输出。逐拍检查权重、结果出现的具体时刻、暂停保持及复位 | [16×16 日志](results/array_ws16_20261118_091047_iverilog/array.log) · [2×2 日志](results/array_ws2_20261118_090956_iverilog/array.log) |
| `make lint DATAFLOW=os` 与 `make lint DATAFLOW=ws` | Verilator 5.044 严格 RTL lint 均通过 | [OS 日志](results/lint_os_20261118_090858/strict.log) · [WS 日志](results/lint_ws_20261118_090858/strict.log) |

比较两个运行的 `actual.txt` 前四列（运行号、用例号、输出索引、FP16 字），WS 的前 9,984 条与 OS 完全相同。WS 另有两帧用于检验装权中途复位的恢复。两模式最大逐帧 RMSE 均为 0.00113698，最大逐元素绝对误差均为 0.00379072。首两帧从第一个输入握手到最后一个输出握手均无停顿，分别测得 OS 1,136 拍和 WS 1,170 拍。差值对应两轮各 16 拍装权加 1 拍写回。

WS 的本地 `attention.vcd` 与仿真日志在同一目录。约 36.045 µs 处为第三帧 QKᵀ 计算，全 2 输入时，第 0、1 行第 0 列 PE 的权重都是 `0x4000`（2），有效部分和分别为 `0x4400`（4）和 `0x4800`（8）。VCD 和编译二进制按项目约定被 Git 忽略。

并行启动阵列单测时发现两个 Python 进程会同时链接共享的 SoftFloat 库。修复位于软件构建入口，对缓存加进程锁，并在同目录链接成功后原子替换动态库。上述带 8 个随机输入的运行使用相同 RTL 和算术，早于构建锁修复。在 macOS 上，修复后的 4 个进程从同一空缓存首次构建通过，另 4 个并发模型单测进程均通过 7 项测试。[并发验证及复现命令](results/softfloat_concurrency_20261118_01/run/summary.json)

在最终源码上同时启动 `make quick` 和 `make quick DATAFLOW=ws`，OS 通过 31 帧、7,936 字，WS 通过 33 帧、8,448 字。两份运行清单中的全部源码哈希均与最终工作区一致。OS 的 `actual.txt` 与加入 WS 前的 08:46 基线完全相同，包括每个输出的握手周期。[OS quick](results/20261118_091205_os_iverilog_seed20261117_89691/summary.json) · [WS quick](results/20261118_091205_ws_iverilog_seed20261117_89690/summary.json)

## 2026-11-18 并行 Softmax 的 quick 回归

测试基于 `726ae6f` 及本地的 16 行并行修改。每行分母用四层相邻配对加法树计算，每个节点舍入至 binary16。测试平台观察第 0 行 Softmax 的状态来注入全局复位。每条除法通道在自己的完成周期保存商，顶层在行完成时写回全部 16 列。

| 操作 | 结果与证据 |
|---|---|
| 修复前运行 `make quick` | Icarus 在展开测试平台时报告两个旧实例路径绑定错误。[编译日志](results/20261118_084440_iverilog_seed20261117_47845/tb_attention_compile.log) |
| 检查此前的 case 9 失败 | `identity_transpose_probe` 第 0 行，顺序求和与树形求和的分母分别为 `0x475c` 和 `0x475d`，对应的 `Y[0,1]` 分别为 `0x2a0c` 和 `0x2a0b`。已加入模型回归。[旧版失败日志](results/20261117_210947_iverilog_seed20261117_71066/simulation.log) |
| 运行 `make lint` | Verilator 5.044 对当前 RTL 的严格检查通过。[严格检查日志](results/lint_20261118_084632/strict.log) |
| 修复后运行 `make quick` | Icarus 12.0、Python 3.9.6，种子 20261117，随机帧数 0。7 项模型单测通过。17 个定向帧和 14 个复位恢复帧共 7,936 个输出逐位一致。相对独立 float64 参考，最大逐帧 RMSE 为 0.0009765625，最大逐元素绝对误差为 0.00149980。15 次复位，13,192 个输入气泡周期，2,598 个输出背压周期。[运行清单](results/20261118_084637_iverilog_seed20261117_57290/manifest.json) · [逐帧结果](results/20261118_084637_iverilog_seed20261117_57290/summary.json) · [仿真日志](results/20261118_084637_iverilog_seed20261117_57290/simulation.log) |

## 2026-11-17：Mac/Surfer 紧凑波形入口

默认 Icarus `--waves` 改为记录顶层、Softmax 和 PE[0,0]/[0,1]/[1,0]/[15,15] 的一层信号；`--waves-full` 保留递归全量跟踪。Verilator 不采用该层次筛选，README 和参数帮助已注明。RTL、ROM、软件数值模型均未修改。

运行 `python3 scripts/run.py --random 0 --waves --outdir results/compact_wave_check_20261117`，Icarus 12.0 下 30 帧、7,680 个输出全部逐位匹配且精度通过，14 次复位、12,577 个输入气泡周期、2,437 个输出背压周期。生成 attention.vcd 为 18,827,197 字节，138 个信号声明；检查包含四个指定 PE 的 acc 和顶层 state，且无 FMA 内部层次。完整结果见该目录 summary.json、manifest.json 和 simulation.log。VCD 已被 Git 忽略；本轮测试平台/脚本/说明改动尚未提交推送。

日期：2026-11-17（Asia/Shanghai）。本轮在本机 macOS arm64 执行；Python 3.9.6、Apple clang 21.0.0、Icarus Verilog 12.0 stable、Verilator 5.044。浮点库版本见 THIRD_PARTY.md。仿真时钟周期为 10 ns，此值不代表硬件时序已闭合。

## 发布版本验证

| 运行目录（results/） | 命令 | 结果 |
|---|---|---|
| release_iverilog_seed20261117 | `python3 scripts/run.py --random 64 --outdir results/release_iverilog_seed20261117 --timeout 900` | PASS；94 帧、24,064 个输出逐位一致 |
| final_verilator_seed20261117 | `python3 scripts/run.py --sim verilator --random 64 --outdir results/final_verilator_seed20261117 --timeout 900` | PASS；94 帧、24,064 个输出逐位一致 |
| arithmetic_iverilog_02 | `python3 scripts/run_arithmetic.py --outdir results/arithmetic_iverilog_02` | PASS；17,000 个 FMA/加/减/乘/除用例，含除法中途复位恢复 |
| array2_iverilog | `python3 scripts/run_array.py --size 2 --outdir results/array2_iverilog` | PASS；8 次 GEMM、32 个输出 |
| array16_iverilog | `python3 scripts/run_array.py --size 16 --outdir results/array16_iverilog` | PASS；8 次 GEMM、2,048 个输出，144 个暂停周期 |
| final_checker_negative | `python3 scripts/checker_selftest.py --run results/final_verilator_seed20261117 --outdir results/final_checker_negative` | PASS；故意翻转第一个期望字的一位，scoreboard 正确报错并非零退出 |
| lint_release | `python3 scripts/lint.py --outdir results/lint_release` | PASS；`--Wall` 严格检查加逐文件白名单，同时保留未过滤日志 |
| release_audit | `python3 results/release_audit/audit.py` | 对照最终源文件摘要及双仿真器归档输出，见 summary.json |

复现时使用新的输出目录；脚本拒绝覆盖已存在的目录。默认 seed=20261117、输入气泡/背压开启。命令原文、工具版本、输入参数和源码 SHA-256 在各运行目录 manifest.json/日志中。算术测试的 NaN 用例核验类别，非 NaN 结果逐位比较；端到端合法数据的全部输出均有限且逐位比较。

两种仿真器运行相同的 81 组输入（17 个定向 + 64 个随机），另做 13 次复位后完整恢复任务，共 94 帧。每个运行包含 14 次复位、41,643 个输入气泡周期、7,939 个输出受阻周期；覆盖顶层全部 8 个状态和 Softmax 的 5 个活动状态，包括非空累加器、正在运行的除法和输出背压。无需任务间复位的连续帧也已验证。

- 最大单帧 RMSE：**0.0018142782905053649**，课程门限 0.06。
- 最大逐元素绝对误差：**0.008003024305335948**，课程门限 0.20。
- 两个仿真器的 input.hex、expected.hex、actual.txt、per_frame.csv 完全相同。
- 全零帧无停顿为 **4,990 周期**（首个输入握手到末个输出握手，含首尾）。除法延迟随数据而变，不能把这个数推广为所有帧的固定时延。
- 每轮矩阵乘为 46 个阵列推进周期；该数不包含装载、清零、Softmax 和输出。

指数表全部 19,542 项使用 Decimal 80/110 位生成结果交叉检查，并独立与 Python math.exp 后舍入到 binary16 的结果核对。float64 数学参考直接执行稳定 Softmax，不使用指数 ROM或内部 FP16 舍入。

## 版本与证据边界

仿真开始时本项目尚无 Git 提交；早期 manifest 的 `git_commit: HEAD` 来自 `git rev-parse HEAD` 在空仓库中的输出，并不是有效提交。记录器现已改为 `--verify` 并明确标记 `UNCOMMITTED`。发布代码的 RTL、ROM、模型、测试平台和第三方数值源码与最终仿真摘要一致，详见 release_audit。运行后仅更新了记录器元数据、lint/单元运行入口、包标记和文档，不改变已验证的 DUT 或数值模型。

原始 cases.json、input.hex、expected.hex、actual.txt、simulation.log、summary.json 和逐帧 CSV 均保留。二进制、编译缓存、大型波形不提交；克隆后重新运行命令生成这些可再生文件。

## 联调历史

- bringup_iverilog：编译失败，初始 files.f 尚未加入顶层。已补齐，不是 DUT 数值失败。
- arithmetic_iverilog：编译失败，TB VECTORS 参数尚未加入。已补齐。
- bringup_iverilog_02：32 帧通过，随后增强计算中途复位覆盖。
- release_verilator_seed20261117：62 帧通过；随后显式加宽 P 缓存地址表达式以消除 lint 警告，并完成以上最终回归。
- checker_negative：早期 62 帧版本验证器的负向自检通过，发布引用 final_checker_negative。
- lint_initial：保留未过滤告警；lint_release 的白名单仅覆盖上游代码风格及明确的时间单位/模块文件名/未使用符号位。

未删除上述历史证据。

发布检查：仓库已创建为 `lllolaa330/Mini_Attention`（私有），首次实现提交 `34559ae87ed8d4639dcc17d0e723d62e25c99ec3` 已推送 main。干净 Git 导出后软件模型重新构建通过 5 个测试。首次导出审计发现通用 `build/` 忽略规则排除了上游 HardFloat 测试构建配置（不影响 DUT）；将规则限定为根目录 `/build/` 并补齐五个配置文件后，干净导出源码审计通过。记录见 results/export_check，数值源码没有变化。

## 尚未验证

FPGA/ASIC 综合、布局布线、STA、实际频率、面积、DSP/BRAM 映射、功耗、板级运行、门级仿真及形式化等价均未执行。这里的 PASS 指对应仿真/源码检查范围。尤其不能把组合 FMA 每拍执行的仿真行为等同于在 100 MHz 或其他频率闭合时序。
