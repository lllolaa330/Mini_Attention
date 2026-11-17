# 当前交接

更新：2026-11-17，Asia/Shanghai。

## 已完成

- 新建独立 Mini_Attention 项目，16×16、256 个 FP16 FMA PE 的输出驻留阵列，复用计算 QKᵀ 和 PV。
- 全 FP16 稳定 Softmax、指数 ROM、迭代浮点除法、FP16 概率缓存和 ready/valid 输入输出。
- Berkeley SoftFloat 逐位模型、独立 float64 数学参考、单命令自检仿真、算术/阵列/协议/复位/负向验证器测试。
- 最终 Icarus 和 Verilator 各通过 94 帧、24,064 个输出；位模式、误差和逐帧周期一致。详细数值、命令和版本见 EXPERIMENTS.md。
- 依赖随仓库分发，许可证和兼容性修改见 THIRD_PARTY.md；未混入旧定点设计、课程 PDF、凭据或编译缓存。

## 使用入口

`make quick` / `make test` / `make test SIM=verilator`。`make arithmetic`、`make array`、`make lint` 分别执行算术、阵列和静态检查。每次保存独立 results 目录。完整数值契约在 PROJECT.md，复用协议/验证边界在 docs/verification.md。

所有边界数值 binary16，FMA 每次单舍入 RNE；支持次正规数。每轮阵列 46 步；当前组合 FMA 无内部流水，物理时序未经综合确认。Softmax 按行按列序累加，先将归一化结果存为 FP16 P，再执行 PV；改变累加或舍入次序必须更新逐位模型并重新验证。

## 后续

若要比较第二设计，先确定 FPGA 器件或 ASIC 工艺/库，再综合当前 baseline。浮点流水线、并行 Softmax、存储映射和精度变化都需要单独记录变量与同条件对比。当前没有已知功能仿真失败，没有尚在运行的验证任务。

GitHub 发布目标：`lllolaa330/Mini_Attention`，main 分支，私有仓库。实际上传和提交状态以 Git remote、HEAD 及远端分支为准。
