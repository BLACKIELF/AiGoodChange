# 仓库协作流程

流程版本：0916v1。相对之前的本地未提交开发：增加工作分支、可审阅提交、PR 检查和发行版本对账。

## 分支与提交

1. 从最新 `main` 创建短期工作分支，例如 `codex/fix-shortcut-recovery`。
2. 一次提交围绕一个明确变化；使用 `feat:`、`fix:`、`docs:` 或 `chore:` 描述结果。
3. 只暂存源码、文档和必要资源。`build/`、`reviews/`、App 包、偏好导出、凭据和本机原始日志不提交。
4. 推送工作分支并向 `main` 发起 PR，填写变化、验证、配置兼容和回退方式。
5. `macOS build and checks`、`Windows win-x64 build and checks` 与 `Windows win-arm64 build and checks` 通过并处理完审阅意见后，由维护者合并。需要时使用 squash 保持线性历史；PR 完成不代表已经发行或安装。

`main` 使用 PR 和必需状态检查保护，禁止强制推送和删除。个人仓库不强制另一位贡献者审批，但仍保留 PR 与检查记录。

## 本地验证

```bash
bash selfcheck.sh
bash package.sh
git diff --check
```

`selfcheck.sh` 默认在 `build/checks/` 构建，`package.sh` 默认在 `build/package/` 构建。需要自定义路径时设置 `QUICKTOGGLE_BUILD_DIR`。日常运行的 `build/AiGoodChange.app` 保持独立；更换安装包前正常退出对应实例。

CI 使用 Apple Silicon macOS runner，执行源码检查、构建、签名、自检、布局检查和发行 ZIP 元数据检查。CI 不替代真实全局按键、休眠、重新登录和辅助功能操作的验证；涉及这些行为时在 PR 中明确记录。

Windows 使用 x64 与 ARM64 原生 runner，构建步骤见 [Windows 说明](windows/README.md)。测试配置与截图使用合成样例，不读取开发者本机偏好。打包后的自带运行时 EXE 必须再次通过自检。

## 版本与发行

- `VERSION` 是语义版本号的唯一来源，当前为 `1.0.0`。日期式 `MMDDvN` 用于流程记录，不代替 App 版本。
- `CHANGELOG.md` 记录相对上一版的变化；提交尚未进入发行版时保留“未发布”。
- 构建包记录版本、构建计数及 `QuickToggleSourceRevision`。带 `-dirty` 的源码状态不能作为正式发行依据。
- 发布须在已合并且验证通过的确定提交上创建 `vX.Y.Z` 标签，核对 ZIP 内版本、源码提交和 SHA-256 后再创建 GitHub Release。不要移动已有发行标签。
- 安装验收与 GitHub Release 分开记录。源码、标签、PR 状态和本机安装包均需核对，不能只依据分支名判断。
- Windows 预览版使用 `v1.0.0-windows-preview.N` 标签和独立 prerelease；ZIP 与 manifest 必须来自该标签指向的已合并提交。不要把后续 Windows 提交的二进制附加到旧 macOS 标签。未签名状态与尚待实机验收的行为应明确写入说明。

## 提交问题

在 Issue 中提供版本与构建号、macOS 版本、触发步骤、预期结果和实际结果。截图或日志应删除与问题无关的个人路径、应用配置及敏感信息。
