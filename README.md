# xiaoai-archive

把微信群聊整理成按时间排列的文本，连同图片、视频和离线预览一起留在本机。

聊天内容只来自微信自己的「合并转发」和导出文件。本工具不读取微信数据库，不解密，不注入，也不改微信。

源码与问题反馈：[luoluo-sen/xiaoai-archive](https://github.com/luoluo-sen/xiaoai-archive)。发行版本：[GitHub Releases](https://github.com/luoluo-sen/xiaoai-archive/releases)。

仓库链接、维护者和发布配置统一放在根目录 `Project.plist`。应用里的“检查更新”查询本仓库最新正式 GitHub Release，以 `v1.2.3` 或 `1.2.3` 形式的标签比较版本，并提供发行说明与下载页面。当前尚未发布正式版本与签名更新源，自动下载安装保持关闭。

应用展示名称与安装包为 `xiaoai-archive`。内部应用标识和已存储的设置键保留现有值。主程序与分享扩展共用 `~/Downloads/xiaoai-archive/Inbox/`，通过 macOS 的下载目录读写权限交接文件，不再依赖原作者的 App Group 或开发团队。原共享容器与 Application Support 中的旧记录不会自动删除或合并。上游网页和更新说明保存于 `Resources/UpstreamSite/` 与 `Resources/UpstreamReleaseNotes/`，不参与本项目更新发布。

## 新电脑首次安装使用

普通用户接收编译好的应用，不需要创建证书、安装开发工具或执行构建脚本。下载目录收件箱可以用于本机签名构建；首次使用需允许应用访问“下载”文件夹。给少量用户传递本机签名的应用时，macOS 可能阻止首次打开。公开发行并减少安装拦截可选用 Developer ID 签名与公证，两者不影响收件箱路径。当前仓库尚未发布正式安装包。

1. 从本仓库 GitHub Releases 下载正式安装包，将 `xiaoai-archive.app` 放到「应用程序」，从这里打开应用。
2. 完成首次设置向导，启用至少一个需要的分享入口。快捷微信转发必须启用「暂存到 xiaoai-archive」；其他分享入口按需选择。未启用任何入口时向导不会显示配置完成。
3. 如果需要读取微信窗口、自动转发或粘贴，在系统隐私与安全设置中添加 `/Applications/xiaoai-archive.app` 并开启辅助功能；系统可能要求触控 ID 或管理员密码。只暂存、复制文件可以跳过此权限。
4. 打开并登录官方微信，让聊天主窗口显示普通或折叠会话列表，然后在应用中读取当前群或窗口列表。需要识别转发按钮位置时，应用会提示另行开启屏幕录制权限。

新电脑不继承旧电脑的系统授权，应用不会绕过本人确认。同一签名身份的正常更新使用原安装路径；签名身份改变时安装流程会停止并说明原因。

正式安装包面向 macOS 14 及以上，并按发布脚本打包 Apple Silicon 与 Intel 两种架构。当前窗口列表识别支持中文版微信的普通与折叠列表；其他微信界面语言尚未实现。

## 开发者从源码构建

新开发机克隆仓库后，若根配置已指定证书而钥匙串没有对应私钥，需要导入同一签名身份。只为自己在新电脑独立构建时，可以明确清空 `Project.plist` 的 `SigningIdentity`，再执行下面的一次性本机设置；普通用户安装正式版本不执行这一步。已授权机器的常规更新不要清空或更换签名配置。

首次运行 `Scripts/make-signing-identity.sh`，建立本机开发签名并把公开证书标识写入 `Project.plist` 的 `SigningIdentity`。私钥保存在登录钥匙串，系统可能要求本人确认。已有正式证书时直接填写其代码签名标识。构建不再自动选择其他证书或使用临时签名。

然后运行 `Scripts/make-app.sh` 和 `Scripts/install-dev-build.sh`。安装位置固定由 `Project.plist` 的 `InstallPath` 指定。安装前验证新版本与已安装版本的签名要求，身份不兼容时会停止，保留当前已授权应用。

从旧临时签名首次迁移到固定证书，运行 `ALLOW_SIGNING_MIGRATION=1 Scripts/install-dev-build.sh` 并重新授权一次；此后使用同一证书和应用标识正常更新。这个迁移选项只允许旧版本确实使用临时签名的首次迁移，不放行证书之间的身份变更。证书过期、更换或应用标识改变仍可能需要重新授权；下面的正式发行脚本使用 Developer ID 证书。

## 正式发行准备

正式发行使用独立于本机开发签名的配置，不会覆盖当前 `SigningIdentity` 或开发版授权。Apple Developer Account Holder 需要创建 `Developer ID Application` 证书，并把证书及私钥导入发布机钥匙串；将其 40 位 SHA-1 标识写入 `Project.plist` 的 `DistributionSigningIdentity`，将团队 10 位 Team ID 写入 `DistributionTeamID`。不需要 App Group 配置。

公证凭据只保存于钥匙串：使用 `xcrun notarytool store-credentials <名称>` 保存 Apple Developer 公证凭据，再把名称写入 `Project.plist` 的 `NotaryProfile`。不要把证书私钥、API key 或密码放进仓库。配置完成后，先运行 `DISTRIBUTION=1 Scripts/check-release-config.sh`，再在已打标签且工作区干净的提交上运行 `Scripts/release.sh`；脚本会生成 `dist/release/` 下的 Universal 发行包，签名、公证并装订票据。关闭自动更新时不会生成 Sparkle appcast，GitHub Releases 仍可正常发布。

## 许可与出处

本项目基于 [Dukou](https://github.com/qzz0518/Dukou) 修改。导入时的上游提交为 [`28f38d7`](https://github.com/qzz0518/Dukou/commit/28f38d7ebb0f107d7bc8cc6ef367753c44250bef)。

Dukou 的版权归 qzz0518 所有：

```text
Copyright (c) 2026 qzz0518
```

Dukou 以 [MIT License](LICENSE) 授权。使用、修改或分发本软件及其实质性部分时，必须保留上述版权声明，以及 `LICENSE` 中的许可全文。本仓库对 Dukou 的修改不改变这一义务。

第三方组件见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。其中 Sparkle 同样以 MIT 协议发布，许可文本在 `Resources/Licenses/Sparkle-LICENSE.txt`。

「微信」是腾讯公司的商标。本项目与腾讯无关联，也未获其背书。

## English

[README_EN.md](README_EN.md)
