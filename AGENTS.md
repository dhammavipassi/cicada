# AGENTS.md

Cicada (知了, formerly Live Subs): a macOS app, run from the menu bar, that turns what the Mac plays into live translated subtitles and meeting notes, keeps each meeting as a bilingual record, and speaks what you say back into the room in their language.

## Scope

- Surfaces: menu bar panel, live notes window (default) or subtitle bar while listening, main window (meeting records), settings, four-step onboarding (system audio, sample meeting, Ling key, speaking if wanted). A request that fits none of them gets pushed back before any UI is added.
- Nothing the user does needs the Terminal.
- Listening: Core Audio process tap → on-device language detection and `SpeechAnalyzer` → translation. Experimental voices: a bundled Core ML voiceprint model (`SpeakerID.swift`), compiled on first use. Speaking: hold right ⌥ or a shortcut → mic → Ming (with a Ling key) or on-device + translation → voice → BlackHole 2ch virtual mic.

## Hard rules

- The Ling key lives only in the 0600 `ling-api-key` file (`AIKey`): never UserDefaults, logs or exports.
- Every Ling call goes through `LingClient` (rate gate, priorities, `thinking: disabled`, content in the system message). Partial text is translated by Google, never Ling.
- Never speak untranslated text into the room. Never bundle the GPL BlackHole driver; download it and check its pinned SHA-256.
- The notes window is a non-activating panel with `sharingType = .none`: it must never take focus, and stays out of screen captures unless the user turns on 共享屏幕时让对方看到 (then it shows a badge).
- UI and engine state are `@MainActor`; audio callbacks hand buffers to `AudioRouter`'s queue.
- Don't change the release bundle id `com.wquguru.cicada` or the ad-hoc designated requirement: permissions are tied to them.
- No third-party dependencies, no `.xcodeproj`; Command Line Tools only.

## Design

- Ground `#F3F4F6`, white cards (the main window is one white sheet, no cards), ink `#15171C`, one accent `#E8552B` for "live", greys `#5A5F6B` / `#6B7080`. Design canvases on claude.ai and the app itself are the source of truth.
- Copy is Chinese and short, at most one grey helper line. Chinese text is the localization key; `Resources/{en,ja,ko}.lproj` translate it. SwiftUI literals localize themselves; other UI strings use `L("…")`; never `L()` prompts, logs or stored values. After changing UI text run `python3 scripts/strings.py` (`--write` adds TODOs), and check the English UI, which runs wider.
- The logo geometry is kept in step in `CicadaLogo` (`Onboarding.swift`), `Sources/LiveSubsIcon` and `site/icon.svg`; then rerun `scripts/site-images.sh`.

## Layout

- `Sources/LiveSubs`: the app, one concern per file. Engines are UI-free (`ListenEngine`, `SpeakEngine`, `SpeakTest`, `Notes`, `Translator`, `Ling`, `VirtualMic`, `SessionStore`, `Updates`…); `AppModel` wires them and holds the debug commands. Settings keys: `AppSettings` in `Settings.swift`.
- `Sources/LiveSubsIcon`: renders the icon set. `site/`: the website, built by `scripts/site.py`.
- The site is Chinese at `/`, English / Japanese / Korean under `/en/` `/ja/` `/ko/`; every `{{t.key}}` comes from `site/i18n/<lang>.json`. `start.html` is the setup page; its `img/start/` screenshots come from the app in each language. `tools/`: test helpers. `Tests/LiveSubsTests`: unit tests for the pure parts.

## Commands

```bash
scripts/test.sh                        # AGENTS.md check + unit tests
scripts/build.sh && open build/Cicada.app   # dev build: own bundle id, settings, log
RELEASE=1 scripts/build.sh             # release build
scripts/package.sh                     # DMG + zip + checksums
scripts/release.sh <x.y.z>             # writes the CHANGELOG section from commits; CI publishes the tag
scripts/deploy-site.sh                 # build the site, wrangler deploy to the cicada-site Worker (cicada.indaloop.app)
```

## Verifying

- Run the app and check the behaviour, not just the build; check the English UI too.
- Drive the dev build with `tools/lsctl` (commands and testing tips in `tools/README.md`; the source of truth is `AppModel.debugCommand`). Use `afplay Resources/sample/sample.m4a` or `say -o` clips as input and read `/tmp/livesubs-dev-debug.log`.
- A real voice, the BlackHole install, Input Monitoring and a Mac without permissions need a person.

## Conventions

- Match the existing naming and comment density; comments say why.
- Commit messages are English only and follow Conventional Commits (`feat:`, `fix:`, `docs:`, `build:`, `refactor:`, `test:`, `chore:`). `feat:` and `fix:` subjects are the release notes (`scripts/changelog.py`), one line each linked to the commit: say what the user gets in one plain sentence, one change per commit; website changes use `feat(site):` / `fix(site):`.
- Every user-visible change also gets a Chinese item in `site/changelog.json`, the website's changelog; keep `README.md` (Chinese, the default) and `README.en.md` in step.
- Versions are semver from 1.0.0: patch for fixes only, minor for features, major only when users must grant permissions again.
- This file stays under 6 KB with these sections; `scripts/check-agents.py` enforces it in `scripts/test.sh`, CI and the pre-commit hook. Implementation detail belongs in code comments, not here.

<!-- BEGIN SCOPE-LIMITS-PROJECT (generated; edit rules/scope-limits-project.md) -->
## 防御预算（全局强约束）

- 同域缺陷主动修复：与当前任务同一子系统、调用链或影响面的问题（含存量缺陷），按根因第一性原理修到根因，不打补丁、不等指示；确认无关的才只报告。不堆防御。
- 校验只在四类信任边界做一次：公开 API、用户入口、配置/数据/网络解析出口、跨进程边界；边界内不重复判空 / 校验；安全 / 数据完整性纵深按项目要求做。
- 不吞错：禁止 `catch → null/false/空集合`、`log and continue`、用 `guest/0/{}/[]` 伪造默认值；只捕说得出名字且失败是正常业务路径的异常，其余抛到能处理的边界。
- 新增 guard / retry / fallback / cache / lock / 兼容层 / 抽象前，先答四问：真实失败、信任边界、失败后动作、测试或证据；缺一不写。第三方兜底注明「谁家问题 + 确切条件 + 何时可删」。
- 不做投机建设；哈希 / 校验和只在替代更贵操作且结果改变下一步时写；数据完整性 / 传输 / 去重所需校验和除外，但要有具名消费者；兼容只在有具名契约时保留（公开 API/CLI/配置/数据、已发布升级、安全边界、已观察生产状态），测试不是契约。
- 测试只为真实失败：用户要求、真实回归/边界/不变量、刚修的 bug、现有测试变红；不写镜像实现、不可能分支、实现细节、覆盖率表演。相关测试先跑，全量最多一轮放最后，验收即停；项目明确要求的测试门禁/契约测试优先；全量限制指本地重复跑，CI 门禁不受此限。
- 防御性代码与行为变化成比例：修 bug 通常几行；新增 >50 行防御性兜底先报「N 行 / M 行是校验兜底 / 不写的代价」。本条约束防御性代码与无关改动，不约束功能完备度、UI/UX、文档、测试或最佳实践所需的架构调整。
- 安全、隐私、鉴权、数据完整性、幂等、已发布迁移、必要调用方与测试、真实生产故障是任务本身，不因本条删掉；删防御前先问「删了会坏什么用户可观察行为？」。
- 项目明确要求的安全/迁移/发布门禁优先；纯范围扩张类项目规则（如「发现任何问题都必须修」）不在此列；安全/数据完整性纵深、易变外部模型/工具/平台的信任边界薄契约、测试隔离适配层与数据完整性校验不算投机建设。
- 「全局 / 架构 / 第一性原理 / 最佳实践 / 全面 / 不留尾巴」要求按最佳实践完整实现目标；范围控制只排除与目标无关的扩张，不削减功能、UI、文档、测试与可访问性。
- 倒金字塔信任与自解释代码：质量由确定性架构、静态类型与验证产物保证；业务层封禁隐式竞态与脆弱 API，清除 99% 不可执行注释；重复出现的纠错强制沉淀为物理级检查（架构/类型/lint/测试），严禁以自然语言重复交代。

完整判据与案例：`~/.config/ai-instructions/rules/scope-limits.md`；全局规则 §3.1。本块由 `~/.config/ai-instructions/rules/scope-limits-project.md` 生成，勿手改。
<!-- END SCOPE-LIMITS-PROJECT -->
