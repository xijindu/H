Pod::Spec.new do |spec|
  spec.name = 'TgVoipWebrtc'
  spec.version = '1.0.0'
  spec.summary = 'Telegram iOS group-call media engine'
  spec.homepage = 'https://github.com/TelegramMessenger/Telegram-iOS'
  spec.license = { :type => 'LGPL-3.0', :file => 'LICENSE' }
  spec.author = 'Telegram Messenger LLP'
  spec.platform = :ios, '15.0'
  spec.source = { :path => '.' }
  spec.module_name = 'TgVoipWebrtc'
  spec.static_framework = true
  spec.vendored_frameworks = 'TgVoipWebrtc.xcframework'
end
