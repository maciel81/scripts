#!/usr/bin/env bash
# Subcomandos que pertencem ao docker compose (rodam no host)
case "${1:-}" in
    logs|up|down|ps|build|restart|stop|start|config|pull|exec|run)
        docker compose "$@"
        ;;
    *)
        # Qualquer outra coisa roda DENTRO do container da aplicação
        service="$(docker compose config --services | grep -vx 'mysql' | head -n1)"
        docker compose exec "$service" "$@"
        ;;
esac
