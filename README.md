# VibeReader 原型（novel_reader）

目标：做一个可在 Windows 11 与 Android 运行的小说阅读器原型，优先把 TXT 阅读体验做完整，PDF 先做到可用与续读。

## 当前状态

- Flutter 工程已创建：`./novel_reader`
- 已跑通 Windows 构建：`flutter build windows --debug` 通过
- 已实现最小可用闭环：
  - 文件视图：选择文件夹 → 浏览 TXT/PDF → 打开阅读
  - TXT：分页缓存 + 左右翻页（PageView）+ 续读（保存 charOffset）
  - PDF：阅读页占位（仅展示路径，后续接入渲染）
  - 书架：展示最近阅读列表，点击继续阅读
- Android：`flutter doctor` 提示 cmdline-tools/SDK license 未完善，不影响 Windows 端继续开发；Android 真机/模拟器运行前需补齐

## 环境准备（Windows 11）

1. 安装 Flutter SDK
   - 下载：https://flutter.dev/docs/get-started/install/windows
   - 解压到：`C:\src\flutter`（示例）
   - 将 `C:\src\flutter\bin` 加入系统 PATH，重新打开终端
   - 运行 `flutter doctor`，确保能正常执行

2. 启用 Windows 桌面开发（用于先跑通 Windows 端）
   - 安装 Visual Studio 2022（或 Build Tools），勾选 **Desktop development with C++**
   - 运行 `flutter doctor`，确认 Windows toolchain 正常

3. Android（可后置）
   - 安装 Android Studio + Android SDK
   - `flutter doctor` 按提示补齐 Android toolchain

## 运行（Windows）

```powershell
cd novel_reader
flutter pub get
flutter run -d windows
```

## 原型范围（A 路线）

- TXT：章节识别目录、分页缓存、左右翻页、主题/字体/字号/行距/页边距、进度条切片跳转、自动翻页、续读
- PDF：打开/翻页/跳页/续读（目录若 PDF 自带则展示）
- 文件视图：直接浏览文件夹打开阅读（不强制入库）
- 书签 + 标签：专门入口聚合展示
- 搜索：当前书 + 全书架（后台索引）
- 同步：局域网同步进度/书签/标签/元信息（文件传输可后置）

## 仓库结构

- `novel_reader/`：Flutter 工程（主开发目录）
- `README.md`：交接/总体说明（本文件）

## 已实现功能（对应代码入口）

- App 路由与启动：[app.dart](file:///c:/Users/Leo/Desktop/code/VibeReader/novel_reader/lib/src/app.dart)、[main.dart](file:///c:/Users/Leo/Desktop/code/VibeReader/novel_reader/lib/main.dart)
- 书架（最近阅读）：[library_page.dart](file:///c:/Users/Leo/Desktop/code/VibeReader/novel_reader/lib/src/presentation/library/library_page.dart)
- 文件视图（选择文件夹/打开书）：[files_page.dart](file:///c:/Users/Leo/Desktop/code/VibeReader/novel_reader/lib/src/presentation/files/files_page.dart)
- 阅读页（TXT/PDF）：[reader_page.dart](file:///c:/Users/Leo/Desktop/code/VibeReader/novel_reader/lib/src/presentation/reader/reader_page.dart)
- SQLite 数据库与表结构：[app_database.dart](file:///c:/Users/Leo/Desktop/code/VibeReader/novel_reader/lib/src/data/db/app_database.dart)

## 数据模型与落库策略（当前实现）

- `books`：打开文件时 upsert（以 bookId 为主键）
- `reading_progress`：TXT 翻页时更新
  - `char_offset`：当前页起始字符索引（用于续读）
  - `segment_index`：当前页序号（临时字段，后续可用于进度条/切片）
- 注意：目前 bookId 使用 `sha1(filePath)`，后续要做跨设备同步时建议改为文件内容 hash（或 fileSize+mtime+path 的组合策略）

## 下一步建议（给后续 AI / 开发者）

1. TXT 目录识别（章节规则）+ 目录页跳转
2. 阅读设置：字号/行距/页边距/主题/字体导入，并触发重新分页
3. 进度条切片（默认 500 字可配置）+ 拖拽跳转
4. 当前书搜索 → 全书架索引（2-gram + segment 倒排）+ 高亮/片段预览
5. PDF 渲染（选择合适插件）+ 页码续读
6. 书签 + 标签中心 + 与关键词联动
7. 局域网同步（进度/书签/标签/元信息）

