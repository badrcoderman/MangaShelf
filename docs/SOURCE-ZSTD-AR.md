# Zstd من المصدر وربط JNI

التاريخ: 24 أكتوبر 2026. تقدم في ENG-05 وENG-16؛ لا IPA جديدة أو تشغيل
إضافة منشورة أو تنفيذ codec على iPhone بهذه الخطوة.

## المدخلات

`runtime-host/zstd-source.lock.json` يثبت مجموعات الملفات كاملة، بالأحجام
وSHA-256 وGit blob SHA-1، قبل تشغيل compiler:

| المجموعة | المصدر المثبت | الملفات | الرخصة المحتفظ بها |
| --- | --- | --- | --- |
| Kotlin وOkio | square/okio-zstd عند `4fbdf35df030888d2a0cce4a84329d107438134f` | 11 Kotlin وLICENSE | Apache-2.0 |
| Zstd C 1.5.8 | facebook/zstd عند `1dbc2e09084e843f6c0dcc2d0791610015c50979` | 61 C/header في common/compress/decompress وzstd.h وzstd_errors.h وLICENSE وCOPYING | BSD-3-Clause، مع إبقاء COPYING أيضًا |
| JNI headers | openjdk/mobile عند `c1ed06aaef34c8dccf71e236d1ffa20918a77cfb` | jni.h وjni_md.h و3 إشعارات | GPLv2 مع Classpath exception كما في الأصل |

طابقت ملفات Kotlin الـ11 source archives العامة لـMaven 0.4.0 قبل النقل.
النسخ الخام لم تعدل. لا تنفيذ build scripts من هذه المستودعات، ولا استخدام
native bytes من JAR منشورة أو IPA المرجع. تستخدم الخطوات compiler المثبتة
والمتحقق منها سابقًا، وClang وأدوات النظام المضيف.

التعديل الوحيد على مصدر Kotlin، في نسخة البناء المؤقتة، موثق بالبصمات
والنصوص في `zstd-compat.patch.json`: استبدال استخراج مكتبة مؤقتة وفحص
`os.name` بـ`System.loadLibrary("mslzstd")`. هذا يسمح للـVM بالعثور على
مكتبة مرتبطة مسبقًا، دون تغيير اسم Darwin على الهاتف. اختبار المضيف يمرر
Darwin مؤقتًا لفحص loader ثم يعيد قيمة المضيف؛ ليس محاكاة iOS.

`build-runtime-host.py` يبني core وOkio بوحدتي metadata منفصلتين، ويحتفظ
بـApache notice داخل JAR. وُسم ملف JNI المشترك الذي يحتوي `expect` كـcommon
input عند استدعاء compiler، مع إبقاء المصدر الخام. JAR لا تحتوي مكتبة
أصلية أو test hooks أو أصناف fixture. حُجز namespace `com.squareup.zstd`
للمضيف في محمّل الإضافات لحفظ هوية هذه الأنواع.

## المحوّل الأصلي

`runtime-native/MSZstdJNI.c` تنفيذ MSL مستقل لعقد JNI المستخدم من هذه
المصادر؛ لا يبني محوّل C++ المنشور. الـlong الممرر من Java رقم في سجل
محدود وليس عنوان ذاكرة. التحقق يشمل وجود السياق ونوعه، حدود المصفوفات وnull
والتداخل وstream mode قبل الوصول إلى الذاكرة. أقصى عدد سياقات حية 128،
وبحد نافذة فك ضغط 64 MiB لكل decoder؛ هذا ليس حدًا لإجمالي حجم المخرجات.
تظل حدود الشبكة/JSON الإجمالية مسؤولية ربط المصدر اللاحق.

لكل سياق mutex للعمل ومراجع native تحميه من الإغلاق المتزامن. الإغلاق يمنع
الاستدعاءات الجديدة ويترك عملية سبقت الإغلاق تنتهي قبل تحرير السياق.
السياقات الأخرى تعمل بالتوازي. فشل حجز مصفوفة أو class global reference
يحافظ على استثناء JVM وينظف ما حُجز. يحتفظ المحوّل بمراجع أصناف codec
التابعة للمضيف، ولا يحتفظ بكائن أو classloader خاص بالإضافة.

تسمح [مواصفات JNI](https://docs.oracle.com/en/java/javase/25/docs/specs/jni/functions.html#newglobalref)
برجوع NULL دون استثناء في بعض حالات الفشل؛ لذلك يعالج المحوّل NULL صراحة
في إنشاء المراجع والبحث عن metadata وإنتاج نص الخطأ، مع إبقاء استثناء قائم
إن وجد. يشمل حقن الفشل رجوع NULL بلا استثناء للمراجع ونص الخطأ أيضًا.

`msl_zstd_shutdown(env)` يتطلب إيقاف استدعاءات Java الجديدة وانتظار عمليات
المصدر/native قبل استدعائه. يرفض الإغلاق أثناء عمل native ما زال قائمًا؛
وإلا يغلق السياقات الخاملة المتبقية ويزيل class global refs. الأرقام لا
يعاد استخدامها بعد الإغلاق. المحوّل يسمح بعمر codec جديد في VM نفسها؛ هذا
لا يثبت إنشاء VM ثانية بعد DestroyJavaVM على iPhone.

## البناء والاختبار

```sh
python3 scripts/test-runtime-zstd.py
# macOS + iOS SDK 26 أو أحدث فقط:
python3 scripts/build-zstd-native.py --target ios
```

المضيف يبني C في 26 ملفًا والمحوّل في ملف منفصل، دون assembly أو worker
threads من Zstd. الناتج الإنتاجي `libmslzstd.a`. ملفات test static/shared
منفصلة، وتضم hooks لحقن فشل الحجز وبوابة تزامن؛ لا تضم النسخة الإنتاجية
هذه hooks. الإشعارات الأصلية تُنسخ إلى مجلد `notices` بجانب المكتبة.

نجح محليًا 17 فحصًا لكل من dynamic وbuiltin، مع `-Xcheck:jni` و`-Xint`:

- loader مع اسم Darwin، وraw/RLE vectors مؤلفة، وempty/binary/Arabic/NUL،
  و1 MiB من بيانات مؤلفة، وoffsets ومخازن صغيرة وbyte counters.
- flush وframes متتالية، وtruncation وchecksum تالف ونافذة كبيرة، وparameters
  وأسماء أخطاء codec.
- إغلاق مكرر واستدعاء بعد الإغلاق، وbounds/null/alias، وأرقام handles/table
  مزيفة أو بنوع غير صحيح، دون استخدام عنوان ذاكرة مشتق من المدخل.
- حقن فشل أول/ثاني array acquisition، وفشل context/global refs وGetFieldID،
  مع نجاح إعادة المحاولة وعدم تسرب السياقات والمراجع.
- إغلاق أثناء native call محجوزة، واستمرار سياق آخر، ورفض shutdown أثناء
  العمل، وإغلاق الخامل وإعادة فتحه دون alias للأرقام القديمة، و8 streams
  متزامنة، وفشل Source/Sink وتنظيفهما.

فحص builtin يستخدم executable مؤلفًا يربط المكتبة static ويصدر
`JNI_OnLoad_mslzstd`، ثم ينشئ JVM المضيف مع `java.library.path` فارغ.
يسجل hook أن مدخل builtin المسمى استُدعي فعلًا، وليس مدخل shared library
العام. انتهت fixture وأُزيلت مراجع codec ثم نجح DestroyJavaVM.
لا extraction إلى tmp في كلا النمطين. حقن الفشل يثبت مسارات التنظيف على
المضيف، ولا يثبت استنفاد ذاكرة iPhone فعليًا.

التقارير: `validation/runtime-zstd-host.json` و`validation/zstd-native-host.json`
و`validation/runtime-host-build.json`. CI أضيف له تشغيل النمطين على Linux
وmacOS، ثم بناء archive وlink probe لـarm64 iOS على macOS وفحص platform
والرموز وغياب hooks.

نجحت المجموعة الكاملة عند `29a1379` في
[40036314382](https://github.com/badrcoderman/MangaShelf/actions/runs/40036314382):
API 45/278 و14 نماذج و20 سجلًا و6 bootstrap و16 تفضيلات و17 إعدادات
و16 HTTP/TLS و20 تحميلًا موقّعًا و46 توقيعًا مؤلفًا، إضافة إلى 17 فحص codec
لكل نمط تحميل على كل منصة. طابقت artifacts ذات 25 ملفًا على macOS و17
على Linux الحجم وSHA-256 وCRC ومدخلات المصدر عند ذلك commit.
[الدليل الكامل](../validation/runtime-host-40036314382.json).

بعد تصحيح NULL دون استثناء، أُعيد فحص codec فقط عند `8734c7b` عبر task
`runtime-codec` في
[40037458892](https://github.com/badrcoderman/MangaShelf/actions/runs/40037458892).
نجحت 17 حالة بكل نمط على المنصتين، مع إعادة build/link iOS. حُذفت التقارير
التاريخية قبل تشغيل task، ولم تُرفع فحوص المجموعة الكاملة المتجاوزة كأنها
أُعيدت؛ artifact الجديدة تضم 18 ملفًا على macOS و10 على Linux.
[دليل التصحيح](../validation/runtime-codec-40037458892.json).

فُحصت archive الإنتاجية: 27 object من نوع arm64/iOS device. فُحص executable
المربوط: iOS 26.0 وSDK 26.0، مع فك export trie والتحقق من مدخلي OnLoad/OnUnload
والدوال التسع لـJNI، وعدم وجود test hooks. تطابقت JAR بين المنصتين وبين
التشغيل الكامل وتصحيح native اللاحق، بما في ذلك كل class/resource بعد فكها.
لا تُعد ترجمة أو رموز link probe تنفيذًا على الهاتف أو تفعيلًا داخل MSL.

## المتبقي

ربط archive الإنتاجية داخل تطبيق iOS مع إبقاء رموز JNI في symbol table،
واستخدام إعداد native access الصريح نفسه الموجود في الفحوص
(`--enable-native-access=ALL-UNNAMED`)، واستدعاء shutdown بعد إغلاق المصادر
وقبل VM، ثم إثبات الضغط وفك الضغط على
الهاتف. كذلك بقيت بقية JSON/Brotli/Android التي يحتاجها المصدر، ونقل
الشبكة/TLS، وowned JNI/نماذج المصدر/الجلسات في Swift، وتدفق إضافة حقيقية
والإلغاء وإعادة التشغيل وبناء IPA. لا يغلق نجاح host أو link probe ENG-16.

الجرد الثابت لمرشح MangaDex المعاد بناؤه كشف 11 class reference غير محلولة
في classpath الحالية: Build.VERSION وSystemClock وLog، وActivity/Intent/Bundle
وActivityNotFoundException المستخدمة في UrlActivity، وBrotli/BrotliInterceptor
وOkHttp Zstd وJsoup Parser. هذا جرد class/descriptor فقط، ولا يثبت أن جميع
الطرق أو reflection أو التبعيات غير المباشرة جاهزة.
[الجرد وبصماته](../validation/mangadex-runtime-dependencies-static.json).
