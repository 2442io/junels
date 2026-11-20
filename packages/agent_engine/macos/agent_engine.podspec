#
# Bindet die vorgebaute AgentEngine.xcframework (llama.cpp + Metal) ein.
# Gebaut wird sie mit scripts/build_apple_framework.sh.
#
Pod::Spec.new do |s|
  s.name             = 'agent_engine'
  s.version          = '1.0.0'
  s.summary          = 'Lokale LLM-Engine (llama.cpp) für die Offline Agent App.'
  s.description      = 'llama.cpp mit Metal-Beschleunigung als dynamisches Framework.'
  s.homepage         = 'https://github.com/2442io/junels'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Offline Agent' => 'offline@localhost' }
  s.source           = { :path => '.' }
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '12.0'
  s.vendored_frameworks = 'Frameworks/AgentEngine.xcframework'
  s.frameworks = 'Metal', 'MetalKit', 'Foundation', 'Accelerate'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
