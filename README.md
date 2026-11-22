<div align="right">简体中文 | <a href="README.en.md">English</a></div>

<div align="center">

<img src="https://raw.githubusercontent.com/DreamDZL/iMusic/main/platforms/ios/docs/iMusicIcon.png" width="140" alt="iMusic" />

# iMusic

**让发现、收藏与聆听，自然流动。**

SwiftUI · 系统 Liquid Glass · LX User API 音源 · LX Sync Server

QQ群：**827131879** · 欢迎加入交流、讨论和反馈 Bug

[![Platform](https://img.shields.io/badge/platform-iOS%2027%2B-blue?logo=apple)](#构建)
[![LGPL-3.0](https://img.shields.io/badge/license-LGPL--3.0-orange)](LICENSE)
[![GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-orange)](COPYING)

</div>

iMusic 是基于 [Moumusic](https://github.com/jiajia2222/Moumusic) 开发的原生 iOS 音乐客户端。主页、新发现、电台、资料库和搜索汇聚在熟悉的底部导航中；SwiftUI 和系统 Liquid Glass 让浏览与播放融为一体。

聚合搜索支持 QQ 音乐、网易云音乐、酷我音乐和酷狗音乐。导入 LX User API 音源后，可使用音源解析播放；可用性取决于音源和服务状态。自动模式也可能使用符合条件的已登录平台账号。

QQ 音乐和网易云公开歌单会导入为可编辑的本地副本。对这些副本的编辑只作用于 iMusic 中的副本，不会写回来源平台歌单。本地收藏和兼容歌单可通过自托管的 [LX Sync Server](https://github.com/lyswhut/lx-music-sync-server) 在设备间同步。音源脚本由每台设备分别管理。

登录网易云后，可在“我喜欢的音乐”中把账号红心复制到 iMusic 本地收藏。这是单向导入；之后的改动只保存在 iMusic 并可经 LX Sync 同步。

## 界面预览

<div align="center">
<img src="platforms/ios/docs/promo/01-home.png" width="19%" alt="主页推荐">
<img src="platforms/ios/docs/promo/02-radio.png" width="19%" alt="iMusic 电台">
<img src="platforms/ios/docs/promo/03-search.png" width="19%" alt="聚合搜索">
<img src="platforms/ios/docs/promo/04-player.png" width="19%" alt="全屏播放器">
<img src="platforms/ios/docs/promo/05-lyrics.png" width="19%" alt="同步歌词">
</div>

## 功能

- 原生主页、新发现、电台、资料库和搜索，适配浅色与深色外观
- 歌手、专辑与歌单详情，迷你播放器、全屏播放器、队列和同步歌词
- 原生锁屏与控制中心播放控制
- LX 音源文件/链接导入、检测、启停、切换、导出和删除
- 四平台聚合搜索，同一录音合并来源并支持选择播放来源
- 本地收藏、最近播放和可编辑歌单
- QQ 音乐与网易云公开歌单导入为本地副本
- 可选 LX Sync，支持兼容的收藏和歌单
- iOS 27 原生 Liquid Glass；透明度、着色及辅助功能表现跟随 iPhone 系统设置
- 连续装饰动效和音频频谱分析会根据低电量、设备热状态及应用场景活跃状态降载或暂停。后台播放时，进度与歌词游标回调由 0.2 秒降至 1 秒；“新发现”自动刷新间隔至少为 10 分钟

默认 iOS 目标不包含应用内音乐下载页面、主屏幕小组件、自定义实时活动或 CarPlay 集成。锁屏与灵动岛仅使用 iOS 原生 Now Playing 媒体卡片。播放器也能复用设备上已有的本地音频文件。

## 音源与同步

进入 **资料库 → 更多 → 管理 LX 音源**，可从文件或 URL 导入音源并检测可用性。仓库不会预置第三方音源地址。

进入 **资料库 → 同步资料库**，填写 LX Sync Server 地址和连接码。客户端同步兼容的收藏与歌单；LX Sync 不同步音源脚本，因此每台设备需要分别导入。对导入的 QQ 音乐和网易云歌单副本进行编辑只保存在 iMusic，不会修改平台歌单。

## 构建

iOS 应用需要 macOS 和 Xcode。使用 XcodeGen 生成 iOS App 目标：

```sh
cd platforms/ios/ios
xcodegen generate
xcodebuild -project KumoneIOS.xcodeproj -scheme KumoneIOS -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO build
```

最低部署版本为 iOS 27，适配目标为常规 iPhone 尺寸；当前不提供折叠屏专属布局。

## 项目结构

```text
platforms/ios/
├── Sources/Kumone/
│   ├── Core/API/          目录、歌单导入和 LX 音源桥接
│   ├── Core/Models/       歌曲、歌单和歌词模型
│   ├── Core/Player/       AVPlayer、队列、歌词和系统播放状态
│   ├── Core/Storage/      本地资料库、音源配置和账号数据
│   ├── Core/Sync/         LX Sync 数据模型与客户端
│   ├── DesignSystem/      SwiftUI 主题和 Liquid Glass 辅助组件
│   └── Features/          主页、新发现、广播、资料库、搜索、设置和播放器
├── ios/                   iOS App 壳、测试和 XcodeGen 配置
└── docs/                  产品图标与截图
platforms/android/         保留的上游子树，不属于 iMusic iOS 目标
```

## 上游与许可证

- [Moumusic](https://github.com/jiajia2222/Moumusic)：原生 iOS 工程基础
- [LX Music Mobile](https://github.com/lyswhut/lx-music-mobile)：LX 音源与数据协议参考
- [LX Sync Server](https://github.com/lyswhut/lx-music-sync-server)：兼容的自托管同步服务

上游代码、资源和声明继续遵守各自许可证。详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)、[LICENSE](LICENSE) 和 [COPYING](COPYING)。
