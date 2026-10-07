# Home test checklist

Details and troubleshooting: [TESTING.md §7](TESTING.md).

- [ ] Webhook route reaches this machine: Cloudflare Zero Trust → Networks →
      Tunnels → picloud → Published application routes → `webhook.salh.xyz`
      Service = `http://<this-machine>:5000`
      (or skip it: `cloudflared tunnel --url http://localhost:5000` and set
      `PLAID_WEBHOOK_URL=https://<random>.trycloudflare.com/plaid`)
- [ ] Fresh start (optional): `rm budget.db`
- [ ] Server: `devenv shell -- dune exec src/main.exe`
- [ ] Tunnel check: `curl -i -X POST https://webhook.salh.xyz/plaid` →
      `400 rejected: no Plaid-Verification header`
- [ ] Watch events: `curl -N http://localhost:5000/api/plaid/events`
- [ ] TUI: `devenv shell -- dune exec bin/tui.exe` → Enter → sign in with
      `user_good` / `pass_good`
- [ ] Server log shows the webhook, the event stream shows a `plaid` frame,
      the TUI shows accounts
