# Day 10.6: Developer Experience — HMR, Logs & Debugging

## The Problem

Currently:
- Changing a service file requires full restart (`Ctrl+C` + `jac start`)
- Service logs go to `/dev/null` — can't see what's happening
- No way to debug a single service without restarting everything
- No colored/formatted output to distinguish services

## What to Build

### Per-Service Log Files

Instead of DEVNULL, write service output to log files:

```
.jac/logs/
├── products.log
├── orders.log
├── cart.log
└── gateway.log
```

`jac scale logs products` reads from the log file.

### Colored Gateway Output

Prefix proxy logs with service color:

```
[products] POST /walker/ListProducts → 200 (12ms)
[orders]   POST /walker/PlaceOrder  → 200 (156ms)
[cart]     POST /walker/ClearCart    → 200 (8ms)
```

### Individual Service Restart

`jac scale restart orders` should:
1. Stop just the orders subprocess
2. Start a new one on the same port
3. Wait for health check
4. Resume routing

Already implemented in `LocalDeployer.restart_service()` — just needs to be tested with running gateway.

### File Watching (Future HMR)

Watch service `.jac` files for changes and auto-restart:

```
Watching: services/orders.jac
  Modified → restarting orders service...
  [OK] orders healthy on :8002
```

Uses `watchdog` library (already in jac dev dependencies).

## Milestone
- [ ] Service logs written to `.jac/logs/{service}.log`
- [ ] `jac scale logs products` shows service logs
- [ ] Colored proxy output in gateway terminal
- [ ] Individual service restart without full shutdown
- [ ] (Stretch) File watching with auto-restart
