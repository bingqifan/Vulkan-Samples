<!--
Created by Fanbingqi at 2026-11-24 09:08 Asia/Shanghai.
Copyright (c) 2026, Fanbingqi
SPDX-License-Identifier: Apache-2.0
Meaning and necessity: Define the iOS picker and its launch, navigation, and renderer lifecycle acceptance criteria.
Problem: The current iOS entry point takes a command-line sample ID, and its full device bundle links two unpackaged libraries.
Solution and approach: Use the existing sample registry in a native list, scope a Vulkan session to each selection, and verify the resulting iPhone build.
-->

# iOS sample picker / iOS 示例选择列表

## Request and evidence / 需求与证据

The fork needs an iOS startup list. A tap must run the selected sample, and the user must be able to return and select another. Explicit `sample`, `batch`, and help invocations remain available to Xcode and command-line users.

Fork 的 iOS 版本需要在启动时显示列表。用户点击后应进入对应示例，返回后应能再次选择。Xcode 和命令行仍可显式传入 `sample`、`batch` 和帮助参数。

`SceneDelegate.m` currently creates a renderer unconditionally. `ViewController.mm` reads `NSProcessInfo` arguments and keeps a `CADisplayLink`, and `main.mm` gives all launches a process-global `IosPlatform`. `apps::get_samples()` enumerates the build's registered samples, including name and ID. `Platform::terminate` finishes the active sample and destroys its window. The existing iPhone sweep confirmed that without iOS static linking, OctoMap's two `.dylib` dependencies prevent even the list from launching.

当前 `SceneDelegate.m` 总是创建渲染页面，`ViewController.mm` 从进程参数取示例并持有 `CADisplayLink`，`main.mm` 使用进程全局的 `IosPlatform`。`apps::get_samples()` 提供本次构建注册的名称和 ID。`Platform::terminate` 会结束示例并销毁窗口。此前真机日志已确认，采用原本的链接方式时，OctoMap 的两个 `.dylib` 缺失会阻止整个应用启动。

The device build is used internally and has an established bundle ID and CLI entry point. The picker uses the current registry on every launch and needs no persisted state or migration. Individual GPU capability and compatibility failures are verified at runtime. No per-device capability cache is planned.

现有内部真机构建已有 Bundle ID 和命令行入口。列表每次启动从注册表读取，无需持久化或迁移。各示例所需的 GPU 能力由运行时实际校验。

## Step 1. Route startup and render a selected sample / 路由启动并运行所选示例

- `app/ios/SceneDelegate.m` uses `+[ViewController initialViewController]`. `app/ios/ViewController.h` declares the factory. The factory chooses a UIKit navigation stack and sample table when the process has no explicit arguments, and the existing renderer for explicit arguments.
- `app/ios/ViewController.mm` keeps the private table implementation in the iOS app. The table reads `apps::get_samples()`, shows the title and canonical sample ID, and passes the exact ID to the renderer. The UIKit navigation stack keeps the list and its scroll position. An empty registry displays a message. A selection checks the current top controller to avoid double pushes.
- `app/ios/main.mm` keeps the UIKit entry point. The renderer owns its `IosPlatform` and context, initializes the filesystem using the existing function, and uses the existing `sample <id>` command path for a picker selection. It stops the display link and terminates the owned platform after a committed back navigation. A canceled interactive pop can resume. The picker reports recoverable runtime errors and returns to the list. CLI runs preserve their termination behavior.
- `app/ios/Info.plist` removes the unused main/scene storyboard bindings. `app/CMakeLists.txt` leaves the launch screen and drops the default iOS scheme argument so a normal Xcode launch shows the picker.
- `framework/platform/platform.cpp` looks up hooks in the current platform on every callback. The present `static` iterator outlives the first platform's map. The frame error path also handles a factory that throws or returns null, with the requested sample ID available for logging.
- Every picker renderer owns a `StartSample` plugin. Generated plugins are process-global and assert when rebound without clearing, so CLI compatibility keeps the existing full set and clears its binding after termination. The renderer owns its Metal view for as long as the C++ context uses its non-owning pointer. Scene disconnect stops the active renderer.
- The isolated XCTest harness covers default launch, selecting Hello Triangle, returning and selecting Texture Loading, selecting a known unsupported sample with a managed error, and the explicit CLI sample route. It only exercises the compiled app, with no mocked registry or navigation.
- This step rolls back through the listed iOS files. It changes no user data.

本步使用 `SceneDelegate` 和 `ViewController` 区分无参数启动及显式命令，由 UIKit 导航栈保留列表位置。渲染页持有单次 Vulkan 会话，成功返回后释放资源，取消返回手势时可恢复。可处理的示例错误会显示原因并返回列表。Xcode 的默认启动进入列表，显式命令保持原流程。隔离 XCTest 将使用编译后的真实应用覆盖入口、示例切换、错误和命令行回归，回滚仅涉及上述文件。

## Step 2. Build, install, and verify / 构建、安装与验证

- `samples/complex/render_octomap/CMakeLists.txt` changes the library type to `STATIC` on iOS, matching the fix previously verified on the full device bundle, and preserves the existing desktop branches.
- Xcode 26.3 builds `vulkan_samples` with the existing iPhone SDK, development profile, bundle ID and all 108 sample entries. `otool -L` confirms the two OctoMap dylib references are gone, `codesign --verify --deep --strict` verifies the bundle, and `devicectl` installs and launches it without arguments on the connected iPhone.
- Temporary files `SamplePickerUITests.swift` and `project.yml` create the isolated XCTest harness outside the fork. `testLaunchesSelectedSampleAndReturns` checks both render destinations and saves the frame captures. `testSampleErrorReturnsToList` exercises `conditional_rendering`, which the iPhone sweep confirmed raises a missing Vulkan extension, and checks a subsequent selection. `testExplicitSampleArgumentBypassesPicker` checks the explicit entry. Console smoke covers `--help` and bounded `batch`. The tests use a branch-named iOS 26 simulator if needed, with `hello_triangle`, `texture_loading`, and `conditional_rendering` enabled explicitly. The physical iPhone is the final install target.
- The user-visible completion evidence is a real picker interaction in XCTest or on the iPhone. The verification records the tested destination, any unverified physical tap, and the resulting app state. The temporary simulator is removed after verification.
- The static-linking change rolls back through the scoped CMake line. The previous signed app remains reinstallable if needed.

本步将 OctoMap 的 iOS 库改为静态链接，保留现有桌面逻辑。Xcode 26.3 使用相同的签名与 Bundle ID 构建 108 个示例，随后通过 `otool`、`codesign` 和 `devicectl` 验证完整产物并安装到真机。临时 XCTest 记录实际界面交互与测试目的地，必要时使用当前分支的 iOS 26 模拟器并在完成后清理。

## Review and execution / 审核与执行

The three independent reviews identified two cross-session blockers. The platform cached hook iterators across instances, and the static plugin registry disallowed rebinding. The revised plan assigns a fresh StartSample plugin, fixes the hook lookup, copies the platform error before cleanup, and checks frame captures and recovery. The reviewers also confirmed the source title `Texture loading and mapping`, the previous simulator build's single-sample configuration, and the distinct iPhone capability failures. The separate shader-object-layer experiment is outside the picker change.

三个独立审核都发现了跨会话问题，包括平台的静态回调迭代器和全局插件的重复绑定。修订方案为点选会话分配独立插件、修复回调查找、在清理前保存错误，并验证实际帧与出错后的再次选择。审核也确认了 Texture Loading 的准确标题及旧模拟器只包含一个示例。此前 Shader Object 的单独打包实验不属于本次列表变更。

Build adjustment: The iPhone build rejected ARC because the checked-in Vulkan-Hpp headers use Metal Objective-C pointers in constant expressions and hash templates. The UIKit sources retain their existing reference-counting mode. The picker explicitly balances ownership of its Metal view, display link, sample ID, and touch. The same device build and UI tests verify the revised ownership path.

构建调整：真机编译确认，Vulkan-Hpp 的常量表达式和哈希模板与 ARC 下的 Metal Objective-C 指针不兼容。UIKit 源码沿用原有引用计数模式，由代码明确管理 Metal 视图、显示回调、示例 ID 和触摸对象的生命周期。真机构建与界面测试继续覆盖这条路径。

Visual verification: The iPhone capture showed that the standard transparent navigation background made a dark sample title unreadable. The picker navigation stack now uses the opaque system navigation appearance. The selection smoke test and its device captures verify that the navigation title remains visible over the Metal view.

视觉验证：真机截图确认，透明导航栏叠在深色示例上时，示例标题难以辨认。示例列表的导航栈改用系统不透明导航栏外观，并通过点选测试及真机截图复核标题显示。

Step 1 verified on the iPhone 12 Pro with iOS 18.7.8. All four XCTest cases passed. The recorded captures show the startup table and rendered Hello Triangle and Texture Loading frames. The unsupported Conditional Rendering sample displayed an error, returned to the table, and allowed Hello Triangle to render. The final navigation appearance change passed a focused rerun, and the new capture shows the Texture Loading title and Back button over the rendered frame.

步骤一已在运行 iOS 18.7.8 的 iPhone 12 Pro 上验证。四项 XCTest 全部通过，截图记录了启动列表、Hello Triangle 和 Texture Loading 的实际渲染。Conditional Rendering 因扩展缺失显示错误，返回后仍能运行 Hello Triangle。最终导航栏样式调整通过定向复测，真机截图显示了示例标题与返回按钮。

Step 2 verified with Xcode 26.3. The signed iPhone build contains 108 registry entries. The dynamic dependency check and strict code-signing verification passed, and the signed build installed successfully. The explicit `sample` UI test passed. `--help` printed usage, and the bounded `complex` batch ran OctoMap for 16 frames and exited successfully. The temporary test runner was removed. The final iPhone build was left running on its startup list.

步骤二已通过 Xcode 26.3 验证。真机签名构建包含 108 个注册示例，通过动态依赖与签名检查，并成功安装。显式 `sample` 的界面测试通过，`--help` 输出用法，`complex` 分类的限定批次完成了 OctoMap 的 16 帧渲染并正常退出。临时测试程序已清理，最终真机构建停在启动列表。
