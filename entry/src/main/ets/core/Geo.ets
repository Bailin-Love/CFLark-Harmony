/**
 * 数据中心（colo）地理信息表
 * 数据来源: https://www.baipiao.eu.org/cloudflare/locations （与原项目 CFData-WEB 一致）
 * 格式: IATA|City|CC2|Region，运行时解析为 Map
 */

/** 数据中心地理信息 */
export class GeoInfo {
  /** 三字码，如 HKG */
  iata: string;
  /** 城市英文名 */
  city: string;
  /** 国家/地区两位代码 */
  cc: string;
  /** 大区英文名 */
  region: string;

  constructor(iata: string, city: string, cc: string, region: string) {
    this.iata = iata;
    this.city = city;
    this.cc = cc;
    this.region = region;
  }
}

/** 原始数据行：IATA|City|CC2|Region */
const RAW: string[] = [
  'TIA|Tirana|AL|Europe',
  'ALG|Algiers|DZ|Africa',
  'AAE|Annaba|DZ|Africa',
  'CZL|Constantine|DZ|Africa',
  'ORN|Oran|DZ|Africa',
  'LAD|Luanda|AO|Africa',
  'EZE|Buenos Aires|AR|South America',
  'COR|Córdoba|AR|South America',
  'NQN|Neuquen|AR|South America',
  'EVN|Yerevan|AM|Middle East',
  'ADL|Adelaide|AU|Oceania',
  'BNE|Brisbane|AU|Oceania',
  'CBR|Canberra|AU|Oceania',
  'HBA|Hobart|AU|Oceania',
  'MEL|Melbourne|AU|Oceania',
  'PER|Perth|AU|Oceania',
  'SYD|Sydney|AU|Oceania',
  'VIE|Vienna|AT|Europe',
  'LLK|Astara|AZ|Middle East',
  'GYD|Baku|AZ|Middle East',
  'BAH|Manama|BH|Middle East',
  'CGP|Chittagong|BD|Asia Pacific',
  'DAC|Dhaka|BD|Asia Pacific',
  'BGI|Bridgetown|BB|North America',
  'MSQ|Minsk|BY|Europe',
  'BRU|Brussels|BE|Europe',
  'PBH|Thimphu|BT|Asia Pacific',
  'LPB|La Paz|BO|South America',
  'GBE|Gaborone|BW|Africa',
  'QWJ|Americana|BR|South America',
  'ARU|Aracatuba|BR|South America',
  'BEL|Belém|BR|South America',
  'CNF|Belo Horizonte|BR|South America',
  'BNU|Blumenau|BR|South America',
  'BSB|Brasilia|BR|South America',
  'CFC|Cacador|BR|South America',
  'VCP|Campinas|BR|South America',
  'CAW|Campos dos Goytacazes|BR|South America',
  'XAP|Chapeco|BR|South America',
  'CGB|Cuiaba|BR|South America',
  'CWB|Curitiba|BR|South America',
  'FLN|Florianopolis|BR|South America',
  'FOR|Fortaleza|BR|South America',
  'GYN|Goiania|BR|South America',
  'JOI|Joinville|BR|South America',
  'JDO|Juazeiro do Norte|BR|South America',
  'MAO|Manaus|BR|South America',
  'PMW|Palmas|BR|South America',
  'POA|Porto Alegre|BR|South America',
  'REC|Recife|BR|South America',
  'RAO|Ribeirao Preto|BR|South America',
  'GIG|Rio de Janeiro|BR|South America',
  'SSA|Salvador|BR|South America',
  'SJP|São José do Rio Preto|BR|South America',
  'SJK|São José dos Campos|BR|South America',
  'GRU|São Paulo|BR|South America',
  'SOD|Sorocaba|BR|South America',
  'NVT|Timbo|BR|South America',
  'UDI|Uberlandia|BR|South America',
  'VIX|Vitoria|BR|South America',
  'BWN|Bandar Seri Begawan|BN|Asia Pacific',
  'SOF|Sofia|BG|Europe',
  'OUA|Ouagadougou|BF|Africa',
  'PNH|Phnom Penh|KH|Asia Pacific',
  'YYC|Calgary|CA|North America',
  'YVR|Vancouver|CA|North America',
  'YWG|Winnipeg|CA|North America',
  'YHZ|Halifax|CA|North America',
  'YOW|Ottawa|CA|North America',
  'YYZ|Toronto|CA|North America',
  'YUL|Montréal|CA|North America',
  'YXE|Saskatoon|CA|North America',
  'ARI|Arica|CL|South America',
  'CCP|Concepción|CL|South America',
  'SCL|Santiago|CL|South America',
  'BAQ|Barranquilla|CO|South America',
  'BOG|Bogota|CO|South America',
  'CLO|Cali|CO|South America',
  'MDE|Medellín|CO|South America',
  'FIH|Kinshasa|CD|Africa',
  'SJO|San José|CR|South America',
  'ABJ|Abidjan|CI|Africa',
  'ASK|Yamoussoukro|CI|Africa',
  'ZAG|Zagreb|HR|Europe',
  'LCA|Nicosia|CY|Europe',
  'PRG|Prague|CZ|Europe',
  'CPH|Copenhagen|DK|Europe',
  'JIB|Djibouti|DJ|Africa',
  'STI|Santiago de los Caballeros|DO|North America',
  'SDQ|Santo Domingo|DO|North America',
  'GYE|Guayaquil|EC|South America',
  'UIO|Quito|EC|South America',
  'CAI|Cairo|EG|Africa',
  'TLL|Tallinn|EE|Europe',
  'ADD|Addis Ababa|ET|Africa',
  'SUV|Suva|FJ|Oceania',
  'HEL|Helsinki|FI|Europe',
  'BOD|Bordeaux|FR|Europe',
  'LYS|Lyon|FR|Europe',
  'MRS|Marseille|FR|Europe',
  'CDG|Paris|FR|Europe',
  'PPT|Tahiti|PF|Oceania',
  'TBS|Tbilisi|GE|Europe',
  'TXL|Berlin|DE|Europe',
  'DUS|Düsseldorf|DE|Europe',
  'FRA|Frankfurt|DE|Europe',
  'HAM|Hamburg|DE|Europe',
  'MUC|Munich|DE|Europe',
  'STR|Stuttgart|DE|Europe',
  'ACC|Accra|GH|Africa',
  'ATH|Athens|GR|Europe',
  'SKG|Thessaloniki|GR|Europe',
  'GND|St. Georges|GD|South America',
  'GUM|Hagatna|GU|Asia Pacific',
  'GUA|Guatemala City|GT|North America',
  'GEO|Georgetown|GY|South America',
  'SAP|San Pedro Sula|HN|South America',
  'TGU|Tegucigalpa|HN|South America',
  'HKG|Hong Kong|HK|Asia Pacific',
  'BUD|Budapest|HU|Europe',
  'KEF|Reykjavík|IS|Europe',
  'AMD|Ahmedabad|IN|Asia Pacific',
  'BLR|Bangalore|IN|Asia Pacific',
  'IXC|Chandigarh|IN|Asia Pacific',
  'MAA|Chennai|IN|Asia Pacific',
  'HYD|Hyderabad|IN|Asia Pacific',
  'CNN|Kannur|IN|Asia Pacific',
  'KNU|Kanpur|IN|Asia Pacific',
  'COK|Kochi|IN|Asia Pacific',
  'CCU|Kolkata|IN|Asia Pacific',
  'BOM|Mumbai|IN|Asia Pacific',
  'NAG|Nagpur|IN|Asia Pacific',
  'DEL|New Delhi|IN|Asia Pacific',
  'PAT|Patna|IN|Asia Pacific',
  'DPS|Denpasar|ID|Asia Pacific',
  'CGK|Jakarta|ID|Asia Pacific',
  'MLG|Malang|ID|Asia Pacific',
  'JOG|Yogyakarta|ID|Asia Pacific',
  'BGW|Baghdad|IQ|Middle East',
  'BSR|Basra|IQ|Middle East',
  'EBL|Erbil|IQ|Middle East',
  'NJF|Najaf|IQ|Middle East',
  'XNH|Nasiriyah|IQ|Middle East',
  'ISU|Sulaymaniyah|IQ|Middle East',
  'DUB|Dublin|IE|Europe',
  'HFA|Haifa|IL|Middle East',
  'TLV|Tel Aviv|IL|Middle East',
  'MXP|Milan|IT|Europe',
  'PMO|Palermo|IT|Europe',
  'FCO|Rome|IT|Europe',
  'KIN|Kingston|JM|North America',
  'FUK|Fukuoka|JP|Asia Pacific',
  'OKA|Naha|JP|Asia Pacific',
  'KIX|Osaka|JP|Asia Pacific',
  'NRT|Tokyo|JP|Asia Pacific',
  'AMM|Amman|JO|Middle East',
  'AKX|Aktobe|KZ|Europe',
  'ALA|Almaty|KZ|Europe',
  'NQZ|Astana|KZ|Europe',
  'MBA|Mombasa|KE|Africa',
  'NBO|Nairobi|KE|Africa',
  'ICN|Seoul|KR|Asia Pacific',
  'KWI|Kuwait City|KW|Middle East',
  'FRU|Bishkek|KG|Asia Pacific',
  'VTE|Vientiane|LA|Asia Pacific',
  'RIX|Riga|LV|Europe',
  'BEY|Beirut|LB|Middle East',
  'VNO|Vilnius|LT|Europe',
  'LUX|Luxembourg City|LU|Europe',
  'MFM|Macau|MO|Asia Pacific',
  'TNR|Antananarivo|MG|Africa',
  'LLW|Lilongwe|MW|Africa',
  'JHB|Johor Bahru|MY|Asia Pacific',
  'KUL|Kuala Lumpur|MY|Asia Pacific',
  'KCH|Kuching|MY|Asia Pacific',
  'MLE|Male|MV|Asia Pacific',
  'MLA|Santa Venera|MT|Europe',
  'MRU|Port Louis|MU|Africa',
  'GDL|Guadalajara|MX|North America',
  'MEX|Mexico City|MX|North America',
  'QRO|Queretaro|MX|North America',
  'KIV|Chișinău|MD|Europe',
  'ULN|Ulaanbaatar|MN|Asia Pacific',
  'MPM|Maputo|MZ|Africa',
  'WDH|Windhoek|NA|Africa',
  'KTM|Kathmandu|NP|Asia Pacific',
  'AMS|Amsterdam|NL|Europe',
  'NOU|Noumea|NC|Oceania',
  'AKL|Auckland|NZ|Oceania',
  'CHC|Christchurch|NZ|Oceania',
  'LOS|Lagos|NG|Africa',
  'SKP|Skopje|MK|Europe',
  'OSL|Oslo|NO|Europe',
  'MCT|Muscat|OM|Middle East',
  'ISB|Islamabad|PK|Asia Pacific',
  'KHI|Karachi|PK|Asia Pacific',
  'LHE|Lahore|PK|Asia Pacific',
  'ZDM|Ramallah|PS|Middle East',
  'PTY|Panama City|PA|South America',
  'ASU|Asunción|PY|South America',
  'LIM|Lima|PE|South America',
  'CGY|Cagayan de Oro|PH|Asia Pacific',
  'CEB|Cebu|PH|Asia Pacific',
  'MNL|Manila|PH|Asia Pacific',
  'CRK|Tarlac City|PH|Asia Pacific',
  'WAW|Warsaw|PL|Europe',
  'WRO|Wroclaw|PL|Europe',
  'LIS|Lisbon|PT|Europe',
  'SJU|San Juan|PR|North America',
  'DOH|Doha|QA|Middle East',
  'RUN|Saint-Denis|RE|Africa',
  'OTP|Bucharest|RO|Europe',
  'KJA|Krasnoyarsk|RU|Asia Pacific',
  'DME|Moscow|RU|Europe',
  'LED|Saint Petersburg|RU|Europe',
  'KGL|Kigali|RW|Africa',
  'DMM|Dammam|SA|Middle East',
  'JED|Jeddah|SA|Middle East',
  'RUH|Riyadh|SA|Middle East',
  'DKR|Dakar|SN|Africa',
  'BEG|Belgrade|RS|Europe',
  'SIN|Singapore|SG|Asia Pacific',
  'BTS|Bratislava|SK|Europe',
  'CPT|Cape Town|ZA|Africa',
  'DUR|Durban|ZA|Africa',
  'JNB|Johannesburg|ZA|Africa',
  'BCN|Barcelona|ES|Europe',
  'MAD|Madrid|ES|Europe',
  'CMB|Colombo|LK|Asia Pacific',
  'PBM|Paramaribo|SR|South America',
  'GOT|Gothenburg|SE|Europe',
  'ARN|Stockholm|SE|Europe',
  'GVA|Geneva|CH|Europe',
  'ZRH|Zurich|CH|Europe',
  'KHH|Kaohsiung City|TW|Asia Pacific',
  'TPE|Taipei|TW|Asia Pacific',
  'DAR|Dar es Salaam|TZ|Africa',
  'BKK|Bangkok|TH|Asia Pacific',
  'CNX|Chiang Mai|TH|Asia Pacific',
  'URT|Surat Thani|TH|Asia Pacific',
  'POS|Port of Spain|TT|South America',
  'TUN|Tunis|TN|Africa',
  'IST|Istanbul|TR|Europe',
  'ADB|Izmir|TR|Europe',
  'EBB|Kampala|UG|Africa',
  'KBP|Kyiv|UA|Europe',
  'DXB|Dubai|AE|Middle East',
  'LHR|London|GB|Europe',
  'MAN|Manchester|GB|Europe',
  'ANC|Anchorage|US|North America',
  'PHX|Phoenix|US|North America',
  'LAX|Los Angeles|US|North America',
  'SMF|Sacramento|US|North America',
  'SAN|San Diego|US|North America',
  'SFO|San Francisco|US|North America',
  'SJC|San Jose|US|North America',
  'DEN|Denver|US|North America',
  'JAX|Jacksonville|US|North America',
  'MIA|Miami|US|North America',
  'TLH|Tallahassee|US|North America',
  'TPA|Tampa|US|North America',
  'ATL|Atlanta|US|North America',
  'HNL|Honolulu|US|North America',
  'ORD|Chicago|US|North America',
  'IND|Indianapolis|US|North America',
  'BGR|Bangor|US|North America',
  'BOS|Boston|US|North America',
  'DTW|Detroit|US|North America',
  'MSP|Minneapolis|US|North America',
  'MCI|Kansas City|US|North America',
  'STL|St. Louis|US|North America',
  'OMA|Omaha|US|North America',
  'LAS|Las Vegas|US|North America',
  'EWR|Newark|US|North America',
  'ABQ|Albuquerque|US|North America',
  'BUF|Buffalo|US|North America',
  'CLT|Charlotte|US|North America',
  'RDU|Durham|US|North America',
  'CLE|Cleveland|US|North America',
  'CMH|Columbus|US|North America',
  'OKC|Oklahoma City|US|North America',
  'PDX|Portland|US|North America',
  'PHL|Philadelphia|US|North America',
  'PIT|Pittsburgh|US|North America',
  'FSD|Sioux Falls|US|North America',
  'MEM|Memphis|US|North America',
  'BNA|Nashville|US|North America',
  'AUS|Austin|US|North America',
  'DFW|Dallas|US|North America',
  'IAH|Houston|US|North America',
  'SAT|San Antonio|US|North America',
  'SLC|Salt Lake City|US|North America',
  'IAD|Ashburn|US|North America',
  'ORF|Norfolk|US|North America',
  'RIC|Richmond|US|North America',
  'SEA|Seattle|US|North America',
  'DAD|Da Nang|VN|Asia Pacific',
  'HAN|Hanoi|VN|Asia Pacific',
  'SGN|Ho Chi Minh City|VN|Asia Pacific',
  'LUN|Lusaka|ZM|Africa',
  'HRE|Harare|ZW|Africa',
];

/** 大区英文名 -> 中文 */

/** 常用 Cloudflare 数据中心所在城市的中文名（IATA → 中文），缺失时回退英文城市名 */
const CITY_ZH: Map<string, string> = new Map<string, string>([
  ['HKG', '香港'], ['MFM', '澳门'], ['TPE', '台北'], ['KHH', '高雄'], ['TSA', '台北'],
  ['NRT', '东京'], ['HND', '东京'], ['KIX', '大阪'], ['ITM', '大阪'], ['NGO', '名古屋'],
  ['CTS', '札幌'], ['FUK', '福冈'], ['ICN', '首尔'], ['SIN', '新加坡'],
  ['CAN', '广州'], ['SZX', '深圳'], ['PVG', '上海'], ['PEK', '北京'], ['CTU', '成都'],
  ['MNL', '马尼拉'], ['CEB', '宿务'], ['BKK', '曼谷'], ['HKT', '普吉'], ['CNX', '清迈'],
  ['KUL', '吉隆坡'], ['CGK', '雅加达'], ['DPS', '巴厘岛'], ['SGN', '胡志明'], ['HAN', '河内'],
  ['DEL', '德里'], ['BOM', '孟买'], ['BLR', '班加罗尔'], ['MAA', '金奈'], ['CCU', '加尔各答'],
  ['CMB', '科伦坡'], ['DAC', '达卡'], ['KHI', '卡拉奇'], ['LHE', '拉合尔'],
  ['TAS', '塔什干'], ['ALA', '阿拉木图'], ['DXB', '迪拜'], ['AUH', '阿布扎比'],
  ['DOH', '多哈'], ['RUH', '利雅得'], ['JED', '吉达'], ['TLV', '特拉维夫'],
  ['KWI', '科威特'], ['BAH', '麦纳麦'], ['MCT', '马斯喀特'], ['AMM', '安曼'],
  ['BEY', '贝鲁特'], ['IST', '伊斯坦布尔'], ['ESB', '安卡拉'],
  ['LHR', '伦敦'], ['LGW', '伦敦'], ['MAN', '曼彻斯特'], ['DUB', '都柏林'],
  ['CDG', '巴黎'], ['MRS', '马赛'], ['AMS', '阿姆斯特丹'], ['FRA', '法兰克福'],
  ['MUC', '慕尼黑'], ['BER', '柏林'], ['DUS', '杜塞尔多夫'], ['ZRH', '苏黎世'],
  ['VIE', '维也纳'], ['MXP', '米兰'], ['FCO', '罗马'], ['MAD', '马德里'],
  ['BCN', '巴塞罗那'], ['LIS', '里斯本'], ['ARN', '斯德哥尔摩'], ['OSL', '奥斯陆'],
  ['CPH', '哥本哈根'], ['HEL', '赫尔辛基'], ['WAW', '华沙'], ['PRG', '布拉格'],
  ['BUD', '布达佩斯'], ['BUH', '布加勒斯特'], ['SOF', '索菲亚'], ['ATH', '雅典'],
  ['BRU', '布鲁塞尔'], ['KEF', '雷克雅未克'], ['LED', '圣彼得堡'], ['DME', '莫斯科'],
  ['SVO', '莫斯科'], ['KBP', '基辅'],
  ['LAX', '洛杉矶'], ['SJC', '圣何塞'], ['SFO', '旧金山'], ['SEA', '西雅图'],
  ['PDX', '波特兰'], ['DEN', '丹佛'], ['SLC', '盐湖城'], ['DFW', '达拉斯'],
  ['IAH', '休斯顿'], ['AUS', '奥斯汀'], ['ORD', '芝加哥'], ['ATL', '亚特兰大'],
  ['MIA', '迈阿密'], ['MCO', '奥兰多'], ['IAD', '华盛顿'], ['DCA', '华盛顿'],
  ['EWR', '纽瓦克'], ['JFK', '纽约'], ['LGA', '纽约'], ['BOS', '波士顿'],
  ['PHL', '费城'], ['DTW', '底特律'], ['MSP', '明尼阿波利斯'], ['PHX', '凤凰城'],
  ['LAS', '拉斯维加斯'], ['SAN', '圣地亚哥'], ['YYZ', '多伦多'], ['YVR', '温哥华'],
  ['YUL', '蒙特利尔'], ['YYC', '卡尔加里'],
  ['GRU', '圣保罗'], ['GIG', '里约热内卢'], ['EZE', '布宜诺斯艾利斯'], ['SCL', '圣地亚哥'],
  ['BOG', '波哥大'], ['LIM', '利马'], ['UIO', '基多'], ['MEX', '墨西哥城'],
  ['CUN', '坎昆'], ['PTY', '巴拿马城'], ['SJO', '圣何塞'],
  ['SYD', '悉尼'], ['MEL', '墨尔本'], ['BNE', '布里斯班'], ['PER', '珀斯'],
  ['ADL', '阿德莱德'], ['AKL', '奥克兰'],
  ['JNB', '约翰内斯堡'], ['CPT', '开普敦'], ['DUR', '德班'], ['LOS', '拉各斯'],
  ['NBO', '内罗毕'], ['CAI', '开罗'], ['CMN', '卡萨布兰卡'], ['TUN', '突尼斯'],
  ['ALG', '阿尔及尔'], ['ACC', '阿克拉'], ['DAR', '达累斯萨拉姆'], ['ADD', '亚的斯亚贝巴']
]);

/** 国家/地区两位代码 -> 中文名（订阅上传备注用） */
const COUNTRY_ZH: Map<string, string> = new Map<string, string>([
  ['SG', '新加坡'], ['JP', '日本'], ['TW', '台湾'], ['HK', '香港'], ['MO', '澳门'], ['KR', '韩国'],
  ['US', '美国'], ['CA', '加拿大'], ['GB', '英国'], ['DE', '德国'], ['FR', '法国'], ['NL', '荷兰'],
  ['AU', '澳大利亚'], ['NZ', '新西兰'], ['IN', '印度'], ['ID', '印度尼西亚'], ['MY', '马来西亚'],
  ['TH', '泰国'], ['VN', '越南'], ['PH', '菲律宾'], ['BR', '巴西'], ['AR', '阿根廷'], ['CL', '智利'],
  ['MX', '墨西哥'], ['RU', '俄罗斯'], ['TR', '土耳其'], ['AE', '阿联酋'], ['SA', '沙特阿拉伯'],
  ['IL', '以色列'], ['ZA', '南非'], ['EG', '埃及'], ['NG', '尼日利亚'], ['KE', '肯尼亚'],
  ['IT', '意大利'], ['ES', '西班牙'], ['PT', '葡萄牙'], ['CH', '瑞士'], ['SE', '瑞典'], ['NO', '挪威'],
  ['DK', '丹麦'], ['FI', '芬兰'], ['PL', '波兰'], ['CZ', '捷克'], ['AT', '奥地利'], ['BE', '比利时'],
  ['IE', '爱尔兰'], ['UA', '乌克兰'], ['RO', '罗马尼亚'], ['GR', '希腊'], ['HU', '匈牙利'],
  ['BG', '保加利亚'], ['HR', '克罗地亚'], ['RS', '塞尔维亚'], ['SK', '斯洛伐克'], ['SI', '斯洛文尼亚'],
  ['LT', '立陶宛'], ['LV', '拉脱维亚'], ['EE', '爱沙尼亚'], ['CY', '塞浦路斯'], ['MT', '马耳他'],
  ['LU', '卢森堡'], ['IS', '冰岛'], ['QA', '卡塔尔'], ['KW', '科威特'], ['BH', '巴林'], ['OM', '阿曼'],
  ['JO', '约旦'], ['LB', '黎巴嫩'], ['IQ', '伊拉克'], ['KZ', '哈萨克斯坦'], ['PK', '巴基斯坦'],
  ['BD', '孟加拉国'], ['LK', '斯里兰卡'], ['NP', '尼泊尔'], ['KH', '柬埔寨'], ['LA', '老挝'],
  ['MM', '缅甸'], ['BN', '文莱'], ['MN', '蒙古'], ['UZ', '乌兹别克斯坦'], ['KG', '吉尔吉斯斯坦'],
  ['CO', '哥伦比亚'], ['PE', '秘鲁'], ['EC', '厄瓜多尔'], ['VE', '委内瑞拉'], ['UY', '乌拉圭'],
  ['PY', '巴拉圭'], ['BO', '玻利维亚'], ['CR', '哥斯达黎加'], ['PA', '巴拿马'], ['GT', '危地马拉'],
  ['DO', '多米尼加'], ['PR', '波多黎各'], ['CU', '古巴'], ['JM', '牙买加'], ['TT', '特立尼达和多巴哥'],
  ['RE', '留尼汪'], ['MU', '毛里求斯'], ['MA', '摩洛哥'], ['TN', '突尼斯'], ['DZ', '阿尔及利亚'],
  ['GH', '加纳'], ['ET', '埃塞俄比亚'], ['TZ', '坦桑尼亚'], ['UG', '乌干达'], ['RW', '卢旺达'],
  ['SN', '塞内加尔'], ['CI', '科特迪瓦'], ['CM', '喀麦隆'], ['ZW', '津巴布韦'], ['ZM', '赞比亚'],
  ['MZ', '莫桑比克'], ['AO', '安哥拉'], ['NA', '纳米比亚'], ['BW', '博茨瓦纳'], ['MG', '马达加斯加'],
  ['FJ', '斐济'], ['PG', '巴布亚新几内亚'], ['NC', '新喀里多尼亚'], ['PF', '法属波利尼西亚'],
  ['GU', '关岛'], ['BQ', '荷兰加勒比区'], ['KY', '开曼群岛'], ['BM', '百慕大']
]);
const REGION_ZH: Map<string, string> = new Map<string, string>([
  ['Asia Pacific', '亚太'],
  ['Europe', '欧洲'],
  ['North America', '北美'],
  ['South America', '南美'],
  ['Africa', '非洲'],
  ['Oceania', '大洋洲'],
  ['Middle East', '中东']
]);

/** 数据中心地理查询 */
export class Geo {
  private static map: Map<string, GeoInfo> | null = null;

  /** 懒加载解析原始表 */
  private static ensure(): Map<string, GeoInfo> {
    if (Geo.map !== null) {
      return Geo.map;
    }
    const m: Map<string, GeoInfo> = new Map<string, GeoInfo>();
    for (let i = 0; i < RAW.length; i++) {
      const parts: string[] = RAW[i].split('|');
      if (parts.length < 4) {
        continue;
      }
      m.set(parts[0], new GeoInfo(parts[0], parts[1], parts[2], parts[3]));
    }
    Geo.map = m;
    return m;
  }

  /** 按 colo 代码查询，未找到返回 null */
  static lookup(colo: string): GeoInfo | null {
    if (colo === undefined || colo === null || colo.length === 0) {
      return null;
    }
    const hit: GeoInfo | undefined = Geo.ensure().get(colo.toUpperCase());
    return hit === undefined ? null : hit;
  }

  /** 城市名，未知返回空串 */
  static city(colo: string): string {
    const g: GeoInfo | null = Geo.lookup(colo);
    return g === null ? '' : g.city;
  }

  /** 城市中文名（优先查内置中文表，缺失回退英文） */
  static cityZh(colo: string): string {
    const z: string | undefined = CITY_ZH.get(colo.toUpperCase());
    if (z !== undefined) {
      return z;
    }
    return Geo.city(colo);
  }

  /** 地区码 + 中文名，例如 "HKG 香港" */
  static placeZh(colo: string): string {
    const z: string = Geo.cityZh(colo);
    if (z.length === 0) {
      return colo;
    }
    return colo + ' ' + z;
  }
  /** 数据中心所在国家/地区两位代码，未知返回空串 */
  static countryCode(colo: string): string {
    const g: GeoInfo | null = Geo.lookup(colo);
    if (g === null || g.cc.length === 0) {
      return '';
    }
    return g.cc.toUpperCase();
  }

  /** 两位国家/地区代码的中文名，未知返回空串 */
  static countryZh(cc: string): string {
    if (cc === undefined || cc === null || cc.length === 0) {
      return '';
    }
    const z: string | undefined = COUNTRY_ZH.get(cc.toUpperCase());
    return z === undefined ? '' : z;
  }

  /** 国家/地区旗帜 emoji，未知返回空串 */
  static flag(colo: string): string {
    const g: GeoInfo | null = Geo.lookup(colo);
    if (g === null || g.cc.length !== 2) {
      return '';
    }
    const base: number = 0x1F1E6;
    const up: string = g.cc.toUpperCase();
    const a: number = up.charCodeAt(0) - 65;
    const b: number = up.charCodeAt(1) - 65;
    return String.fromCodePoint(base + a) + String.fromCodePoint(base + b);
  }

  /** 大区中文名，未知返回空串 */
  static regionZh(colo: string): string {
    const g: GeoInfo | null = Geo.lookup(colo);
    if (g === null) {
      return '';
    }
    const zh: string | undefined = REGION_ZH.get(g.region);
    return zh === undefined ? g.region : zh;
  }

  /** 已收录数据中心数量 */
  static size(): number {
    return Geo.ensure().size;
  }
}