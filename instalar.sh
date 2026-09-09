#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
  echo "ERRO / ERROR / ERROR: Execute este script como root ('sudo -i')."
  exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -z "$REAL_HOME" ] && REAL_HOME="/home/$REAL_USER"

echo ">>> [PT] Sincronizando relógio e fuso horário automaticamente / [EN] Syncing clock & timezone automatically / [ES] Sincronizando reloj y zona horaria..."
apt-get update -o Acquire::Check-Valid-Until=false -y || true
DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-timesyncd tzdata
systemctl enable --now systemd-timesyncd
timedatectl set-timezone $(curl -s https://ipapi.co/timezone || echo "America/Sao_Paulo")
timeout 10 bash -c 'until timedatectl | grep -q "synchronized: yes"; do sleep 1; done' || true

export DEBIAN_FRONTEND=noninteractive

echo ">>> Verificando SWAP / Checking SWAP / Verificando SWAP..."
if [ "$(swapon --show | wc -l)" -le 1 ]; then
  fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo ">>> Instalando dependências básicas e ferramentas de segurança..."
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y nano curl wget gpg ufw software-properties-common default-jre-headless \
              libapache2-mod-security2 fail2ban postfix libsasl2-modules glabels \
              at rclone avahi-daemon memcached

systemctl enable --now avahi-daemon
systemctl enable --now fail2ban

mkdir -p /usr/share/keyrings
wget -q --timeout=20 --tries=3 -O - https://debian.koha-community.org/koha/gpg.asc | gpg --dearmor --yes -o /usr/share/keyrings/koha-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/koha-keyring.gpg] https://debian.koha-community.org/koha oldstable main" > /etc/apt/sources.list.d/koha.list

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server koha-common

systemctl enable --now mariadb

echo ">>> Configurando Apache, portas e memcached..."
sed -i 's/^INTRAPORT=.*/INTRAPORT="8080"/' /etc/koha/koha-sites.conf
sed -i 's/^OPACPORT=.*/OPACPORT="80"/' /etc/koha/koha-sites.conf
sed -i 's/^#*MEMCACHED_SERVERS=.*/MEMCACHED_SERVERS="127.0.0.1:11211"/' /etc/koha/koha-sites.conf
sed -i 's/^#*MEMCACHED_PREFIX=.*/MEMCACHED_PREFIX="koha_"/' /etc/koha/koha-sites.conf

a2enmod rewrite cgi deflate headers proxy_http
grep -q "^Listen 8080" /etc/apache2/ports.conf || sed -i '/Listen 80/a Listen 8080' /etc/apache2/ports.conf
systemctl restart apache2

echo ">>> Removendo qualquer instância/banco anterior chamado 'library'..."
koha-remove library 2>/dev/null || true
mysql -e "DROP DATABASE IF EXISTS koha_library;" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS 'koha_library'@'localhost';" 2>/dev/null || true
rm -rf /etc/koha/sites/library

echo ">>> Criando instância 'library' (Motor de busca nativo Zebra)..."
koha-create --create-db library

sed -i 's/__MEMCACHED_SERVERS__/127.0.0.1:11211/g' /etc/koha/sites/library/koha-conf.xml
sed -i 's/__MEMCACHED_PREFIX__/koha_library:/g' /etc/koha/sites/library/koha-conf.xml

a2dissite 000-default 2>/dev/null || true
a2ensite library
systemctl restart apache2
systemctl restart memcached

koha-translate --install pt-BR
koha-plack --enable library
koha-plack --start library
systemctl restart koha-common

# Habilitando o Zebra de forma nativa e compatível com as versões recentes
koha-enable library
koha-start-zebra library

echo ">>> Configurando backup e crontab..."
ARQUIVO_CONF="/etc/koha/sites/library/koha-conf.xml"
DB_PASS=$(grep -oP '(?<=<pass>)[^<]+' "$ARQUIVO_CONF" | head -n 1)
DB_USER="koha_library"

mkdir -p "$REAL_HOME/logs" "/var/backups"
chown -R "$REAL_USER":"$REAL_USER" "$REAL_HOME/logs" 2>/dev/null || true

cat << 'EOF' > "$REAL_HOME/backup_aut.sh"
#!/bin/bash
set -o pipefail
DATA=\$(date +%Y-%m-%d_%Hh%M)
DIR_BACKUP="/var/backups"
DIR_LOG="$REAL_HOME/logs"

mkdir -p "\$DIR_BACKUP" "\$DIR_LOG"
LOG_FILE="\$DIR_LOG/backup_\$DATA.log"

echo "Iniciando backup em \$DATA" >> "\$LOG_FILE"
mysqldump -u"koha_library" -p'${DB_PASS}' "koha_library" | gzip > "\$DIR_BACKUP/koha_library_\$DATA.sql.gz"

if [ \$? -ne 0 ]; then
  echo "ERRO: Falha ao gerar o dump do banco!" >> "\$LOG_FILE"
  exit 1
fi

/usr/bin/rclone --config /root/.config/rclone/rclone.conf move "\$DIR_BACKUP/koha_library_\$DATA.sql.gz" gdrive:Backup_Koha >> "\$LOG_FILE" 2>&1
find "\$DIR_BACKUP" -name "koha_library_*.sql.gz" -mtime +7 -exec rm {} \;
echo "Finalizado em \$(date)" >> "\$LOG_FILE"
EOF

chmod +x "$REAL_HOME/backup_aut.sh"
chown "$REAL_USER":"$REAL_USER" "$REAL_HOME/backup_aut.sh" 2>/dev/null || true
ln -sf "$REAL_HOME/backup_aut.sh" /root/backup_aut.sh

cat << EOF > /tmp/koha_cron
30 0 * * * /usr/bin/journalctl --vacuum-time=14d
0 1 5 * * /usr/bin/mysqlcheck --check --auto-repair --databases koha_library
0 5 * * * /usr/sbin/koha-plack --restart library
40 17 * * * /bin/bash $REAL_HOME/backup_aut.sh
*/5 * * * * koha-rebuild-zebra -z -b -a library
EOF
crontab /tmp/koha_cron
rm /tmp/koha_cron

echo ">>> Ativando firewall..."
echo "ufw disable" | at now + 10 minutes
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 8080/tcp
ufw allow 587/tcp
ufw allow 53682/tcp
echo "y" | ufw enable

IP_REAL=$(hostname -I | awk '{print $1}')
[ -z "$IP_REAL" ] && IP_REAL="ipdoservidor"

cat << EOF > /etc/issue
Ubuntu \n \l

======================================================================
         SISTEMA KOHA PRONTO / KOHA SYSTEM READY / SISTEMA LISTO!
======================================================================
  Enderecos de Acesso / Access URLs / Direcciones de Acceso:
  - Staff (Adm):   http://${IP_REAL}:8080
  - OPAC (Leitor): http://${IP_REAL}:80
----------------------------------------------------------------------
  Primeiro Acesso / First Access / Primer Acceso:
  - Usuario / User / Usuario: $DB_USER
  - Senha / Password / Contraseña:   $DB_PASS
======================================================================

EOF
cp /etc/issue /etc/issue.net
cp /etc/issue /etc/motd

echo ""
echo "======================================================================"
echo " INSTALAÇÃO BASE CONCLUÍDA / BASE INSTALLATION COMPLETE."
echo " Acesse http://${IP_REAL}:8080 e complete o Web Installer no navegador."
echo " Usuário: $DB_USER  | Senha: $DB_PASS"
echo ""
echo " Crie uma senha forte para o administrador / Create a strong password."
echo "======================================================================"

echo -e "\n\033[1;33m======================================================================"
echo "        AUTORIZAÇÃO DO GOOGLE DRIVE (RCLONE) / GOOGLE DRIVE AUTH        "
echo "======================================================================\033[0m"
echo "O link de autorização aparecerá abaixo / The auth link will appear below:"
echo "----------------------------------------------------------------------"

mkdir -p /root/.config/rclone
/usr/bin/rclone config create gdrive drive scope drive

/usr/bin/rclone --config /root/.config/rclone/rclone.conf mkdir gdrive:Backup_Koha 2>/dev/null || true
echo ">>> Rclone configurado com sucesso! / Rclone successfully configured!"

echo ""
echo "======================================================================"
echo " Aguardando conclusão do Web Installer em http://${IP_REAL}:8080 ..."
echo " Waiting for Web Installer completion..."
echo "======================================================================"
while true; do
  COUNT=$(mysql -N -e "SELECT COUNT(*) FROM koha_library.borrowers;" 2>/dev/null || echo 0)
  if [ "$COUNT" -gt 0 ] 2>/dev/null; then
    break
  fi
  sleep 10
done

echo ">>> Web Installer concluído! Finalizando..."

mysql -e "UPDATE koha_library.systempreferences SET value='Zebra' WHERE variable='SearchEngine';"
koha-rebuild-zebra -v -f library

systemctl restart koha-common
koha-plack --restart library

for job in $(atq 2>/dev/null | cut -f1); do
  atrm "$job" 2>/dev/null || true
done
