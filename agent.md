# 安装新应用时必须删掉旧的

代码更新并安装新的 `xiaoai-archive.app` 时，机器上只能留下这一份新应用。先装好、确认能打开，再删掉其余所有同名副本。不要让打开面板里同时出现两个 xiaoai-archive。

正式安装位置以 `Project.plist` 的 `InstallPath` 为准，当前是 `/Applications/xiaoai-archive.app`。这一份是要保留的新应用。

## 每次安装按这个顺序做

1. 用项目自己的流程构建并安装：`Scripts/make-app.sh`，然后 `Scripts/install-dev-build.sh`。安装脚本会先退出正在运行的旧应用，再替换 `InstallPath` 上的那一份。
2. 本机命令行工具缺少 SwiftUI 宏插件时，构建前设置 `SDKROOT` 为 `/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`。不要改签名身份、Bundle ID 或权限配置。
3. 安装完成后立刻清掉其余副本，至少包括仓库里的 `dist/xiaoai-archive.app`。它和「应用程序」里的是同一份构建，但会被系统登记成第二个应用。
4. 用 `lsregister -u` 取消已删除副本的注册，再用 `lsregister -f` 登记保留的那一份。
5. 用 `mdfind "kMDItemFSName == 'xiaoai-archive.app'"` 确认只剩下 `InstallPath` 这一条，然后打开它。

```bash
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
APP="$(/usr/libexec/PlistBuddy -c 'Print :InstallPath' Project.plist)"
DIST="$(cd "$(dirname "$0")" && pwd)/dist/xiaoai-archive.app"

"$LSREGISTER" -u "$DIST"
rm -rf "$DIST"
"$LSREGISTER" -f "$APP"
open "$APP"
```

在仓库根目录执行时，把上面的 `DIST` 换成 `"$PWD/dist/xiaoai-archive.app"`。

除了 `dist/` 和 `InstallPath`，如果搜索还发现桌面、下载目录或其他位置的 `xiaoai-archive.app`，那些也是旧副本，一并取消注册并删除。不要删掉刚刚安装、正在运行的那一份。
