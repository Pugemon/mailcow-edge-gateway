"""Минимальный SMTP-сервер для тестов tools/check-relay.sh.

Запуск: python3 tests/fake_smtp.py PORT_FILE MODE
Слушает 127.0.0.1 на свободном порту и записывает его номер в PORT_FILE.
MODE задаёт ответ: denied — RCPT отклонён как relay; open — RCPT принят (open relay);
unknown — RCPT отклонён по другой причине; busy — сервер не принимает соединение.
Обслуживает соединения по очереди (проверка доступности тоже подключается) и завершается
после QUIT или через 15 секунд.
"""

import socket
import sys

RCPT = {
    "denied": "554 5.7.1 <probe@example.net>: Relay access denied",
    "open": "250 2.1.5 Ok",
    "unknown": "550 5.1.1 <probe@example.net>: Recipient address rejected: User unknown",
}


def serve(conn, mode):
    """Один SMTP-диалог. Возвращает True, если клиент прислал QUIT."""
    f = conn.makefile("rwb", buffering=0)

    def say(line):
        f.write(line.encode() + b"\r\n")

    say("554 5.3.2 busy" if mode == "busy" else "220 fake.example ESMTP")
    for raw in f:
        cmd = raw.decode(errors="replace").strip().upper()
        if cmd.startswith("EHLO") or cmd.startswith("HELO"):
            say("250-fake.example")
            say("250 8BITMIME")
        elif cmd.startswith("MAIL FROM"):
            say("250 2.1.0 Ok")
        elif cmd.startswith("RCPT TO"):
            say(RCPT.get(mode, RCPT["denied"]))
        elif cmd.startswith("RSET"):
            say("250 2.0.0 Ok")
        elif cmd.startswith("QUIT"):
            say("221 2.0.0 Bye")
            return True
        else:
            say("502 5.5.2 Error: command not recognized")
    return False


def main():
    port_file, mode = sys.argv[1], sys.argv[2]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    srv.listen(5)
    srv.settimeout(15)
    with open(port_file, "w") as fh:
        fh.write(str(srv.getsockname()[1]))
    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            return
        conn.settimeout(15)
        try:
            if serve(conn, mode):
                return
        except OSError:
            pass
        finally:
            conn.close()


if __name__ == "__main__":
    main()
