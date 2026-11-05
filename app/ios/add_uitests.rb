#!/usr/bin/env ruby
# Adds the RunnerUITests UI-testing bundle to the Flutter Runner project and
# registers it in the shared Runner scheme's Test action, so
# `xcodebuild test -only-testing:RunnerUITests` can drive the app on a device.
# Idempotent: re-running removes the prior RunnerUITests target first.

require "xcodeproj"

IOS_DIR   = File.expand_path(File.dirname(__FILE__))           # app/ios
PROJ_PATH = File.join(IOS_DIR, "Runner.xcodeproj")
# Team and bundle id come from the environment (see scripts/set-apple-identity.sh).
TEAM      = ENV.fetch("AURORA_APPLE_TEAM", "")
UI_ID     = "#{ENV.fetch("AURORA_BUNDLE_ID", "com.aurora.vpn")}.RunnerUITests"
DEPLOY    = "15.0"
UI_NAME   = "RunnerUITests"

project = Xcodeproj::Project.open(PROJ_PATH)
runner  = project.targets.find { |t| t.name == "Runner" }
raise "Runner target not found" unless runner

# --- clean previous run --------------------------------------------------
if (old = project.targets.find { |t| t.name == UI_NAME })
  old.remove_from_project
end
project.groups.select { |g| g.display_name == UI_NAME }.each(&:remove_from_project)

# --- create the UI test target -------------------------------------------
ui = project.new_target(:ui_test_bundle, UI_NAME, :ios, DEPLOY)

ui_group = project.main_group.new_group(UI_NAME, UI_NAME)
ref = ui_group.new_reference("RunnerUITests.swift")
ui.source_build_phase.add_file_reference(ref)

ui.add_dependency(runner)

ui.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"]  = UI_ID
  s["PRODUCT_NAME"]               = "$(TARGET_NAME)"
  s["CODE_SIGN_STYLE"]            = "Automatic"
  s["DEVELOPMENT_TEAM"]           = TEAM
  s["IPHONEOS_DEPLOYMENT_TARGET"] = DEPLOY
  s["SWIFT_VERSION"]              = "5.0"
  s["GENERATE_INFOPLIST_FILE"]    = "YES"
  s["TEST_TARGET_NAME"]           = "Runner"
  s["TARGETED_DEVICE_FAMILY"]     = "1,2"
end

project.save
puts "RunnerUITests target added."

# --- register in the shared Runner scheme's Test action -------------------
scheme_path = File.join(PROJ_PATH, "xcshareddata", "xcschemes", "Runner.xcscheme")
scheme = Xcodeproj::XCScheme.new(scheme_path)
already = scheme.test_action.testables.any? do |t|
  t.buildable_references.any? { |r| r.target_name == UI_NAME }
end
unless already
  testable = Xcodeproj::XCScheme::TestAction::TestableReference.new(ui)
  scheme.test_action.add_testable(testable)
  scheme.save!
  puts "RunnerUITests wired into Runner.xcscheme Test action."
else
  puts "RunnerUITests already present in Runner.xcscheme."
end
