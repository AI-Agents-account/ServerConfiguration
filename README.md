# ServerConfiguration

Настройка связки:

- **server2** — Shadowsocks server (`shadowsocks-libev`)
- **server1** — клиентская сторона (`ss-local` + `tun2socks`)

## Структура

- `server2/` — настройка сервера Shadowsocks
- `server1/` — настройка клиента на базе `ss-local + tun2socks`

См. также:
- `server2/README.md`
- `server1/README.md`
- `HARDENING_PLAN.md` — поэтапный план усиления безопасности и управляемости конфигураций

## Рекомендуемый порядок

### 1. Настроить server2

Инициализация:

```bash
sudo bash ./start.sh
```

Подготовка конфига:

```bash
cp server2/.env.example server2/.env && nano server2/.env
```

Применение:

```bash
sudo bash ./server2/setup.sh server2/.env
```

Проверить:

```bash
systemctl status shadowsocks-libev --no-pager
sudo nft list set inet filter ALLOWED_SPROXY
```

### 2. Настроить server1 в safe mode

Инициализация:

```bash
sudo bash ./start.sh
```

Подготовка конфига:

```bash
cp server1/.env.example server1/.env && nano server1/.env
```

Применение:

```bash
sudo bash ./server1/setup.sh safe server1/.env
```

Проверить:

```bash
sudo bash ./server1/check_via_server2.sh server1/.env safe
sudo via-server2 curl -4 https://ifconfig.me
```

### 3. Перевести server1 в full-tunnel mode (опционально)

> Внимание: full-tunnel может повлиять на SSH и другой исходящий трафик. Делать только при наличии аварийного доступа через консоль провайдера.

Инициализация:

```bash
sudo bash ./start.sh
```

Применение:

```bash
sudo bash ./server1/setup.sh full server1/.env
```

Проверка:

```bash
sudo bash ./server1/check_via_server2.sh server1/.env full
```

---

## Что выбрать

### Safe mode
Рекомендуется по умолчанию.

- туннель работает только для отдельного системного пользователя `tunroute`
- команды через туннель запускаются так:

```bash
sudo via-server2 curl -4 https://ifconfig.me
```

Подходит для:
- безопасной проверки
- выборочного трафика
- сценариев, где нельзя рисковать SSH-доступом

### Full-tunnel mode
Весь исходящий трафик сервера уводится в `tun2socks`, кроме явно исключённого.

Подходит только если:
- есть консольный доступ к серверу
- вы понимаете последствия policy routing / nftables
- нужно увести наружу именно весь egress

---

## Smoke tests

### SOCKS-проверка

```bash
curl -4 --socks5-hostname 127.0.0.1:1080 -s https://ifconfig.me
```

Ожидаемый результат: IP `server2`.

### Safe mode

```bash
sudo via-server2 curl -4 -s https://ifconfig.me
```

### Full mode

```bash
curl -4 -s https://ifconfig.me
```

---

## Важное замечание

В этом репозитории:
- **safe mode** соответствует реально проверенной рабочей схеме
- **full-tunnel mode** добавлен как отдельная инсталляция и требует осторожного ввода в эксплуатацию
