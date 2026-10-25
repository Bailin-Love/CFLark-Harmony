# CFLark-Harmony · 鸿蒙 Cloudflare 节点优选应用（源码）

> 从会话「鸿蒙 CF 节点优选应用开发」中提取的完整应用源码。
> 提取对象：`C:\cfdev\cflark`（该会话最终交付工程，版本 1.3.5）。
> 提取时间：2026-10-25（v1.3.5）。源码已通过 `devecocli build --build-mode release` 实际编译验证（BUILD SUCCESSFUL）。

## 基本信息

| 项 | 值 |
| --- | --- |
| 应用名 | CFLark（全称 CFLark-Harmony） |
| bundleName | `com.cflark.app` |
| 版本 | versionName `1.3.5` / versionCode `1003005` |
| 目标 SDK | HarmonyOS API 26（target/compatible 均为 26.0.0） |
| 设备 | phone / tablet / 2in1（手机、平板、PC 自适应） |
| UI 框架 | ArkTS + ArkUI 声明式 UI（Stage 模型，单页面多页签） |

## 目录结构

```
CFLark-Harmony/
├── AppScope/                         # 应用级配置与资源
│   ├── app.json5                     # bundleName / 版本 / 图标
│   └── resources/
├── entry/                            # 主模块（HAP）
│   ├── src/main/
│   │   ├── ets/
│   │   │   ├── entryability/EntryAbility.ets    # 入口 Ability + 沉浸式状态栏 BarStyle
│   │   │   ├── entrybackupability/              # 备份扩展
│   │   │   ├── pages/Index.ets                  # ★ 唯一页面：4 个页签全部 UI 与业务编排
│   │   │   ├── components/SplashPage.ets        # 启动页组件（当前入口直接进 Index，备用）
│   │   │   └── core/                            # 纯逻辑层
│   │   │       ├── Types.ets          # Candidate/ScanConfig/ScanMode/IpVersion/Verdict/Stage 等类型
│   │   │       ├── ConfigStore.ets    # Preferences 持久化 + 默认参数 + 主题配置（ThemeMode/UiConfig）
│   │   │       ├── IpUtil.ets         # IP 生成、解析、随机化、过滤、CIDR
│   │   │       ├── Probe.ets          # 单候选 TCP ping / trace 探测
│   │   │       ├── Scanner.ets        # 并发扫描、三阶段流水线、取消令牌、进度回调
│   │   │       ├── Ranker.ets         # 延迟/速度归一化、加权评分、数据中心分组
│   │   │       ├── SpeedTest.ets      # 下载测速（有限时间窗内累计字节）
│   │   │       ├── Geo.ets            # IP → 城市 / colo 映射
│   │   │       ├── DnsService.ets     # 域名解析（A/AAAA）与域名分享
│   │   │       ├── EdgeTunnel.ets     # edgetunnel 订阅自动上传（登录上传 / Cloudflare API 直传）
│   │   │       ├── Exporter.ets       # TXT/CSV 导出内容与文件名生成
│   │   │       └── FileSaver.ets      # DocumentViewPicker 保存文本文件
│   │   ├── resources/
│   │   │   ├── base/element/          # 颜色、字符串、尺寸
│   │   │   ├── base/media/            # 应用图标（前景/背景/分层图标）与启动图
│   │   │   ├── base/profile/          # main_pages.json（pages/Index）、backup_config.json
│   │   │   └── dark/element/          # 深色模式颜色
│   │   └── module.json5               # 权限、设备类型、沉浸光感元数据、Ability 注册
│   ├── build-profile.json5            # 模块构建配置
│   ├── hvigorfile.ts
│   └── oh-package.json5
├── hvigor/                            # 构建脚本
├── build-profile.json5                # ★ 应用构建配置（已移除原机签名信息，见下方“构建运行”）
├── hvigorfile.ts
├── oh-package.json5 / oh-package-lock.json5
├── code-linter.json5
└── README.md
```

## 功能概览

1. **扫描**（`ScanPage`）
   - 官方 IP 段 / 自定义 CIDR / 自定义 IP / 域名 四种候选来源，IPv4 / IPv6 双栈。
   - 端口可选：443、2053、2083、2087、2096、8443。
   - 两阶段扫描：TCP 延迟筛选（每候选多次 ping 取最小值，默认 2 次）→ `/cdn-cgi/trace` 获取数据中心（colo）信息。
   - 可选第三阶段下载测速（`speed.cloudflare.com/__down`），支持全量 / 按地区选取地址。
   - 扫描中显示进度行（进度文本 + 进度条）、开始/取消按钮；进度条仅在扫描运行时出现。
   - 平板/2in1 为三列布局，手机单列。

2. **筛选**（`PingPage`）
   - 按数据中心分组展示扫描结果，支持筛选与排序，查看每个候选的延迟、丢包、colo。

3. **测速**（`SpeedPage`）
   - 对候选地址做下载测速，展示延迟 + 下载速度 + 加权得分；可复测、导出 TXT/CSV。
   - 导出走系统文件保存选择器（`DocumentViewPicker`），保存到用户指定位置。

4. **设置**（`SettingsPage`）
   - 扫描默认参数（采样数量、并发、ping 次数、延迟上限、trace 并发等）。
   - 外观：深浅色（跟随系统/浅色/深色）、沉浸光感材质（全部卡片与悬浮导航统一）、背景图（从相册选择）。
   - **edgetunnel 订阅上传**：支持「登录上传」（域名 + 密码）与「Cloudflare API 直传」（Account ID + KV 命名空间 ID + API Token）两种方式；支持覆盖/追加、自定义保留行位置、自动/手动上传与日志。
   - 关于页与版本号。

## 订阅上传的两种方式

EdgeTunnel.ets 提供两条写入 edgetunnel ADD.txt（Workers KV 键，即后台「自定义节点」内容）的路径：

| 方式 | 必填 | 原理 |
| --- | --- | --- |
| 登录上传（默认） | 域名、后台登录密码 | POST {host}/login 取得 uth Cookie → 读取/写入 /admin/ADD.txt |
| Cloudflare API 直传 | Account ID、KV 命名空间 ID、API Token | PUT https://api.cloudflare.com/client/v4/accounts/{acct}/storage/kv/namespaces/{ns}/values/ADD.txt，读取用同路径 GET |

- API 直传不经过 edgetunnel 站点域名，因此在「站点域名被网络阻断（TLS SNI 被重置）」的环境里仍可用；Token 只保存在本机 Preferences，需具备该 Account 的 **Workers KV Read/Write** 权限。
- 两种方式都遵循相同的上传语义：**覆盖** = 自定义保留行 + 本次节点（按位置拼接）；**追加** = 先读取远端 ADD.txt，读取失败即中止（绝不退化成覆盖），再与本次节点、自定义行做精确行合并（保留远端普通节点，自定义行不会无限重复）。
- 写回会校验响应：登录上传要求 JSON success: true；API 直传要求 HTTP 200 且 JSON success: true，401/403/404/413/429/5xx 会带服务端错误信息展示。
- **上传数量**（全部 / 前3 / 前5 / 前10，默认全部）：只影响上传内容，不影响测速和结果列表。规则随「测速范围」自动切换——「完全测速 / 地区测速」按所有地区合计限制排序最靠前的 N 个；「全部地区」则每个地区各限 N 个。测速地址数默认 3，即默认「测 3 个、传 3 个」（1.3.0 修正了默认值，旧版本只改了提示、未改默认值）。
- 真实网络下如果登录上传报「无法连接/网络内部错误」，把上传方式切到 API 直传即可绕过被阻断的站点域名。

### 上传的节点行格式

每条节点占一行，格式为：

```
IP:端口#地区 V4/V6中文名序号
```

示例（真实一次优选上传的内容）：

```
172.66.216.120:443#HK V4香港1
104.18.46.214:443#HK V4香港2
104.21.201.118:443#US V4美国1
[2606:4700:440e:8f3:d964:4056:e20d:1dd5]:443#SG V6新加坡1
```

- 地区为 CF 数据中心 colo 代码 + 中文地区名（如 `HK 香港`、`US 美国`、`SG 新加坡`）；同一地区的节点连续排列，同一地区内 V4 在 V6 之前、各自按得分从高到低编号（1、2、3…）。
- **追加模式序号续接**（1.3.0）：同一地区、同一版本（V4/V6）的编号从远端已有内容的最大序号继续递增，不会与旧行重号；远端旧格式行（纯 `IP:端口`）仍原样保留。
- IPv6 地址用 `[地址]:端口` 形式，避免冒号歧义。
- 合并/去重以「地址（IP:端口）」为键，`#` 后的备注不参与去重；因此追加模式不会因序号变化重复堆积，远端已有的旧格式行（纯 `IP:端口`）会原样保留。
- 未拿到地区信息（trace 失败等）时按 `CF` 兜底，仍保持同样的格式与编号规则。

## 扫描与排序逻辑

```
候选 IP（官方段/自定义/域名） 
  → [阶段1] TCP 连接测延迟（并发，每 IP 多次取最小值）→ 过滤超时/超延迟
  → [阶段2] /cdn-cgi/trace 获取 colo 数据中心（并发 30）→ 按地区/数据中心分组
  → [阶段3]（可选）下载测速 → 得到速度
  → 加权排序：finalScore = 0.1 × 延迟得分 + 0.9 × 速度得分（均可调）
  → 结果列表（延迟升序 / 速度降序 / 加权降序）
  → 导出 TXT / CSV，或自动上传 edgetunnel 订阅
```

- 延迟得分/速度得分均为 min-max 归一化（`Ranker.ets`），权重默认 **延迟 0.1 / 速度 0.9**。
- 默认参数（`ConfigStore.ets`）：采样 2000、并发 16（上限 200）、ping 2 次（间隔 50ms、超时 1s）、延迟上限 220ms、trace 并发 30、测速默认取 3 个地址（可改，范围 1~99）/ 每地区 3 个 / 1 轮 / 3s 窗口 / 并发 1。
- 结果上限默认 0（不限制），仅显示延迟最低的 100 条。
- 测速域名不校验归属（任意可下载域名均可）。

## 构建运行

### 环境要求

- DevEco Studio（含 HarmonyOS SDK API 26）
- 或命令行 `devecocli`（本机验证时使用）
- ohpm、hvigor（随 SDK 提供）

### 关键注意：工程路径必须是纯 ASCII

hvigor 对工程路径有严格限制，**路径中不能有中文等非 ASCII 字符**，否则构建直接失败：

```
hvigor ERROR: 00306003 Specification Limit Violation
Invalid project path. Current path does not match: ...
```

建议放在如 `C:\cfdev\cflark`、`D:\work\CFLark-Harmony` 这类纯英文路径下再构建。
（本次提取验证就是在 `C:\cfdev\_cfverify` 这类 ASCII 路径完成的。）

### 构建 / 安装

```powershell
# 1) 安装依赖（首次）
ohpm install

# 2) 构建
devecocli build            # 产物：entry/build/default/outputs/default/entry-default-signed.hap

# 3) 运行到设备/模拟器（设备已连接）
devecocli run
```

也可以用 DevEco Studio 打开工程后直接 Run。

### 签名配置（重要）

原工程 `build-profile.json5` 里的 `signingConfigs`（本机证书路径 `.cer/.p7b/.p12` 与加密口令）**已从本交付中移除**，避免泄露本机签名材料。因此：

- 首次打开工程后，在 DevEco Studio 中进入 **Project Structure → Signing Configs**，勾选 **Automatically generate signature**（自动生成签名），或粘贴你自己的签名配置；
- 再用 `devecocli build` / DevEco Studio Run 构建安装即可；
- 若仅需编译检查（不装机），可临时移除 product 的 `signingConfig` 字段后构建未签名 HAP。

## 沉浸材质与导航光感（v1.3.1 ~ v1.3.2）

- **统一玻璃**：10 张卡片全部使用系统 `backgroundBlurStyle` + 主题霜面渐变 + 亮边 + 柔和投影，「全局沉浸光感」开关现在对全部卡片和底部悬浮导航同时生效（此前只有「材质」「外观」两张卡有底色变化）。
- **材质等级**：自适应/精致/柔和/平滑 → 精致=更厚的背景模糊 + 更通透的霜面 + 更深投影；平滑=更薄、更实。选「自适应」时读取设备系统材质等级（`uiMaterial.getGlobalMaterialLevel`：EXQUISITE/GENTLE/SMOOTH），修正了此前「选项越精致反而越薄」的反向映射。
- **进度条**：扫描/测速进度条改为跟随主题色（主题色 → 浅主题色渐变），不再固定蓝紫色。
- **悬浮导航**：选中页签由实心色块改为主题色柔光（横向主光 + 纵向衰减）；手指按下/滑过导航时出现跟随触摸位置的扫光，松开后 260ms 淡出；关闭沉浸光感或选择「无材质」时退回无模糊的轻量样式。
- **顶部/底部边缘虚化（v1.3.2，v1.3.3 优化性能）：条带改为顶部 30 层、底部 24 层细条（层高=步进×1.6，最大模糊半径 16，指数衰减），并叠加与页面底色同色的渐变蒙版；视觉与原来一致，但渲染层数减少约 2/3，滚动/切页更顺。
- **内容顶边延伸（v1.3.2）**：把 Tabs 内容区整体上移 1 个状态栏高度，并同步增大内容顶部留白，使滚动时内容能完整延伸到屏幕最顶部（消除顶部那条「画面没铺满」的空带接缝），静止时布局与原来一致。
- **性能优化（v1.3.3）**：滚动回调不再写入 @State（改为阈值布尔，避免滚动时逐帧整页重建）；进度/日志/结果列表改为普通字段 + 80~120ms 批量刷新；顶部/底部虚化条带缓存且数量从 111/90 降到 30/24。
- **IPv6 优选修复（v1.3.5）**：TCP 探测构造连接地址时未指定地址族，SDK 默认按 IPv4 处理，导致 IPv6 候选全部连接失败、被误报为「当前网络可能不支持 IPv6」。现按地址中是否含冒号设置 `family`（IPv6=2，IPv4=1）。
- **悬浮导航交互（v1.3.5）**：轻点页签不再触发 q 弹形变与扫光；只有手指在导航上拖动（位移超过 8vp）才显示跟手光带，松手后 120ms 淡出；同时收窄光带与亮芯范围、降低胶囊形变幅度。
- **版本记录**：1.3.1 加入材质/光感改造；1.3.2 重做边缘虚化并让内容顶边延伸；1.3.3 做运行性能优化；1.3.4 在「关于」中加入 GitHub 项目主页 / 下载最新版本入口与免责条款；1.3.5 修复 IPv6 优选误报并微调悬浮导航的拖动交互。

- **导航交互（q 弹）**：手指在悬浮导航上按住/滑过时，跟随柔光会带一点弹簧惯性与拖尾（真实物理步进，约 16ms 一帧）；切换页签时光会从旧页签弹到新页签再淡出；选中项本身只显示一层无边框的径向柔光。
- **浅色背景**：浅色模式背景从纯白改为带灰蓝的雾白渐变，并叠一层很淡的主题色环境光，避免大面积纯白刺眼；卡片玻璃质感与文字对比不变。

## 说明与已知限制

- 本包是 2026-10-25 的源码快照（**v1.3.0**）：包含早期 UI 调整（合并进度行、深色按钮位置、平板三列、手机单列恢复、页签左右滑动切换等）与「Cloudflare API 直传」；1.3.0 新增/修正：上传数量按测速范围自动切换（合计前 N / 每地区前 N）、追加模式跨批次连续编号、默认测速地址数改为 3；1.3.1 新增：全部卡片统一沉浸玻璃质感、材质等级自适应设备系统等级并修正反向映射、进度条跟随主题色、悬浮导航选中态改为无边框柔光并支持拖拽弹簧（q 弹）与切页光迁移、浅色背景改为雾白灰蓝渐变（版本 1.3.1 / versionCode 1003001）。
- 模拟器网卡带宽不代表真实设备，测速结果仅供参考。
- IPv6 地址生成与扫描已实现，但未在真实 IPv6 环境充分验证。
- 测速依赖 `speed.cloudflare.com` 的 `/__down` 接口可访问。
- `components/SplashPage.ets` 为启动页组件备用（当前入口直接进入 `pages/Index`）。
- 同会话早期还产出过一个以 CFData-WEB 为模板的工程 `C:\cfdev\cfharmony`（bundleName `com.harmony.cfdata`），**未包含在本包中**；如需可另行提取。
- 会话中的方案文档（功能规格、技术方案、UI 设计规格等）保存在工作区 `docs/` 目录；旧版 `CFLark-README.md` 为早期版本说明，其中页签数量与默认权重等信息已与当前源码不一致，请以本 README 为准。


## 应用内 GitHub 入口与免责声明（v1.3.4）

- 「设置 → 关于」新增两行入口：
  - **GitHub 项目主页** → https://github.com/Bailin-Love/CFLark-Harmony
  - **下载最新版本** → https://github.com/Bailin-Love/CFLark-Harmony/releases/latest
  点击后通过系统 `openLink` 打开浏览器（失败时回退为隐式 Want 打开）。
- 「关于」底部新增**免责条款**：本应用仅供学习与个人研究使用，与 Cloudflare 官方无关；请遵守所在地法律法规及 Cloudflare 服务条款，使用后果由使用者自行承担。