# إعدادات المصادر — تنفيذ المضيف

التاريخ: 24 أكتوبر 2026. هذه خطوة في ENG-05؛ ليست تفعيل إضافات iOS أو
واجهة إعدادات SwiftUI. لا توجد IPA جديدة بهذه الخطوة.

## العقد الذي نُفذ

- `ConfigurableSource.setupPreferenceScreen(PreferenceScreen)` وواجهات
  `androidx.preference` المثبتة من extensions-lib عند
  `42255ee5fa96d9425697b7c143587483207308d1`.
- قائمة اختيار، اختيار متعدد، مفاتيح تبديل، checkbox، إدخال نص وصفوف
  action، مع key/title/summary/enabled/visible/default والقيم ومستمعي التغيير
  والنقر وربط محرر النص.
- مطابقة ABI تشمل الآن 45 صنفًا و278 عضوًا عامًا/محميًا. التحقق يشمل
  الوراثة والظهور وstatic والـdescriptors؛ ليس مجرد وجود أسماء الأصناف.
- حفظ القيم في `SharedPreferences` الخاصة بـ`source_<signed Long id>`،
  واستعادة القيمة المحفوظة قبل default. لا تُستدعى change listeners عند
  تعيين قيمة برمجيًا أو استعادة default. يسبق مستمع التغيير اعتماد تعديل
  المستخدم ويمكنه رفضه. القيم غير المدرجة والصفوف المخفية/المعطلة ترفض التعديل.
- نسخ defensive للخيارات والمجموعات وlabels؛ summary من نوع `%s` لقائمة
  الاختيار يعرض اسم الخيار الحالي. نسخ الشاشة المرسلة للمضيف قيم immutable.

البناء مستقل، ولا يستخدم أصناف specimen أو stubs ترمي عند استدعاء الإعدادات.
مصدر MangaDex العام المثبت عند
`1d3d7c4b3e876fb0c26ae3ade8113fb329af15fa` دُرس نصيًا فقط: إعداداته
تحتوي 12 صفًا (قائمة و7 مفاتيح و2 اختيار متعدد و2 إدخال UUID)، ويستخدم
TextWatcher وخطأ EditText وتعطيل زر الموافقة. الفحص المؤلف يحاكي هذه الأنواع
والتفاعل دون نسخ أو تنفيذ أصناف MangaDex.

## التحقق من النص

تنفيذ صغير لـ`View` و`TextView` و`Button` و`EditText` و`Editable` و
`TextWatcher` يمرر النص إلى bind callback ثم before/on/afterTextChanged.
الإحداثيات UTF-16، ويمكن للـwatcher تعديل النص عبر Editable. توجد عقدة root
وزر موجب بمعرّف Android `16908313`، ليعمل نمط
`rootView.findViewById<Button>(android.R.id.button1)` المستخدم للتحقق.

الخطأ أو تعطيل الزر يمنع الحفظ واستدعاء change listener. `validateText`
يعيد allowed/error والنص المصحح دون تعديل التفضيل. كل محاولة تحقق تنشئ محررًا مستقلًا
وتزيل watchers بعد انتهائها. هذا نموذج نص وحوار بلا سطح Android أو Looper
أو spans/layout؛ ليس Android SDK كاملًا. نتيجة التحقق لا تحمل محررًا أو
callback إلى Swift.

مراجع العقد العام:
[Preference](https://developer.android.com/reference/androidx/preference/Preference)،
[EditTextPreference](https://developer.android.com/reference/androidx/preference/EditTextPreference)،
[المعرّف button1](https://developer.android.com/reference/android/R.id#button1).

## عمر الشاشة وأرشيف المصدر

`mangashelf.host.SourcePreferenceSession` يشغّل إعداد الشاشة والتعديل والنقر
والتحقق وأخذ snapshots داخل عملية `SourceRegistry.withSource` واحدة طويلة.
تبقى كائنات Preference ومستمعو الإضافة داخل lease الخاصة بالمصدر؛ الذي يخرج
هو DTO من أنواع المضيف فقط، لا source أو listener أو Throwable خاص بالإضافة.
تستخدم الاستدعاءات سياق classloader الخاص بالحزمة عبر التعليق والاستئناف.

واجهة الجلسة: `open` ثم `snapshot` / `change` / `validateText` / `click`،
و`closeAndJoin` عند إغلاق الشاشة. `close()` يبدأ الإلغاء فقط. صفوف snapshot
لها IDs تبدأ من 1 وفق ترتيب الإضافة، ولا تُعرض هذه الأرقام للمستخدم.
يجب على ربط Swift لاحقًا إعادة توجيه الأوامر إلى الجلسة نفسها، وإغلاقها قبل
إغلاق HostServices. لا يجوز الاحتفاظ بصف الإضافة خارج lease ثم استدعاؤه لاحقًا.

عند إزالة الحزمة: تُمنع استدعاءات جديدة، تُلغى عملية الجلسة، تزال callbacks
وتنتهي عملية المصدر قبل إغلاق archive handle. تنتظر release ticket ذلك
التنظيف؛ الإضافة التي تتجاهل الإلغاء يمكن أن تؤخره. إغلاق الجلسة وحده يبقي
المصدر مثبتًا. أخطاء callback تُحول إلى code مؤلف دون cause/message خاص
بالإضافة، وتُنهى الطلبات المنتظرة. إلغاء طلب ما زال في الطابور يمنع تنفيذه؛
لا يوجد rollback لتعديل متزامن بدأ بالفعل داخل callback.

حدود التنفيذ: 512 صفًا، 2048 خيارًا، 4096 قيمة للمجموعات، 16 Ki حرفًا
للـlabels، 1 MiB من UTF-8 للنص المدخل، 1 Mi حرفًا لمجموع snapshot، وطابور
16 طلبًا. المدخلات ذات surrogate غير مزدوج تُرفض. لا sandbox أو إجبار على
unload للأصناف أو threads أنشأتها الإضافة خارج السجل.

## دليل الاختبار

الأوامر المحلية:

```sh
python3 scripts/test-runtime-host.py
python3 scripts/test-runtime-source-preferences.py
python3 scripts/test-extension-loader.py
```

- فحوص API: 45/278، والنماذج 14 والسجل 20.
- 17 حالة إعدادات مؤلفة: الأنواع الـ12، snapshots immutable، قبول/رفض وحفظ،
  UUID validator والنص المصحح قبل المستمع والحفظ، namespaces وإعادة تشغيل الخدمات، defaults والمراجع mutable،
  enabled/visible والزر، حدود الإدخال، تعديل Editable وUTF-16، إلغاء طلب
  منتظر، إزالة حزمة محجوزة حتى detach، إغلاق جلسة مستقل، خطأ callback وطلبات
  منتظرة وإعادة فتح، إلغاء setup، رفض source غير قابل للإعداد/غير موجود،
  وتراجع إضافة صف عند فشل attach.
- المصدر الموقّع المؤلف يستخدم الخدمات وAPI من parent والـcallbacks من
  VerifiedExtensionClassLoader. إعداد caption يؤثر في نتيجة HTTP فعلية
  على loopback، ويستعاد بعد إزالة الحزمة وإعادة تثبيتها؛ ويقرأ callback
  التنظيف موردًا من الأرشيف قبل تحريره وبعد بوابة تنظيف محجوزة.

التقارير تحت `validation/`: `runtime-host-tests.json` و
`runtime-source-preferences-host.json` و`extension-loader-host.json`؛ تحتوي
بصمات المدخلات والأوامر ونتائج التشغيل. workflow `backend-probe.yml` يحتوي
فحص الإعدادات على Linux وmacOS ويحذف التقارير التاريخية قبل الفحوص. تشغيل
CI الجديد نجح في
[Actions 40032630971](https://github.com/badrcoderman/MangaShelf/actions/runs/40032630971)
عند `8e3102e54bcb7515d4f83684d233cc911cf5acbc`: على كل منصة 17 حالة
إعدادات و20 تحميلًا موقّعًا و14 نماذج و20 سجلًا و6 bootstrap و16 تفضيلات
و16 HTTP/TLS و46 توقيعًا مؤلفًا، مع مطابقة ABI 45/278. فُحص ملفا artifact
بالحجم وSHA-256 وCRC، وبصمات المدخلات مقابل commit، ومحتواهما التساعي
ورخصة Injekt وmodule metadata وغياب fixture classes والمكتبات الأصلية؛
تطابقت JAR بين المنصتين. [الدليل](../validation/runtime-host-40032630971.json).
لا IPA أو تشغيل مصدر منشور/iPhone بهذا workflow.

## ما بقي لتفعيل الإضافات

بناء Zstd/JNI من المصدر لـarm64 iOS وتحميل ملائم لـDarwin، وبقية JSON/Android
التي يحتاجها بدء المصدر، وربط نموذج المصدر والجلسة وowned JNI بـSwift.
بعدها إثبات النقل/TLS والتدفق الحقيقي للمصدر والإلغاء وإعادة التشغيل على
iPhone، وبناء IPA واختبارها. إعدادات التطبيق والنسخ الاحتياطي وألوان/خطوط
واجهة Tachimanga نطاق مستقل ما زال مفتوحًا؛ Wi‑Fi مؤجل بطلب المستخدم.
