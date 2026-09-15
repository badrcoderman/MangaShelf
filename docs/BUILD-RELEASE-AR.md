# البناء والإصدار

## Linux/CI

لا تعتمد على وجود الملف وحده. شغّل:

```bash
python3 scripts/test_native.py
python3 scripts/run_sanitizers.py
python3 scripts/test_packaging.py
python3 scripts/audit_project.py
```

هذه تفحص C/Python/manifest ولا تبني Swift.

## macOS/Xcode

استخدم Xcode 26 وSDK يدعم iOS 26.0. تحقق من:

```bash
xcodebuild -version
xcodebuild -showsdks
```

ثم:

```bash
bash scripts/build-ios.sh simulator
bash scripts/build-ios.sh unsigned
```

لا تستخدم `unsigned.ipa` على جهاز إلا بعد توقيع صالح. للأرشفة:

```bash
export MANGASHELF_TEAM_ID='YOUR_TEAM_ID'
export MANGASHELF_BUNDLE_ID='app.mangashelf.reader'
bash scripts/build-ios.sh archive
bash scripts/build-ios.sh export
```

لا تضع شهادات أو provisioning profiles أو tokens داخل المستودع. افحص IPA الناتج: Payload واحد، bundle identifier صحيح، architecture arm64، لا JAR/APK/dylib غير متوقع، وPrivacyInfo.xcprivacy حاضر. احسب SHA-256 وسجل commit/Xcode/SDK.

## SideStore

اختبر تثبيت IPA الموقعة على جهاز فعلي، ثم افتح كل تبويب، استورد CBZ، عطّل الشبكة واختبر القراءة المحلية، اختبر اللغة والتدوير وDynamic Type وVoiceOver، وراقب الذاكرة/الحرارة/السجل. سجّل المشكلة مع الجهاز والإصدار والcommit بدل تخمين السبب.
