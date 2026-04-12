# Установка и управление Мультиплексором VPN (setup_new.sh)

Архитектура:
Единый `sing-box` работает как SNI-мультиплексор на портах 443 TCP/UDP и распределяет трафик между встроенными VPN-протоколами (VLESS+Reality, Trojan, Hysteria2) и локальным TrustTunnel. Остальной трафик перенаправляется на Nginx-заглушку.

## 1. Установка сервера (\`setup_new.sh\`)

Скрипт `setup_new.sh` производит полностью автоматическую установку всех компонентов, не требуя ввода данных через диалоговые окна (unattended install). 

### Подготовка конфигурации
Скопируйте пример конфига и заполните нужные домены и email (для Let's Encrypt).
```bash
cp .env.example .env
nano .env
```
Обязательно заполните:
- `DOMAIN` - домен для Trojan/Hysteria2
- `TRUSTTUNNEL_DOMAIN` - домен для TrustTunnel
- `EMAIL` - ваш email для Let's Encrypt

### Запуск
```bash
sudo ./setup_new.sh .env
```
По завершении скрипт выведет на экран все необходимые данные и ключи (UUID, пароли, Reality Public Key, и deeplink для TrustTunnel). Обязательно **сохраните** их.

---

## 2. Добавление нового пользователя (\`add_user_new.sh\`)

Скрипт `add_user_new.sh` позволяет добавить нового клиента сразу во все запущенные VPN сервисы (VLESS, Trojan, Hysteria2 и TrustTunnel) и перезагружает нужные службы.

### Использование
```bash
sudo ./add_user_new.sh <имя_пользователя>
```
Например:
```bash
sudo ./add_user_new.sh ivan
```

### Что делает скрипт:
1. Генерирует новые секреты (UUID для VLESS, и безопасные случайные пароли для Trojan, Hysteria2 и TrustTunnel).
2. Безопасно обновляет конфигурацию `sing-box` (`/etc/sing-box/config.json`) через утилиту `jq`.
3. Добавляет пользователя в конфигурацию TrustTunnel (`/opt/trusttunnel/credentials.toml`).
4. Перезапускает сервисы (`systemctl restart sing-box`, `systemctl restart trusttunnel`).
5. Выводит на экран сводку доступов:
   - UUID для VLESS (Reality Public Key остается прежним с этапа установки)
   - Пароли для Trojan и Hysteria2
   - Готовую ссылку-deeplink (`tt://?`) для настройки клиента TrustTunnel.
