#!/bin/sh
set -eu

LOG_CMD='sudo journalctl -k | grep "apparmor=\"DENIED\"" | tail -n 10'

sep() {
  echo "------------------------------------------------------------"
}

run_allowed() {
  desc="$1"
  shift
  echo
  sep
  echo "[ALLOWED] $desc"
  echo "[CMD] $*"
  if "$@"; then
    echo "[OK] Comando terminato con successo (nessun blocco evidente)."
  else
    echo "[WARN] Comando terminato con errore (non necessariamente AppArmor)."
  fi
}

run_forbidden() {
  desc="$1"
  shift
  echo
  sep
  echo "[FORBIDDEN] $desc"
  echo "[CMD] $*"
  if "$@"; then
    echo "[WARN] Comando è andato a buon fine, ma mi aspettavo un blocco."
  else
    echo "[OK] Comando fallito come previsto (possibile blocco AppArmor)."
  fi
  echo "[LOG] Ultimi DENIED da AppArmor:"
  eval "$LOG_CMD" || true
}

echo "== Test AppArmor per /usr/bin/ssh =="

# Test preliminare: verifica che il profilo sia caricato
echo
sep
echo "[INFO] Profili AppArmor attivi per ssh:"
if command -v aa-status >/dev/null 2>&1; then
  sudo aa-status | grep ssh || echo "  (nessun profilo ssh trovato in aa-status)"
else
  echo "  (aa-status non disponibile)"
fi

# Test ALLOWED 1: stampa versione ssh
run_allowed "ssh -V (versione client SSH)" ssh -V

# Test ALLOWED 2: elenco cipher supportati
run_allowed "ssh -Q cipher (elenco cipher supportati)" ssh -Q cipher

# Test FORBIDDEN 1: lettura credential store di sistema (/etc/shadow)
run_forbidden "Tentativo di usare /etc/shadow come file di config" \
  sudo ssh -F /etc/shadow localhost

# Test FORBIDDEN 2: accesso a materiale sensibile in ~/.ssh (fake_config)
mkdir -p "$HOME/.ssh"
echo "test" > "$HOME/.ssh/fake_config"

run_forbidden "Tentativo di usare ~/.ssh/fake_config come file di config" \
  ssh -F "$HOME/.ssh/fake_config" localhost

# Test FORBIDDEN 3: esecuzione di payload da /tmp via ProxyCommand
echo '#!/bin/sh' > /tmp/payload.sh
echo 'echo PWNED from /tmp' >> /tmp/payload.sh
chmod +x /tmp/payload.sh

run_forbidden "Tentativo di eseguire /tmp/payload.sh tramite ProxyCommand" \
  ssh -o ProxyCommand=/tmp/payload.sh localhost

echo
sep
echo "[DONE] Test AppArmor completati."