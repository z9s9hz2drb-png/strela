# Strela — VPN-клиент для iPad/iPhone на ядре Xray

Клиент в духе Happ: подписки, VLESS/Reality/XHTTP, автовыбор лучшего сервера по **Proxy GET** и умная маршрутизация (РФ напрямую, остальное через VPN).

## Возможности

- **Ядро Xray-core 26.11.9** через [libXray](https://github.com/XTLS/libXray). Встроенный TUN Xray работает прямо с дескриптором utun: один Go-рантайм, без tun2socks.
- **Протоколы**: всё, что понимает Xray и его парсер ссылок. Это VLESS (Reality, XTLS Vision, XHTTP, WS, gRPC, HTTPUpgrade), VMess (AEAD и старый формат `vmess://base64`), Trojan, Shadowsocks, SOCKS и Hysteria2 (`hy2://`). Плюс полные JSON-конфиги Xray из JSON-подписок.
- **Автовыбор по GET**:
  1. Перед подключением все серверы группы проверяются настоящим GET-запросом через прокси.
  2. N лучших попадают в балансировщик Xray `leastPing`.
  3. `observatory` раз в N минут повторяет GET и переключает трафик на самый быстрый сервер, а с упавшего уводит автоматически.
  4. На главном экране видно, какой сервер выбран сейчас.
- **Проверка задержки**: Proxy GET, Proxy HEAD или TCP. При включённом VPN проверка идёт из туннельного расширения, поэтому цифры не искажает текущий прокси.
- **Умная маршрутизация**. Готовые профили:
  - «Умный: РФ напрямую»;
  - «Умный + без рекламы»;
  - «Только заблокированное»;
  - «Всё через VPN».

  Можно завести свои профили. Совместимость с Happ: импорт `happ://routing/add|onadd/{base64}`, `happ://routing/off`, а также `routing`-заголовок и `#routing` в теле подписки. Гео-базы по умолчанию берутся из [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat) и обновляются раз в неделю.
- **DNS без утечек**: весь DNS перехватывается в Xray. Российские домены резолвятся напрямую (77.88.8.8), остальные через DoH внутри туннеля (1.1.1.1).
- **Подписки как в Happ**:
  - заголовки `profile-title`, `subscription-userinfo` (трафик и срок), `profile-update-interval`, `support-url`, `profile-web-page-url`, `announce`;
  - `routing`, `routing-enable`, `ping-type`, `check-url-via-proxy`, `proxy-ping-timeout`;
  - `subscription-autoconnect(-type)`, `subscription-ping-onopen-enabled`, `subscription-auto-update(-open)-enable`;
  - `fragmentation-*`, `sniffing-enable`, `mux-enable`, `hide-settings`, `subscriptions-sort-type`;
  - `change-user-agent`, `xray-tun-mtu`, `include-all-networks-enable`, `exclude-local-networks-enable`, `exclude-apns-enable`;
  - `new-url`, `fallback-url`. Всё то же самое работает и строками `#ключ: значение` в теле подписки.
- **HWID**: заголовки `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model` (лимит устройств в Remnawave). Есть шифрование подписок age (`X-Age-Public-Key`).
- **Импорт**: буфер обмена, QR с камеры, QR из фото, deep links (`happ://add/…`, `vless://…`, `strela://add/…`). Ярлыки: `strela://connect`, `strela://disconnect`, `strela://toggle`.
- **Прочее**: фрагментация TLS ClientHello, Mux, IPv6, MTU, VPN по требованию, kill switch (`includeAllNetworks`), статистика трафика (через VPN и напрямую), журналы Xray и приложения.
- **Переподпись**: после GBox, ESign или Sideloadly приложение само находит App Group (из `embedded.mobileprovision`) и ID туннельного расширения.

## Как поставить на iPad

VPN на iOS работает только с правом **Network Extension**. Его даёт платный Apple Developer аккаунт или сертификат, где это право включено.

### Вариант A — через GBox

1. **Получите IPA.** Его собирает GitHub Actions на бесплатном Mac-сервере GitHub:
   - создайте репозиторий на GitHub и загрузите в него эту папку целиком, включая скрытую `.github` (на iPad удобно через приложение Working Copy);
   - **Actions → Build iOS → Run workflow**. Первая сборка идёт 20–40 минут, потому что ядро Xray компилируется из исходников; дальше оно берётся из кэша;
   - готовые файлы появятся в **Releases** (`build-N`): `Strela-unsigned.ipa` и `Strela-trollstore.tipa`.
2. **Скачайте IPA на iPad.** Откройте Releases в Safari и скачайте `Strela-unsigned.ipa`. Затем в «Файлах» нажмите «Поделиться» и выберите GBox (или импортируйте файл внутри GBox).
3. **Подпишите в GBox** своим сертификатом.
   - Сертификат должен поддерживать **VPN (Network Extension)**, желательно и **App Groups**.
   - **Не удаляйте расширения (PlugIns)**: в них работает сам туннель.
4. **Проверьте подпись.** Откройте Strela, перейдите в **Настройки → Подпись**. Там должно быть «VPN (Network Extension): есть ✓». Если «нет», iOS не даст включить VPN: нужен другой сертификат. Об этом же предупредит красная карточка на главном экране.

Если App Groups в сертификате нет, VPN всё равно заработает: конфигурация передаётся в туннель напрямую. Но туннелю будут недоступны гео-базы, поэтому правила geoip/geosite отключатся, а останутся только правила по доменам. Например, `domain:ru` продолжит работать.

### Вариант B — свой Apple Developer аккаунт, без Mac: GitHub Actions → TestFlight

1. На developer.apple.com зарегистрируйте:
   - App Group `group.com.ВАШЕ_ИМЯ.strela`;
   - App ID `com.ВАШЕ_ИМЯ.strela` и App ID `com.ВАШЕ_ИМЯ.strela.tunnel`. Обоим включите App Groups и Network Extensions.
2. В App Store Connect:
   - **Apps → + → New App** с этим bundle ID;
   - **Users and Access → Integrations → App Store Connect API**: создайте ключ с ролью Admin.
3. В GitHub откройте **Settings → Secrets and variables → Actions**:
   - variable `APP_BUNDLE_ID`;
   - secrets `TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (текст `.p8` или его base64).
4. Запустите **Run workflow**. Сборка сама уйдёт в TestFlight. Сборки там живут 90 дней.

### Вариант C — Mac с Xcode 16+

```bash
brew install xcodegen go
./Scripts/build-libxray.sh          # ~15 минут, один раз
printf 'APP_BUNDLE_ID = com.ВАШЕ_ИМЯ.strela\nDEVELOPMENT_TEAM = ВАШ_TEAM_ID\n' > Configs/Local.xcconfig
xcodegen generate && open Strela.xcodeproj
```

### TrollStore (iPadOS 14.0–16.6.1 и 17.0)

`Strela-trollstore.tipa` из Releases уже содержит нужные entitlements и ставится без подписи.

### Если сборка упала

Лог сборки публикуется в Releases как `build-log-N`. Пришлите его, и ошибку можно будет исправить.

## Как это устроено

```
App (SwiftUI)                         PacketTunnel (NEPacketTunnelProvider)
 ├─ подписки, парсинг (libXray)        ├─ читает tunnel-plan.json из App Group
 ├─ ConfigBuilder → Xray JSON          ├─ резолвит адреса серверов до поднятия туннеля
 ├─ testXray: проверка конфига         ├─ Xray TUN inbound (env xray.tun.fd)
 ├─ тест GET без VPN (свой Xray)       ├─ DNS: порт 53 → dns-out → DoH/DoU
 └─ IPC: status / ping / reload ──────►└─ metrics /debug/vars: трафик и observatory
```

- **Автовыбор**: `routing.balancers = [{selector: ["auto-"], strategy: leastPing}]` и `observatory {probeURL, probeInterval}`. Observatory в Xray шлёт именно `GET`.
- **Тест GET при включённом VPN**: в рабочий конфиг добавлены локальные HTTP-входы `127.0.0.1:порт → конкретный сервер`. Расширение делает GET через них, а его собственный трафик идёт мимо туннеля.
- **Проверка перед подключением**: конфиг собирается настоящим ядром (`testXray`). Если в гео-базе нет нужной категории, правила geoip/geosite временно отключаются, а приложение об этом предупреждает.
- **Смена сервера без переподключения**: через IPC `reload` перезапускается только ядро Xray, туннель остаётся.

## Структура

```
App/            SwiftUI-приложение (модель, VPN-контроллер, экраны)
PacketTunnel/   Network Extension
Shared/         общий код: модели, парсер ссылок, генератор конфига Xray, тесты задержки
Scripts/        сборка LibXray.xcframework, упаковка IPA/TIPA
Configs/        bundle id, team, версии
project.yml     описание проекта для XcodeGen
```

## Замечания

- Лимит памяти Network Extension на iOS — около 50 МБ. Категории вроде `geosite:ru-blocked-all` (700 тыс. доменов) могут его превысить, поэтому в профиле «Только заблокированное» стоит `ru-blocked`.
- Зашифрованные ссылки Happ (`happ://crypt…`) не поддерживаются: это закрытый формат Happ.
- По умолчанию User-Agent подписки — `Strela/1.0`. Если провайдер отдаёт конфиги только «своим» клиентам, поменяйте его в настройках.
