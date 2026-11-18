# 接收 V 与 PV 重叠：实测时间线

本目录只读取本次归档中的逐拍调度，不重新运行 RTL 仿真。绘图规范采用 `/Users/jiaojiayi/Documents/ChatGPT/00科研绘图规范_跨项目版.md`，版本 2.0，2026-11-01；阶段配色固定，白底、无纹理，英文标签使用 DejaVu Sans。

## 图与口径

- `timeline_resident.{png,pdf,svg}`：Q/K/V 已预填片上存储，`CLEAR_QK` 的上升沿为第 1 拍。四组为 OS / WS 的修改前后。第 0 帧为 `all_zero`：OS 输出区间均为 83–113，WS 从 117–147 提前为 101–131。新版 WS 的 V 行写入在 65–80 拍，与包含启动拍的 Softmax（65–82）重叠。
- `timeline_stream.{png,pdf,svg}`：每拍输入一个 FP16，输出持续 ready；第一个 Q0 字的输入握手为第 1 拍。上部给出 Q0/K0/V0/Q1 与计算总览，下部放大 510–840 拍。OS 输出从 786–816 提前至 755–785；WS 从 803–833 提前至 772–802。四个基准用例的输入 II 都维持 768 拍。

两图展示同一选择规则：逐拍文件中完整记录的第 0 帧 `all_zero`。区间端点均计入周期数，记录为上升沿前信号；条形的每个整数拍对应一个实测动作。其他三个 resident 用例的 Softmax 多 1 拍，不应把本图的零输入延迟当作所有输入的固定延迟。

紫色仅覆盖 `RUN_PV && array_step` 的有效启用拍；灰色为原版 `WAIT_V` 或新版 `RUN_PV && !array_step` 的等 V 停顿。新版 OS 为 46 个有效步、160 个等待拍，新版 WS 为 47 个有效步、159 个等待拍。WS 的 47 步含底部结果写回，不能理解成全阵列每拍都有 256 次有效 FMA。金色来自真实 `ws_shift_qk` / `ws_shift_v` / `ws_row_load`，新版 WS 行号由 `ws_load_row` 读出。流式新版 WS 前 5 行在 Softmax 期间写入；第 15 行在第 769 拍写入。

输出线两端是首/末组成功握手，共 31 组、256 个 FP16 字。流式总览的输入带取最长首帧记录 `before_ws/stream/schedule.csv`，Q1 只显示已经记录的 769–833 拍；其他三份记录到各自末输出为止，均验证连续供数。所有图均为仿真周期，不代表已测频率、面积或功耗。

## 重放

从任意目录执行：

```sh
/Users/jiaojiayi/miniconda3/bin/python3 \
  /Users/jiaojiayi/Documents/ChatGPT/Mini_Attention/results/v_overlap_20261118_120306/figures/plot_timelines.py
```

脚本读入 `../benchmarks/{before,after}_{os,ws}/{resident,stream}/schedule.csv`、相邻 `summary.json` 和 `../benchmarks/comparison.json`，自动检查逐拍连续性、PV 逻辑步顺序、启用步数、31 次输出握手/256 个字以及首末输出周期与汇总一致。只有通过后才生成两张图及 `plotted_data.json`、`figure_manifest.json`。

PNG 为 350 dpi（片上 5880×3080、流式 5880×4340）；PDF/SVG 保留文字与几何图元，未将整图嵌入位图。`figure_manifest.json` 保存源文件 SHA256、绘图环境及导出文件 SHA256。`plotted_data.json` 保存实际绘制的区间、行写入时间和有效逻辑步。PDF 渲染预览与检查结论见 `qa/`、`visual_check.json`。
