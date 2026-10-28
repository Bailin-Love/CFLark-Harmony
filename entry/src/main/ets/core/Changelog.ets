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
