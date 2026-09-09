#!/bin/bash
set -e

if [ "$EUID" -ne 0 ]; then
   echo "ERRO: Execute este script como root ('sudo -i')."
   exit 1
fi

BACKUP_FILE="${1:-/home/$SUDO_USER/koha_library.sql}"

if [ ! -f "$BACKUP_FILE" ]; then
   echo "ERRO: arquivo de backup não encontrado em: $BACKUP_FILE"
   echo "Uso: bash <(curl -s ...) /caminho/para/koha_library.sql"
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

echo ">>> Reativando Elasticsearch nas preferências do sistema..."
mysql -e "INSERT INTO koha_library.systempreferences (variable, value, type) VALUES ('SearchEngine', 'Elasticsearch', 'Choice') ON DUPLICATE KEY UPDATE value='Elasticsearch';"
mysql -e "INSERT INTO koha_library.systempreferences (variable, value, type) VALUES ('ElasticsearchCommitImmediately', '1', 'YesNo') ON DUPLICATE KEY UPDATE value='1';"

echo ">>> Apagando índices antigos (se existirem) e reindexando do zero..."
curl -s -X DELETE 'localhost:9200/koha_library_biblios' >/dev/null 2>&1 || true
curl -s -X DELETE 'localhost:9200/koha_library_authorities' >/dev/null 2>&1 || true
koha-elasticsearch --rebuild -d library

echo ">>> Reiniciando serviços..."
systemctl restart koha-common
koha-plack --restart library

echo ">>> Verificando se o daemon de indexação está de pé..."
sleep 3
if ps aux | grep -v grep | grep -q es_indexer_daemon; then
   echo "OK: daemon es_indexer_daemon está rodando."
else
   echo "ATENÇÃO: o daemon não apareceu no ps aux. Confira:"
   echo "  journalctl -u koha-common -n 50 --no-pager | grep -A3 es-indexer"
fi

echo ""
echo "======================================================================"
echo " RESTAURAÇÃO CONCLUÍDA COM ELASTICSEARCH ATIVO."
echo " Teste buscando por um registro que existia no backup antigo."
echo "======================================================================"