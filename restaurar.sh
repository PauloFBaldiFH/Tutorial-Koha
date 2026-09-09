#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
   echo "ERRO: Execute este script como root ('sudo -i')."
   exit 1
fi

BACKUP_FILE="${1:-/home/$SUDO_USER/koha_library.sql}"

if [ ! -f "$BACKUP_FILE" ]; then
   echo "ERRO: arquivo de backup não encontrado em: $BACKUP_FILE"
   echo "Uso: $0 /caminho/para/koha_library.sql"
   exit 1
fi

echo ">>> Backup encontrado: $BACKUP_FILE"

echo ">>> Recriando o banco de dados koha_library do zero..."
mysql -e "DROP DATABASE IF EXISTS koha_library; CREATE DATABASE koha_library;"

echo ">>> Restaurando o backup (isso pode demorar alguns minutos)..."
mysql koha_library < "$BACKUP_FILE"

echo ">>> Reiniciando memcached..."
systemctl restart memcached

echo ">>> Aplicando atualizações de schema (koha-upgrade-schema)..."
koha-upgrade-schema library

echo ">>> Garantindo que Zebra seja o motor de busca padrão..."
mysql -e "INSERT INTO koha_library.systempreferences (variable, value, type) VALUES ('SearchEngine', 'Zebra', 'Choice') ON DUPLICATE KEY UPDATE value='Zebra';"

echo ">>> Limpando e reindexando o acervo do zero no Zebra..."
koha-rebuild-zebra -v -f library

echo ">>> Reiniciando serviços..."
systemctl restart koha-common
koha-plack --restart library
