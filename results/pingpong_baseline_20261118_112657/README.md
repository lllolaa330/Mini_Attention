# 连续帧吞吐比较：封存原版与 ping-pong 版

封存日期：2026-11-18，Asia/Shanghai。原版顶层 SHA-256：
`3e6e29ae198159ee4c374b3e7f77f98c5ea5900b0a61b888ed6b59e8d359d354`。

`rtl_snapshot/` 保存修改前的完整自有 RTL/ROM；`model_snapshot/` 保存当时软件模型。HardFloat 仍使用仓库内同一份第三方源码，运行原版时会逐文件核对 `snapshot.json` 中的摘要。不会把修改后的顶层冒充原版重新测量。

`fixtures.json` 固定 17 个定向 + 8 个随机帧（seed=20261117）。原版和新版本共用 `input.hex`、`expected.hex`，新版本运行时也校验输入摘要。`cases.json` 保存完整输入、软件逐位期望和独立 float64 数学参考。

原版使用 `tb_stream.sv`，新版本使用 `tb_stream_wide.sv` 的输出适配；两者仅依赖顶层 ready/valid 接口，不引用内部状态。输入源每拍保持 valid，直到 25 帧的全部 19,200 字接受；遇到背压保持当前数据，不插入源气泡。输出 ready 恒为 1，逐字比较 6,400 个输出，检查 out_last、有限值、done 数量及最终空闲。首帧后不复位。新输出适配按每拍对角线验证 lane mask、映射到 Y[row,col] 逐位核验，最终将 actual.hex 重排为行优先。

比较包含两种架构变化：ping-pong/计算调度重叠，以及从 16-bit 逐元素输出变为 256-bit、带 lane-valid 的对角线输出。即使输出 sink 均始终 ready，也不能把时延/II 的全部改善单独归因于 ping-pong。

每帧 `timing.csv` 字段均按实际上升沿握手记录：

- first_input / last_input：首/末输入字被接受的周期。
- first_output / last_output：首/末输出字被接受的周期。
- latency：last_output − first_input + 1，包含首尾。
- input_ii：本帧 first_input − 上帧 first_input；首帧写 0。

`summary.json` 同时给出输入 II 与首输出 II。平均有用 FMA 占用按 `8192 / (256 × 平均输入II)` 计算，仅计两次 GEMM 的数学必需 FMA，不把灌入/排空、无效槽或 Softmax 算术计为有用阵列 FMA。这是周期模型中的占用，不是综合后的频率、面积或能耗。

在工程根目录复现，`--outdir` 必须新建：

```sh
python3 results/pingpong_baseline_20261118_112657/measure.py \
  --variant baseline --dataflow os --outdir results/my_old_os
python3 results/pingpong_baseline_20261118_112657/measure.py \
  --variant baseline --dataflow ws --outdir results/my_old_ws
python3 results/pingpong_baseline_20261118_112657/measure.py \
  --variant current --dataflow os --outdir results/my_new_os
python3 results/pingpong_baseline_20261118_112657/measure.py \
  --variant current --dataflow ws --outdir results/my_new_ws
```

每次保存源文件摘要、编译命令、仿真器版本、原始日志、实际输出和逐帧周期。`baseline_os` / `baseline_ws` 是首轮工具命令参数顺序错误留下的失败证据；`baseline_os_02` / `baseline_ws_02` 是修正命令后的原版测量入口。原始失败文件保留。

## 实测比较（同一 25 帧）

| 版本 | 数据流 | 首输入至末输出（周期，含首尾） | 平均输入 II（周期） | 平均有用 FMA 占用 |
|---|---|---:|---:|---:|
| 原版 | OS | 1136–1137 | 1136.458333 | 2.8158% |
| 原版 | WS | 1170–1171 | 1170.458333 | 2.7340% |
| 新版 | OS | 816 | 768 | 4.1667% |
| 新版 | WS | 833 | 768 | 4.1667% |

四个运行各有 6,400 个输出全部逐位匹配；重排行优先后的 actual.hex 与共同 expected.hex 的 SHA-256 均为 `e2f69d7dc3db9e12c8fa14e135569ac2c32b91596cb18dee346790b573d3f80d`。新版本每个输入 II 和首输出 II 都为 768，不只是平均数等于 768。以平均输入 II 的倒数衡量，OS 吞吐率提高 1.47976 倍，WS 提高 1.52403 倍。结果仅对应无输入源气泡、输出无背压的连续帧测量。

最终证据是 baseline_os_02、baseline_ws_02、current_os_02、current_ws_02。运行 `python3 results/pingpong_baseline_20261118_112657/compare.py` 会重新验证四组输入/输出摘要并生成 comparison.json。当前新 RTL 的所有编译源摘要已与两份 current manifest 逐项核对一致；各 current 目录额外保存编译时的 compiled_attention_fp16.sv。

current_os / current_ws 为 Icarus 对二维银行动态寻址触发内部断言的失败记录。顶层改为扁平 9-bit 银行地址后，current_os_02 / current_ws_02 编译和仿真通过。失败记录未覆盖。
