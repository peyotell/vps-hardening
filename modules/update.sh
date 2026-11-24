echo
echo "==> [1/4] Обновление системы"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold

apt-get install -y unattended-upgrades curl
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

echo "Система обновлена, автообновления безопасности включены."
