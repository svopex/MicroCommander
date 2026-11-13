#!/bin/bash
# SPDX-FileCopyrightText: 2026 Open Samandarin Authors
# SPDX-License-Identifier: GPL-2.0-or-later
#
# End-to-end test SFTP přihlášení (heslo se netestuje – vyžaduje PAM):
# spustí dočasný sshd jen na 127.0.0.1 pod aktuálním uživatelem s vlastní
# konfigurací, vygeneruje testovací klíče (ed25519 s heslem i bez, RSA PEM,
# ECDSA, neautorizovaný klíč), spustí ssh-agent a pak ignorované testy jádra
# sftp_*. Systémové „Vzdálené přihlášení“ se nemění, vše se po testu uklidí.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d -t sal-sftp)"
# Volný port (vybere systém), aby test nekolidoval s ničím jiným.
PORT="${SAL_TEST_SSH_PORT:-$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')}"

# Úklid: zastavení sshd a agenta, smazání dočasného adresáře.
cleanup() {
    [ -n "${SSHD_PID:-}" ] && kill "$SSHD_PID" 2>/dev/null || true
    # Při chybě ukázat log serveru (diagnostika).
    [ "${KEEP_LOG:-0}" = 1 ] && cat "$WORK/sshd.log" 2>/dev/null || true
    [ -n "${SSH_AGENT_PID:-}" ] && kill "$SSH_AGENT_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

# Klíče: hostitelský + testovací (id_other záměrně není v authorized_keys).
cd "$WORK"
ssh-keygen -q -t ed25519 -N "" -f host_ed25519
ssh-keygen -q -t ed25519 -N "" -C test-plain -f id_plain
ssh-keygen -q -t ed25519 -N "tajne-heslo" -C test-pass -f id_pass
ssh-keygen -q -t rsa -b 3072 -m PEM -N "" -C test-rsa-pem -f id_rsa_pem
ssh-keygen -q -t ecdsa -N "" -C test-ecdsa -f id_ecdsa
ssh-keygen -q -t ed25519 -N "" -C test-unauthorized -f id_other
cat id_plain.pub id_pass.pub id_rsa_pem.pub id_ecdsa.pub > authorized_keys
chmod 600 authorized_keys

# Konfigurace sshd: jen klíče, jen localhost, vlastní soubory v dočasném adresáři.
cat > sshd_config <<CFG
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/host_ed25519
AuthorizedKeysFile $WORK/authorized_keys
PidFile $WORK/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
Subsystem sftp /usr/libexec/sftp-server
CFG
# Na popředí (-D) na pozadí shellu – démonizace pod běžným uživatelem neprojde.
/usr/sbin/sshd -D -e -f "$WORK/sshd_config" > "$WORK/sshd.log" 2>&1 &
SSHD_PID=$!
# Čekání, až sshd poslouchá (max. 5 s).
for _ in $(seq 50); do
    grep -q "Server listening" "$WORK/sshd.log" 2>/dev/null && break
    sleep 0.1
done

# ssh-agent s načteným id_plain (test přihlášení přes agenta).
eval "$(ssh-agent -s -a "$WORK/agent.sock")" > /dev/null
ssh-add -q "$WORK/id_plain"

# Ignorované testy jádra se proměnnými testovacího serveru.
cd "$ROOT/core"
SAL_TEST_SSH_PORT="$PORT" SAL_TEST_SSH_KEYDIR="$WORK" SAL_TEST_SSH_AGENT_SOCK="$WORK/agent.sock" \
    cargo test --release --lib -- --ignored --test-threads=1 sftp_

# Stejné připojení přes FFI (Swift obálka, kterou používá aplikace).
cd "$ROOT"
SAL_TEST_SSH_PORT="$PORT" SAL_TEST_SSH_KEYDIR="$WORK" SAL_TEST_SSH_AGENT_SOCK="$WORK/agent.sock" \
    make --no-print-directory smoke
