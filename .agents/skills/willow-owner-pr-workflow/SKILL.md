---
name: willow-owner-pr-workflow
description: 在 Willow 为项目所有者开发并交付改动时使用。从 develop 创建 feature 分支，通过中文 PR 合并回 develop。
---

# Willow 所有者开发流程

本流程适用于用户本人在 Willow 的开发任务。用户有其他明确指示时，以当次指示为准。纯咨询、审查和临时实验不会触发交付。

1. 从最新的 `develop` 创建 `feature/<topic>`。如果已有未提交的本次改动，把它们带到 feature 分支。检查工作区与暂存区，保护无关改动。
2. 在 feature 分支验证并提交本次改动。Git commit 的标题和正文使用英语。
3. 推送 feature 分支到 `origin`，创建以 `develop` 为 base 的 PR。PR 的标题和正文均使用中文，并说明改动与验证结果。
4. 创建 PR 后直接通过 GitHub 合并，遵守仓库的合并条件。合并后确认 PR 状态并同步本地 `develop`。发布、打 tag 或合并到 `main` 按用户另行指示执行。

已确认交付的所有者开发任务默认走完整流程。用户要求先留在本地、只开 PR 或暂缓合并时，按当次要求停止。
