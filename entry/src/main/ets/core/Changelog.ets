/**
 * 更新日志（真实记录）。
 *
 * 数据来源：
 *  - v1.4.1：本轮迭代实际完成的改动（2026-10-28）。
 *  - v1.4.0：docs/versions/RELEASE-v1.4.0.md 与 git tag v1.4.0 日期。
 * 更早版本未在本文件重复维护，统一指向 GitHub Releases（见 AppMeta.RELEASES_URL）。
 *
 * 每条文案同时提供中文与英文，避免再走一层 i18n 键表。
 */
import { AppMeta } from './AppMeta';

export enum ChangeKind {
  NEW = 0,
  IMPROVE = 1,
  FIX = 2
}

export interface ChangeItem {
  kind: ChangeKind;
  zh: string;
  en: string;
}

export interface ChangelogEntry {
  version: string;
  /** 发布日期 YYYY-MM-DD */
  date: string;
  items: ChangeItem[];
}

export class Changelog {
  private static readonly DATA: ChangelogEntry[] = [
    {
      version: '1.4.3',
      date: '2026-10-31',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '自定义背景格里加了「自定义」角标：上传过图片以后，那一格左下角会有个小标签，一眼就能和 7 张内置预设分开。',
          en: 'The custom background cell now carries a small "Mine" badge once you have uploaded an image, so it is easy to tell apart from the seven built-in presets.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '「声明」里补上了「致敬与致谢」：本应用的外观风格与玻璃材质思路借鉴了开源项目 OpenAuthenticator（作者 mroble），并得到作者在实现思路上的指导，在此致谢。',
          en: 'The statements page now credits OpenAuthenticator by mroble: its visual style and glass-material approach inspired this app, and the author kindly shared implementation guidance. Sincere thanks.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '预设背景的第 3、5、7 张换了新图（彩球、罗盘、蒲公英），并按手机竖屏重新裁切；升级后会自动换成新图，不需要重新选一次。',
          en: 'Presets 3, 5 and 7 have new artwork (clay beads, compass, dandelion), cropped for portrait phones. Existing selections refresh automatically after upgrading; no need to pick again.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '右上角的深浅色切换按钮和右下角的置顶按钮，改成和卡片完全同一套玻璃：颜色、模糊、描边、阴影都跟卡片走，拖动「卡片通透度」时它们也一起变。',
          en: 'The theme toggle and back-to-top buttons now use exactly the same glass as the cards: same tint, blur, border and shadow, and they follow the card clarity slider too.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '升级说明弹层不再占满左右屏幕：最宽 460vp、左右各留 24vp，手机、平板、电脑上都是一块居中的卡片。',
          en: 'The what-is-new sheet no longer spans the full width: it is capped at 460vp with 24vp side margins, so it reads as a centered card on phones, tablets and PCs.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修好「自定义背景换第二张必须重启才生效」：每次选图都存成新文件，选完立刻替换，并自动清掉同模式的旧图。',
          en: 'Fixed custom backgrounds not refreshing until a restart: each pick is saved under a new file name, applied immediately, and the previous image of that theme is cleaned up.'
        }
      ]
    },
    {
      version: '1.4.2',
      date: '2026-10-30',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '候选来源可以自己建分组了：一个分组里能混放链接、文件和粘贴的文本，链接来源支持一键更新；官方 IP 段和社区段库始终只读，不会被误改。IPv4 与 IPv6 各存一套、互不影响，导入时按当前 IP 版本校验，贴错类型会直接告诉你原因。',
          en: 'You can now build your own source groups: one group may mix links, files and pasted text, and link sources refresh in one tap. The official and community ranges stay read-only. IPv4 and IPv6 keep separate sets, and imports are checked against the selected IP version with a clear reason when a line does not match.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '外观和主题合并到一页：跟随系统 / 深色 / 浅色三选一，6 种主题色，9 格背景（无背景 + 7 张预设 + 自定义图片）；浅色和深色可以各用各的背景，选「跟随系统」时会真的跟着手机深浅色切换。',
          en: 'Appearance and theme now live on one page: system / dark / light, six accent colors and a nine-cell background grid (none, seven presets, your own image). Light and dark can use different backgrounds, and following the system really follows the device.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '背景和玻璃都能自己调：背景模糊、背景明亮、背景遮罩，加上新做的「卡片通透度」——想看清壁纸就往通透调，想文字更稳就往扎实调，深浅色各自记忆。',
          en: 'Background and glass are yours to tune: background blur, brightness, scrim, plus the new card clarity slider. Push toward clear to see the wallpaper, toward solid to keep text steady; both themes remember their own values.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '平板和电脑上：扫描页改成左右两列四张卡；设置页改成左边菜单、右边内容（默认停在「订阅与上传」）；窗口变窄会自动退回单列。',
          en: 'On tablets and PCs the scan page uses two columns with four cards, settings uses a left menu with content on the right (opening on Subscription upload), and narrow windows fall back to a single column.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '扫描、筛选、测速三个页面的进度条统一了：都在各自卡片里，显示当前阶段、已完成数量和百分比，停止后明确显示「已停止」。',
          en: 'Progress bars on scan, filter and speed pages are now consistent: each sits in its own card and shows the stage, completed count and percentage, with a clear stopped state.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '来源管理改成卡片式列表，和主页面同一套玻璃质感；筛选页的地区分组展开一张卡时，只把同一列下面的卡片挤下去，旁边的列保持不动。',
          en: 'Source management now uses cards with the same glass look as the main pages, and expanding a region card only shifts the cards below it in the same column.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '七个「ⓘ」说明统一成同一种弹窗：中英双语、正文可滚动，点遮罩、「知道了」或系统返回键都能关闭。',
          en: 'The seven info buttons share one dialog now: bilingual text, scrollable body, closable by tapping the scrim, the button or the system back key.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '下载测速不再有开关，测速参数始终可见；旧的冗余代码一并清理，应用更轻。',
          en: 'The speed test switch is gone and its parameters are always visible; a batch of unused legacy code was removed as well.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修好浅色主题配深色壁纸时标题和文字看不清的问题；切换深浅色后，状态栏图标与窗口底色也会跟着变。',
          en: 'Fixed unreadable titles and text when a light theme sat on a dark wallpaper, and the status bar icons plus window background now follow theme changes.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修好直接写 IPv6 地址（例如 2606:4700::1）被当成「地址:端口」拆开、导致节点悄悄丢失的问题。',
          en: 'Fixed bare IPv6 addresses such as 2606:4700::1 being split into address and port, which silently dropped nodes.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修好「停止」按钮和进度条显示成另一项任务的问题：扫描、质量预检和测速现在各管各的状态。',
          en: 'Fixed the stop button and progress strip sometimes showing another task; scanning, quality pre-check and speed testing now track their own state.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修好平板/电脑点「查看完整日志」没反应、改完参数马上退出会丢最后一次修改、背景图读取失败会清空已选背景这几处问题。',
          en: 'Fixed the changelog link doing nothing on tablets and PCs, the last parameter edit being lost when quitting immediately, and a background read failure clearing the saved background.'
        }
      ]
    },
    {
      version: '1.4.1',
      date: '2026-10-28',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '支持中英文切换：跟随系统、简体中文、English，切换后界面立即生效，无需重启。',
          en: 'Chinese and English support: follow the system, Simplified Chinese, or English. Changes apply immediately without restarting.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '设置页改为分类入口 + 二级页面，常用的外观、材质、扫描测速、订阅上传、关于与诊断分区进入。',
          en: 'Settings now use category entries with detail pages: Appearance, Material, Scan & Speed test, Subscription upload, About, and Diagnostics.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '关于页新增「检查更新」：可对比 GitHub Releases 上的正式版本，显示最新版本号、发布时间与更新摘要，并给出官方下载入口。',
          en: 'About now has "Check for updates": compares the official releases on GitHub, shows the latest version, publish date and summary, and links to the official download page.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '新增「更新日志」页面；应用从旧版本升级后，会在首次启动时提示当前版本的主要变化，确认后不再重复弹出。',
          en: 'New "Changelog" page. After upgrading, the app shows what changed in this version once on first launch, and will not ask again.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '关于页补充参考项目说明与 AI 辅助开发声明。',
          en: 'About now documents referenced projects and AI-assisted development.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复扫描页滚动到底部时出现的大面积空白：底部安全区避让不再重复计算。',
          en: 'Fixed the large blank area at the bottom of the Scan page caused by bottom inset being applied twice.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复滑动切页未达阈值回弹后，底部导航选中态提前跳到另一页的问题；选中态现在只跟随真正生效的页面切换。',
          en: 'Fixed the bottom navigation highlighting another tab after a swipe springs back. The highlight now follows the page that actually became active.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '「Ping 次数」新安装默认值由 2 次改为 1 次（已保存的自定义值保持不变）。',
          en: 'Default ping count for new installs is now 1 instead of 2. Values you saved before are kept.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '关于页按钮重新排版，项目主页、检查更新、更新日志与诊断入口不再重叠或职责重复。',
          en: 'Reworked the buttons in About so repository, update check, changelog, and diagnostics no longer overlap or duplicate each other.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '参数卡片改为紧凑两列布局，扫描设置更集中；设置页改用分类入口，减少纵向长度。',
          en: 'Parameter cards use a compact two-column layout, and settings are grouped into categories to shorten the page.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复扫描页底部异常留白：卡片内百分比高度的承载层在滚动区被撑到整屏高度。',
          en: 'Fixed the unexpected blank area at the bottom of the Scan page: a card layer sized by percentage stretched to the viewport inside the scroll area.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复「应用建议」提示成功但参数未回显的问题。',
          en: 'Fixed "Apply recommendations" reporting success while the inputs did not update.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '关于页把「检查更新」和「下载最新版本」合并为一个入口，避免按钮重复。',
          en: 'Merged "Check for updates" and "Download the latest version" in About into a single entry point.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '置顶按钮改为与底部导航同一套几何规则定位，与导航胶囊保持固定间距，滚动区底部预留同等空间，内容不再被按钮压住。',
          en: 'The back-to-top button now follows the same geometry rules as the bottom navigation: a fixed gap above the pill, with matching space reserved at the end of the scroll area so content is no longer covered.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '设置页改为「分类列表 → 分类详情」：手机打开时不再默认展开某一类，平板与电脑为左侧菜单加右侧内容；语言并入分类，关于与更新、更新日志保留独立详情页。',
          en: 'Settings now use a category list with detail pages: nothing expands by default on phones, while tablets and desktop show a left menu with content on the right. Language moved into the category list; About & updates and Changelog keep their own pages.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '「检查更新」并入「关于」卡片并放在项目主页下方，不再单独成卡，也不再出现重复入口。',
          en: '"Check for updates" is now part of the About card, placed under the project page entry, so there is no separate card or duplicated entry.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '快速筛选参数取消高级选项折叠：合格速度直接展示可改，参数说明改为按需打开的弹窗，关闭后保留已填写的输入。',
          en: 'Quick filter parameters no longer hide behind an advanced fold: the minimum speed is always editable, and the parameter notes open in a dialog that keeps your input when closed.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '更新日志按版本折叠，默认只展开当前版本，版本增多后不必再一路翻页。',
          en: 'Changelog entries are collapsible by version; only the current version starts expanded, so the page stays short as versions accumulate.'
        }
      ]
    },
    {
      version: '1.4.0',
      date: '2026-10-28',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '接入华为 HDS 沉浸光感：全局开关、材质类型（自适应 / 沉浸 / 无材质）与材质等级（自适应 / 精致 / 柔和 / 平滑）。',
          en: 'Huawei HDS immersive material: a global switch, material type (Adaptive / Immersive / None) and level (Adaptive / Fine / Gentle / Smooth).'
        },
        {
          kind: ChangeKind.NEW,
          zh: '6 套主题色，按钮、选中态与强调文字同步跟随；深色 / 浅色 / 跟随系统三种颜色模式。',
          en: 'Six accent themes applied to buttons, selections and highlighted text, with Dark / Light / Follow system color modes.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '背景图支持 7 张预设与图库自选，新增背景模糊程度与明亮程度滑杆。',
          en: 'Seven preset backgrounds plus your own photo, with blur and brightness sliders.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '底部导航改为 HDS 悬浮胶囊，跟手拖动高亮、松手回弹，与系统「联系人」悬浮栏对齐。',
          en: 'The bottom navigation is now an HDS floating capsule that follows your drag and springs back, aligned with the system Contacts bar.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '四个页面的滚动边缘改为渐变虚化，替代原来的条带蒙层。',
          en: 'Scroll edges on all four pages now use gradient blur instead of overlay stripes.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '平板改为三列等宽布局，运行日志限高，筛选与测速页居中限宽。',
          en: 'Tablets use a three-column layout; the run log is height-capped and the Filter/Speed pages are centered with a max width.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复质量预检进度条分母错误（曾出现 130% 这类越界）。',
          en: 'Fixed the pre-check progress bar denominator that could exceed 100%.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复深色模式悬浮导航发白与屏幕底部亮带。',
          en: 'Fixed a washed-out bottom navigation and a bright band at the bottom edge in dark mode.'
        }
      ]
    },
    {
      version: '1.3.9',
      date: '2026-10-26',
      items: [
        {
          kind: ChangeKind.IMPROVE,
          zh: '测速域名的采样改为自动：解析 A 与 AAAA 记录后直接并入候选，不再需要手动打开「域名解析采样」。',
          en: 'Speed test domain sampling is automatic now: A and AAAA records are resolved and added to candidates, so the old toggle is gone.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复域名采样开关在不同设备上状态不一致的问题。',
          en: 'Fixed the domain sampling switch keeping different states across devices.'
        }
      ]
    },
    {
      version: '1.3.8',
      date: '2026-10-26',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '设置新增「运行」卡片：后台保持运行（数据传输连续任务）与域名解析采样。',
          en: 'New Runtime card in settings: keep running in background with a data transfer task, plus domain resolution sampling.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '网络诊断增强：IPv4 与 IPv6 双自检、结果可复制，并加入 120 秒看门狗避免长时间卡住。',
          en: 'Enhanced diagnostics: separate IPv4 and IPv6 self checks, copyable results, and a 120 second watchdog.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '参数默认值与分档上限：延迟上限 300ms，并发默认 20，上限手机 120、平板 200、电脑 300。',
          en: 'New defaults and per-device caps: latency cap 300ms, concurrency default 20 with caps of 120 on phones, 200 on tablets and 300 on PCs.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '性能优化：日志条数上限、结果 120ms 合并刷新、进度 80ms 合并、日志 100ms 合并。',
          en: 'Performance: capped log lines and batched result, progress and log updates.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复底部导航占用视口、页面底边被裁切的问题。',
          en: 'Fixed the bottom navigation covering part of the viewport and clipping page bottoms.'
        }
      ]
    },
    {
      version: '1.3.7',
      date: '2026-10-25',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '新增「合格速度」门槛（默认 0.1MB/s），测速结果按该门槛判定是否可用。',
          en: 'New minimum speed threshold (0.1MB/s by default) used to judge whether a result is usable.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '订阅上传数量可自定义（默认 3 个）。',
          en: 'Configurable upload count for subscription uploads (3 by default).'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '测速地址数默认改为 10；第一轮进度显示「通过 X、未通过 Y」。',
          en: 'Speed test addresses default to 10, and the first round shows passed and failed counts.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '平板设置页重新分组，IPv4 自检入口补齐。',
          en: 'Regrouped the tablet settings page and added an IPv4 self check.'
        }
      ]
    },
    {
      version: '1.3.6',
      date: '2026-10-25',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '扫描测速参数持久化，重启后保留上次的填写内容。',
          en: 'Scan and speed parameters persist across restarts.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '参数建议值与「应用建议」按钮，IPv4 与 IPv6 分别给出推荐默认。',
          en: 'Suggested parameter values with an Apply button, tuned separately for IPv4 and IPv6.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '阶段一失败分类统计更清晰，便于判断是超时、不可达还是被拒绝。',
          en: 'Clearer failure breakdown in the first stage so timeouts, unreachable and rejected results are easy to tell apart.'
        },
        {
          kind: ChangeKind.FIX,
          zh: '修复切换 IP 版本或应用建议后输入框不刷新的问题。',
          en: 'Fixed inputs not refreshing after switching IP version or applying suggestions.'
        }
      ]
    },
    {
      version: '1.3.5',
      date: '2026-10-25',
      items: [
        {
          kind: ChangeKind.IMPROVE,
          zh: '悬浮导航交互优化：轻点不触发回弹与扫光，拖动才跟手，松手后淡出。',
          en: 'Floating navigation tuning: taps no longer trigger bounce or shine, dragging follows the finger, and it fades after release.'
        },
        {
          kind: ChangeKind.IMPROVE,
          zh: '内容上下边缘改为渐变虚化过渡，滚动时不再出现生硬的蒙层。',
          en: 'Top and bottom content edges use a gradient fade instead of a hard overlay while scrolling.'
        }
      ]
    },
    {
      version: '1.3.4',
      date: '2026-10-25',
      items: [
        {
          kind: ChangeKind.NEW,
          zh: '关于页新增「GitHub 项目主页」与「下载最新版本」入口。',
          en: 'About now links to the GitHub project page and the latest release download.'
        },
        {
          kind: ChangeKind.NEW,
          zh: '新增免责声明，说明工具用途与使用风险。',
          en: 'Added a disclaimer about the intended use and its risks.'
        }
      ]
    }
  ];

  /** 新→旧排序的全部本地记录 */
  static entries(): ChangelogEntry[] {
    return Changelog.DATA;
  }

  static count(): number {
    return Changelog.DATA.length;
  }

  /** 取指定版本（接受带 v 前缀） */
  static forVersion(version: string): ChangelogEntry | null {
    const v: string = AppMeta.base(version);
    for (let i = 0; i < Changelog.DATA.length; i++) {
      if (Changelog.DATA[i].version === v) {
        return Changelog.DATA[i];
      }
    }
    return null;
  }

  /** 当前安装版本对应的说明；没有可靠记录时返回 null，由调用方做空缺处理 */
  static forCurrent(version: string): ChangelogEntry | null {
    return Changelog.forVersion(version);
  }

  static kindLabel(kind: ChangeKind, en: boolean): string {
    if (kind === ChangeKind.NEW) {
      return en ? 'New' : '新增';
    }
    if (kind === ChangeKind.IMPROVE) {
      return en ? 'Improved' : '优化';
    }
    return en ? 'Fixed' : '修复';
  }
}
