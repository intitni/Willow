#!/usr/bin/env ruby
require 'xcodeproj'
root = File.expand_path('..', __dir__)
project = Xcodeproj::Project.new(File.join(root, 'Willow.xcodeproj'))
target = project.new_target(:application, 'Willow', :ios, '26.0')
group = project.main_group.new_group('Willow', 'Willow')
Dir.glob(File.join(root, 'Willow/App/*.swift')).sort.each do |path|
  reference = group.new_file(path.delete_prefix(root + '/Willow/'))
  target.source_build_phase.add_file_reference(reference)
end
icon = group.new_file('Willow_icon.icon')
icon.last_known_file_type = 'folder.icon'
target.resources_build_phase.add_file_reference(icon)
# 本地化资源由各 Swift package target 管理。
signing = project.main_group.new_file('Config/Signing.xcconfig')
package_reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_reference.relative_path = 'Core'
project.root_object.package_references << package_reference
product = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product.package = package_reference
product.product_name = 'Core'
target.package_product_dependencies << product
build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product
target.frameworks_build_phase.files << build_file
project.root_object.known_regions = ['en', 'zh-Hans', 'Base']
project.root_object.development_region = 'en'
%w[Info.plist Willow.entitlements].each { |name| group.new_file(name) }
phase = target.new_shell_script_build_phase('Build Breeze plugin runtime')
phase.shell_script = '"${SRCROOT}/Scripts/build-rust.sh"'
phase.always_out_of_date = '1'
target.build_phases.delete(phase)
target.build_phases.insert(0, phase)
target.build_configurations.each do |config|
  config.base_configuration_reference = signing
  settings = config.build_settings
  profile = config.name == 'Release' ? 'release' : 'debug'
  settings.merge!({
    'PRODUCT_BUNDLE_IDENTIFIER' => 'com.intii.Willow',
    'MARKETING_VERSION' => '1.0.0',
    'CURRENT_PROJECT_VERSION' => '1',
    'PRODUCT_NAME' => 'Willow',
    'ASSETCATALOG_COMPILER_APPICON_NAME' => 'Willow_icon',
    'INFOPLIST_FILE' => 'Willow/Info.plist',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'SWIFT_VERSION' => '6.0',
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
    'CODE_SIGN_ENTITLEMENTS' => 'Willow/Willow.entitlements',
    'CODE_SIGN_STYLE' => 'Automatic',
    'TARGETED_DEVICE_FAMILY' => '1,2',
    'SUPPORTED_PLATFORMS' => 'iphoneos iphonesimulator',
    'SUPPORTS_MACCATALYST' => 'NO',
    'ENABLE_USER_SCRIPT_SANDBOXING' => 'NO',
    'ARCHS' => 'arm64',
    'OTHER_LDFLAGS' => ['$(inherited)', '-lwillow_bridge', '-lc++', '-lz', '-framework', 'SystemConfiguration', '-framework', 'Security'],
    'LIBRARY_SEARCH_PATHS[sdk=iphoneos*]' => "$(SRCROOT)/Bridge/target/aarch64-apple-ios/#{profile}",
    'LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*]' => "$(SRCROOT)/Bridge/target/aarch64-apple-ios-sim/#{profile}",
    'SWIFT_EMIT_LOC_STRINGS' => 'YES'
  })
end
project.save
scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(File.join(root, 'Willow.xcodeproj'), 'Willow', true)
