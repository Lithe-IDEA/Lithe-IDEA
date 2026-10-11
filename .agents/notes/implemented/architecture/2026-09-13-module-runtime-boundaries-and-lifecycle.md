# Agent 笔记：模块运行时边界与生命周期

状态：已实现

## 先说结论

模块的启动、停止、资源持有和故障恢复由统一运行时负责，模块本身只使用被授予的能力。禁用模块不能偷偷启动进程或 watcher；模块启动失败后，运行时必须能记录状态并支持后续恢复。

## 问题

功能模块不仅是隐藏的 UI 或源码目录，还必须决定什么时候构造、由谁持有
长生命周期资源、如何和其他模块通信，以及发生启动故障后如何恢复。如果
这些职责散落在 `AppModel`、服务字段和平台组合代码中，禁用模块仍可能
启动任务或进程，休眠也可能留下 watcher、连接、PTY 或子进程。

原生插件还需要在不加载模块代码的情况下完成版本、所有权和恢复判断。否则
一次未完成的激活或 Bundle 加载失败，会让下一次启动再次触发同一个故障。

## 决策

Lithe 使用 `LitheModuleAPI` 加 `LitheApplicationKernel` 作为统一的模块运行时
边界。模块生命周期、依赖、能力、资源和恢复状态由运行时持有，功能模块只
通过 `ModuleContext` 获得声明过的能力和资源接口。

```text
MacServiceContainer
    -> ModuleRegistry
        -> ModuleRuntime
            -> ModuleFactory
                -> LitheModule
```

### API 与运行时分层

- `LitheModuleAPI` 只定义平台无关的 `ModuleID`、manifest、依赖、能力、
  生命周期、事件、资源、lease、贡献和插件宿主协议。它不得依赖 UI、
  AppKit、具体平台适配器、Rust bridge 或功能实现。
- `LitheApplicationKernel` 中的 `ModuleRuntime` 负责注册、依赖图校验、
  能力提供者解析、按需构造、状态转换、资源回收、能力发布和关闭。
- `ModuleRegistry` 是组合根的声明式注册面：每个功能模块提供一个
  `ModuleFactory`，注册结果必须和已校验的静态插件 manifest 及贡献目录
  一致。
- macOS 的 `MacServiceContainer` 负责创建平台能力、读取模块配置和恢复
  元数据、注册内置模块与已加载插件。它不把全部功能实例提前构造到
  `AppServices`。

模块实现 target 只依赖 `LitheModuleAPI`、`LitheCoreContracts` 和自身需要
的工作流库；模块不能反向依赖 `Lithe` 可执行 target。应用侧通过能力、
事件和贡献目录使用模块，不通过另一个模块的具体 service 类型。

### 必须保持的生命周期不变量

1. 禁用、隔离或 Safe Mode 抑制的可选模块不会调用 factory，也不会启动
   task、timer、session、watcher、连接或子进程。
2. `onDemand` 模块只有在声明的能力被请求或被显式激活时才构造。依赖
   先于被依赖模块激活，依赖图必须无环，能力提供者不能发生静默覆盖。
3. 每个长期资源只能登记到一个模块的 `ModuleResourceScope`。注销活动
   资源会被拒绝，停止资源后才能释放登记。
4. `ModuleLease` 表示不可中断工作。存在活动 lease 时，休眠失败并发布
   可观察的阻塞原因；运行、测试、调试、终端、导入导出和事务等工作必须
   使用这个机制阻止后台回收。
5. 休眠依次准备模块、停止模块服务、停止登记资源、确认没有活动资源、
   移除能力和贡献，并释放实例。唤醒时重新构造实例，先激活依赖，再恢复
   能力。
6. 可选模块在调用 factory 前写入 pending activation 标记。启动时如果
   标记未清除，恢复存储会先把模块隔离，应用可以在不构造模块的情况下
   启动并允许用户重新启用它。
7. 原生插件 Bundle 加载使用独立的进程级恢复标记。插件 manifest、宿主
   版本、模块所有权、语言支持和入口信息在加载 Bundle 前校验；Safe Mode、
   禁用和隔离状态在触碰 Bundle 前过滤。
8. 模块仍然运行在应用进程内。上述标记、隔离和 Safe Mode 是下一次启动
   的恢复机制，不等同于进程隔离，也不能宣称第三方模块崩溃不会终止应用。
9. 静态贡献目录可以被工作台读取而不构造模块；模块实例激活后才发布
   实际贡献，休眠、禁用或失败回滚时移除这些贡献。

### 数据库视图在模块释放后的刷新

退出应用或休眠数据库模块时，SwiftUI（macOS 的声明式界面框架）可能先刷新
已经存在的子视图，再移除父视图。父级检查“模块是否激活”不能保证子视图
刷新时能力缓存仍存在。#924 的退出崩溃堆栈落在数据库工作区渲染函数；
该函数原本会强制读取能力缓存，缓存已清空时会触发断言，与报告吻合。

工作台和编辑区入口通过可空的 `databaseFeatureIfActive` 获取当前状态对象，
再用 SwiftUI 环境传给数据库工作区、侧栏和弹窗。它们只读取、观察这次注入的
`DatabaseFeatureModel`，不再每次渲染或异步操作恢复时从 `AppModel` 强制取值。
例如，旧查询视图在模块释放后仍可完成最后一次刷新；模块重新激活时，新视图
会接收新实例，旧视图的晚到回调不会转而修改新实例。

视图持有状态对象不代表模块继续运行：`prepareForModuleRelease()` 仍在释放
流程中停止定时器、取消计划任务并使在途请求失效。旧对象只保留到最后一个
视图或回调放开引用，不把它永久缓存为 `AppModel` 的后备实例。不要通过
延迟清空能力缓存、只切换侧栏，或访问失败时临时构造模块来掩盖退出竞态；
这些做法分别依赖刷新时序或破坏按需激活边界。

代价是数据库视图入口必须传入状态对象，弹窗也必须继承同一环境。
`DatabaseWorkspaceLifecycleTests` 覆盖原生视图在会话关闭后再次渲染、弹窗
晚到刷新，以及模块休眠后资源清理、旧状态释放和唤醒的新实例隔离。

### 数据库右侧入口与编辑器标签

数据库连接树通过已有模块入口注册到右侧停靠区，与 Maven、Agent 共用一个
位置；打开入口不替换左侧项目树，也不切换中央代码。搜索图标左侧的概览按钮
按需打开可关闭的 Database Overview 标签，保留连接数、已连接数、类型数、
快速开始、常用操作和最近八条 SQL 六个区域。统计、连接和历史直接读取现有
DatabaseFeatureModel，不复制会话；共享标题、分隔线、字体、表面与行悬停代替旧卡片样式。
概览的常用操作按钮取消 Spacer 撑满整行和零圆角悬停，复用共享 litheRowHover，背景只覆盖按钮内容及内边距，禁用动作不绘制悬停。
依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `ActionButtonLook.paintBackground`，悬停背景取控件本身尺寸并扣除 insets；`IdeaActionButtonLook` 使用圆角背景，Islands 主题为 ActionButton 提供 hoverBackground token。这里复用项目已批准的圆角/颜色，不把主工具栏按钮尺寸套到概览。
连接弹窗保留原生 DisclosureGroup 箭头和展开状态；Safety/Advanced network 的标签填满标题行，并在标签上切换同一状态，避免必须精确命中箭头。手势只作用于标签，不拦截展开内容的输入或开关。
概览连接弹窗删除 SwiftUI sheet，改用与侧栏一致的 LitheCenteredPopup：animationBehavior.none、原生有标题子窗口，无系统 sheet 遮罩和额外自绘外框。
概览和内容标签统一使用侧栏圆柱图标；每个连接在编辑器中保留一个数据库标签，标题使用配置的数据库名（无数据库名时使用连接名），不随 Data/SQL/Structure/History 页面切换改名。没有连接的全局历史仍使用 SQL History。
概览和各数据库工作区可以同时保留；同一连接重复打开只选中已有标签。
右侧树切换表，不再创建第二层表标签，原 `openTableTabs` 状态与关闭表入口一并删除。
四个页面改用原始 16pt SVG 和共享 22pt 图标按钮，与刷新、编辑、更多、TSV、分页
共用一行 30pt 工具栏。页面按钮保持选中背景、默认箭头、悬停名称与辅助功能标签；
非 Data 页面或未选表时，表格操作禁用，页面切换仍可用。

标签顺序只持有连接 ID；数据库模块仍只有一个状态对象与一套 Provider。
模块记住各连接最后的表、页面、SQL 草稿及选中查询；切回时复用既有请求加载表，
不缓存结果页或开启后台连接。SQL 查询结果和运行状态不跨连接带入。
关闭标签不删除连接或草稿；休眠、关闭项目和禁用模块移除全部数据库标签，
同时释放连接位置缓存。切换已配置连接的 MySQL 数据库会清理旧表与旧查询位置，
避免把旧数据库的内容带入新库。

数据库标签的激活属于点击时的同步导航：`AppModel.selectDatabaseWorkspace` 复用
`DatabaseFeatureModel.activateProfile` 切换连接并立即打开标签，随后才刷新数据。
侧栏、概览、查询、历史恢复和表动作使用同一入口；页面与 SQL 草稿也在点击时配置。
正确做法是先选中 B 标签，再让 B 的请求更新数据；不要在 `await select/refresh` 后
重新打开标签，否则用户期间转到文件、Overview 或关闭 B，会被迟到结果抢回。
不额外维护导航令牌，因为数据完成回调不承担导航；旧数据仍由模块已有请求 ID
和代次检查丢弃。关闭标签后已开始的数据加载正常结束，避免留下永久 loading 状态。
`delayedConnectionLoadPreservesLaterNavigation` 使用已有 TestGate 控制成功/失败请求，
覆盖切到文件、概览、关闭单个/全部标签和请求开始前关闭，断言请求结束后不改变导航。

不采用每张表独立标签、每个标签复制一个模块或永久缓存完整结果集：它们分别带来
重复导航、重复资源生命周期和额外内存占用。代价是返回连接时会重新加载表，
未提交的数据单元格编辑仍是当前视图状态，切换连接不会把草稿应用到另一连接。

工具栏分隔线参考 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`ActionToolbarImpl.kt` / `MySeparator`、`JBUI.CurrentTheme.Toolbar.SEPARATOR_COLOR`
及 `ManyIslands{Dark,Light}.theme.json`：`ToolBar.separatorColor` 解析到
`toolbar-border` / `core-border-transparent`，深色 `#FFFFFF21`、浅色 `#00000020`。
共享 `LitheTheme.ActionToolbar.separator` 持有这个独立颜色，不改通用面板分隔线；
分隔项保留 7pt 槽位与 1pt 线，删除数据工具栏使用通用 divider 的做法。
Structure 图标使用同版 `platform/icons/src/expui/toolwindows/structure{,_dark}.svg`，
Data/SQL/History 复用已经导入的 table/shell/history 资源，不新增数据库功能。

数据库停靠入口使用 IDEA `IU-262.9437.185` 的 `DatabaseIconMappings.json` 所指定的 `icons/expui/dbms@20x20{,_dark}.svg` 描边圆柱；本机发行包 `intellij.database.jar` 中两份 SVG 均明确标注 Apache-2.0 授权，保留原始字节及 NOTICE 来源，不将其误称为 Community 资源。删除此前误用的调试器数据库对象图标。Maven 按 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `MavenIconMappings.json` 使用 `images/expui/toolwindow/maven@20x20{,_dark}.svg`，不放大旧 16pt 图标；Maven 面板标题移除左侧图标，保留标题及项目副标题。两处继续使用共享停靠按钮尺寸和模板配色。
数据库连接树复用共享 litheTreeRow/Tree 的 24pt 行高、13pt 常规文字、16pt 图标与 19pt 层级缩进；展开箭头使用现有 IDEA SVG，移除连接颜色竖线、对象数胶囊和空表卡片，避免数据库单独定义一套树样式。连接品牌、状态、只读和保护语义保留；按用户要求，连接行删除只读锁图标，只显示保存的连接名称，不追加数据库类型。演示名称中人为添加的类型后缀仅在仓库外临时数据中清理，不对真实连接名称做自动裁剪。成功/失败状态显示在品牌图标右下角（绿/红点），未连接不加点，连接中保留进度提示，删除行尾重复类型与状态符号。Provider 改用 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `platform/icons/src/providers` 原始 16×16 SVG 及可用明暗变体，Nacos 保持现有资源；删除对应 DBX 大画布资源，避免图形实际占用过小。共享品牌图标缓存区分主题。状态点依据同版 `platform/icons/src/modifiers/dot.svg` 的 5pt 直径，按用户要求对现有主题语义色轻微提高饱和度，不修改全局配色。树容器使用共享左右 12pt、上下 4pt 留白；文件夹和连接行只追加层级缩进，删除首层额外的 7pt/4pt 留白，避免与容器内边距叠加；连接和表的选择色由共享活动区域观察器及窗口 key 状态共同决定，获得焦点时使用主题蓝色，点击树外或切换窗口后恢复非活动灰色，避免选择状态与焦点状态混淆。
数据库 Data/SQL/Structure/History 导航使用共享工具栏图标按钮，删除原文字页签和原生分段按钮；数据空状态复用 LitheUnavailableView，删除蓝色装饰卡片。模块协调器在激活时观察操作错误并交给现有全局通知入口，重复激活不重复注册；休眠由能力 store 取消观察，侧栏隐藏不影响错误通知。连接树不调用手形光标修饰器，保留默认箭头。
四个工作区页面删除独立查询/表页签底色和下划线、工具栏组合框与 WHERE/ORDER BY 装饰边框、History/Structure 原生 inset List；复用共享页签、标题分隔线、滚动条、按钮尺寸与常规字体。SQL 编辑器保留原生编辑/选择/补全，但字体和颜色来自 LitheTheme。概览 Quick Start 和 Recent SQL 与 Common Actions 一致，在内容及内边距上绘制共享圆角 hover，外留白在 hover 外布局，状态和时间继续右对齐，禁用动作不绘制 hover。参考 Community c7f91397daa3a961b4e78bc634fe467a0a7d9ade 的 platform/platform-impl/src/com/intellij/openapi/wm/impl/content/ContentTabLabel.java 与 platform/platform-impl/src/com/intellij/openapi/actionSystem/ex/ActionButtonLook.java，沿用已有共享 owner，不复制上游未实现的功能。
数据库工具栏中的搜索、筛选和排序直接复用 `litheToolbarIconButton` / `LitheIconButtonStyle`：
16pt 原始图标放入 22pt 点击区域，不用 SF Symbols 字重模拟，也不在筛选/排序外层
再画边框。搜索默认仅显示图标，点击后仅展开共享输入，点击输入框后才聚焦；关闭搜索时清空查询，
避免隐藏筛选条件。工具栏图标的用途提示复用 `workbenchHoverHelp` 和面板局部 `workbenchHoverTooltipScope`，包括禁用动作，不依赖原生 `.help` 的延迟提示。筛选和排序固定在工具栏右侧，左侧动作可横向滚动。空状态仅保留 13pt 常规灰色提示，不显示大图标、说明段落或重复的新建按钮；添加连接沿用工具栏加号。提示脱离连接树滚动内容，按 IDEA Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `platform/platform-api/src/com/intellij/util/ui/StatusText.java` 在内容区横向居中、纵向约三分之一处显示，颜色沿 `SimpleTextAttributes.GRAYED_ATTRIBUTES` → `NamedColorUtil.getInactiveTextColor()` 对应 `Component.infoForeground`，复用已有 `LitheTheme.searchFieldPlaceholder` 同源 token。
连接新建/编辑、文件夹和 DBX 导入复用 `LitheCenteredPopup` 原生居中标题框，
输入框和确认/取消按钮复用 `LitheCommitDialogInputStyle` / `LitheCommitDialogButtonStyle`。
连接和文件夹表单使用无分组背景的滚动容器，保留展开后的滚动空间；共享输入
固定为 28pt 居中，并复用搜索输入的 I-beam 悬停处理，密码字段同样适用。
连接表单用原生 `Grid` 统一标签列和输入列；Host/Port 同行，开关和提示文字
跟随输入列。窗口按常规、SQLite、Nacos 和展开状态收缩/扩展高度，保留滚动。
这里只复用 IDEA 的表单排版规则，不引入驱动管理、认证类型等新业务控件。
弹窗继承模块环境与语言；DBX 关闭由显式绑定驱动并清空导入数据，保留连接验证、
凭据存储和原生文件选择流程，不修改共享弹窗本身。
图标来自 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的
`platform/icons/src/expui`；`PlatformIconMappings.json` 提供 NewFolder、Console
映射，`ActionButton.java` 的图标/按钮尺寸分离方式与现有共享样式一致。新增原始
明暗资源记录在 `macos/Resources/IDEAIcons/NOTICE.txt`；这些是通用开源图标，
不是专有数据库插件的动作资源。安装时作为静态资源打包，运行时只读，不生成缓存。

验证由 `WorkbenchModuleUIRegistryTests` 和 `DatabaseWorkspaceLifecycleTests`
覆盖停靠位置、重复打开、独立关闭与模块释放，完整工作台仍须实机核对。

### 插件宿主边界

插件只能通过 `PluginHostContext` 按稳定 ID 获取宿主提供的窄协议，不得
导入应用 executable target，也不得自行构造 macOS adapter。插件的
manifest 负责声明模块、依赖、能力、语言支持和入口；运行时负责生命周期，
平台层负责进程、文件、PTY、密钥链和原生 UI 等具体能力。

### 内部功能与插件市场的界线

插件市场只管理用户可以单独启用、关闭，并由插件运行时停止其资源的功能。
静态外观资源和应用自身的工作区能力不因代码曾经使用插件 manifest 就继续显示为插件。

macOS 的 Database 是内部工作区模块，默认可用，但仍按需构造并在空闲后休眠；
旧版在插件市场留下的禁用状态会在组合根迁移，避免数据库工作区永久不可用。
Windows 的预装图标和配色由外观设置持有。图标目录只加载当前选中的主题，
不向扩展注册表登记四个伪扩展；SQLite 是应用内部的数据库能力，也不生成市场卡片。

真正需要独立生命周期的官方插件放在 `Plugins/mac/` 或 `Plugins/win/` 的平台目录。
例如语言插件关闭后要释放语言服务器和监听器，因此应保留插件身份；
图标主题切换只替换静态资源，不需要通过插件启停来实现。

语言服务器、语言包和 Rust LSP runtime 的具体归属遵循
[`语言工具分层与 LSP Runtime 归属`](2026-09-13-language-tooling-and-lsp-runtime-ownership.md)；
本 Note 只约束它们作为模块接入运行时的边界。

## 考虑过的备选方案

### 在 `AppModel` 或 `AppServices` 中直接持有全部功能实例

这样调用路径较短，但禁用和按需激活无法从构造阶段保证，功能资源也会
逃离统一的停止和休眠流程。模块运行时改为持有 factory、实例和资源 scope，
应用侧只持有组合入口和能力协调器。

### 应用启动时 eager 构造所有模块

实现最直接，但会启动用户未使用的后台资源，无法满足禁用模块零资源、
按需激活和故障隔离要求，因此只有 manifest 明确声明 `eager` 的必要模块
才在启动阶段激活。

### 每个模块都做成独立进程

可以隔离崩溃，但会引入跨进程协议、启动成本和状态同步复杂度，当前模块
API 也没有以此为前提。Lithe 先采用同进程模块边界和可恢复启动标记；只有
安全或稳定性要求明确达到进程隔离级别时，才重新评估此方向。

### 让模块直接导入其他模块的实现

局部接入更快，但会形成隐式依赖和能力提供者竞争，导致模块无法独立禁用、
休眠或替换。跨模块交互统一经过能力、不可变事件和声明式贡献。

## 后果

- 模块是否被构造、是否拥有资源、是否可以休眠和是否能恢复，都有单一的
  运行时归属，测试可以直接验证 factory、lease、resource 和 state。
- 工作台可以显示模块快照和静态贡献，而不必为了展示入口提前启动模块。
- 原生插件的 manifest 校验和恢复判断可以在加载代码前完成，插件故障不会
  阻止必要的应用壳启动。
- 代价是 `ModuleRuntime`、`ModuleRegistry` 和各模块的 manifest 必须保持
  一致，模块不能通过快捷的具体 service 引用绕过这层边界。
- 这套设计只提供同进程恢复，不提供第三方代码的运行时崩溃隔离；如果未来
  引入真正的跨进程插件，必须重新定义 `ModuleContext` 和能力传输协议。

## 验证

- `./scripts/verify-agent-notes.sh`
- `./scripts/verify-module-boundaries.sh`
- `./scripts/verify-service-boundaries.sh`
- `./scripts/verify-shared-contracts.sh`
- `./scripts/test-macos.sh`
- `macos/Tests/LitheApplicationKernelTests/ModuleRuntimeTests.swift`
- `macos/Tests/LitheTests/DatabaseWorkspaceLifecycleTests.swift`

这些检查覆盖禁用模块不调用 factory、依赖顺序、能力冲突、lease 阻塞
休眠、资源回收、唤醒重建、关闭清理、贡献目录、Safe Mode、隔离恢复和
内置 manifest 漂移。

## 适用范围

- `macos/Sources/LitheModuleAPI/`
- `macos/Sources/LitheApplicationKernel/`
- `macos/Sources/Lithe/Platform/MacOS/MacServiceContainer.swift`
- `macos/Sources/LitheApplicationKernel/Registry/ModuleRegistry.swift`
- `macos/Sources/Lithe/`
- `macos/Sources/Lithe*Module/`
- `Plugins/mac/Official/`
- `macos/Tests/LitheApplicationKernelTests/`
- `scripts/verify-module-boundaries.sh`

Redis Key Browser 的标题栏、DB 标识、SCAN 搜索/刷新与空状态接入现有共享控件；移除红色图标底板、胶囊及局部错误条，错误统一由已有协调器通知，不重复显示。Estimate size 是布尔选项，沿用 Community `c7f91397` 的 `DarculaCheckBoxUI` 复选框语义，macOS 复用原生常规 checkbox 而非另写 Java 绘制器；刷新/搜索沿用同版原始 SVG 和共享 22pt 工具栏按钮。空浏览区填充可用高度，搜索保持顶部，避免空状态固有高度把整列垂直居中。此调整仅覆盖 Redis 截图指定区域，Nacos 和 Redis 有值编辑表单保持现有实现。

工具栏置于 WHERE/ORDER BY 分栏上方，删除无动作的 All rows 胶囊；行号列替代复选框外观，原点击选行及 # 全选保留。单元格以原生焦点确定选中位置，以共享活动区域及 key-window 状态选择蓝/灰底色，切换表清理焦点，数字右对齐。树节点与表头 schema/objectGroup/table/column 的原始 16pt SVG 来自本机 IDEA IU-262.9437.185 的 DatabaseTools `lib/modules/intellij.database.jar`，每个资源明确 Apache-2.0 授权；它们不是 Community 来源，保留版权与 NOTICE，不复制数据库插件实现。

Data 表格的实际基准为 Community c7f91397 的 `grid/impl`，不是通用 JBTable：GridColorSchemeUtil 读取编辑器 INDENT_GUIDE/SELECTION_BACKGROUND；SelectionColorLayer 经 DataGridUIUtil.softHighlightOf 对表头背景每个 RGB 通道加/减 16。删除原 toolHeader/toolWindowBorder 作为数据网格颜色的用法，专用共享 DatabaseGrid token 不改变侧栏与其他工具窗口。CellRenderingUtils 表头左内边距 4pt、DefaultTextRendererFactory 单元格左右 3pt，TableResultView 行高按字体行高乘共享编辑器行距后加 1pt 行间隔和 4pt 留白；排序使用 getSortOrderIcon 指向的原始 arrowSplitCenterV/arrowUp/arrowDown。筛选保留既有弹出动作，删除整块列表悬停背景，不增加截图中 Lithe 尚未实现的数据库功能。

行号列对照同 revision 的 `grid/impl/src/run/ui/table/TableResultRowHeader.java`：文字由表格的 PLAIN 字体绘制并居中，Lithe 明确使用与数据相同的 13pt JetBrains Mono Regular 和 DatabaseGrid.text，避免继承普通按钮字重及前景色。沿 `SelectionColorLayer.getRowHeaderBackground` 与默认非透明行号栏规则，普通行继续用 softHighlightOf 背景，选中行号块取 GRID_CURRENT_ROW，即编辑器 CARET_ROW_COLOR（Islands Dark #1F2024、Light.xml #FCFAED）；选中单元格所在行与显式选中行都更新行号块，失焦不把行号块画成单元格蓝色。右侧保留源码的 1pt 网格边线，原行号选行、# 全选、删除禁用和右键动作不变。

Data 网格全选之后，已有行和新增行的普通单元格点击都必须清除 selectedRows，再设置单元格焦点；否则全行背景层仍覆盖原选择，使逐个点击看起来没有效果。行号点击继续切换单行，# 继续全选/取消全选。只读连接继续禁止进入编辑；演示可编辑设置须作用于用户实际运行实例的同一条临时 SQLite 连接，不能只改变独立预览偏好。Tables/Collections 是可展开的分类节点，标题使用共享 Tree.text，数量使用 Tree.secondaryText，避免普通可点击文字被画成禁用样式。验证覆盖全选→逐行取消→单元格单选及编辑，并核对取消草稿不写入演示库。

新增行与已有行必须在同一个 ForEach 中使用全表唯一行号，避免 LazyVStack 合并两个从 0 开始的标识后遗漏草稿行。对照同 revision 的 AddRowAction / GridUtil.newInsertOrCloneRowRequestSource，新增后滚动到末行并选中第一个单元格；单击只选中、双击再出现无框编辑器。行号延续已有数据，待提交整行复用 MutationsColorLayer → CellColors.INSERT → TableDiffColors.TDIFF_INSERTED 对应的共享 Diff.inserted 配色；空值取 GRID_NULL_VALUE 的 DEFAULT_LINE_COMMENT 色。尚未填写的列仍从插入字典中省略以保留数据库默认值，显式 Set NULL 才发送 null。提交使用 Community AllIcons.Actions.Upload 原始 SVG，撤销使用 intellij.grid.impl.xml 的 RevertSelected 所指定的 General.Reset；不仿造 Community 中未提供的数据库专用提交动作图标。新增在加载、无列和只读状态禁用；提交失败保留草稿，成功刷新后才清理。新增/连续新增/撤销在外部演示库中通过原生预览核对；DatabaseGridClickTests 继续保护共享单元格的即时点击回调，DatabaseToolbarAppearanceTests 核对新增的原始资源。

筛选/排序弹出区域复用 LitheCommitDialogButtonStyle/InputStyle 与 LitheSettingsSegmentedControl，保留条件和查询动作。列宽移除等分视口策略，参考同版 DefaultGridColumnLayout 的内容测量、40pt 下限、黄金分割 preferred 上限；按用户要求分配面板剩余空间，不使用 full×1.2 上限；当前只采样前 100 条已加载数据，不支持冻结列/持久化拖动宽度。单击聚焦普通文本单元格，双击可写连接进入原 TextField 草稿编辑，失焦退出编辑；只读连接始终只显示文本，保留原行选择与菜单。

数据库表头根据已有 primaryKeyColumns 元数据选择主键列图标，普通列保留 column.svg；主键列使用同版 IDEA DatabaseTools 明确 Apache-2.0 授权的 columnGoldKey.svg 原始 16pt 明暗变体，不拼接或重绘钥匙，也不把所有名为 id 的字段推定为主键。

SQLite PRAGMA 的列声明类型可能为 NULL，实际返回值却是整数；sidecar 的共享 row_json 必须按 ValueRef 的实际类型解码，避免 pk/cid/notnull 被降为 unsupported。这同时影响主键图标和主键编辑约束，修复在共享解码处，不在 UI 按字段名猜主键。

按用户要求，数据网格列少时也铺满当前面板：仍测量内容并按内容比例分配空余宽度，但不再保留 Community DefaultGridColumnLayout 的 full×1.2 上限；宽列总量超过面板时仍横向滚动。单击单元格保留整格选中色和键盘焦点，复用 Git Log 已有的 macOS 14+ 隐藏系统焦点效果入口，提取到共享 Theme；不再在文字周围重复画系统焦点框，macOS 13 保留兼容行为。

数据表删除独立路径/属性工具栏，保留单行共享 30pt 工具栏和 16pt 原始 SVG、22pt 按钮，参考 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 ActionButton/ActionButtonLook 与既有工具窗口共享基线。刷新和编辑动作在左，TSV/分页固定在右；跳转列、行详情及原导入/导出/批量操作收进 Data Tools，删除仅供旧工具栏使用的标签绘制函数，数据库顶层标签显示数据库名，内层表标签已删除。没有增加 IDEA 专有动作。

工具栏禁用反馈由共享 `LitheIconButtonStyle` 读取环境中的 `isEnabled`，覆盖直接禁用、父组禁用和 helper 参数三条入口，避免每个调用者补透明度或重复变暗。沿 Community 同 revision 的 `platform/platform-impl/src/com/intellij/openapi/actionSystem/impl/ActionButton.java` 的 `getIcon`/`getPopState` 核对禁用图标及只有可用按钮进入 hover 的语义；保留原始 SVG，macOS 使用共享透明度降低原始灰色图标的亮度，透明度沿用既有 0.45，不声称复刻 Java 的像素滤镜。TSV 触发器复用同一按钮样式，只让文字标签保留固有宽度，删除局部 row-hover；分页继续复用同一图标样式。

普通单元格的两个 SwiftUI TapGesture 会等待双击判定，不能承担即时选择。复用共享右键捕获视图的原生命中筛选模式，数据表局部 NSView 在左键 mouseDown 同步传递 clickCount：第一下选择，第二下可写连接编辑；Control-click/右键不截获，滚轮不命中，编辑中的 TextField 移除捕获层以保留原生插入点和输入。没有全局事件监视器或定时器，视图卸载即释放回调；保留原键盘焦点。DatabaseGridClickTests 在没有鼠标松开/定时器推进前断言首次回调，同时覆盖双击与菜单事件。

单元格编辑状态依据 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `grid/impl/src/run/ui/grid/editors/GridCellEditorTextField.java`、`platform/platform-impl/src/com/intellij/ide/ui/laf/darcula/DarculaUIUtil.java` 和同版 Islands 深浅主题：编辑器使用网格原背景，焦点边框是内侧 2pt 矩形，颜色由 `Component.focusColor → control-brand-border → blue-80` 解析为 #3871E1；不是文字外面的原生圆角输入框。已有行与新增草稿行共用 DatabaseGrid token，焦点边框不拦截输入和右键，失焦时移除。与上游 GridTableCellEditor 默认行为一致，单击立即显示整格选中色，双击可写单元格才进入编辑并显示矩形焦点边框；只读和已标记删除的行不进入编辑。点击行号或 # 结束当前编辑视图，保留已有草稿；取消仍通过 Discard，未提交不写数据库。原生深浅主题预览已核对单击没有原生字段、双击出现编辑器、全选后单击和新增草稿行；文本输入与撤销通过，未提交演示数据。本次 43 项 macOS 定向测试通过。

数据库变更背景继续沿 Community `c7f91397daa3a961b4e78bc634fe467a0a7d9ade` 的 `grid/impl/src/datagrid/color/MutationsColorLayer.java` → `GridUtil.getMutationCellAttributes` → `CellColors` → `TableDiffColors` 解析：修改复用 Diff.modified（Islands 深/浅 #385570/#C2D8F2），新增复用 Diff.inserted（#294436/#BEE6BE），删除复用 Diff.deleted（#484A4A/#D6D6D6），不再使用半透明警告黄或降低整行透明度。红色在该源码中来自提交失败覆盖：MessageType.ERROR → Notification.errorBackground → feedback-error-bg，Islands 深/浅为 #56272B/#FFF6F5；只对仍未提交的变更显示，撤销或成功提交清除；异步提交固定草稿快照，仅在同一连接/表且草稿未被取消或改写时更新本地状态，避免迟到结果改变新的草稿。与 SelectionColorLayer / DataGridUIUtil.softHighlightOf 一致，当前行或行高亮保留变更色并对深/浅 RGB 各增加/减少 0x10，通道钳制在 0…255 且保留透明度；取消整行选择后若当前单元格仍在该行，高亮色仍有依据。真正选中的单元格覆盖为网格选中色。普通、修改、新增、删除、失败状态均保留同一网格线。TableResultView 启用横/竖线时预留 1 个逻辑像素，GridColorSchemeUtil 使用 INDENT_GUIDE_COLOR（Islands 深/浅 #323438/#E6E6E6）；Lithe 用无额外间距的相邻行列和内侧 1pt 单边绘制，不叠加两条边框。DatabaseGridAppearanceTests 保护跨主题动态解析、通道钳制、未高亮颜色及透明度保留。

本轮原生预览在隔离 SQLite 演示库中覆盖修改蓝色、新增绿色、重复主键提交失败后的两种红色、全选再取消、删除标记和撤销；深浅主题均核对，失败事务前后 customers/orders 内容一致。捕获用于完整界面的视觉核对，不把带显示器 ICC 与有损压缩的屏幕图像当作精确色值或物理像素测量；色值与线宽依据固定版本的源码和专用 token，动态高亮算法由原生颜色解析测试保护。
