Pod::Spec.new do |s|
  s.name = 'asterlink_js'
  s.version = '1.0.0'
  s.summary = 'Bounded QuickJS source runtime for AsterLink'
  s.homepage = 'https://github.com/z7786/wenxi'
  s.license = { :type => 'MIT', :file => '../src/quickjs/LICENSE' }
  s.author = { 'AsterLink' => 'https://github.com/z7786/wenxi' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/*.c'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_C_LANGUAGE_STANDARD' => 'gnu11',
    'GCC_SYMBOLS_PRIVATE_EXTERN' => 'NO',
    'HEADER_SEARCH_PATHS' => '"${PODS_TARGET_SRCROOT}/../src/quickjs"'
  }
end
