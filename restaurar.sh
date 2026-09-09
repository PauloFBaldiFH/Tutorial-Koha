#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
   echo "ERRO / ERROR: Execute este script como root ('sudo -i')."
   exit 1
fi

# 1. Correção da captura segura do diretório do usuário
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
[ -z "$REAL_HOME" ] && REAL_HOME="/home/$REAL_USER"

BACKUP_FILE="${1:-$REAL_HOME/koha_library.sql}"

if [ ! -f "$BACKUP_FILE" ]; then
   echo "ERRO: Arquivo de backup não encontrado em / Backup file not found at: $BACKUP_FILE"
   echo "Uso: $0 /caminho/para/koha_library.sql"
   exit 1
fi

echo ">>> Backup encontrado / Backup found: $BACKUP_FILE"

# 2. Correção Crítica: Recriando o banco com a codificação correta para não quebrar os acentos
echo ">>> Recriando o banco de dados koha_library (utf8mb4)..."
mysql -e "DROP DATABASE IF EXISTS koha_library; CREATE DATABASE koha_library CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

echo ">>> Restaurando o backup (isso pode demorar alguns minutos)..."
mysql koha_library < "$BACKUP_FILE"

echo ">>> Reiniciando memcached para limpar o cache antigo..."
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

echo ">>> RESTAURAÇÃO CONCLUÍDA COM SUCESSO / RESTORATION SUCCESSFULLY COMPLETED!"
