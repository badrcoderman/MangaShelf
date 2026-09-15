# خطة الإكمال التنفيذية

## المرحلة ٢ — المحرك وصقل الواجهة

**الهدف:** تشغيل مصدر واحد حقيقي على iPhone مع استمرار واجهة Tachimanga.

1. ثبّت مراجعة مصدر محرك JVM/compatibility ورخصه وتبعياته.
2. ابنِ ARM64 iOS داخل Xcode، وافحص Mach-O وlinkage وmemory limits. نجاح Linux أو macOS وحده لا يكفي.
3. شغّل VM داخل test host، ثم حمّل `RuntimeProbe` مستقلًا، ثم اختبر دورة start/stop/restart والاستثناءات.
4. اربط NativeNet وNativeChannel بأقل واجهة مطلوبة، مع URLSession وcookie/redirect policy وحدود body.
5. نفّذ فهرسًا مثبتًا، stage JAR معروفًا، تحقق SHA/signing/trust، ثم اختبر search/details/chapters/pages.
6. أكمل القائمة العائمة: RTL، outside tap، Escape، Dynamic Type، Reduce Motion/Transparency، وLiquid Glass على iOS 26.
7. ابنِ لقطات جهاز للغة الإنجليزية والعربية والوضعين الداكن والفاتح، وقارنها بالمراجع.

**الإغلاق:** إضافة فعلية تعمل على جهاز، rollback عند تلف الحزمة، وقائمة خيارات مقروءة ومطابقة.

## المرحلة ٣ — المكتبة

فلاتر المصدر والعلامات، multi-select، عمليات جماعية آمنة، sorting/grid/list محفوظ لكل فئة، notes، random title، إحصاءات وقت القراءة، Trash واستعادة وتنظيف صريح.

## المرحلة ٤ — القارئ

EPUB وfolders، crop، two-page/iPad، إعدادات لكل عنوان، auto-scroll، touch zones، keyboard/pencil، rotation، حفظ موضع webtoon الحقيقي، ImageIO format matrix.

## المرحلة ٥ — التنزيلات والتحديث

Queue قابلة للإيقاف والإلغاء والاستئناف، background lifecycle، retry/backoff، 429، storage cleanup، إشعارات غير مكررة، source migration ومعاينة التقدم.

## المرحلة ٦ — النسخ والمزامنة والتتبع

نسخ Tachimanga/Tachiyomi/Mihon بإصدارات موثقة، migrations وrollback، مزامنة محلية/سحابية وتعريف تعارضات، Keychain، AniList/MAL وغيرها بعد مراجعة APIs والرخص.

## المرحلة ٧ — ميزات المنتج

ترجمة محلية اختيارية للصفحات مع عدم رفع الصور افتراضيًا، OCR بإذن واضح، Debug Menu واسع لكن آمن، About مع changelog منسدل بالتاريخ، إزالة premium gate، وإزالة Share to More/Contact Us حسب مواصفات المنتج.
