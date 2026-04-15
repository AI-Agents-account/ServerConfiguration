# wireguard (ServerConfiguration)

Этот пакет — про практическую эксплуатацию WireGuard на VPS, особенно когда на том же сервере включён **full-tunnel egress** через отдельный интерфейс (например `tun0` от `tun2socks`).

## Проблема (частый кейс)

Симптом:
- На телефоне WireGuard «подключается» (есть handshake), но трафик идёт **частично** или **вообще не идёт** (не открываются сайты/YouTube, иногда работают только отдельные приложения).

Наблюдение:
- На сервере по умолчанию может быть `default route` через `tun0`.
- Если `wg0` настроен так, что NAT/форвардинг выполняется **в `tun0`**, то любые проблемы/ограничения в цепочке `tun0` (policy routing, MTU, особенности tun2socks для forwarded трафика и т.п.) могут приводить к «чёрной дыре» для WireGuard клиентов.

## Быстрый диагностический обходной путь (workaround)

Временно **принудительно направить трафик подсети WireGuard напрямую через WAN-интерфейс VPS** (например `enp3s0`), обходя `tun0`.

Это позволяет быстро ответить на вопрос:
> «WireGuard как транспорт работает, а ломается именно выход через `tun0`?»

Если после применения workaround трафик на телефоне начинает работать полностью — проблема почти наверняка в egress-цепочке `tun0`, а не в ключах/порте WireGuard.

### Что делает workaround

1) Добавляет policy routing: трафик **from WG subnet** идёт в отдельную таблицу маршрутизации (table 100) с `default via <WAN_GW> dev <WAN_IF>`.
2) Добавляет NAT (MASQUERADE) для WG subnet на WAN-интерфейс.

### Скрипты

- `apply_egress_direct.sh` — применить workaround
- `remove_egress_direct.sh` — убрать workaround

> Скрипты не меняют ваш WireGuard конфиг автоматически; они накладывают правила на running system. Для постоянного решения — перенесите команды в `PostUp/PostDown` вашего `/etc/wireguard/wg0.conf`.

## Настройки

Скрипты принимают параметры через env:

- `WG_NET` (default: `10.66.66.0/24`)
- `WAN_IF` (default: `enp3s0`)
- `WAN_GW` (default: `176.109.104.1`)
- `TABLE` (default: `100`)
- `PRIO` (default: `1000`)

Пример:

```bash
WG_NET=10.66.66.0/24 WAN_IF=eth0 WAN_GW=1.2.3.1 sudo bash wireguard/apply_egress_direct.sh
```

## Дальнейшее исправление «чтобы трафик шёл через туннель и не ломался»

Если direct-egress workaround помог, следующий шаг — чинить именно `tun0`-цепочку для forwarded трафика WireGuard:

- MTU/MSS: снижать MTU на wg-клиенте и/или делать `TCPMSS --clamp-mss-to-pmtu`
- Явная policy routing для трафика из `wg0` в ту же таблицу/маркировку, что использует full-tunnel
- Проверка, что tun2socks/policy routing обрабатывает forwarded-пакеты (а не только локальные)

(Этот раздел будет расширяться по мере накопления практики.)
