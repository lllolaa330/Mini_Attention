# 52 拍跨帧排程的公开端口实测

两次运行都从一个 256 位输入口连续发送同一批 6 帧非零 FP16 数据，输出持续 ready。旧版原始 VCD 来自 [6 帧基线](../cross_frame_wave_20261118_bdk_rkfs/sim/attention.vcd)。新版用独立测试平台运行全套顶层 RTL，输入、两套金标和指数表与旧版逐字节相同。夹具检查每个 P、每个 Y、每条输出掩码与帧尾；脚本另从两份 VCD 独立核对 4,608 个输入字、1,536 个输出字、96 个 P 行返回握手，以及所有物理 PE 的活动。命令和源码摘要见 [清单](top_ready/manifest.json)。

从每个 PE 在上升沿前的 step 及两个输入 valid 采样实际乘加，按每个坐标连续的 16 个 QK 项和 16 个 PV 项归帧。逐帧窗口、局部 PE 轨迹、帧间跨帧重叠、旧输出与下一点积的逐坐标交接均从 VCD 得到。图选取 6 帧的第 4、5 帧，对齐两版各自的 F3 首个 QK 乘加。[两帧时间线 PNG](full_match/timeline.png) · [PDF](full_match/timeline.pdf) · [SVG](full_match/timeline.svg) · [逐帧数据](full_match/comparison.json) · [新顶层 VCD](top_ready/attention.vcd)

| 项目 | 优化前 | 优化后 |
|---|---:|---:|
| 首帧由首输入到首／末组输出（含首拍） | 86／116 | 85／115 |
| 相邻 QK、PV、首／末输出间隔（5 对） | 全部 85 | 全部 52 |
| 相邻首输入握手间隔 | 48、68、85、85、85 | 48、51、52、52、52 |
| 每次跨帧同时执行前帧 PV 与后帧 QK 的拍数 | 0 | 30 |
| 旧 Y 握手至同坐标下一帧首个 QK 乘加的时差 | 所有位置 33 拍 | 所有位置 0 拍 |

输出组依照对角线传输。相同周期号表示旧 Y 在采样沿前被接收，同一 PE 在该沿执行下一点积首项。新版的 5 次交接、每次 256 个坐标都满足。稳态帧间隔以始终就绪接收端的周期计；随机背压由项目常规回归验证。

从本目录重放，输出目录使用新名字。

```sh
python3 run_trace.py replay_new
python3 compare_trace.py replay_new comparison_new --expected-ii 52
python3 draw_timeline.py comparison_new
```

本次新版编译输入顶层已封存于 [attention_fp16.sv](top_ready/attention_fp16.sv)。另外以同一小型夹具复演了旧版，复核得到与旧版原始波形相同的所有帧间整数拍数。[旧版夹具自检](driver_old/simulation.log)

为直接打到跨帧交接沿，额外让接收端在每一帧的对角线 0、15、30 上各拒收 23 拍。6 帧共 18 段、414 拍有效输出被暂停，其中两级输出缓存同时占满 285 拍；在这些拍检查了所有 PE 均停止有效乘加。阻塞期间总线载荷、通道掩码、帧尾均保持；1,536 个 P、1,536 个 Y 和 6 次 done 全部通过。重放使用 `python3 run_trace.py replay_holds --hold-output`。[实验日志](targeted_hold_b/simulation.log) · [背压波形](targeted_hold_b/attention.vcd)
