/**
 * 全局「功能说明」文案中心
 *
 * 页面里只保留必要的操作信息（参数名、输入框、运行状态、错误与风险提示），
 * 参数原理、功能用途、较长的操作说明统一收进感叹号按钮的弹窗里，
 * 文案全部集中在这里，中英文成对维护，避免同一句话散落在多处。
 *
 * 文案中的 {cap} / {ping} / {latency} / {rounds} / {window} 等占位符
 * 由页面在渲染前用当前真实状态替换，保证说明与实际配置一致。
 */

export const HELP_FILTER: string = 'filter';
export const HELP_SOURCE: string = 'source';
export const HELP_SPEED: string = 'speed';
export const HELP_UPLOAD: string = 'upload';
export const HELP_MATERIAL: string = 'material';
export const HELP_DIAG: string = 'diag';
export const HELP_RUNTIME: string = 'runtime';

export class HelpText {
  /** 弹窗标题（与入口的无障碍描述共用） */
  static title(key: string, en: boolean): string {
    if (key === HELP_SOURCE) {
      return en ? 'Candidate sources' : '候选来源说明';
    }
    if (key === HELP_SPEED) {
      return en ? 'Speed test notes' : '测速说明';
    }
    if (key === HELP_UPLOAD) {
      return en ? 'Subscription upload' : '订阅上传说明';
    }
    if (key === HELP_MATERIAL) {
      return en ? 'Immersive material' : '沉浸材质与光感';
    }
    if (key === HELP_RUNTIME) {
      return en ? 'Runtime notes' : '运行说明';
    }
    if (key === HELP_DIAG) {
      return en ? 'Network diagnostics' : '网络诊断说明';
    }
    return en ? 'Parameter notes' : '参数说明';
  }

  /** 弹窗正文：每项一段，长文本由弹窗自身换行/滚动 */
  static body(key: string, en: boolean): string[] {
    if (key === HELP_SOURCE) {
      if (en) {
        return [
          'Official and community ranges are built-in read-only sources; they cannot be edited or deleted.',
          'A custom group may contain several sources of mixed kinds: link, file and pasted text.',
          'Imports are validated against the current IP version: the IPv4 page only accepts IPv4 ranges and the IPv6 page only accepts IPv6 ranges. Lines of the wrong type are rejected with a reason.',
          'Link sources can be refreshed in one tap. A failed source stays in the list with its reason and is not counted as enabled.'
        ];
      }
      return [
        '官方 IP 段与社区段库为内置只读来源，不允许编辑或删除。',
        '一个自定义分组可包含多个来源，链接、文件、文本三种方式可以混用。',
        '导入时按当前 IP 版本严格校验：IPv4 页面只接受 IPv4 网段，IPv6 页面只接受 IPv6 网段；类型不符的行会被拒绝并给出原因。',
        '链接来源支持一键更新；解析失败的来源会保留在列表里并标注原因，不计入启用来源。'
      ];
    }
    if (key === HELP_SPEED) {
      if (en) {
        return [
          'Full test: round 1 addresses are sorted by latency, lowest first, and only the top N are tested (default 10, range 1-99); the upload count can be limited in Settings - Subscription upload.',
          'Region test: groups by region and speed-tests the few lowest-latency addresses in each region; covers all regions.',
          'Each address is tested {rounds} times and the results averaged; each download window is {window}ms. Keep rounds at 10 or fewer, otherwise the total takes a long time.',
          'The test domain is used for the Host/SNI check and its A (IPv4)/AAAA (IPv6) records are resolved into candidates; if blank, speed.cloudflare.com is used.'
        ];
      }
      return [
        '完全测速：第一轮通过的地址按延迟从低到高排序，只测前 N 个（默认 10，范围 1~99）；上传数量可在「设置 → 订阅上传」限制。',
        '地区测速：按地区分组，每个地区各取延迟最低的前几个地址测速；覆盖所有地区。',
        '每个地址测 {rounds} 次取平均，单次下载窗口 {window}ms。建议次数不超过 10，否则总耗时很长。',
        '测速域名用于 Host/SNI 校验，并自动解析其 A（IPv4）/AAAA（IPv6）记录并入候选；留空则用 speed.cloudflare.com。'
      ];
    }
    if (key === HELP_UPLOAD) {
      if (en) {
        return [
          'Upload format: "IP:port#region V4/V6NameIndex", e.g. 162.159.9.26:443#SG V4Singapore1.',
          'Login upload: signs in to edgetunnel with the domain and dashboard password. Set "Preferred subscription mode" to custom subscription in edgetunnel; more nodes is not always better.',
          'API direct upload: reads and writes the Worker-bound KV directly (key ADD.txt). The token is stored only on this device and needs Workers KV read/write permission for that account.'
        ];
      }
      return [
        '上传格式为「IP:端口#地区 V4/V6中文名序号」，例如 162.159.9.26:443#SG V4新加坡1。',
        '登录上传：用域名与后台密码登录 edgetunnel 后写入；edgetunnel 需把「优选订阅模式」设为自定义订阅，节点不是越多越好。',
        'API 直传：直接读写 Worker 绑定的 KV（键 ADD.txt）；Token 只保存在本机，需要该 Account 的 Workers KV 读写权限。'
      ];
    }
    if (key === HELP_MATERIAL) {
      if (en) {
        return [
          'Global immersive material: when off, cards and the bottom navigation stop using the system material and fall back to ordinary blurred glass.',
          'Type: adaptive picks by device capability, immersive forces the system material, none adds no material layer.',
          'Level: adaptive picks by device tier; refined / soft / flat map to different thickness and blur.'
        ];
      }
      return [
        '全局沉浸光感：关闭后卡片与底部导航不再使用系统沉浸材质，改用普通模糊玻璃。',
        '类型：自适应按设备能力选择，沉浸强制使用系统沉浸材质，无材质则不加材质层。',
        '等级：自适应按设备等级选择；精致 / 柔和 / 平滑对应不同的厚度与模糊强度。'
      ];
    }
    if (key === HELP_RUNTIME) {
      if (en) {
        return [
          'When on, scans, speed tests and uploads keep running after switching to the background: phones and tablets use a DATA_TRANSFER continuous task, PC prefers a compute task.',
          'When off, the system default background policy applies and the task may be paused shortly after switching away.'
        ];
      }
      return [
        '开启后扫描 / 测速 / 上传期间切到后台不中断：手机与平板使用数据传输连续任务，PC 优先计算任务。',
        '关闭后使用系统默认后台策略，切到后台可能很快被暂停。'
      ];
    }
    if (key === HELP_DIAG) {
      if (en) {
        return [
          'Network diagnostics help distinguish: app socket issues / carrier routing issues / unreachable random addresses / timeouts that are too short / an overly strict latency threshold.',
          'The self-test always uses a 3000ms timeout and runs sequentially; it does not change scan settings.'
        ];
      }
      return [
        '网络诊断用于区分：应用 Socket 问题 / 运营商路由问题 / 随机地址不可达 / 超时过短 / 延迟门槛过严。',
        '自检固定使用 3000ms 超时、顺序执行，不会修改扫描配置。'
      ];
    }
    if (en) {
      return [
        'Samples: 3000 for both IPv4 and IPv6; if random addresses have a low hit rate, sample domain AAAA records instead.',
        'Concurrency cap: 120 on phones / 200 on tablets / 300 on computers (this device: {cap}). Values above it are reset to the cap automatically.',
        '{latency}',
        'Each IP gets {ping} TCP samples, keeping the minimum; nodes above the latency cap are dropped. IPv4 and IPv6 share the same cap.',
        'Min speed: after the round 1 pre-filter, nodes below this value are eliminated one by one in ascending latency order, and the process stops early if the target cannot be filled (0 = no elimination).'
      ];
    }
    return [
      '采样数：本次扫描最多生成多少个候选地址，IPv4/IPv6 通用（默认 3000）。填 0 表示采样全部段：官方段库每个 /24（IPv6 每个 /48）各取 1 个，社区与自定义来源每一行各取 1 个，候选量会明显变大，扫描也更久。',
      '并发上限：手机 120 / 平板 200 / 电脑 300（当前设备 {cap}），超过会自动改回上限。',
      '{latency}',
      '每个 IP 连 {ping} 次 TCP 取最小值；超过延迟上限直接淘汰，IPv4/IPv6 共用同一上限。',
      '合格速度：低于该值的节点在第一轮初筛后按延迟从低到高逐个淘汰，凑不满会提前中止（0 = 不淘汰）。'
    ];
  }
}
