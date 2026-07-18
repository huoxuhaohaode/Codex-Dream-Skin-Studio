# 主题扩展与发布

Codex Dream Skin 支持三种主题分发方式。主题只包含 JSON 配置和背景图，导入器不会
执行第三方脚本或 CSS。

## 1. 内置预设

适合希望随每个发行版一起安装的原创主题。在 `macos/presets/` 新建
`preset-<slug>/`，放入 `theme.json` 和它引用的单张背景图，然后按
[`../presets/README.md`](../presets/README.md) 完成尺寸、命名、版权和测试检查。

```bash
node macos/scripts/injector.mjs \
  --check-payload \
  --theme-dir macos/presets/preset-<slug>
cd macos && npm test
```

内置主题适合通过 Git 提交和 Pull Request 维护，图片更新也会留下可追溯历史。

## 2. 已审核社区目录

适合保留在作者仓库中、由应用社区页按需安装的主题。目录文件是
[`catalog.json`](./catalog.json)，每一项必须满足：

- 仓库和提交公开可访问；
- `themeURL` 与 `imageURL` 都指向 40 位提交哈希下的
  `raw.githubusercontent.com` 文件，不能使用会移动的分支名或 latest 链接；
- 分别记录 `theme.json` 和背景图的 SHA-256；
- 明确软件许可、图片许可和来源；
- 不含真人肖像、第三方角色、品牌素材、私密截图或来源不明的图片。

计算哈希：

```bash
shasum -a 256 path/to/theme.json path/to/background.png
```

更新目录后运行 `cd macos && npm test`。审核记录同步写入
[`../docs/community-theme-sources.md`](../docs/community-theme-sources.md)。

## 3. `.dreamskin` 文件

适合个人之间直接分享，或在正式收录前测试。原生工具可以导出和导入这一数据包：

```bash
./macos/scripts/export-theme-macos.sh \
  --id custom-example \
  --output "$HOME/Desktop/example.dreamskin"

./macos/scripts/import-theme-macos.sh \
  --source "$HOME/Desktop/example.dreamskin" \
  --no-apply
```

`.dreamskin` 是严格 JSON 数据包，只容纳一份主题配置、一张 base64 图片、媒体信息和
SHA-256，不包含可执行代码。分享前仍应检查图像权利和文件内容。

## 发布前隐私清单

- 不提交 `auth.json`、API Key、访问令牌、`.env` 或个人 Codex 配置；
- 不提交 `~/Library/Application Support/CodexDreamSkinStudio/` 下的用户状态与日志；
- 不提交带聊天内容、桌面文件名、账号头像或通知的屏幕截图；
- 删除图片中的 GPS、作者、来源路径等不必要元数据；
- 使用 GitHub noreply 邮箱提交，避免暴露私人邮箱；
- 发行包只通过项目构建脚本生成，`release/`、`runtime/` 和本地构建目录不进入 Git。

新主题可以使用仓库的“主题投稿”Issue 模板先做来源审核，再决定进入内置预设还是
社区目录。
