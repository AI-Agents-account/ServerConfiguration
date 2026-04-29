# Split-routing для server1: архитектура и спецификация

## 1. Текущее состояние

### 1.1. Общая схема server1 ↔ server2

- **server2** — публичный Shadowsocks-сервер.
  - `server2/setup.sh`:
    - устанавливает `shadowsocks-libev` и `nftables`;
    - пишет `/etc/shadowsocks-libev/config.json`;
    - создаёт `set inet filter ALLOWED_SPROXY` с разрешёнными IP `server1`;
    - открывает порт Shadowsocks только для ALLOWED_SPROXY;
    - сохраняет правила в `/etc/nftables.conf`.

- **server1** — клиентская сторона (`ss-local` + `tun2socks`), три целевых режима:
  - **safe** (уже реализован);
  - **full-tunnel** (уже реализован);
  - **split** (требуется реализовать).

server1 работает по следующей общей схеме:

1. `install_tun2socks_binary.sh` ставит бинарь `tun2socks`.
2. `install_sslocal.sh` поднимает `ss-local` как клиента к `server2`.
3. В зависимости от режима:
   - `install_safe_mode.sh` — только трафик пользователя `tunroute` уходит через `tun0` (таблица 100);
   - `install_full_tunnel_mode.sh` — весь egress через `tun0`, с аккуратной обработкой ingress и обходами.

### 1.2. Safe mode (реализовано)

Ключевые элементы (`server1/install_safe_mode.sh`):

- Создаётся системный пользователь `tunroute`.
- Поднимается `tun0`:
  - `ip link set tun0 up mtu <TUN2SOCKS_MTU>`
  - `ip addr replace <TUN2SOCKS_TUN_ADDR> dev tun0`.
- Создаётся таблица 100:
  - `ip route replace default dev tun0 table 100`.
- Правило policy routing:
  - `ip rule add priority 1000 uidrange <uid(tunroute)>-<uid(tunroute)> lookup 100`.
- Обёртка `via-server2`:
  - запускает команды от пользователя `tunroute`.

**Итого:**
- Default route системы не меняется;
- Только процессы пользователя `tunroute` используют туннель;
- SSH/системный трафик не трогается.

### 1.3. Full-tunnel mode (реализовано)

Ключевые элементы (`server1/install_full_tunnel_mode.sh`):

- Обязательные переменные `.env`: `TUN_SSIP`, `LOCAL_SOCKS_ADDR`, `LOCAL_SOCKS_PORT`, `TUN2SOCKS_IFACE`, `TUN2SOCKS_TUN_DEV`, `TUN2SOCKS_TUN_ADDR`, `TUN2SOCKS_MTU`, `FULL_TUNNEL_BYPASS_IPS`.
- Поднимается `tun0` аналогично safe mode (через `tun2socks-post-up-full.sh`).
- Создаётся таблица `lip` (через `/etc/iproute2/rt_tables.d/90-tun2socks.conf`).
- Скрипт `tun2socks-apply-full-routing.sh`:
  - Чистит legacy-настройки (старый fwmark/table100, таблица 100, table `lip`, nft table `tun2socks`).
  - Находит:
    - дефолтный gateway `gw` через uplink-интерфейс (`TUN2SOCKS_IFACE`);
    - публичный IP `server_ip` на uplink-интерфейсе;
    - upstream DNS (не 127.x.x.x) и активные SSH-пиры.
  - Настраивает **uplink-исключения** через `gw`:
    - маршрут к `gw/32`;
    - маршрут к `TUN_SSIP/32` (адрес `server2`);
    - маршрут к `169.254.169.0/24`;
    - по одному маршруту `/32` к каждому обнаруженному DNS-серверу;
    - по одному маршруту `/32` к каждому активному SSH-пиру;
    - маршруты из `FULL_TUNNEL_BYPASS_IPS` (список IP/подсетей).
  - Настраивает таблицу `lip`:
    - `ip route replace default via <gw> dev <uplink> table lip`;
    - `ip rule add priority 32765 from <server_ip>/32 lookup lip`
      — ответы на входящие соединения уходят через uplink, а не в туннель.
  - Основная модель маршрутизации:
    - `ip route replace default dev tun0 metric 50`;
    - `ip route replace default via gw dev uplink metric 200`.
- systemd-юниты:
  - `tun2socks-server2.service` — запускает `tun2socks` с `-device tun://tun0` и `-tun-post-up`;
  - `tun2socks-full-routing.service` — one-shot, выполняет `tun2socks-apply-full-routing.sh`, RemainAfterExit.

**Итого:**
- Для всего исходящего трафика default route — через `tun0`.
- Для ответов на входящие подключения (по публичному IP `server1`) используется отдельная таблица `lip`, чтобы сохранить корректный обратный путь.
- Критичные IP (gateway, `server2`, DNS, активные SSH-пиры, доп. bypass IP) всегда идут напрямую через uplink.

## 2. Цель split-routing режима

**Задача:** добавить **третий режим**:

- российский/внутренний трафик (`RU`) — **напрямую** через uplink-интерфейс `server1` (WAN);
- зарубежный трафик (`FOREIGN`) — через туннель `tun0` → `server2`;
- SSH-доступ к `server1` **никогда** не должен оказаться в туннеле;
- поведение safe/full режимов не ломается.

Режим должен:

- включаться одной командой, аналогично уже существующим:
  - `sudo bash ./server1/setup.sh split server1/.env`;
- иметь простые smoke-тесты;
- иметь понятный rollback (отключение split без разрушения safe/full).

## 3. Выбранный подход для первой реализации

Для первой итерации split-routing выбираем **вариант A** из раздела 9 HARDENING_PLAN:

> ipset + nftables + policy routing по IP-сетям, **без** дополнительных зависимостей (dnsmasq/BGP и т.д.).

Мотивация:

- минимальные новые зависимости (нужен только `nftables` и `ipset`, которые уже используются на server2 и планируются для hardening); 
- вся логика — в bash + `nft` + `ip` (хорошо вписывается в текущий стиль репозитория);
- можно использовать готовые списки RU-подсетей (antizapret, bgp.he.net, `ipgeo`-списки) как **внешние артефакты**, подгружаемые в ipset;
- проще контролировать и отлаживать без изменения DNS-пути.

## 4. Высокоуровневая архитектура split-routing

### 4.1. Сетевые сущности

- **Интерфейсы:**
  - `uplink` (по умолчанию берём из `ip route show default`, как в full-tunnel) — физический WAN-интерфейс `server1` (например, `eth0`);
  - `tun0` — виртуальный интерфейс `tun2socks` (уже используется в safe/full).

- **Таблицы маршрутизации:**
  - `main` — стандартная системная таблица; здесь остаётся direct default route через uplink;
  - `tun` — **новая** таблица, в которой default route указывает на `tun0`;
  - `lip` — как и в full-tunnel, может использоваться для ingress (по необходимости, см. ниже).

- **Маркировка трафика:**
  - `fwmark SPLIT_MARK` (например, `0x65` или отдельное значение из `.env`),
  - `ip rule add fwmark SPLIT_MARK lookup tun` — отправляет помеченный трафик в таблицу `tun`;
  - непомеченный трафик остаётся в таблице `main` (uplink).

### 4.2. nftables/ipset слой

Новая таблица `inet sc_split` (название можно вынести в `.env`, но на первом шаге жёстко задать):

- **sets**:
  - `set RU_NETS` — список российских/внутренних подсетей, которые **идут напрямую (WAN)**;
  - `set DIRECT_NETS` — дополнительные IP/подсети, которые нужно **жёстко держать на WAN** (управляющие IP, SSH-пиры, DNS, `server2`, gateway и т.п.);
- **chain**:
  - `chain mark_for_tun { type route hook output priority mangle; policy accept; }`

Логика в chain `mark_for_tun` (упрощённо):

```nft
# 1) Никогда не трогаем SSH к server1
ip daddr $SERVER1_PUBLIC_IP tcp dport 22 return

# 2) Никогда не трогаем трафик к DIRECT_NETS
ip daddr @DIRECT_NETS return

# 3) Трафик к RU_NETS — остаётся на WAN (ничего не делаем)
ip daddr @RU_NETS return

# 4) Всё остальное — помечаем для туннеля
meta mark set $SPLIT_MARK
```

Где значения:

- `$SERVER1_PUBLIC_IP` — как в full-tunnel: IPv4 сервера на uplink-интерфейсе;
- `$SPLIT_MARK` — константа (например, `0x65`) или параметр из `.env`.

### 4.3. Policy routing

В `install_split_mode.sh` (новый скрипт) выполняются шаги:

1. Определить uplink-интерфейс и `SERVER1_PUBLIC_IP` (по аналогии с full-tunnel).
2. Убедиться, что `tun0` уже поднят и доступен (tun2socks/ss-local установлены и запущены).
3. Создать таблицу `tun` в `/etc/iproute2/rt_tables.d/` (например, `201 tun`):

```bash
echo '201 tun' >/etc/iproute2/rt_tables.d/91-tun-split.conf
```

4. В таблицу `tun` добавить default route через `tun0`:

```bash
ip route replace default dev tun0 table tun
```

5. Добавить правило policy routing для `fwmark SPLIT_MARK`:

```bash
ip rule add priority 1100 fwmark ${SPLIT_FWMARK} lookup tun
```

6. Убедиться, что в таблице `main` сохранён direct default route через uplink (если ранее включался full-tunnel, необходимо очистить его влияние, либо не комбинировать режимы одновременно).

**Важно:** split-mode **не должен** сам превращать весь трафик в full-tunnel. Он только добавляет `ip rule fwmark → tun` + nft-маркировку.

## 5. Модель совместимости режимов

- Safe / full / split — **логические режимы** одной и той же связки `tun2socks + ss-local`.
- Для простоты первой итерации:
  - считаем, что одновременно активен только **один режим** (safe, full или split);
  - `setup.sh split`:
    - устанавливает/обновляет `tun2socks` и `ss-local` (как уже делается для safe/full);
    - приводит систему к целевому состоянию split (при необходимости — очищает следы full-tunnel: default route через tun0, таблицу `lip`, старые `ip rule` для full).
- Откат split не должен ломать safe/full:
  - отдельный скрипт отката не обязателен на первом шаге, но как минимум:
    - `install_split_mode.sh` должен быть идемпотентным и уметь безопасно переустановить split;
    - для полного отката достаточно:
      - удалить `ip rule fwmark ... lookup tun`;
      - сбросить/отключить цепочку `sc_split mark_for_tun` (или убрать jump из точки подключения);
      - удалить/очистить таблицу `tun`.

## 6. Конфигурационные параметры split-mode

Новые поля в `server1/.env` (предложение):

```dotenv
# Включение режима split (опционально, для читабельности)
SPLIT_MODE_ENABLED="1"

# fwmark для отправки трафика в таблицу tun
SPLIT_FWMARK="0x65"  # любое значение, не конфликтующее с другими правилами

# Путь к файлам с подсетями для RU и DIRECT
SPLIT_RU_NETS_FILE="/etc/server1-split/ru_nets.txt"
SPLIT_DIRECT_NETS_FILE="/etc/server1-split/direct_nets.txt"

# (опционально) Явный uplink-интерфейс, если автоопределение нежелательно
SPLIT_UPLINK_IFACE=""
```

Формат файлов подсетей (пример):

```text
# ru_nets.txt
5.45.192.0/18
31.173.64.0/18
...

# direct_nets.txt
# Управляющие IP-адреса, которыми нельзя рисковать
203.0.113.10/32
198.51.100.0/24
# DNS-серверы, провайдеры мониторинга и т.п.
8.8.8.8/32
1.1.1.1/32
```

Ответственность за наполнение файлов лежит на операторе/плейбуке Ansible/отдельных скриптах; ServerConfiguration только **подхватывает** эти файлы и загружает в ipset.

## 7. Поведение и шаги скрипта install_split_mode.sh (спецификация для devops)

Новый файл: `server1/install_split_mode.sh`.

### 7.1. Общий каркас

- Shebang и опции:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- Параметр ENV_FILE по аналогии с существующими:

```bash
ENV_FILE="${1:-server1/.env}"
```

- Вспомогательные функции:
  - `log()` — как в других скриптах;
  - `require_root()` — проверка EUID;
  - `load_env()` — загрузка `.env` и проверка необходимых переменных (см. раздел 6);
  - `detect_uplink_and_ip()` — определение uplink-интерфейса и публичного IP.

### 7.2. Проверки и зависимости

- Проверить наличие:
  - `tun2socks`;
  - `ss-local`;
  - `ip`, `nft`, `ipset`.
- При необходимости установить `nftables`/`ipset` через `apt-get` (аналогично full-tunnel):

```bash
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nftables ipset
```

### 7.3. Поднятие tun0 (если ещё не поднят)

- Либо переиспользовать уже существующую логику `tun2socks-post-up-*` и systemd-юнит `tun2socks-server2.service`;
- Либо явно проверить, что `ip -br addr show tun0` показывает `UP`.

**Рекомендуемая стратегия:** split-mode не изобретает свой tun2socks, а **перепользует** существующий сервис `tun2socks-server2.service` (как safe/full). То есть:

1. Убедиться, что `tun2socks-server2.service` установлен и включён (через `install_tun2socks_binary.sh` и `install_sslocal.sh`).
2. Если не включён — включить `systemctl enable --now tun2socks-server2.service`.

### 7.4. Настройка таблицы tun и ip rule

1. Создать запись в `/etc/iproute2/rt_tables.d/`:

```bash
install -d -m 0755 /etc/iproute2/rt_tables.d
echo '201 tun' >/etc/iproute2/rt_tables.d/91-tun-split.conf
```

2. Убедиться, что в таблице `tun` есть default route через tun0:

```bash
ip route replace default dev tun0 table tun
```

3. Добавить (идемпотентно) `ip rule` для `SPLIT_FWMARK`:

```bash
ip rule del fwmark ${SPLIT_FWMARK} lookup tun 2>/dev/null || true
ip rule add priority 1100 fwmark ${SPLIT_FWMARK} lookup tun
```

### 7.5. Создание/загрузка ipset-ов

1. Создать ipset-ы (с фиксированными именами):

```bash
ipset create SC_RU_NETS hash:net -exist
ipset create SC_DIRECT_NETS hash:net -exist
```

2. Очистить их перед загрузкой (чтобы переустановка не приводила к "слоению"):

```bash
ipset flush SC_RU_NETS
ipset flush SC_DIRECT_NETS
```

3. Если указаны файлы `SPLIT_RU_NETS_FILE`/`SPLIT_DIRECT_NETS_FILE` и они существуют — загрузить содержимое:

```bash
if [[ -f "$SPLIT_RU_NETS_FILE" ]]; then
  while read -r net; do
    net="${net%%#*}"  # отбросить комментарий
    net="${net// /}"   # убрать пробелы
    [[ -n "$net" ]] || continue
    ipset add SC_RU_NETS "$net" -exist
  done <"$SPLIT_RU_NETS_FILE"
fi

if [[ -f "$SPLIT_DIRECT_NETS_FILE" ]]; then
  while read -r net; do
    net="${net%%#*}"
    net="${net// /}"
    [[ -n "$net" ]] || continue
    ipset add SC_DIRECT_NETS "$net" -exist
  done <"$SPLIT_DIRECT_NETS_FILE"
fi
```

### 7.6. Конфигурация nftables (таблица inet sc_split)

1. Создать таблицу и chains, если их ещё нет. Примерный шаблон:

```bash
nft list table inet sc_split >/dev/null 2>&1 || nft add table inet sc_split

nft list chain inet sc_split mark_for_tun >/dev/null 2>&1 || nft add chain inet sc_split mark_for_tun '{ type route hook output priority mangle; policy accept; }'

nft add set inet sc_split RU_NETS '{ type ipv4_addr; flags interval; auto-merge; }' >/dev/null 2>&1 || true
nft add set inet sc_split DIRECT_NETS '{ type ipv4_addr; flags interval; auto-merge; }' >/dev/null 2>&1 || true
```

2. Привязать ipset-ы к nft-sets (или использовать напрямую ipset через `ip daddr @ipsetname` — зависит от выбранного стиля; для простоты допускается прямое использование системных ipset без дублирования в nft).

3. Записать правила chain `mark_for_tun` (предварительно очистив старые):

```bash
nft flush chain inet sc_split mark_for_tun

# SSH к самому server1 (по его публичному IP) не трогаем
nft add rule inet sc_split mark_for_tun ip daddr ${SERVER1_PUBLIC_IP} tcp dport 22 return

# DIRECT_NETS всегда через WAN
nft add rule inet sc_split mark_for_tun ip daddr @SC_DIRECT_NETS return

# RU_NETS всегда через WAN
nft add rule inet sc_split mark_for_tun ip daddr @SC_RU_NETS return

# Всё остальное — в туннель
nft add rule inet sc_split mark_for_tun meta mark set ${SPLIT_FWMARK}
```

> Важно: в окончательной реализации нужно синхронизировать имена sets между ipset и nft. Один из вариантов — использовать только ipset, а в правилах `nft` писать `ip daddr @SC_RU_NETS`, где `SC_RU_NETS` — **ipset** (через `type ipv4_addr; flags interval;` и `map` к ipset). Конкретный синтаксис devops подберёт при реализации и тесте.

### 7.7. Включение/отключение split-набора правил

Для безопасного отката и включения/выключения split-режима предлагается:

- **Не** врезаться в существующие таблицы `inet filter`/`nat` и т.п.;
- Использовать **route hook output** только в `inet sc_split` — этого достаточно для управления исходящим трафиком с хоста.

На первом шаге достаточно, что наличие цепочки `mark_for_tun` + `ip rule fwmark` уже реализует split-mode. Выключить режим можно простыми командами (описать в README):

```bash
# Отключить split-mode (ручной откат)
sudo ip rule del fwmark ${SPLIT_FWMARK} lookup tun || true
sudo nft flush chain inet sc_split mark_for_tun || true
```

## 8. Изменения по файлам (ToDo для devops)

### 8.1. Новый скрипт `server1/install_split_mode.sh`

Реализовать по спецификации раздела 7. Основные требования:

- `set -euo pipefail`;
- Идемпотентность: повторный запуск не ломает конфигурацию и не дублирует правила;
- Логирование основных шагов через `log "..."`;
- Явная проверка env-переменных и зависимостей с понятными ошибками.

### 8.2. Обновление `server1/setup.sh`

- Добавить третий режим:

```bash
Usage:
  bash ./server1/setup.sh safe [server1/.env]
  bash ./server1/setup.sh full [server1/.env]
  bash ./server1/setup.sh split [server1/.env]
```

- Валидация `MODE` должна включать `split`:

```bash
case "$MODE" in
  safe|full|split) ;;
  * ) usage; exit 1;;
esac
```

- Добавить ветку `split`:

```bash
case "$MODE" in
  safe)
    bash "$SCRIPT_DIR/install_safe_mode.sh" "$ENV_FILE"
    ;;
  full)
    bash "$SCRIPT_DIR/install_full_tunnel_mode.sh" "$ENV_FILE"
    ;;
  split)
    bash "$SCRIPT_DIR/install_split_mode.sh" "$ENV_FILE"
    ;;
esac
```

### 8.3. Обновление `server1/README.md`

Добавить раздел "Split mode" с описанием:

- Назначение режима (RU → WAN, foreign → tun0);
- Требования:
  - наличие и корректность `server1/.env`;
  - подготовленные файлы подсетей (опционально, с примерами);
- Команды применения:

```bash
sudo bash ./server1/setup.sh split server1/.env
```

- Smoke-тесты (из HARDENING_PLAN 9.6, адаптировать под split):
  - curl к российскому ресурсу (ожидаем WAN);
  - curl к зарубежному (`ifconfig.me`, ожидаем IP `server2`);
  - ssh-тест (подтвердить, что не пропал доступ).

### 8.4. Обновление корневого `README.md`

- Добавить упоминание нового режима split наряду с safe/full;
- Краткая ссылка на `docs/split-routing-architecture.md` и раздел 9 `HARDENING_PLAN.md`.

### 8.5. Скрипт установки окружения (если есть общий `setup.sh` в корне)

- При необходимости — добавить туда упоминание split-режима и проверку наличия `nftables`/`ipset`.

## 9. Минимальные smoke-тесты для split-mode

Примеры команд (ожидается, что devops добавит аккуратный чек-лист в README):

1. **Проверка базовой связности и SSH**

```bash
# С управляющего хоста
ssh user@server1 'echo OK && ip route get 1.1.1.1'
```

Ожидаем:
- SSH стабилен;
- маршрут до 1.1.1.1 после включения split использует таблицу `tun` (по `ip route get` должно быть видно `dev tun0` или `table tun`, в зависимости от реализации).

2. **Российский ресурс через WAN**

```bash
ssh user@server1 'curl -4 -s https://ya.ru -o /dev/null -w "%{remote_ip} %{http_code}\\n"'
```

- Проверить по трассировке (`mtr/traceroute`), что маршрут идёт через uplink;
- По логам `nft` убедиться, что правило маркировки не срабатывает (нет `SPLIT_FWMARK`).

3. **Зарубежный ресурс через туннель**

```bash
ssh user@server1 'curl -4 -s https://ifconfig.me -o /dev/null -w "%{remote_ip} %{http_code}\\n"'
```

- Внешний IP должен соответствовать `server2`/провайдеру туннеля;
- `ip route get <remote_ip>` должен демонстрировать использование `table tun` / `dev tun0`.

4. **Диагностика ipset/nftables**

```bash
ssh user@server1 '
  sudo ipset list SC_RU_NETS || true
  sudo ipset list SC_DIRECT_NETS || true
  sudo nft list table inet sc_split || true
'
```

5. **Отключение split (ручной rollback)**

```bash
ssh user@server1 '
  sudo ip rule del fwmark ${SPLIT_FWMARK} lookup tun || true
  sudo nft flush chain inet sc_split mark_for_tun || true
  ip route get 1.1.1.1
'
```

Ожидаем:
- весь трафик снова идёт через WAN;
- SSH не теряется.

---

Этот документ фиксирует архитектуру и минимальную спецификацию split-routing режима для `server1`. Следующий шаг — реализация по этому плану в новой ветке (`devops`-агентом) с добавлением:

- `server1/install_split_mode.sh`;
- обновлений `server1/setup.sh`, `server1/README.md`, корневого `README.md`;
- smoke-тестов и краткой инструкции по откату.