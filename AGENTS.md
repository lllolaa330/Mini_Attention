# Mini_Attention 工作约定

- 本项目实现 `Y = Softmax(QKᵀ/4)V`，Q/K/V/Y 均为 16×16，按行 Softmax；采用 16×16 个 FP16 PE 的 Output Stationary 脉动阵列。
- 开始修改前读取 README.md、PROJECT.md、EXPERIMENTS.md、HANDOFF.md 并检查 Git 状态。项目目标和位精确运算顺序以 PROJECT.md 为准。
- 所有矩阵数据、PE 累加器、Softmax 算术边界为 IEEE binary16；RNE 舍入，保留次正规数。不得未经记录改为 FP32 累加、FTZ 或定点数据通路。
- RTL 必须可综合，不得使用 real、shortreal、DPI、仿真数学函数或延时。离线 ROM 生成器和 testbench 不受 RTL 算术限制。
- 数值行为修改必须同步更新位精确软件模型，独立 float64 参考保持数学定义。FMA 与拆开的乘法/加法具有不同舍入语义，不得静默替换。
- 逐位比较必须通过，同时每帧 RMSE ≤ 0.06、每元素绝对误差 ≤ 0.20，输出必须有限。必须覆盖复位恢复、气泡、输出背压、连续帧和超时。
- 每轮实验保存在唯一 results 子目录，记录输入、工具版本、源码摘要、执行命令和原始输出；保留失败证据，不覆盖已有结果。不把编译缓存和大型波形提交到 Git。
- 收尾更新 EXPERIMENTS.md 和 HANDOFF.md，说明实际验证范围。未经综合、STA、功耗分析，不得把逻辑步数或 testbench 时钟称为硬件性能。
- 第三方代码保留原许可证；来源和版本见 THIRD_PARTY.md。本项目为自建课程 baseline，不是课程官方参考实现。
