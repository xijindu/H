require 'xcodeproj'

proj_path = File.join(__dir__, 'Runner.xcodeproj')
project = Xcodeproj::Project.open(proj_path)
target = project.targets.find { |t| t.name == 'Runner' }
abort 'Runner target not found' unless target

# File reference to the vendored xcframework (relative to ios/ = SOURCE_ROOT).
group = project.main_group['Frameworks'] || project.main_group.new_group('Frameworks')
existing = group.files.find { |f| f.path && f.path.end_with?('tdjson.xcframework') }
ref = existing || group.new_file('tdjson/tdjson.xcframework')

# 1) Link Binary With Libraries
target.frameworks_build_phase.add_file_reference(ref, true)

# 2) Embed Frameworks (copy into .app/Frameworks, code-sign on copy)
embed = target.copy_files_build_phases.find { |p| p.symbol_dst_subfolder_spec == :frameworks }
unless embed
  embed = target.new_copy_files_build_phase('Embed Frameworks')
  embed.symbol_dst_subfolder_spec = :frameworks
end
bf = embed.add_file_reference(ref, true)
bf.settings = { 'ATTRIBUTES' => ['CodeSignOnCopy', 'RemoveHeadersOnCopy'] }

# 3) Build settings: framework search path + deployment target (tdjson supports iOS 15)
(target.build_configurations + project.build_configurations).each do |c|
  c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
  paths = c.build_settings['FRAMEWORK_SEARCH_PATHS']
  paths = paths ? Array(paths) : ['$(inherited)']
  paths << '$(PROJECT_DIR)/tdjson' unless paths.include?('$(PROJECT_DIR)/tdjson')
  c.build_settings['FRAMEWORK_SEARCH_PATHS'] = paths
end

project.save
puts "OK: linked + embedded tdjson.xcframework into Runner; deployment target 15.0"
puts "Link phase files: #{target.frameworks_build_phase.files.map { |f| f.display_name }.join(', ')}"
puts "Embed phase files: #{embed.files.map { |f| f.display_name }.join(', ')}"
