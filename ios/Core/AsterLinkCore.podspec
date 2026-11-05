Pod::Spec.new do |s|
  s.name = 'AsterLinkCore'
  s.version = '1.0.0'
  s.summary = 'AsterLink in-process download transport'
  s.homepage = 'https://github.com/z7786/wenxi'
  s.license = { :type => 'MIT', :file => '../../native/gopeed/LICENSE' }
  s.author = { 'AsterLink' => 'https://github.com/z7786/wenxi' }
  s.source = { :path => '.' }
  s.platform = :ios, '13.0'
  s.vendored_frameworks = 'AsterLinkCore.xcframework'
  s.libraries = 'resolv'
end
