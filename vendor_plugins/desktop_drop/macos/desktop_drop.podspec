Pod::Spec.new do |s|
  s.name = 'desktop_drop'
  s.version = '0.8.4'
  s.summary = 'Desktop file drop destination'
  s.homepage = 'https://github.com/MixinNetwork/flutter-plugins'
  s.license = { :file => '../LICENSE' }
  s.author = { 'Mixin' => 'https://github.com/MixinNetwork' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '11.0'
  s.swift_version = '5.0'
end
