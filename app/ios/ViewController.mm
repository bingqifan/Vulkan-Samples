/* Copyright (c) 2024-2026, Holochip Inc.
*
* SPDX-License-Identifier: Apache-2.0
*
* Licensed under the Apache License, Version 2.0 the "License";
* you may not use this file except in compliance with the License.
* You may obtain a copy of the License at
*
*     http://www.apache.org/licenses/LICENSE-2.0
*
* Unless required by applicable law or agreed to in writing, software
* distributed under the License is distributed on an "AS IS" BASIS,
* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
* See the License for the specific language governing permissions and
* limitations under the License.
 */

#include "ViewController.h"
#include "../plugins/plugins.h"
#include "../plugins/start_sample/start_sample.h"
#include "apps.h"
#include "core/platform/entrypoint.hpp"
#include "filesystem/filesystem.hpp"
#include "ios/context.hpp"
#include "platform/input_events.h"
#include "platform/ios/ios_platform.h"
#include "platform/ios/ios_window.h"

@interface ViewController () {
	NSString *_sampleID;
	CADisplayLink *_displayLink;
	std::unique_ptr<plugins::StartSample> _pickerPlugin;
	std::unique_ptr<vkb::IosPlatform> _platform;
	vkb::ExitCode _code;
	UITouch *_activeTouch;
}
- (instancetype)initWithSample:(const apps::SampleInfo &)sample;
@end

@interface SamplePickerViewController : UITableViewController {
	std::vector<apps::AppInfo *> _samples;
}
@end

@implementation SamplePickerViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Vulkan Samples";
	_samples = apps::get_samples();
	[self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"Sample"];
	if (_samples.empty()) {
		UILabel *message = [[[UILabel alloc] init] autorelease];
		message.text = @"This build contains no samples.";
		message.textAlignment = NSTextAlignmentCenter;
		message.textColor = UIColor.secondaryLabelColor;
		message.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
		self.tableView.backgroundView = message;
	}
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
	return static_cast<NSInteger>(_samples.size());
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
	const auto &sample = *static_cast<apps::SampleInfo *>(_samples[indexPath.row]);
	NSString *sampleID = @(sample.id.c_str());
	UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Sample" forIndexPath:indexPath];
	UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
	content.text = @(sample.name.c_str());
	content.secondaryText = sampleID;
	cell.contentConfiguration = content;
	cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
	cell.accessibilityIdentifier = [@"sample." stringByAppendingString:sampleID];
	return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
	[tableView deselectRowAtIndexPath:indexPath animated:YES];
	UINavigationController *navigation = self.navigationController;
	if (navigation.topViewController != self || navigation.transitionCoordinator) {
		return;
	}
	const auto &sample = *static_cast<apps::SampleInfo *>(_samples[indexPath.row]);
	ViewController *renderer = [[[ViewController alloc] initWithSample:sample] autorelease];
	[navigation pushViewController:renderer animated:YES];
}

@end

@implementation ViewController

+ (UIViewController *)initialViewController {
	if (NSProcessInfo.processInfo.arguments.count > 1) {
		return [[[ViewController alloc] init] autorelease];
	}
	SamplePickerViewController *picker = [[[SamplePickerViewController alloc] initWithStyle:UITableViewStyleInsetGrouped] autorelease];
	UINavigationController *navigation = [[[UINavigationController alloc] initWithRootViewController:picker] autorelease];
	// Keep the title readable over samples whose Metal view clears to black.
	UINavigationBarAppearance *appearance = [[[UINavigationBarAppearance alloc] init] autorelease];
	[appearance configureWithOpaqueBackground];
	navigation.navigationBar.standardAppearance = appearance;
	navigation.navigationBar.scrollEdgeAppearance = appearance;
	return navigation;
}

- (instancetype)initWithSample:(const apps::SampleInfo &)sample {
	self = [super initWithNibName:nil bundle:nil];
	if (self) {
		_sampleID = [[NSString alloc] initWithUTF8String:sample.id.c_str()];
		self.title = @(sample.name.c_str());
		self.edgesForExtendedLayout = UIRectEdgeNone;
	}
	return self;
}

- (void)dealloc {
	[self stopRendering];
	[_sampleID release];
	[super dealloc];
}

- (void)loadView {
	VulkanView *view = [[[VulkanView alloc] initWithFrame:CGRectZero] autorelease];
	view.backgroundColor = UIColor.blackColor;
	view.contentScaleFactor = UIScreen.mainScreen.nativeScale;
	view.accessibilityIdentifier = @"vulkan.sample.rendering";
	view.accessibilityLabel = @"Vulkan sample rendering";
	view.accessibilityTraits = UIAccessibilityTraitImage;
	self.view = view;
}

- (void)viewDidLoad {
	[super viewDidLoad];

	NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
	if (_sampleID) {
		arguments = @[arguments.firstObject, @"sample", _sampleID];
	}
	std::vector<char *> argv;
	argv.reserve(arguments.count);
	for (NSString *argument in arguments) {
		argv.push_back(const_cast<char *>(argument.UTF8String));
	}
	auto context = create_platform_context(static_cast<int>(argv.size()), argv.data());
	static_cast<vkb::IosPlatformContext &>(*context).view = self.view;
	vkb::filesystem::init_with_context(*context);
	_platform = std::make_unique<vkb::IosPlatform>(*context);

	// Picker sessions bind their own launcher. CLI options keep the full plugin set.
	if (_sampleID) {
		_pickerPlugin = std::make_unique<plugins::StartSample>();
		_code = _platform->initialize({_pickerPlugin.get()});
	} else {
		_code = _platform->initialize(plugins::get_all());
	}
}

- (void)viewDidAppear:(BOOL)animated {
	[super viewDidAppear:animated];
	if (_platform && !_displayLink) {
		_displayLink = [[CADisplayLink displayLinkWithTarget:self selector:@selector(renderLoop)] retain];
		_displayLink.preferredFramesPerSecond = 60;
		[_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSDefaultRunLoopMode];
	}
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopDisplayLink];
	if (_activeTouch) {
		[self forwardTouch:_activeTouch action:vkb::TouchAction::Cancel];
		[self clearActiveTouch];
	}
}

- (void)didMoveToParentViewController:(UIViewController *)parent {
	[super didMoveToParentViewController:parent];
	if (!parent && _sampleID) {
		// An interactive pop only tears down Vulkan after UIKit removes this controller.
		[self stopRendering];
	}
}

- (void)stopRendering {
	[self stopRenderingWithCode:vkb::ExitCode::Close];
}

- (void)stopDisplayLink {
	[_displayLink invalidate];
	[_displayLink release];
	_displayLink = nil;
}

- (void)clearActiveTouch {
	[_activeTouch release];
	_activeTouch = nil;
}

- (void)stopRenderingWithCode:(vkb::ExitCode)code {
	[self stopDisplayLink];
	[self clearActiveTouch];
	self.viewIfLoaded.isAccessibilityElement = NO;
	if (_platform) {
		_platform->terminate(code);
		_platform.reset();
		if (!_sampleID) {
			for (auto *plugin : plugins::get_all()) {
				plugin->clear_platform();
			}
		}
		_pickerPlugin.reset();
	}
}

- (void)renderLoop {
	if (!_platform || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
		return;
	}
	if (_code == vkb::ExitCode::Success) {
		_code = _platform->main_loop_frame();
		if (_code == vkb::ExitCode::Success) {
			if (!self.view.isAccessibilityElement) {
				self.view.isAccessibilityElement = YES;
			}
			return;
		}
	}

	const std::string error = _platform->get_last_error();
	[self stopRenderingWithCode:_code];
	if (!_sampleID) {
		// CLI and batch callers depend on this development app exiting when the run ends.
		exit(0);
	}
	if (_code == vkb::ExitCode::Close) {
		[self.navigationController popViewControllerAnimated:YES];
		return;
	}

	NSString *message = error.empty() ? @"The selected sample stopped during startup." : @(error.c_str());
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Sample could not run"
	                                                               message:message
	                                                        preferredStyle:UIAlertControllerStyleAlert];
	__unsafe_unretained ViewController *renderer = self;
	[alert addAction:[UIAlertAction actionWithTitle:@"Back to Samples" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[renderer.navigationController popViewControllerAnimated:YES];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)forwardTouch:(UITouch *)touch action:(vkb::TouchAction)action {
	if (!_platform || _code != vkb::ExitCode::Success) {
		return;
	}
	CGPoint point = [touch locationInView:self.view];
	CGFloat scale = self.view.contentScaleFactor;
	_platform->input_event(vkb::TouchInputEvent{
		0, 1, action,
		static_cast<float>(point.x * scale),
		static_cast<float>(point.y * scale)});
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (!_activeTouch && _platform) {
		_activeTouch = [touches.anyObject retain];
		[self forwardTouch:_activeTouch action:vkb::TouchAction::Down];
	}
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (_activeTouch && [touches containsObject:_activeTouch]) {
		[self forwardTouch:_activeTouch action:vkb::TouchAction::Move];
	}
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (_activeTouch && [touches containsObject:_activeTouch]) {
		[self forwardTouch:_activeTouch action:vkb::TouchAction::Up];
		[self clearActiveTouch];
	}
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
	if (_activeTouch && [touches containsObject:_activeTouch]) {
		[self forwardTouch:_activeTouch action:vkb::TouchAction::Cancel];
		[self clearActiveTouch];
	}
}

@end
