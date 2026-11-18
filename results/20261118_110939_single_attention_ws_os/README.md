# 单次完整 Attention：WS / OS 波形

2026-11-18，Asia/Shanghai。两模式使用相同的 `random_uniform_001` 输入，来自 `make_cases(seed=20261117, random_count=2)`；Q/K/V 各 16×16，元素为 [-2,2] 内 FP16 正负数。输入归档为 `single_input.json`。

| 模式 | VCD | 完整帧 / 输出 | 端到端仿真周期 | done 次数 | 文件大小 |
|---|---|---|---:|---:|---:|
| WS | [ws/attention.vcd](ws/attention.vcd) | 1 / 256 | 1171 | 1 | 179,568 byte |
| OS | [os/attention.vcd](os/attention.vcd) | 1 / 256 | 1137 | 1 | 174,362 byte |

每份波形只包含一次启动复位、一次完整 `QKᵀ → Softmax → PV → 输出` 和结束后 20 拍空闲观察。无输入气泡、无输出背压、无中途复位或恢复帧。时钟周期 10 ns；上述周期包含首个输入握手至最后一个输出握手，不是已闭合硬件时序。

两模式各 256 字均与 SoftFloat 模型逐位匹配，并且两模式输出完全相同。相对独立 float64 数学参考，RMSE 为 0.000668248795，最大绝对误差为 0.00249899501，均通过课程门限。ROM 检查、7 项现有模型单测通过。这里的单帧模式不构成新的完整协议覆盖回归。

## 波形导航

建议先看 `tb_attention.dut.state`、`feed_step` 及顶层 `clk/rst_n/busy/done/in_valid/in_ready/out_valid/out_ready/out_last/out_data`。展开 `tb_attention.dut.array_impl.array_core.rows[0].cols[0].pe`：WS 看 `weight/a_in/psum_in/psum_out/psum_valid_out`；OS 看 `a_in/b_in/acc`。另记录 PE[0,1]、PE[1,0]、PE[15,15] 和第 0 行 Softmax。数据信号按 FP16 解读；此 VCD 为紧凑层次，不递归展开 HardFloat 内部组合节点。

从约 **7.7 µs** 开始观察阵列，前段为 768 字输入。以下为 `state` 更新的时刻（µs）：

| 阶段 | WS | OS |
|---|---:|---:|
| 清 QK 阵列 | 7.705 | 7.705 |
| 装 Kᵀ 权重 | 7.715 | — |
| QKᵀ 计算 | 7.875 | 7.715 |
| Softmax 启动 | 8.345 | 8.175 |
| 清 PV 阵列 | 8.535 | 8.365 |
| 装 V 权重 | 8.545 | — |
| PV 计算 | 8.705 | 8.375 |
| 开始输出 | 9.175 | 8.835 |
| 最后输出接受，done 拉高 | 11.735 | 11.395 |

状态编码：LOAD=0、CLEAR_QK=1、RUN_QK=2、SM_START=3、SM_WAIT=4、CLEAR_PV=5、RUN_PV=6、EMIT=7、LOAD_W_QK=8、LOAD_W_PV=9。

## 复现

从 Mini_Attention 根目录执行，使用新的输出目录：

```sh
python3 scripts/run.py --sim iverilog --dataflow ws --vectors results/20261118_110939_single_attention_ws_os/single_input.json --single-frame --stalls 0 --waves --seed 20261117 --outdir results/my_new_single_ws --timeout 600
python3 scripts/run.py --sim iverilog --dataflow os --vectors results/20261118_110939_single_attention_ws_os/single_input.json --single-frame --stalls 0 --waves --seed 20261117 --outdir results/my_new_single_os --timeout 600
```

直接复核两份已生成的 VCD（计数输入/输出握手、done、复位及阶段顺序；比对两模式输入和输出）：

```sh
python3 results/20261118_110939_single_attention_ws_os/inspect_waves.py
```

工具与源码：Icarus Verilog version 12.0 (stable) ()；Python 3.9.6。Git HEAD 为 `726ae6fe6bb6732fa06e6eabf4291005a56e2d7e`，运行基于未提交工作区。各模式 `manifest.json` 保存精确命令、参数、工具版本、源码摘要和 Git 状态；`source_snapshot.tar.gz` 保存运行时源码，`source.diff` 保存当时工作区差异。两模式的全部源码摘要一致，已逐项核对与源码快照和运行后工作区一致。RTL 与数值模型本轮未修改；仅增加脚本/测试平台的可选单帧入口及使用记录。VCD 检查证据和 SHA-256 见 `wave_inspection.json`。未提交或推送。
