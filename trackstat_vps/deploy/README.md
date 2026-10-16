# TrackStat VPS deployment

These files assume Ubuntu/Debian, Python 3.11+, systemd, and Caddy.

## 1. Install

```bash
sudo mkdir -p /opt/trackstat
sudo chown "$USER":"$USER" /opt/trackstat
# Copy the repository's trackstat_vps/ directory to /opt/trackstat/trackstat_vps/
python3 -m venv /opt/trackstat/.venv
```

The service uses only Python's standard library; no pip packages are required.

## 2. Configure secrets

Create `/etc/trackstat/trackstat.env` with restrictive permissions:

```text
TRACKSTAT_HOST=127.0.0.1
TRACKSTAT_PORT=8787
TRACKSTAT_DB=/var/lib/trackstat/trackstat.sqlite3
TRACKSTAT_STALE_SECONDS=60
TRACKSTAT_OFFLINE_SECONDS=180
TRACKSTAT_DEVICE_TOKEN_SHA256=replace-with-sha256-of-device-token
TRACKSTAT_DASHBOARD_TOKEN_SHA256=replace-with-sha256-of-dashboard-token
```

```bash
sudo install -d -m 0750 /var/lib/trackstat
sudo install -d -m 0750 /etc/trackstat
sudo chmod 0600 /etc/trackstat/trackstat.env
```

Generate token digests without putting the plaintext tokens in the repository:

```bash
printf '%s' 'device-token' | sha256sum
printf '%s' 'dashboard-token' | sha256sum
```

## 3. Install systemd service

```bash
sudo install -m 0644 trackstat.service /etc/systemd/system/trackstat.service
sudo systemctl daemon-reload
sudo systemctl enable --now trackstat
sudo systemctl status trackstat
```

## 4. Put Caddy in front

Copy the `Caddyfile.example` block into the site's Caddy configuration and reload Caddy. The Python listener remains bound to localhost and is not directly exposed.

## 5. Verify

```bash
curl -fsS https://trackstat.example.com/healthz
sudo journalctl -u trackstat -n 50 --no-pager
```

Then load the dashboard URL and sign in with the dashboard token. Test one device before enabling a larger account pool.
