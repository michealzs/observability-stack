# Alerts

Every alerting rule in `prometheus/rules/` with its severity, the condition in plain words and the first thing to do. `scripts/check_rules.py` enforces that each rule has a `for`, a severity from {critical, warning, info}, a summary and a description.

## Severities

| Severity | Meaning | Routing (alertmanager/alertmanager.yml.tmpl) |
| --- | --- | --- |
| critical | Something is down or about to be. Act now. | `slack-critical`, group wait 15s, repeats every 1h |
| warning | Degraded or heading for trouble. Act during working hours. | `slack-warning`, repeats every 4h |
| info | For the record. No action. | `slack-info`, no resolved messages, repeats every 24h |

A critical alert inhibits the warning with the same `alertname` and `instance`. `NodeExporterDown` inhibits every warning and info alert for that instance. `Watchdog` goes to the `null` receiver.

## Hosts (`prometheus/rules/node.yml`, job `node`)

| Alert | Severity | Fires when | What to do |
| --- | --- | --- | --- |
| HostHighCpuLoad | warning | Non idle CPU above 85% for 15 minutes | `top` or `htop` on the host. If it is a runaway process, deal with it; if it is normal load, the host needs more CPU or less work. |
| HostOutOfMemory | warning | Less than 10% of memory available for 5 minutes | `free -m`, then `ps aux --sort=-rss \| head`. Expect an OOM kill next if nothing changes. |
| HostOutOfDiskSpace | critical | A real filesystem has under 10% free for 5 minutes | `df -h`, `du -xsh /* 2>/dev/null \| sort -h`. Usual suspects: logs, Docker images, package caches, old backups. |
| HostDiskWillFillIn24Hours | warning | Under 20% free and, extrapolating the last 6 hours, empty within 24 hours, for 30 minutes | Find what is growing (`du` twice a few minutes apart) before it becomes the critical alert. |
| HostOutOfInodes | warning | Under 10% of inodes free for 5 minutes | `df -i`. Look for directories with millions of small files (mail queues, session files, caches). |
| HostHighLoad | warning | 5 minute load average above 2 per core for 15 minutes | Check whether it is CPU (`top`) or I/O wait (`iostat -x 1`, `vmstat 1`). High load with idle CPU means blocked I/O. |
| HostOomKillDetected | warning | The kernel OOM killer ran in the last 10 minutes | `dmesg -T \| grep -i "killed process"` and `journalctl -k`. Add a memory limit to the offender or give the host more memory. |
| HostClockNotSynchronising | warning | NTP not synchronised for 10 minutes and error estimate above 16 seconds | `timedatectl` and `chronyc tracking` (or `systemctl status systemd-timesyncd`). Check outbound UDP 123. |
| NodeExporterDown | critical | Prometheus cannot scrape the host for 5 minutes | Ping it, `ssh` in, `systemctl status node_exporter`. If the host is fine, check the firewall rule for port 9100 from the monitoring host. Also see the ICMP probe in the Alerts dashboard. |

## Containers (`prometheus/rules/containers.yml`, job `cadvisor`)

| Alert | Severity | Fires when | What to do |
| --- | --- | --- | --- |
| ContainerKilled | warning | A container seen 5 minutes ago is gone (matched by name, so a recreate does not count) for 1 minute | `docker ps -a --filter status=exited`, then `docker logs <name>`. If it was intentional, nothing to do; the alert clears in 5 minutes. |
| ContainerHighCpu | warning | One container uses more than 80% of all host cores for 10 minutes | `docker stats`. Give it a `cpus` limit in compose or find the hot loop. |
| ContainerCpuThrottled | warning | More than 25% of CFS periods were throttled for 15 minutes | The container is hitting its `cpus` limit. Raise the limit or reduce the work. |
| ContainerHighMemory | warning | Working set above 85% of the memory limit for 10 minutes | `docker stats`. Raise the `memory` limit or fix the leak. At 100% the kernel kills it. Containers without a limit never trigger this. |
| ContainerVolumeUsage | warning | A container filesystem is more than 80% full for 10 minutes | `docker system df -v`. Usually the writable layer or a log file inside the container. |

## Probes (`prometheus/rules/blackbox.yml`, jobs `blackbox-http` and `blackbox-icmp`)

| Alert | Severity | Fires when | What to do |
| --- | --- | --- | --- |
| BlackboxProbeFailed | critical | An HTTP or ICMP probe has failed for 3 minutes | For HTTP, `curl -sv <url>` from the monitoring host. For ICMP, the host is unreachable: check it and the network path. |
| BlackboxSlowProbe | warning | HTTP probe averaged more than 2 seconds over 5 minutes | Check the service behind the URL and its dependencies. Compare with the Node Overview for that host. |
| BlackboxProbeHttpFailure | critical | HTTP status is below 200 or 400 and above for 3 minutes | `curl -sI <url>`. 5xx is the service, 4xx is usually a changed path or auth, 0 means no HTTP answer at all. |
| BlackboxSslCertificateWillExpireSoon | warning | Certificate expires in under 30 days | Renew it. If certbot or an ACME client should have done this already, find out why it did not. |
| BlackboxSslCertificateWillExpireSoon | critical | Certificate expires in under 3 days | Renew it today. The warning is inhibited while this fires. |

## The stack itself (`prometheus/rules/prometheus.yml`)

| Alert | Severity | Fires when | What to do |
| --- | --- | --- | --- |
| Watchdog | info | Always | Nothing. If it stops arriving at a dead man's switch, or the Alerts dashboard shows it missing, Prometheus or Alertmanager is broken. |
| PrometheusTargetMissing | critical | Any non node target cannot be scraped for 5 minutes | `docker compose ps`, then `docker compose logs <service>`. |
| PrometheusRuleEvaluationFailures | critical | A rule group failed to evaluate in the last 5 minutes | `docker compose logs prometheus \| grep -i "evaluat"`. Usually a bad expression after an edit; `make validate` first next time. |
| PrometheusConfigReloadFailed | warning | The last configuration reload failed | Prometheus keeps running the previous config. `make validate`, fix, `make reload`. |
| PrometheusNotConnectedToAlertmanager | critical | Prometheus has discovered no Alertmanager for 5 minutes | `docker compose ps alertmanager`, `docker compose logs alertmanager`. Alerts are not being delivered until this clears. |
| AlertmanagerConfigReloadFailed | warning | The last Alertmanager configuration reload failed | `docker compose run --rm alertmanager check` shows the error. |
| AlertmanagerNotificationsFailing | critical | Slack (or another integration) has been failing for 5 minutes | Check `SLACK_WEBHOOK_URL` in `.env` and outbound HTTPS from the host. `docker compose logs alertmanager` shows the response. |

## Silencing

Alertmanager is not published on the host, so use `amtool` inside the container:

```bash
# silence one alert on one host for two hours
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 \
  silence add alertname=HostHighCpuLoad instance=10.0.10.11:9100 \
  --duration=2h --author="$USER" --comment="batch job, expected"

# list and expire
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 silence query
docker compose exec alertmanager amtool --alertmanager.url=http://localhost:9093 silence expire <id>
```

Silences also work from the provisioned Alertmanager datasource in Grafana (Alerting, Silences).
