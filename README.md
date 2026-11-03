# Yakala - Tarayici + Dosya Yakalayici (Android)

Siteyi uygulama icinde acarsin (bot korumasini sen gecersin), sonra **Yakala** dugmesiyle
sayfadaki epub / pdf / txt / csv vb. dosyalari listeler, secip indirirsin.

## Kelimelerin anlami
- **APK**: Android uygulama dosyasi. Telefona kurarsin.
- **GitHub Actions**: GitHub'in ucretsiz "derleme makinesi". Kodu yukleyince APK'yi senin yerine uretir.
- **Build/Derleme**: Koddan APK uretme islemi.
- **Bot korumasi**: "Robot degilim" kontrolu. Uygulama gercek tarayici gibi calistigi icin sen gecersin, sonra indirme ayni oturumla yapilir.

## 1) APK'yi uretme (GitHub)
1. github.com'da yeni bir **repository** (depo) olustur (adi: yakala).
2. Bu klasorun **icindekileri** yukle: `.github` klasoru, `app_src` klasoru, `README.md`.
   (`.github` gizli klasor olabilir; telefonda gosterilmiyorsa bilgisayardan veya "Add file > Upload files" ile klasor olarak yukle.)
3. Ustteki **Actions** sekmesine gir. "APK Derle" calisiyor olmali (yoksa soldan sec, **Run workflow**).
4. Yesil tik cikinca (yaklasik 5-10 dk) calismanin icine gir, en alttaki **Artifacts > Yakala-APK** dosyasini indir.
5. Zip'i ac, `app-release.apk` dosyasini telefona kur ("bilinmeyen kaynaklara izin ver" gerekebilir).

## 2) Kullanim
1. Ustteki kisayollardan (bdebooks, Archive.org, Gutenberg) birini ac ya da adres yaz.
2. Bot korumasi cikarsa gec.
3. Sag alttaki **Yakala** dugmesine bas.
4. Format sec (epub, pdf, txt, csv ...). Listede yoksa "Diger uzantilar" kutusuna yaz (ornek: `fb2, lit`).
5. **Kelime filtresi**: ornek `chemistry` yaz. Birden fazla kelime yazarsan hepsi gecen dosyalar kalir.
6. **Tum siteyi tara** kapaliysa sadece acik sayfa taranir. Aciksa site icindeki sayfalar da gezilir (en fazla secilen sayfa sayisi kadar). Cok sayfa = daha yavas.
7. Dosya satirindaki oka basarsan **tekli indirme**, alttaki **Secilenleri indir** ile **toplu indirme** olur (ayni anda 3 dosya).
8. Sayfada bir dosya baglantisina dogrudan dokunursan o da otomatik inip kaydedilir.

## 3) Dosyalar nereye iner?
`Download/Yakala` klasorune. Ilk indirmede "Tum dosyalara erisim" izni ister; vermezsen
`Android/data/com.yakala.yakala/files/Yakala` klasorune kaydeder.

## 4) Bilinen sinirlar
- Baglantisi yalnizca JavaScript ile sonradan olusan sitelerde bazi dosyalar gorunmeyebilir; sayfayi tam yukleyip tekrar Yakala'ya bas.
- Giris/uyelik isteyen sitelerde once uygulama icinde giris yap; indirme ayni oturumu kullanir.
- Sadece indirme hakkin olan icerikleri indir.
- Derleme hata verirse Actions'taki kirmizi hatanin son satirlarini bana gonder, duzeltirim.

## Dosya yapisi
- `app_src/main.dart` : uygulamanin kodu
- `app_src/pubspec.yaml` : kullanilan paketler listesi
- `app_src/patch_manifest.py` : internet ve dosya izinlerini ekler
- `.github/workflows/build.yml` : GitHub'a "APK uret" talimati
