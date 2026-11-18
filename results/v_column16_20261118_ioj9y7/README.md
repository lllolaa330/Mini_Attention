# V 按整列输入的同条件波形测量

比较同一个全 FP16、256 PE OS Attention 的两版输入通路。修改前每次输入握手送一个行优先 V 字；修改后每次送一列的 16 个 FP16。两版都先从低 16 位收 256 个 Q 字与 256 个 K 字。V 列号 j 由握手次序确定，位段 `16*k +: 16` 载入 V[k,j]。本目录的 before、after RTL 按各自 files.f 独立展开，复用仓库内 Berkeley HardFloat。

## 激励和验证

题设矩阵、SoftFloat 行概率、期望输出和指数表取自同一个非零单帧 `random_uniform_001`。输入端持续 valid，初始复位后只发送这一帧。每个配置 31 组输出，逐列检查掩码、out_last 以及全部 256 个 Y 和归一化产生的 256 个 P；另检查受阻的整组数据始终稳定。ready 测量始终允许输出。backpressure 测量使第 5 号输出组（从 0 起）在 out_valid 为 1 时连续等待 12 拍。事件对齐到同一组结果，所以两版都会实遇 12 拍背压。每次仿真独立计数并断言以上次数。命令和各源文件 SHA 在两份 manifest 中。

## 计数口径与数据

PV 窗口取该帧第一个到最后一个 `pv_step`，首尾均包含。有效推进一直都是 46 拍，最后一个物理 PV 乘加的拍号必须与最后一次推进相同。比较脚本在每个时钟上升沿之前读取掩码 `pe_mac[16*i+j]`，并将每个 PE 的前 16 次有效乘加归为 QK、后 16 次归为 PV；各坐标必须恰执行 32 次。计算窗口从第一个 QK MAC 到最后一个 PV MAC；端到端窗口为首输入到末输出握手。三个窗口各自的 PE 利用率分别是 16/PV跨度、32/计算跨度和32/端到端跨度。本次四种波形的 PV 窗口中，所需 P 行均已准备好。V 缺失和输出缓冲占满的等待互斥。12 拍外部输出受阻中，旁路缓冲让阵列额外推进 1 拍，因此 PV 窗口中只有 11 拍等待输出空间。比较针对确定性单帧，不测实际频率、面积或功耗。

| 模式 | PV 有效 / 空闲 | 其中缺 V / 输出无空间 | 计算跨度 / 利用率 | 首/末组输出（从首输入） |
|---|---:|---:|---:|---:|
| 旧版，下游 ready | 46 / 189 | 189 / 0 | 271 / 11.81% | 755 / 785 |
| 新版，下游 ready | 46 / 0 | 0 / 0 | 82 / 39.02% | 566 / 596 |
| 旧版，背压 12 拍 | 46 / 200 | 189 / 11 | 282 / 11.35% | 755 / 797 |
| 新版，背压 12 拍 | 46 / 11 | 0 / 11 | 93 / 34.41% | 566 / 608 |

[波形图 PNG](figures/pv_waveforms.png) · [矢量 PDF](figures/pv_waveforms.pdf) · [四组结果](matched/comparison.json) · [逐 PE 数据](matched/per_pe.csv) · [逐拍数据](matched/cycles.csv)

原始 VCD 在 `matched/{before,after}/{ready,backpressure}/attention.vcd`，由 Icarus 在本地生成。图 A 从首个 PV 有效步计，图 B 从首个 QK MAC 计，两张图均按实际物理时钟，空闲周期也计入横轴。图 B 中重合线段对应两个版本在该周期有相同数量的活跃 PE。

## 复现

在本目录运行以下命令，将两版的新结果写入尚不存在的输出目录。每版只编译一次。绘图脚本读取默认 matched 下的 cycles.csv、comparison.json，以 Matplotlib 导出 350 dpi PNG 及矢量 SVG/PDF。

```sh
python3 benchmark.py --version before --out-root repeat_1
python3 benchmark.py --version after --out-root repeat_1
python3 compare.py --root repeat_1
python3 plot_waveforms.py
```
