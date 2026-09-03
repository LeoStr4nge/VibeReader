# VibeReader

跨平台本地小说阅读器，支持 Windows 与 Android。无需导入书库、无需账号，直接浏览文件夹打开 TXT/PDF 阅读；阅读进度、书签、标签全部本地持久化，并支持局域网多设备同步。

## 功能

### 阅读

- **TXT**：直接浏览文件夹打开（不强制入库）；中文小说章节自动识别（第X章/序章等常见格式）生成目录；后台 Isolate 分页缓存，左右翻页；进度条拖拽跳转
- **PDF**：基于 pdfrx 渲染，翻页/跳页/页码续读
- **阅读设置**：字号、行距、页边距、主题（含夜间），即改即生效并持久化
- **续读**：TXT 记录章节+字符偏移，PDF 记录页码，重新打开自动定位

### 书签与搜索

- 书签记录精确位置（TXT：字符偏移+章节；PDF：页码）及文字摘录
- 标签系统：书签可打多标签，书签中心支持跨书按标签筛选
- 全书架全文搜索：首次打开自动建立 500 字分段索引，后台构建不卡 UI

### 局域网同步

两台设备（如 Windows + Android）连同一 WiFi 即可互相同步：

- 同步范围：阅读进度、书签、标签、书文件本体（TXT/PDF）
- 自动发现：UDP 广播探测 + TCP 子网扫描兜底；也可手动输入 IP 连接
- 冲突解决：记录级时间戳 LWW（新者胜），删除通过墓碑传播
- 图书身份：按文件内容 MD5 识别，同一本书在不同设备不同路径/文件名也能正确匹配
- 传输可靠性：流式上传/下载带进度显示，落盘前 MD5 校验

### 数据存储

全部本地 SQLite，无任何云端依赖：

| 平台 | 数据库位置 |
|---|---|
| Windows | `%APPDATA%\com.novel\com.novel.reader\novel_reader\db\` |
| Android | 应用私有目录 |

同步下载的书籍存放于「文档/sync_incoming」；自行打开的书保持原位置不动。

## 技术栈

- [Flutter](https://flutter.dev)（Dart 3.13+）
- SQLite（`sqlite3` + `sqlite3_flutter_libs`，直接 SQL 无 ORM）
- [pdfrx](https://pub.dev/packages/pdfrx)（PDF 渲染）
- [shelf](https://pub.dev/packages/shelf) + [http](https://pub.dev/packages/http)（局域网同步的服务端/客户端）

## 项目结构

```
novel_reader/
├── lib/src/
│   ├── data/          # 数据层：SQLite 数据库、TXT 章节识别
│   ├── domain/        # 领域模型：Book、Bookmark、Progress、Settings
│   ├── presentation/  # UI：书架/文件/阅读/书签中心/搜索/同步页
│   ├── sync/          # 局域网同步：协议模型、合并器、服务端、客户端、UDP 发现
│   └── utils/         # 编码探测、内容哈希、格式工具
└── test/              # 单元测试（含同步合并收敛性、真实 HTTP 回环测试）
```

## 构建与运行

### Windows

```powershell
cd novel_reader
flutter pub get
flutter run -d windows          # 开发调试
flutter build windows --release # 发布构建
```

产物在 `build/windows/x64/runner/Release/`，双击 `novel_reader.exe` 即可运行（需与同目录 DLL 及 data 文件夹一起分发）。

### Android

```powershell
cd novel_reader
flutter run -d <device-id>
flutter build apk --release
```

需要 Android SDK；存储权限（Android 11+ 为「所有文件访问」）在首次进入文件视图时申请。

## 测试

```powershell
cd novel_reader
flutter test
```

覆盖：章节识别、编码探测（GBK/UTF-16）、分页哈希、数据库迁移与同步方法、合并收敛性、真实 HTTP 回环同步。

## 说明

- Android 端接收 UDP 广播需要 MulticastLock（已通过平台通道在开启同步服务时自动获取）
- 部分路由器开启「AP 隔离」会阻断设备间通信，需在路由器设置中关闭
- Release APK 目前使用 debug 签名，正式分发前请配置自己的签名
