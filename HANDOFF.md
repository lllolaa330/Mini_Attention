# 当前交接

更新于 2026-11-18，Asia/Shanghai。

## 当前的流式 Attention

[OS/WS 流水时间线](results/stream_timeline_20261118/mini_attention_timeline.pdf) 展示当前无背压首帧的两处重叠。逐阶段拍号及两份原始 VCD 路径见[时间线数据](results/stream_timeline_20261118/timeline.json)。

输入端的两个 Q/K/V 帧槽独立于计算状态机。最后一个 K 字到达后即开始 QKᵀ，V 和 P 同帧就绪后执行 PV。输出端的 `out_data[255:0]` 按列切成 16 个 FP16，`out_lane_valid[j]` 标记有效列；每帧接受 31 组，最后一组握手后发出 done。运行入口仍是 `make test` 和 `make test DATAFLOW=ws`，可加 `ARGS=--waves`。观察输入与计算重叠可添加 `load_count`、`write_bank`、`compute_bank` 和 `state`。观察背压可添加 `out_valid`、`out_ready`、`out_lane_valid`、`skid_valid`、`feed_step` 和 `done`。

Icarus 带背压验证通过 OS 45 帧和 WS 47 帧，含两槽均满时的复位恢复。连续供数、下游就绪时，两种配置的输入帧间隔均为 768 拍，整帧延迟分别为 816 和 833 拍。完整对比和复现命令见 [新旧接口同输入测量](results/pingpong_baseline_20261118_112657/README.md)。实际验证与未验证边界见 [实验记录](EXPERIMENTS.md)；本轮修改在本地工作区。

## 历史标量接口的单帧波形（2026-11-18）

已用同一组正负随机 FP16 输入各跑一次完整 WS 与 OS Attention，无输入气泡、无输出背压、无中途复位。各 256 字逐位自检及精度检查通过，VCD 内各只有一次 done；WS 1171 拍，OS 1137 拍。波形路径：`results/20261118_110939_single_attention_ws_os/{ws,os}/attention.vcd`。阶段时间、复现命令与证据见该目录 README.md；从约 7.7 µs 开始看阵列。

新增 `--single-frame` 仅运行输入列表第一帧，常规回归默认仍保留全部复位恢复测试。未指定 `--vectors` 时第一帧是全零；要复现本次有变化的波形，使用该目录 `single_input.json` 并加 `--stalls 0 --waves`。源码快照与 VCD 计数检查已归档；此轮未重跑完整协议回归。修改尚未提交或推送。

本地工作区可用 `attention_fp16.USE_WS` 在展开时选择 OS（默认）或 WS，两个模式共用 16 行并行 Softmax 和软件模型。`make quick` 跑 OS，`make quick DATAFLOW=ws` 跑 WS。查看 WS 波形可加 `ARGS=--waves`，在 `dut.array_impl.array_core.rows[0].cols[0].pe` 观察 `weight`、`a_in`、`psum_out` 和 `psum_valid_out`。

## 已完成

- 每种配置使用 16×16、256 个 FP16 FMA PE，复用计算 QKᵀ 和 PV。OS 在 PE 内累加。WS 第一轮装 Kᵀ，第二轮装 V，部分和逐级向下传。
- 全 FP16 稳定 Softmax、指数 ROM、迭代浮点除法、FP16 概率缓存和 ready/valid 输入输出。
- Berkeley SoftFloat 逐位模型、独立 float64 数学参考、单命令自检仿真、算术/阵列/协议/复位/负向验证器测试。
- 旧串行版本的 Icarus 和 Verilator 各通过 94 帧、24,064 个输出；位模式、误差和逐帧周期一致。并行版本的运行记录见 EXPERIMENTS.md 的 11 月 18 日条目。
- 依赖随仓库分发，许可证和兼容性修改见 THIRD_PARTY.md；未混入旧定点设计、课程 PDF、凭据或编译缓存。

## 使用入口

`make quick` / `make test` / `make test SIM=verilator`。`make arithmetic`、`make array`、`make lint` 分别执行算术、阵列和静态检查。每次保存独立 results 目录。完整数值契约在 PROJECT.md，复用协议/验证边界在 docs/verification.md。

所有边界数值为 binary16，FMA 每次按 RNE 单次舍入，支持次正规数。每轮 OS 运行 46 拍，WS 先装权 16 拍再运行 47 拍（含写回）。每行 Softmax 用四层 FP16 加法树求分母，再将 16 路归一化结果存为 FP16 P。收齐全部行后，顶层复用同一个阵列执行 PV。

## 后续

本轮修复在本地工作区，尚未提交或推送。并行版本的综合、时序和功耗待验证。

已发布到 [lllolaa330/Mini_Attention](https://github.com/lllolaa330/Mini_Attention)，main 分支，私有仓库；初次实现提交 `34559ae87ed8d4639dcc17d0e723d62e25c99ec3`。随后补齐上游测试构建配置归档，实际最新提交以 Git remote/HEAD 为准。

干净 Git 导出包的源码摘要审计已通过，软件模型可从导出文件重新编译并通过 5 个测试；证据见 results/export_check。上传不包含本地构建缓存。
