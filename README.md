# CFLark · 鸿蒙 Cloudflare 节点优选

CFLark 是一款为 HarmonyOS NEXT 打造的原生 Cloudflare 节点优选工具。它会自动扫描 Cloudflare 官方 IP 段，经过 **TCP 延迟筛选 → 数据中心识别 → 下载测速 → 加权排序**，帮你在当前网络下找到更快、更稳的 Cloudflare 节点；支持域名端到端校验，并可把优选结果一键写入 edgetunnel 的 `ADD.txt` 订阅。

应用完全使用 ArkTS + ArkUI 原生实现，手机、平板、2-in-1 自适应布局，支持浅色/深色主题与系统沉浸材质。

## 功能特性

- **官方 IP 段扫描**：内置 Cloudflare IPv4 / IPv6 官方网段，支持“官方 IP 段”与“自定义 IP”两种候选来源。
- **三阶段优选流水线**：TCP 延迟筛选（并发可调、取多次最小值）→ 数据中心（colo）识别 → 下载速度测试，全程可取消、实时进度与日志。
- **地区化筛选**：按 HKG / LAX / NRT / SIN 等地区分组展示，可指定地区码后测速，也可“每地区各取最优”批量测速。
- **加权排序**：延迟与速度分别归一化后加权评分，支持完全测速 / 地区测速 / 全部地区三种模式。
- **域名端到端校验**：可指定域名作为 Host/SNI 参与测速，验证“IP + 域名”组合是否真正可用。
- **后台保持运行（设置 → 运行）**：默认关闭。开启后扫描/测速/订阅上传期间切后台不中断（TASK_KEEPING 长时任务），任务结束或手动停止即释放。
- **测速域名自动采样**：在扫描页「下载测速 → 测速域名」填写域名后，会自动解析其 A（IPv4）/ AAAA（IPv6）记录并入候选池（日志可见「域名采样：… 解析到 N 个地址」）；留空使用默认 speed.cloudflare.com，无需额外开关。
- **结果导出**：一键导出 TXT / CSV，方便粘贴到客户端或订阅配置。
- **edgetunnel 订阅上传**：支持“登录上传”（域名 + 后台密码）与“API 直传”（Cloudflare API Token 直写 KV）两种方式，覆盖/追加可选，支持自定义保留行与写入位置，自动连续编号。
- **参数持久化**：采样数、并发、延迟上限、测速参数等全部自动保存，下次打开无需重填；IPv4/IPv6 各有推荐默认值并可一键套用。
- **合格速度门槛（第一轮初筛内配额预检）**：可设置“合格速度”（MB/s，默认 0.1，0=不淘汰）。TCP 初筛后，从延迟最低的候选开始逐个做小窗口测速，**凑够「测速地址数」个达标节点**才进入正式测速，不达标的直接淘汰、不进入测速页/导出/上传；若连续大量节点不达标（疑似网络异常或门槛过高）会提前中止并在日志中提示检查网络。
- **初筛进度与提速**：进度条显示「已测/总数 · 通过 X · 未通过 Y」；首个 ping 超时即跳过剩余次数，已明显达标即提前结束，减少无效等待。
- **自定义上传数量**：订阅上传的数量改为数值输入（默认前 3，0=不限制），完全/地区测速按合计、全部地区按每地区分别限制。
- **网络诊断**：设置页内置 IPv4 / IPv6 双自检（默认网络、固定/近邻/随机地址连通性），结果可一键复制，便于排查网络问题。
- **沉浸式 UI**：玻璃卡片、悬浮导航、浅色/深色主题、主题色与自定义背景图，支持跟随系统材质等级；平板为三列设置布局。

## 应用截图

> 手机与平板截图一一对应，共 10 张。

| 手机 | 平板 |
| --- | --- |
| <img src="docs/screenshots/phone_01_scan.jpg" width="230" /><br><sub>扫描 · 候选来源 / 端口 / 快速筛选</sub> | <img src="docs/screenshots/tablet_01_scan.jpg" width="500" /><br><sub>扫描 · 平板三栏布局与运行日志</sub> |
| <img src="docs/screenshots/phone_02_scan_running.jpg" width="230" /><br><sub>扫描进行中 · 实时进度</sub> | <img src="docs/screenshots/tablet_02_scan_running.jpg" width="500" /><br><sub>扫描进行中 · 进度与日志</sub> |
| <img src="docs/screenshots/phone_03_filter.jpg" width="230" /><br><sub>地区筛选 · 按地区分组</sub> | <img src="docs/screenshots/tablet_04_filter.jpg" width="500" /><br><sub>地区筛选 · 平板双列展示</sub> |
| <img src="docs/screenshots/phone_04_speed_results.jpg" width="230" /><br><sub>下载测速 · 结果与导出</sub> | <img src="docs/screenshots/tablet_03_speed_results.jpg" width="500" /><br><sub>下载测速 · 平板结果列表</sub> |
| <img src="docs/screenshots/phone_05_settings_upload.jpg" width="230" /><br><sub>设置 · 订阅上传</sub> | <img src="docs/screenshots/tablet_05_settings.jpg" width="500" /><br><sub>设置 · 订阅上传 / 外观 / 材质</sub> |

## 安装

### 安装工具推荐

- **首选：Hokit** —— 对 HAP 安装/签名兼容性最好，支持拖入安装、查看应用信息与日志。
- 备选：**轻启·安装器**、**小白盒子**、**Hapkit**（按个人习惯选择即可）。
- 也可以使用 DevEco Studio 自带的 hdc 命令行安装（见下方方式一）。

### 方式一：HAP 安装（调试包）

1. 下载 Releases 中的 `CFLark-Harmony-1.4.1-debug.hap`（未签名构建）。
2. 连接鸿蒙设备（需开启开发者模式与 USB 调试），执行：

```bash
hdc install CFLark-Harmony-1.4.1-debug.hap
```

3. 也可以把 HAP 传到手机/平板后用文件管理器打开安装（需允许安装未知来源应用）。

### 方式二：App Pack 安装（发行版，推荐）

下载 `CFLark-Harmony-1.4.1-app-release.app.hap`，**Hokit 可直接安装，无需修改后缀**；也可用于归档或上架流程。

> GitHub 附件不支持 `.app` 后缀，因此发行版 `.app` 统一命名为 `*.app.hap`，本质仍是鸿蒙 App Pack。

> 1.4.1 的两个安装包均为**未签名**构建 —— 这是刻意为之：当前鸿蒙侧载生态（Hokit、轻启、Hapkit、小白盒子等）会在安装时自动重签，无需自带签名。推荐直接拖入 Hokit 安装。

## 使用流程

1. **扫描**：选择 IP 版本（IPv4 / IPv6）、端口与采样数，点击「开始优选」。
2. **筛选**：查看各地区通过 TCP 筛选的节点数量与最快/平均延迟。
3. **测速**：选择测速地址数后开始测速，得到下载速度与最终排名。
4. **导出/上传**：导出 TXT/CSV，或在「设置 → 订阅上传」中配置 edgetunnel 自动上传。

### 参数默认值与建议

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| 采样数 | 3000 | IPv4 / IPv6 统一 |
| 并发线程 | 30 | 上限按设备分档：手机 120 / 平板 200 / 电脑 300 |
| 延迟上限 | 300 ms | IPv4 / IPv6 同一上限 |
| Ping 次数 | 1 | 超过 300 ms 直接淘汰 |
| 合格速度 | 0.1 MB/s | 低于该值不进入结果列表 |
| 测速地址数 | 10 | 每个地址测 1 次，窗口 6000 ms |
| 上传数量 | 前 3 | 0 = 不限制 |

在扫描页点击「应用建议」可一键套用以上参数（IPv4 / IPv6 同一套）。

### 订阅上传（edgetunnel）

- **登录上传**：填写 edgetunnel 后台域名与密码，App 通过登录接口写入 `/admin/ADD.txt`。
- **API 直传**：填写 Cloudflare Account ID、Workers KV 命名空间 ID 与 API Token（需 Workers KV 读写权限），直接读写 KV 中的 `ADD.txt`，不依赖域名可达性。
- 支持「覆盖 / 追加」，上传数量可自定义（默认前 3，0=不限制）；完全/地区测速按合计、全部地区按每地区分别限制。追加时自动保留远程已有节点并继续编号。

## 从源码构建

环境要求：DevEco Studio 6.x（HarmonyOS SDK API 26）、Node.js 18+、ohpm、hvigor。

```bash
# 1. 安装依赖
ohpm install

# 2. 用 DevEco Studio 打开工程，或在工程根目录构建
hvigor assembleHap --mode module -p product=default

# 3. 命令行（若已安装 devecocli）
devecocli build --build-mode release
```

> 工程内的 `AppScope/app.json5` 已包含版本号；构建产物位于 `entry/build/default/outputs/default/`。

## 开发者文档

- [沉浸光感与视觉体系约定](docs/沉浸光感与视觉体系约定.md)：材质开关的判定链（`effLevel()`）、玻璃卡片模板、控件令牌、深浅色 helper、构建与真机验证流程。

## 隐私与安全

- 应用不收集、不上传任何用户数据到第三方服务器；所有扫描与测速请求均由本机直连 Cloudflare 完成。
- 订阅上传所需的域名、密码、API Token 仅保存在本机 Preferences 中，不会发送到除 edgetunnel 服务端 / Cloudflare API 之外的任何地方。
- 源码中不包含任何签名证书、私钥、Token 等敏感文件；`.gitignore` 已排除证书与本地配置。

## 免责声明

本应用仅供学习与个人研究使用，与 Cloudflare 官方无关。请遵守所在地区法律法规及 Cloudflare 服务条款；因使用本应用（含节点测速、订阅上传等）产生的任何后果由使用者自行承担。

## 版本记录

各版本的变更说明、源码快照与安装包统一在 [Releases](https://github.com/Bailin-Love/CFLark-Harmony/releases) 中维护，README 不再累积历史列表。

## 许可证

本仓库仅用于学习交流。使用、修改与分发请自行评估风险并遵守相关法律法规。


