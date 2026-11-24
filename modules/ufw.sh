echo
echo "==> [3/4] Файрвол (UFW)"

apt-get install -y ufw

ufw allow "$SSH_PORT"/tcp
read -ra extra_ports <<< "$EXTRA_TCP_PORTS"
for p in "${extra_ports[@]}"; do
    [[ $p == "$SSH_PORT" ]] && continue
    ufw allow "$p"/tcp
done

ufw default deny incoming
ufw default allow outgoing
ufw --force enable

ufw status verbose
