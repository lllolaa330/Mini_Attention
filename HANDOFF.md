# 当前交接

更新于 2026-11-18，Asia/Shanghai。

## Stream OS 阵列内指数的 PE 设计图

按 SCOPE 图 9 的格式建立 [OS 三种 PE 电路图](docs/os_scna_pe/os_scope_pe.svg)，现已实现为 [16×16 OS-SCOPE](rtl/os_scope_attention_fp16.sv)。每个 score 的指数只算一次。顶层实测 PV 在 t=120 启动，稳态 II=52，冷启动首/末输出为 169/199 拍。复现用 `make os-scope`、`make os-scope SIM=verilator`、`make os-scope-lint`、`make scope-compare`。波形展开 `dut`，看 `step`、`launch`、`qk_diag_valid`、`exp_diag_valid`、`pv_diag_valid`、`norm_valid` 以及输出握手；某一对角线 d 的实际乘加在 `step && mask[d]` 时推进。SCOPE 与 OS-SCOPE 工作保存在 `SCOPE` 分支，频率及能效待测。[四版简报](docs/SCOPE_Attention_实验简报.pdf) · [原始结果及验证范围](EXPERIMENTS.md) · [排程与缓存](docs/os_scna_pe/schedule.md)

## SCOPE Attention

新增独立的 `scope_attention_fp16` 顶层与三个 PE 文件，原 Stream 顶层可继续用 `make quick` 重放。新顶层运行 `make scope`，用 `STRIPS=1` 切到三种 PE 共存的单条带；`make scope-compare` 目前同时覆盖 OS-SCOPE。当前匹配输入的无停顿测量为基线 5117.83、Stream 52、SCOPE 双条带 139 拍/帧。能效及上板频率待测。本轮代码及数值结果收录在 `SCOPE` 分支。[一页报告](docs/SCOPE_Attention_实验简报.pdf) · [数值及数据流](PROJECT.md#scope-attention) · [实测记录](EXPERIMENTS.md) · [源码摘要与复现参数](results/scope_report_final_20261118/scope/manifest.json)

## 当前的全 OS、整行归一化实现

顶层 `attention_fp16` 用一块 16×16 OS 阵列计算 QKᵀ 和 PV。两个帧槽共用 256 位输入口，每次握手写入一整行 Q、一整行 K 或一整列 V。每帧依序接收 16 行 Q、16 行 K 和 16 列 V，共 48 拍。接收 K 最后一行后，该帧具备启动 QKᵀ 的条件。在线 Softmax 的 16 路 exp/div 每拍可接一行，P 按 k 从左侧送回阵列。输出按对角线分 31 组握手。[数据与握手契约](PROJECT.md)

顶层支持相邻帧在同一阵列上重叠。旧帧 PV 第 16 步起允许新帧 QK 发车，第 30 步完成最后一次 P/V 边界注入后归还输入槽。无停顿的 6 帧波形显示每次相邻 QK、PV 和首末输出的间隔均为 52 拍；初始第一帧在第 85/115 拍接受首/末结果。两波共同停顿以保护阵列链路和尚未缓存的输出。[前后 timeline](results/frame52_top_20261118_9myellui/full_match/timeline.png) · [回归与证据](EXPERIMENTS.md)

运行 `make quick`、`make test`、`make test SIM=verilator` 或 `make lint`。在 Surfer 打开[新版六帧 VCD](results/frame52_top_20261118_9myellui/top_ready/attention.vcd)，添加 `dut.qk_step`、`qk_age`、`qk_bank`、`pv_step`、`feed_step`、`pv_bank` 和 `out_valid`。在上升沿前观察两个 step 同为 1 且 bank 不同的区间；两帧任务分别在不同对角线上执行。信号 `release_input` 表示输入槽已完成最后一次读取，`out_last && out_valid && out_ready` 为该帧最后一组输出握手。

此前仅 V 改为整列、Q/K 仍为标量的版本，每帧输入 528 拍。其 PV 空闲和 256 个位置的 PE 利用率比较保存在[V 列输入实验](results/v_column16_20261118_ioj9y7/matched/comparison.json)。更早的 OS/WS 双模式测量见[历史时间线](results/v_overlap_20261118_120306/figures/README.md)。

## 历史标量接口的单帧波形（2026-11-18）

已用同一组正负随机 FP16 输入各跑一次完整 WS 与 OS Attention，无输入气泡、无输出背压、无中途复位。各 256 字逐位自检及精度检查通过，VCD 内各只有一次 done；WS 1171 拍，OS 1137 拍。波形路径：`results/20261118_110939_single_attention_ws_os/{ws,os}/attention.vcd`。阶段时间、复现命令与证据见该目录 README.md；从约 7.7 µs 开始看阵列。

新增 `--single-frame` 仅运行输入列表第一帧，常规回归默认仍保留全部复位恢复测试。未指定 `--vectors` 时第一帧是全零；要复现本次有变化的波形，使用该目录 `single_input.json` 并加 `--stalls 0 --waves`。源码快照与 VCD 计数检查已归档；此轮未重跑完整协议回归。修改尚未提交或推送。

当时的标量接口版本可用 `attention_fp16.USE_WS` 在展开时选择 OS（默认）或 WS，两个模式共用 16 行并行 Softmax 和软件模型。`make quick` 跑 OS，`make quick DATAFLOW=ws` 跑 WS。查看 WS 波形可加 `ARGS=--waves`，在 `dut.array_impl.array_core.rows[0].cols[0].pe` 观察 `weight`、`a_in`、`psum_out` 和 `psum_valid_out`。

## 早期实现记录

- 每种配置使用 16×16、256 个 FP16 FMA PE，复用计算 QKᵀ 和 PV。OS 在 PE 内累加。WS 第一轮装 Kᵀ，第二轮装 V，部分和逐级向下传。
- 全 FP16 稳定 Softmax、指数 ROM、迭代浮点除法、FP16 概率缓存和 ready/valid 输入输出。
- Berkeley SoftFloat 逐位模型、独立 float64 数学参考、单命令自检仿真、算术/阵列/协议/复位/负向验证器测试。
- 旧串行版本的 Icarus 和 Verilator 各通过 94 帧、24,064 个输出；位模式、误差和逐帧周期一致。并行版本的运行记录见 EXPERIMENTS.md 的 11 月 18 日条目。
- 依赖随仓库分发，许可证和兼容性修改见 THIRD_PARTY.md；未混入旧定点设计、课程 PDF、凭据或编译缓存。

## 使用入口

`make quick` / `make test` / `make test SIM=verilator`。`make arithmetic`、`make array`、`make lint` 分别执行算术、阵列和静态检查。每次保存独立 results 目录。完整数值契约在 PROJECT.md，复用协议/验证边界在 docs/verification.md。

## 后续

本次新 RTL、验证脚本和运行记录均在本地工作区，尚未提交或推送。全 OS 实现的面积、时序和功耗待验证。

已发布到 [lllolaa330/Mini_Attention](https://github.com/lllolaa330/Mini_Attention)，main 分支，私有仓库；初次实现提交 `34559ae87ed8d4639dcc17d0e723d62e25c99ec3`。随后补齐上游测试构建配置归档，实际最新提交以 Git remote/HEAD 为准。

干净 Git 导出包的源码摘要审计已通过，软件模型可从导出文件重新编译并通过 5 个测试；证据见 results/export_check。上传不包含本地构建缓存。
