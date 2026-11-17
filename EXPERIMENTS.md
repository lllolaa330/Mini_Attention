# 验证记录

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
