# CocoaPods, only for libsignal: Signal ships LibSignalClient as a CocoaPod (not as a Swift package), the way
# Signal-iOS uses it. Run `pod install` after `xcodegen generate` (scripts/test.sh does both); open ZapaKid.xcworkspace.
# Bump libsignal by hand (Dependabot can't): see CONTRIBUTING.md.
platform :ios, '17.0'
use_frameworks!
install! 'cocoapods', warn_for_unused_master_specs_repo: false

# SHA-256 of Signal's prebuilt libsignal_ffi.a archive for this release, from the release asset
# libsignal-client-ios-build-v0.106.0.tar.gz.sha256. The pod's build phase refuses an archive that doesn't match.
ENV['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] = 'ddfa5ac6fd6e0da9ebe4eb23890af048140aec1a3e916d3eccadc1036627152f'

target 'ZapaKid' do
  pod 'LibSignalClient', git: 'https://github.com/signalapp/libsignal.git', tag: 'v0.106.0'

  target 'ZapaKidTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
      # libsignal_ffi.a contains BoringSSL (C++); link the C++ standard library with it.
      config.build_settings['OTHER_LDFLAGS'] = '$(inherited) -lc++' if target.name == 'LibSignalClient'
    end
  end
end
