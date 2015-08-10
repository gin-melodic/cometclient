source 'https://github.com/CocoaPods/Specs.git'

platform :ios, '7.0'
inhibit_all_warnings!

xcodeproj 'CometClient'


pod 'Reachability'
pod 'SocketRocket', '~> 0.3.1-beta2'

post_install do |installer|
    installer.project.targets.each do |target|
        target.build_configurations.each do |config|
            config.build_settings['ENABLE_STRICT_OBJC_MSGSEND'] = "NO"
        end
    end
end