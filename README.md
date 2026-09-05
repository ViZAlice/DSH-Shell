# DSH Shell

一个非官方的 macOS 原生薄壳：在本机准备并启动
[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)，再通过 AppKit + WKWebView
显示它的 Web UI。构建产物在 macOS 中显示为 **DeepSeek Harness.app**。

> 本项目不是 DeepSeek 官方产品，也未获得 DeepSeek 的认可或背书。

## 下载与首次打开

GitHub Releases 提供自动构建的 Universal macOS ZIP，同时支持 Apple Silicon 和 Intel Mac。
该产物使用 ad-hoc 签名，但**没有 Developer ID 签名，也没有经过 Apple 公证**。

1. 下载并解压 `DeepSeek-Harness-*-macOS-universal-unsigned.zip`，将 App 移入“应用程序”。
2. 第一次尝试打开时，macOS 可能阻止运行。
3. 打开“系统设置 → 隐私与安全性”，在安全性区域选择“仍要打开”，然后确认。

只有在你信任本仓库及对应 Release 时才应手动放行。受组织管理的 Mac 可能不允许绕过该限制。

## 运行要求

- macOS 14 或更高版本
- Git
- Node.js `^22.19.0` 或 `>=24.0.0`
- pnpm，建议使用 DSH 当前声明的 `11.7.0`
- 首次安装依赖及获取更新时能访问 GitHub 和 npm registry

DSH、Node 和 pnpm 均不打包进 App。缺少上述命令时，启动准备会失败。

## 工作方式

首次启动会将 DSH 克隆到：

```text
~/Library/Application Support/DSHShell/deepseek-harness
```

App 选择本地可用的最新 RC tag；没有 RC 时回退到最新版本 tag。首次运行或版本变化时执行
`pnpm install --frozen-lockfile` 和 `pnpm run build`，随后以 `pnpm dsh web --no-open`
启动本地服务。正常启动后只在后台执行 `git fetch --tags --prune`；发现新版本时由用户确认重启更新。

App 只管理自己的 Application Support 仓库，不会修改用户的其他 DSH checkout。完整 Server 输出可从
“DSH → 显示 Console”查看。

## 从源码构建

需要 Xcode 16 或更高版本。打开 `DSHShell.xcodeproj`，选择 `DSHShell` scheme 后运行即可。

也可以使用命令行：

```bash
xcodebuild -project DSHShell.xcodeproj \
  -scheme DSHShell \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

## 自动发布

推送形如 `v1.0.0` 的 tag 会触发 GitHub Actions：

- 构建 arm64 + x86_64 Universal Release；
- 对 App 进行 ad-hoc 签名并验证签名和架构；
- 使用 `ditto` 创建保留 macOS Bundle 元数据的 ZIP；
- 生成 SHA-256 文件；
- 创建 GitHub Release 并上传两份文件。

该流程不需要 Apple 证书或仓库 Secrets。普通 push 和 pull request 会执行一次无签名 Debug 构建。

## 安全与版本说明

这个 App 会下载并执行最新 DSH RC 及其锁定的 npm 依赖。相同版本的 Shell 在不同日期首次启动时，
可能获得不同的 DSH RC。公开安装前请理解这一信任边界；Release 的 SHA-256 只能校验 Shell 包体，
不能固定首次启动后下载的 DSH 内容。

## 许可证与品牌

本项目代码以 [MIT License](LICENSE) 发布。DSH 及随附鱼形素材的许可和归属见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。`DeepSeek Harness` 是上游项目/品牌名称；本项目
仅作为非官方本地 macOS 承载程序使用该显示名称。
