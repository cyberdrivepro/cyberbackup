# CyberVPS templates

This directory holds template files used during fresh install and restore.

Template files:
- system.txt.template: system manifest template
- files.txt.template: files manifest template
- micromamba-env.yml.template: micromamba environment template
- micromamba-explicit.txt.template: explicit package list template
- pm2-dump.pm2.template: PM2 dump template (empty, to be populated by backup)
- supervisor.conf.template: supervisor config template
- nginx.conf.template: nginx config template
- redis.conf.template: redis config template
- hosting24.conf.template: hosting flags template
- cloudflare-quick-tunnel.sh.template: cloudflared helper template
- scheduler.conf.template: scheduler supervisor program template
- cron.example.template: cron example job template
- .bashrc.template: shell config template
- .profile.template: profile template

Templates are used by fresh-install.sh and restore.sh to recreate
configuration files when they are missing or when rebuilding from zero.
