# Mac Performance Monitor Lite：源码分析与实现范围

分析日期：2026-10-15。基线：`bfbd512dd5e2e00b763f8b58e2986e3549885fd7`。

上游：<https://github.com/Zesty0wl/mac-performance-monitor>。
个人 fork：<https://github.com/JoernZheng/mac-performance-monitor-lite>。
工作分支：`codex/lite`。

状态：已完成 fork、模块分析和第一版纯后台改造，代码在本地 `codex/lite` 分支。
项目采用 Mac Performance Monitor Lite 名称，工作分支为 `codex/lite`。
以下第 1 至 6 节保留改造前的源码分析和初始建议；
最终范围以本节及第 7 节的用户决定为准。不是全仓逐行安全审计。

## 已确认的用户目标

- 主要在后台自动收集，之后再由用户和助手分析。
- 最初问题是过去七天的内存压力，尤其人在工作或明显有任务运行的时候。
- 偏好开源，希望基于现有代码删去不需要的功能并改造。
- 用户已选择纯后台加命令行、保留所有性能指标类别，并区分人在使用、后台繁忙、空闲。

## 1. 原项目的构建模块

来源：[上游基线 Package.swift](https://github.com/Zesty0wl/mac-performance-monitor/blob/bfbd512dd5e2e00b763f8b58e2986e3549885fd7/Package.swift)。数量是本次基线的源代码计数，不代表运行时开销。

| Target | 当前作用 | 裁剪含义 |
| --- | --- | --- |
| `CMacPerfMonitor` | 2 个 C/header 文件，326 行；暴露 libproc、Mach、sysctl 等底层接口 | 保留所需的内存、CPU、进程读取接口 |
| `MacPerfMonitorCore` | 138 个 Swift 文件，约 3.3 万行；采样、数据库、分析、查询、硬件和磁盘扫描等 | 可复用，但整个 Core 并不等于最小采集核心 |
| `MacPerfMonitor` | 160 个 Swift 文件，约 5.35 万行；窗口、菜单栏、图表、设置及常驻调度 | 后台版可以移除大部分；调度需先迁移 |
| `MacPerfMonitorIPC` | App 与 root helper 的 XPC 协议、连接、签名及 ANE 采样 | 无特权版可移除；代价是部分进程指标不可读 |
| `MacPerfMonitorHelper` | root LaunchDaemon 入口 | 基础整机内存统计不需要；不作为第一版默认依赖 |
| `macperfmonitor-cli` | 原始数据层探针、有限时长采集、磁盘扫描等诊断命令 | 可作提取入口参考，不应未经改造直接当生产常驻服务 |
| `mpm` | 只读历史查询、CSV/JSON 输出、MCP 服务 | 适合保留查询能力，解除其对完整 Ask/Explorer 的依赖 |

外部 Swift 包为 `GRDB.swift`。App 还链接 vendored Sparkle 自动更新框架。
Core 不依赖 SwiftUI，但仍包含 IOKit、Metal、CoreWLAN、DiskArbitration、Security 等依赖。
原完整 App 的构建及打包包含 App Intents、String Catalog 等步骤。
本机已检测到 Xcode 27 和 arm64 Swift 工具链，尚未执行基线构建。

## 2. 功能模块清单

| 功能 | 主要实现 | 实际能力与代价 | 第一版建议 |
| --- | --- | --- | --- |
| 系统内存与压力 | `System/SystemMemoryReader.swift`、`Sampling/Taxonomy*.swift`、`Sampling/SwapActivityTracker.swift` | 系统压力等级、压缩、wired、swap 用量、换入换出及读数有效性 | 保留，作为主数据 |
| 系统 CPU | `System/CPUReader.swift`、`Sampling/CPUMath.swift` | 总负载、核心类型、累计计数差分；可辅助识别后台繁忙 | 保留 |
| 进程 CPU/内存 | `System/ProcessReader.swift`、`Sampling/Sampler.swift`、`Models/ProcessSample.swift` | 枚举进程、footprint、RSS、CPU、PID 与启动时间；还包含 FD、签名、磁盘、GPU 等额外读取 | 保留所需字段，拆分昂贵和无关采样 |
| 进程分组与关联 | `Analysis/GroupFootprint.swift`、`Persistence/GroupHistory.swift`、App 的 `ProcessGroupStore` | 把主程序和 helpers 组合观察，避免只看到单个 Electron/Chrome 子进程 | 保留轻量的自动身份映射；自定义分组 UI 可后置 |
| 常驻采样调度 | `ViewModels/SamplerModel.swift` | 约 3443 行；调度、持久化、UI 消费者、历史缓存、告警、GPU demand 混在一起 | 提取独立 recorder；不能直接删除后期待 Core 自运行 |
| 历史数据库 | `Persistence/Database.swift`、`SampleStore.swift`、`Retention.swift` | SQLite WAL、变更门控写入、分钟/小时聚合、保留期与空间清理 | 保留思路，缩减 schema 并补充目标统计 |
| 历史查询与导出 | `Persistence/HistoryQuery.swift`、`SystemHistory.swift`、`ProcessHistory.swift`、`Agent/*`、`mpm` | 只读查询、覆盖范围、单位转换、CSV/JSON、MCP | 保留 SQL/JSON/CSV；MCP 可后置 |
| GPU / ANE / 功耗 / 温度 | `Sampling/GPUReader.swift`、`PowerReader.swift`、`SMCReader.swift`、`ANE*`、`System/GPUProcessReader.swift`、IPC | 本地 AI/图形任务可能有价值；部分使用私有接口，ANE 功耗需要 helper | 默认候选移除，待用户选择 |
| 磁盘与网络吞吐 | `System/DiskReader.swift`、`NetworkReader.swift`、`NetworkProcessReader.swift` | 整机吞吐相对便宜；逐进程网络会运行 `nettop`，原项目默认关闭 | 可选轻量附加项；逐进程网络不默认保留 |
| 磁盘空间扫描与清理 | `Core/DiskMap/*`、`DiskUsageView`、`DiskMapView` | 遍历文件树、空间图、快照比较、删除等 | 与本需求无直接关系，建议移除 |
| 网络诊断与扫描 | `System/NetworkScanner.swift`、`NetworkScanView` 等 | 网络设备/端口/服务及厂商信息等交互诊断 | 建议移除 |
| 电池与附件 | `System/BatteryReader.swift`、`AccessoryBatteryReader.swift`、`Analysis/BatteryRuntimeEstimator.swift`、`Persistence/BatteryHistory.swift` | 电池健康、续航、能耗、附件电量 | 建议移除完整功能；若需要评估记录器耗电，另做短期验证 |
| 硬件清单 | `Core/Hardware/*`、`HardwareView` | 设备树、系统配置、硬件报告 | 建议移除；仅保存 RAM、核心数、OS、boot/session 等解释数据所需元信息 |
| 自动诊断与通知 | `Core/Analysis/*`、`Alerts/*`、`Settings/AlertSettings.swift` | 内存增长、疑似泄漏、CPU、swap、温度、事件及通知 | 第一版仅采集事件和健康状态，不保留完整规则与通知系统 |
| 内置 AI 与自然语言解释 | `MacPerfMonitor/Ask/*`、`Core/Ask/*` | 本机模型、事实摘要、问答规划、App Intents | 建议移除；助手通过结构化数据分析即可 |
| Apple 应用活动历史 | `Persistence/KnowledgeActivityReader.swift`、`UsageTimelineStore.swift` | 可选读取 `knowledgeC.db`，需要 Full Disk Access；不等同已验证的前台使用记录 | 不作为工作时段识别的基础，建议移除 |
| 大窗口与图表 | `Views/*`、`Charts/*`、`ContentView.swift` | Dashboard、Processes、GPU、Energy、Network、Disk、Hardware、Explorer、Insights、Groups 共 10 个主 Tab | 纯后台版移除；极简状态 UI 单独决定 |
| 更新、内容下载、品牌与安装 | `UpdateController.swift`、`Catalog/*`、`Resources/Info.plist`、`Scripts/*` | Sparkle 更新、签名内容、原产品身份和 helper 注册 | 移除上游自动更新；自用版采用独立身份和独立数据目录 |

## 3. 当前调用链与可复用边界

```text
App 生命周期 / 设置
  -> SamplerModel：计时器、扫描队列、是否录制、UI 订阅、事件和维护
      -> Sampler.tickSystem
          -> 内存 / CPU / 电池 / 网络 / 磁盘 / 可选 GPU 与传感器
      -> Sampler.tickProcesses
          -> 全进程枚举 + CPU/内存 + FD/路径/签名 + GPU + 可选 helper/nettop
      -> SampleStore.insertChanged
          -> SQLite system_samples + processes + process_samples
      -> Retention
          -> minute/hour 聚合 + trim + checkpoint / vacuum 等维护

窗口与 Explorer / mpm / MCP
  -> 历史查询或只读 AgentStore
      -> 数据覆盖范围 + 统一单位的 SQL views
```

需要注意的耦合：

1. `SamplerModel` 的系统基准心跳由 `LiveRefreshCadence` 保持在 1 秒。
   把 UI 或原始写盘频率设置成 10 秒，不等于所有底层读取都只运行一次。
   原 App 还有为实时 UI 服务的 strict timer、较高 QoS 和 App Nap assertion。
   后台记录器应另行设计调度，并实测采样稳定性与耗电，不能照搬全部断言。
2. `Sampler.tickProcesses` 即使不打开 GPU 页面，也有逐进程 GPU registry pass。
   移除 GPU UI 不等于去掉 GPU 采集；FD、签名解析等也要按运行路径裁剪。
3. Core 的系统和进程模型、schema 已包含大量外围指标。
   把整个 Core 原样链接进一个新 executable 会保留这些依赖和数据库复杂度。
4. `mpm brief` 与 Ask 的摘要、分区模型有联系。
   可以删掉模型推理与 AI UI，同时保留只读 SQL；不能机械删除整个 Ask 目录后假设 `mpm` 原样可编译。
5. `macperfmonitor-cli sample` 默认采集 20 秒、写临时文件；支持无限时长和指定数据库，
   但主要是诊断 harness。它按固定 sleep 循环逐次写入，维护错误被 `try?` 忽略，
   仅注册 SIGINT，缺少正式服务的配置、健康状态、重启和生命周期契约。

## 4. 针对原始问题必须补齐的数据语义

### 原生压力等级与自定义指数分开

`SystemMemoryReader.pressureLevelReading` 读取内核的 1/2/4，分别映射为
normal/warning/critical。`PressureIndex.compute` 的 0 至 100 是应用自定义指数。
长期汇总当前主要存这个指数的 min/avg/max，不能从均值倒推出各等级的持续时间。
`PressureEvents.swift` 的事件查询还将窗口限制为最近 2 小时的原始数据。

精简版应以原生等级为主，保存各等级的覆盖秒数、未知秒数、有效采样数量及间隔。
如果保留自定义指数，名称应明确为自定义指数，避免与 Apple 官方指标混淆。
轮询能给出采样分辨率内的估计，不能声称知道两次采样之间的精确转换时刻。

### 工作、后台繁忙和空闲是新增分类

目前的进程运行历史表示“采集时观察到它存在”，并不表示用户正在工作。
可选的 Apple 活动历史也不能可靠替代本机当前的交互状态。

建议分别记录原始信号，再由查询层按可解释规则分类：

- 会话/屏幕锁定、睡眠唤醒、键鼠 idle 的时长等状态，不记录键盘内容。
- 系统 CPU 和可读进程活动，必要时加入可选 GPU；持续占用内存本身不足以证明任务正在计算。
- 只要用户同意，前台应用 bundle ID 可作为辅助信号；不能把它当作任务正在运行的充分条件。
- 可选人工 session marker，用于标记“编译”“浏览”“Codex 任务”等。

分类阈值应可配置。数据要允许重算，不能只持久化一个无法追溯的 active=true。

### 覆盖范围与计时

- 每个记录器运行段、boot、开始/结束及异常终止后的 gap 都应可识别。
- 墙钟用于展示和时间范围；持续时间优先使用单调时钟，处理时钟调整、睡眠、重启。
- 唤醒后的累计 swap/CPU 计数基线需要重置，避免把睡眠时间误算为工作或均值分母。
- 各读数保留有效性；权限不足或 API 失败用 unknown，不能写成正常或零占用。
- 原有 PID 加启动时间的身份和 CPU 时间单位换算值得保留。
- 需要按覆盖时长统计平均值与压力等级占比，避免采样丢失和变更门控写入导致偏差。

## 5. 建议的精简结构（待用户确认形态与指标范围）

```text
轻量 recorder 常驻进程
  readers：内存、CPU、必要进程信息
  activity：会话/idle/任务信号
  scheduler：不同采集频率、sleep/wake、异常重启
  writer：SQLite、批次事务、保留期限、覆盖范围

独立只读 query 命令
  status / coverage / summary / processes / export
  JSON / CSV / 可选受限 SQL

可选极简菜单栏
  仅展示记录中、暂停、状态、退出，不承担采集生命周期
```

初步默认建议：

- 第一版无 root helper、无 Full Disk Access、无内置 AI、无自动上传。
  全局内存统计仍然可读；不可读系统进程的归因应明确显示覆盖缺口。
- 系统内存/CPU 10 秒采样；进程详细信息可采用较低频率。
  具体间隔需结合用户的短任务捕获要求与 M1 上的实测开销决定。
- 系统原始指标保留 30 天。10 秒频率约 25.9 万条系统记录，不乘进程数量。
  进程数据量远大于系统记录；全部进程还是 Top N、细粒度保留多久，需单独预算。
- 保留 CSV/JSON 与覆盖范围说明；先不实现新的大型图表界面。
- 以分钟汇总保存 normal/warning/critical/unknown 的覆盖时长，并按所选时段类型分别统计。
- 保留独立数据目录和服务标识，避免与上游应用共用数据、卸载逻辑或自动更新。
  `Resources/Info.plist` 的 Sparkle feed 当前指向上游发行包，必须移除或改为自有更新渠道。
- 保留 MIT 版权声明和仍使用的第三方依赖许可证。

## 6. 改造顺序

1. 确认运行形态、采集范围、工作时段定义，形成最小数据契约。
2. 新增独立 recorder/query target，复用或抽取必要 readers，先让新路径可构建和短时采集。
3. 实现覆盖计时、等级时长汇总和健康状态，验证查询结果可回答七天问题。
4. 在新路径通过验证后，移除不再被引用的 UI、Ask、扫描器、helper、Sparkle 等目标和代码。
   不能仅隐藏 UI，却继续运行相关 collectors。
5. 验证 sleep/wake、SIGTERM、重启、空记录、权限缺口、数据库错误、保留期边界。
6. 在 M1 上对比采样前后的 CPU、physical footprint、写盘和电池影响；再确定常驻配置。
7. 安装与登录启动属于后续具体执行步骤，本阶段没有创建 launchd 任务或启用常驻服务。

验证重点：真实的等级持续时间与未知覆盖、CPU 差分、PID 重用、跨休眠时间权重、
稀疏进程写入的加权均值、分钟/小时聚合、并发只读查询、保留/空间上限、干净退出和自动恢复。
现有相应单元测试可作为基线，删除功能时只保留仍在产品范围内的验证。

## 7. 已确认的决定与当前实现

用户已明确选择：纯后台加命令行查询；保留所有性能指标类别；分别统计人在使用、后台繁忙和空闲。
因此，前面表格中 GPU、磁盘、网络、电池、温度的候选删除建议不再适用。

当前结构：

- `MacPerfMonitorCore`：保留性能采样器、必要模型、历史查询及 SQLite 写入和聚合。
- `RecorderKit`：配置、单实例锁、后台定时/压力事件采样、交互 idle/session 信号、覆盖计时、只读查询。
- `mpm-lite`：record/status/summary/processes/sql/export；`mac-recorder` 保留为兼容产品。
- 移除 SwiftUI App、XPC/root helper、内置 AI、扫描/清理工具、上游更新、品牌资源和对应 UI 测试。
- 保留各性能类别的可用读数；硬件、权限或私有接口限制的指标标记不可用。
  无 root helper 的第一版不保证读取 ANE 功耗及所有系统进程 footprint。
- 原生压力等级独立保存，汇总输出 normal/warning/critical/unknown 秒数与占比。
  原项目自定义指数仅作次要数据，查询视图已明确命名为 custom_pressure_index。
- 系统默认 10 秒，进程和逐进程网络默认 30 秒；完整系统快照保留 30 天，原生压力时长不依赖旧聚合指数。
- 程序不记录键盘内容、截图或 Apple knowledgeC 活动历史；三类活动状态属于可调整的估计。
- 默认使用独立的 `MacPerformanceRecorder/history.sqlite`；保留原服务标识与数据库路径，避免重命名影响现有安装。

构建和测试见根目录 README；实测与检查范围见 [validation.md](validation.md)。
