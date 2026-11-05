#!/usr/bin/env ruby
# Adds the Aurora PacketTunnel Network Extension target to the Flutter Runner
# project and wires App Group / entitlements / signing / framework embedding.
# Idempotent: re-running removes the prior PacketTunnel target first.

require "xcodeproj"

IOS_DIR   = File.expand_path(File.dirname(__FILE__))           # app/ios
PROJ_PATH = File.join(IOS_DIR, "Runner.xcodeproj")
# Signing identity and bundle id come from the environment so no one account is
# baked in. Run `scripts/set-apple-identity.sh` to rewrite the Swift sources,
# entitlements and plists to the same bundle id.
TEAM      = ENV.fetch("AURORA_APPLE_TEAM", "")
APP_ID    = ENV.fetch("AURORA_BUNDLE_ID", "com.aurora.vpn")
EXT_ID    = "#{APP_ID}.PacketTunnel"
DEPLOY    = "15.0"
EXT_NAME  = "PacketTunnel"

project = Xcodeproj::Project.open(PROJ_PATH)
runner  = project.targets.find { |t| t.name == "Runner" }
raise "Runner target not found" unless runner

# --- clean previous run --------------------------------------------------
if (old = project.targets.find { |t| t.name == EXT_NAME })
  # drop embed/dependency references to the old target from Runner
  runner.dependencies.dup.each { |d| d.remove_from_project if d.target == old }
  runner.build_phases.grep(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase).each do |ph|
    ph.files.dup.each do |bf|
      bf.remove_from_project if bf.file_ref == old.product_reference
    end
  end
  old.remove_from_project
end
project.groups.select { |g| g.display_name == EXT_NAME }.each(&:remove_from_project)
# Remove any leftover "Embed App Extensions" copy phases (idempotency).
runner.build_phases
  .select { |p| p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && p.display_name == "Embed App Extensions" }
  .each(&:remove_from_project)

# --- create the extension target ----------------------------------------
ext = project.new_target(:app_extension, EXT_NAME, :ios, DEPLOY)

ext_group = project.main_group.new_group(EXT_NAME, EXT_NAME)
%w[PacketTunnelProvider.swift AuroraPlatform.swift].each do |f|
  ref = ext_group.new_reference(f)
  ext.source_build_phase.add_file_reference(ref)
end

# Libbox.xcframework: link + embed into the extension bundle.
xcfw_ref = ext_group.new_reference("Libbox.xcframework")
ext.frameworks_build_phase.add_file_reference(xcfw_ref)
embed_fw = ext.new_copy_files_build_phase("Embed Frameworks")
embed_fw.symbol_dst_subfolder_spec = :frameworks
bf = embed_fw.add_file_reference(xcfw_ref)
bf.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }

# Info.plist + entitlements references (just for navigator visibility)
ext_group.new_reference("Info.plist")
ext_group.new_reference("PacketTunnel.entitlements")

ext.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"]   = EXT_ID
  s["PRODUCT_NAME"]                = "$(TARGET_NAME)"
  s["INFOPLIST_FILE"]              = "#{EXT_NAME}/Info.plist"
  s["CODE_SIGN_ENTITLEMENTS"]      = "#{EXT_NAME}/PacketTunnel.entitlements"
  s["CODE_SIGN_STYLE"]             = "Automatic"
  s["DEVELOPMENT_TEAM"]            = TEAM
  s["IPHONEOS_DEPLOYMENT_TARGET"]  = DEPLOY
  s["SWIFT_VERSION"]               = "5.0"
  s["GENERATE_INFOPLIST_FILE"]     = "NO"
  s["SKIP_INSTALL"]                = "YES"
  s["FRAMEWORK_SEARCH_PATHS"]      = ["$(inherited)", "$(PROJECT_DIR)/#{EXT_NAME}"]
  # Go's net resolver (inside libbox) references libresolv (_res_9_n*).
  s["OTHER_LDFLAGS"]               = ["$(inherited)", "-lresolv"]
  s["LD_RUNPATH_SEARCH_PATHS"]     = ["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"]
  s["MARKETING_VERSION"]           = "1.0"
  s["CURRENT_PROJECT_VERSION"]     = "1"
  s["TARGETED_DEVICE_FAMILY"]      = "1,2"
end

# --- embed extension into Runner + dependency ----------------------------
runner.add_dependency(ext)
embed_ext = runner.new_copy_files_build_phase("Embed App Extensions")
embed_ext.symbol_dst_subfolder_spec = :plug_ins
ebf = embed_ext.add_file_reference(ext.product_reference)
ebf.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }
# Must run BEFORE Flutter's "Thin Binary" script phase, otherwise the new build
# system reports a dependency cycle between embed + thin-binary.
phases = runner.build_phases
phases.delete(embed_ext)
thin_idx = phases.find_index { |p| (p.respond_to?(:name) && p.name) ? p.name == "Thin Binary" : p.display_name == "Thin Binary" } || phases.count
phases.insert(thin_idx, embed_ext)

# --- Runner target: bundle id, entitlements, signing, AuroraVPN.swift, libbox
runner_group = project.main_group.find_subpath("Runner", true)
unless runner.source_build_phase.files_references.any? { |r| r && r.path&.end_with?("AuroraVPN.swift") }
  av = runner_group.new_reference("AuroraVPN.swift")
  runner.source_build_phase.add_file_reference(av)
end
unless runner_group.files.any? { |r| r.path == "Runner.entitlements" }
  runner_group.new_reference("Runner.entitlements")
end

# aurora-global.json is no longer bundled: start() now writes the Dart
# ConfigCompiler output straight into the App Group container, and the offline
# fallback contract ships as a Flutter asset (assets/configs). Drop the stale
# resource so the build doesn't depend on a gitignored file.
runner.resources_build_phase.files.dup.each do |bf|
  bf.remove_from_project if bf.file_ref&.path&.to_s&.end_with?("aurora-global.json")
end
project.files.select { |f| f.path&.to_s&.end_with?("aurora-global.json") }.each(&:remove_from_project)

# Libbox.xcframework: LINK (do NOT embed) into the app target as well, so
# AuroraVPN can drive a libbox CommandClient against the extension's
# CommandServer. The xcframework is a STATIC archive (ar) — linking pulls the Go
# code into the app binary, so there's nothing to embed; -lresolv (added via
# Flutter/{Debug,Release}.xcconfig) satisfies Go's libresolv (_res_9_*) refs.
runner.frameworks_build_phase.files.dup.each do |bf|
  bf.remove_from_project if bf.file_ref&.display_name == "Libbox.xcframework"
end
runner.frameworks_build_phase.add_file_reference(xcfw_ref)

runner.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"] = APP_ID
  s["CODE_SIGN_ENTITLEMENTS"]    = "Runner/Runner.entitlements"
  s["CODE_SIGN_STYLE"]           = "Automatic"
  s["DEVELOPMENT_TEAM"]          = TEAM
end

project.save
puts "OK: PacketTunnel target added. Targets => #{project.targets.map(&:name).join(', ')}"
