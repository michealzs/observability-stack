# Adding a host

Four steps: install node_exporter on the host, let the monitoring host reach it, add it to the target list, confirm it shows up. Nothing on the monitoring side needs a restart.

## 1. Install node_exporter on the host

Use the `node_exporter` role from [ansible-linux-baseline](https://github.com/michealzs/ansible-linux-baseline). It installs the pinned release, creates a system user, and runs it as a systemd unit on port 9100:

```bash
# from a checkout of ansible-linux-baseline
ansible-playbook -i inventory/hosts.ini playbooks/site.yml --limit web-03 --tags node_exporter
```

Any other method is fine as long as `curl -s http://<host>:9100/metrics | head` works on the host itself. A few things worth keeping:

- Bind to the internal interface if the host has a public one: `--web.listen-address=10.0.10.13:9100`.
- Leave the default collectors alone. The dashboards and alerts use `cpu`, `meminfo`, `loadavg`, `filesystem`, `diskstats`, `netdev`, `netstat`, `sockstat`, `timex`, `vmstat` and `uname`, which are all on by default.
- Run it as an unprivileged user. It only reads `/proc` and `/sys`.

## 2. Open the port to the monitoring host only

Prometheus scrapes TCP 9100 and the blackbox exporter pings the host (ICMP echo). Allow both from the monitoring host's address and nothing else.

```bash
# ufw
sudo ufw allow from 10.0.10.5 to any port 9100 proto tcp comment "node_exporter from monitoring"

# firewalld
sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="10.0.10.5" port port="9100" protocol="tcp" accept'
sudo firewall-cmd --reload

# nftables (inside your inet filter input chain)
ip saddr 10.0.10.5 tcp dport 9100 accept
```

If the hosts talk over WireGuard or Tailscale, use those addresses everywhere and the metrics never cross the public network.

Check from the monitoring host before going further:

```bash
curl -s --max-time 5 http://10.0.10.13:9100/metrics | grep '^node_uname_info'
```

## 3. Add the host to the target list

```bash
scripts/add-node.sh 10.0.10.13 --env prod --role web
```

This appends a block to `prometheus/targets/nodes.yml`, checks the file still parses, and runs `make reload`. Prometheus also re-reads the file on its own within a minute, so the reload is not strictly required. The same list drives the ICMP probe job, so the host is pinged from now on too.

Hostnames work as well (`scripts/add-node.sh web-03.internal --role web`), provided the Prometheus container can resolve them. Edit the file by hand if you prefer; each `- targets:` block carries its own labels, and the labels end up on every metric and alert from that host.

Commit the change. The target list is configuration, and the git history is the change log for the fleet.

## 4. Confirm it is being scraped

Either of these:

- Grafana, Explore, Prometheus datasource: `up{job="node", instance="10.0.10.13:9100"}` should return `1`.
- The Node Overview dashboard: the new host appears in the instance dropdown after the next dashboard refresh.

If `up` is `0`, `NodeExporterDown` fires after 5 minutes. The usual causes are a firewall rule on the wrong interface, node_exporter bound to 127.0.0.1, or a typo in the address.

## Removing a host

Delete its entry from `prometheus/targets/nodes.yml` and run `make reload`. Its series stay queryable until they age out of retention. If the host is gone for good, consider a silence on `instance=<addr>` first so `NodeExporterDown` does not fire while you edit.

## Logs from fleet hosts

Promtail in this stack only reads the monitoring host's Docker logs and `/var/log`. Loki is not published on the host. To ship logs from other machines, run Promtail or Grafana Alloy there, point it at `http://<monitoring-host>:3100/loki/api/v1/push`, and publish port 3100 on the monitoring host's private interface with a compose override, the same way `docker-compose.override.example.yml` publishes Prometheus.
