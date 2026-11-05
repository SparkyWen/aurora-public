#!/usr/bin/env ruby
# Adds the Aurora PacketTunnel SYSTEM EXTENSION target to the Flutter macOS
# Runner project and wires sources / entitlements / signing / libbox linking —
# the scripted equivalent of app/macos/README.md steps 3–7 (macOS twin of
# app/ios/add_packettunnel.rb, which builds an *app extension* instead).
# Idempotent: re-running removes the prior PacketTunnel target first.

require "xcodeproj"

MACOS_DIR = File.expand_path(File.dirname(__FILE__))           # app/macos
PROJ_PATH = File.join(MACOS_DIR, "Runner.xcodeproj")
# Team and bundle id come from the environment (see scripts/set-apple-identity.sh).
TEAM      = ENV.fetch("AURORA_APPLE_TEAM", "")
EXT_ID    = "#{ENV.fetch("AURORA_BUNDLE_ID", "com.aurora.vpn")}.PacketTunnel"
DEPLOY    = "12.0"
EXT_NAME  = "PacketTunnel"
# The xcframework lives with the iOS extension; the macos-arm64_x86_64 slice
# inside it is what this project links (static archive, so link — never embed).
XCFW_PATH = "../ios/PacketTunnel/Libbox.xcframework"

project = Xcodeproj::Project.open(PROJ_PATH)
runner  = project.targets.find { |t| t.name == "Runner" }
raise "Runner target not found" unless runner

# --- clean previous run --------------------------------------------------
if (old = project.targets.find { |t| t.name == EXT_NAME })
  runner.dependencies.dup.each { |d| d.remove_from_project if d.target == old }
  runner.build_phases.grep(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase).each do |ph|
    ph.files.dup.each do |bf|
      bf.remove_from_project if bf.file_ref == old.product_reference
    end
  end
  old.remove_from_project
end
project.groups.select { |g| g.display_name == EXT_NAME }.each(&:remove_from_project)
runner.build_phases
  .select { |p| p.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) && p.display_name == "Embed System Extensions" }
  .each(&:remove_from_project)

# --- create the extension target -----------------------------------------
# xcodeproj has no :system_extension template; create an :app_extension for
# :osx and convert the product type + wrapper (what Xcode's NE template does).
# CRITICAL: a system-extension bundle MUST be named "<full-bundle-id>.systemextension"
# (its directory name == its CFBundleIdentifier). OSSystemExtensionRequest matches
# the requested identifier against the bundle NAME during enumeration; a bundle
# named "PacketTunnel.systemextension" for id "com.aurora.vpn.PacketTunnel" is silently
# skipped → activationRequest fails with OSSystemExtensionErrorDomain code 4
# "Extension not found in App bundle". So PRODUCT_NAME must be the full EXT_ID.
ext = project.new_target(:app_extension, EXT_NAME, :osx, DEPLOY)
ext.product_type = "com.apple.product-type.system-extension"
prod = ext.product_reference
prod.explicit_file_type = "wrapper.system-extension"
prod.name = "#{EXT_ID}.systemextension"
prod.path = "#{EXT_ID}.systemextension"

ext_group = project.main_group.new_group(EXT_NAME, EXT_NAME)
%w[main.swift PacketTunnelProvider.swift AuroraPlatform.swift].each do |f|
  ref = ext_group.new_reference(f)
  ext.source_build_phase.add_file_reference(ref)
end
# Info.plist + entitlements references (navigator visibility only)
ext_group.new_reference("Info.plist")
ext_group.new_reference("PacketTunnel.entitlements")

# Libbox.xcframework: LINK only (static ar archive — nothing to embed).
# Anchor to SOURCE_ROOT (app/macos) — a group-relative path would resolve
# against macos/PacketTunnel and point at a non-existent macos/ios/… tree.
xcfw_ref = ext_group.new_reference(XCFW_PATH)
xcfw_ref.source_tree = "SOURCE_ROOT"
xcfw_ref.path = XCFW_PATH
ext.frameworks_build_phase.add_file_reference(xcfw_ref)

ext.build_configurations.each do |c|
  s = c.build_settings
  s["PRODUCT_BUNDLE_IDENTIFIER"]  = EXT_ID
  # PRODUCT_NAME = full bundle id so the built bundle is "<id>.systemextension"
  # (see note above). Keep PRODUCT_MODULE_NAME stable ("PacketTunnel") so the
  # Info.plist NEProviderClasses value $(PRODUCT_MODULE_NAME).PacketTunnelProvider
  # still resolves to the Swift class in the source module.
  s["PRODUCT_NAME"]               = EXT_ID
  s["PRODUCT_MODULE_NAME"]        = "PacketTunnel"
  s["INFOPLIST_FILE"]             = "#{EXT_NAME}/Info.plist"
  s["CODE_SIGN_ENTITLEMENTS"]     = "#{EXT_NAME}/PacketTunnel.entitlements"
  # Developer ID + notarization is the ONLY path that activates a system
  # extension with SIP on (dev-signed needs `systemextensionsctl developer on`
  # → SIP off). Build here with Automatic/Development signing, then re-sign to
  # Developer ID via `xcodebuild archive` + `-exportArchive method=developer-id`
  # (Xcode auto-creates the Developer ID profiles carrying the NE capability).
  s["CODE_SIGN_STYLE"]            = "Manual"
  s["CODE_SIGN_IDENTITY"]         = "Developer ID Application"
  s["PROVISIONING_PROFILE_SPECIFIER"] = "Aurora PacketTunnel DevID"
  s["DEVELOPMENT_TEAM"]           = TEAM
  s["MACOSX_DEPLOYMENT_TARGET"]   = DEPLOY
  s["ENABLE_HARDENED_RUNTIME"]    = "YES"   # required for notarization
  s["OTHER_CODE_SIGN_FLAGS"]      = "--timestamp"        # secure timestamp (notarization)
  s["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = "NO"          # no get-task-allow in Developer ID
  s["SWIFT_VERSION"]              = "5.0"
  s["GENERATE_INFOPLIST_FILE"]    = "NO"
  s["SKIP_INSTALL"]               = "YES"
  s["WRAPPER_EXTENSION"]          = "systemextension"
  # NO $(inherited) here: the Runner/Pods config's OTHER_LDFLAGS links the Flutter
  # plugin frameworks (flutter_secure_storage_macos, tray_manager, …). Inheriting
  # them makes the extension dyld-crash at launch ("Library not loaded:
  # @rpath/flutter_secure_storage_macos.framework") because those frameworks live
  # only in the app, not the extension. The extension links ONLY Libbox + Cocoa
  # (via its Frameworks phase) + libresolv (Go net resolver _res_9_n*).
  s["FRAMEWORK_SEARCH_PATHS"]     = ["$(PROJECT_DIR)/../ios/PacketTunnel"]
  s["OTHER_LDFLAGS"]              = ["-lresolv"]
  s["MARKETING_VERSION"]          = "1.0"
  s["CURRENT_PROJECT_VERSION"]    = "2"
end

# --- embed extension into Runner + dependency -----------------------------
runner.add_dependency(ext)
embed_ext = runner.new_copy_files_build_phase("Embed System Extensions")
embed_ext.symbol_dst_subfolder_spec = :products_directory
embed_ext.dst_path = "$(SYSTEM_EXTENSIONS_FOLDER_PATH)"
ebf = embed_ext.add_file_reference(ext.product_reference)
ebf.settings = { "ATTRIBUTES" => ["RemoveHeadersOnCopy"] }

# --- Runner target: sources, libbox link, signing -------------------------
runner_group = project.main_group.find_subpath("Runner", true)
%w[AuroraVPN.swift SystemExtensionInstaller.swift].each do |f|
  next if runner.source_build_phase.files_references.any? { |r| r && r.path.to_s.end_with?(f) }
  ref = runner_group.files.find { |r| r.path == f } || runner_group.new_reference(f)
  runner.source_build_phase.add_file_reference(ref)
end

# AuroraVPN.swift imports Libbox (CommandClient against the extension's
# CommandServer) — link the same static xcframework into the app binary.
runner.frameworks_build_phase.files.dup.each do |bf|
  bf.remove_from_project if bf.file_ref&.display_name == "Libbox.xcframework"
end
runner.frameworks_build_phase.add_file_reference(xcfw_ref)

runner.build_configurations.each do |c|
  s = c.build_settings
  s["CODE_SIGN_STYLE"]        = "Manual"
  s["CODE_SIGN_IDENTITY"]     = "Developer ID Application"
  s["PROVISIONING_PROFILE_SPECIFIER"] = "Aurora macOS App DevID"
  s["DEVELOPMENT_TEAM"]       = TEAM
  s["ENABLE_HARDENED_RUNTIME"] = "YES"   # required for notarization
  s["OTHER_CODE_SIGN_FLAGS"]  = "--timestamp"        # secure timestamp (notarization)
  s["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = "NO"      # no get-task-allow in Developer ID
  s["FRAMEWORK_SEARCH_PATHS"] = ["$(inherited)", "$(PROJECT_DIR)/../ios/PacketTunnel"]
  s["OTHER_LDFLAGS"]          = ["$(inherited)", "-lresolv"]
end

project.save
puts "OK: PacketTunnel system-extension target added. Targets => #{project.targets.map(&:name).join(', ')}"
