# SOCKS-туннель через зарубежный сервер

Настройка безопасного SOCKS5-туннеля через SSH для обхода региональной блокировки.

- **Локальная машина** (этот сервер, IP заблокирован) — ssh-клиент с локальным SOCKS.
- **Зарубежный сервер** (второй сервер) — настраивается вручную напрямую на нём (скрипт `setup-remote.sh`).

Трафик идёт внутри зашифрованного SSH-канала. На сервере ничего кроме sshd не ставится.

## Настройка

### 1. Локальная машина

```bash
cd ~/socks-tunnel
./setup-local.sh
```

Скрипт создаёт ключ `~/.ssh/tunnel` (и `.pub`), блок `Host tunnel` в `~/.ssh/config`
и печатает публичный ключ — он понадобится на шаге 2.

### 2. Зарубежный сервер (вручную, напрямую на нём)

Перенеси туда `setup-remote.sh` и публичный ключ (например `scp`):
```bash
scp setup-remote.sh ~/.ssh/tunnel.pub user@server:~/
```
Затем на сервере:
```bash
sudo ./setup-remote.sh "$(cat ~/tunnel.pub)"
# или так же: sudo ./setup-remote.sh ~/tunnel.pub
```

Скрипт создаст пользователя `tunnel`, ограничит его ключ
(`restrict,port-forwarding`), усилит sshd (запрет паролей и root, `AllowUsers`),
сделает бэкап конфига в `/etc/ssh/sshd_config.bak.pre-tunnel`.

### 3. Назад на локальную машину

```bash
./tunnel.sh start
./tunnel.sh check     # должен показать IP зарубежного сервера
source ~/socks-tunnel/proxy-env.sh
opencode
```

## Управление

| Команда | Действие |
| --- | --- |
| `./tunnel.sh start` | запустить туннель |
| `./tunnel.sh stop` | остановить |
| `./tunnel.sh restart` | перезапустить |
| `./tunnel.sh status` | статус процесса и порта |
| `./tunnel.sh check` | показать внешний IP через туннель |

## Состав

- `config.env` — настройки для локальной машины (адрес сервера, порты, имя host-блока).
- `setup-local.sh` — локальная сторона: ключ + `~/.ssh/config` + вывод ключа.
- `setup-remote.sh` — серверная сторона, запускается вручную на зарубежном сервере.
- `tunnel.sh` — start/stop/status/check.
- `proxy-env.sh` — `source` для экспорта `HTTPS_PROXY` и др. в текущую оболочку.

## Безопасность

- Порт SOCKS слушается только на `127.0.0.1`, без `-g`.
- Ключ туннеля на сервере ограничен: `restrict,port-forwarding` (без pty, X11, agent forwarding).
- `sshd`: `PasswordAuthentication no`, `PermitRootLogin no`, `AllowUsers <admin> tunnel`.
- Прошлая конфигурация sshd сохраняется в `/etc/ssh/sshd_config.bak.pre-tunnel`.
- Учти: исходящий трафик виден на зарубежном сервере — доверяй ему настолько, насколько это допустимо.