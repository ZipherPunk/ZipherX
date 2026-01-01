# Tor Issues - To Investigate Later

**Date:** 2025-12-26
**Status:** Deferred - Testing Direct Connection Mode first

---

## Summary

Tor integration is causing intermittent connection issues. We've disabled Tor temporarily to stabilize the core wallet functionality. Once the app works reliably with direct connections, we'll re-enable Tor and investigate these issues.

---

## Issues Identified

### 1. Intermittent SOCKS5 Connection Refused (Medium Priority)

**Symptoms:**
- 27 "SOCKS5 error: Connection refused" errors over 4 minutes
- Some peers connect successfully, others fail
- Pattern: 2-3 peers succeed, 2-3 fail each connection attempt

**Evidence:**
```
13:45:25] ❌ Failed hardcoded peer 157.90.223.151: Connection failed: SOCKS5 error: Connection refused
13:45:25] ✅ Connected to 205.209.104.118
13:45:25] ✅ Connected to 140.174.189.3
```

**Hypothesis:**
- Tor SOCKS5 proxy (Arti) is overloaded
- Too many simultaneous connection attempts
- Connection pool not managing load properly

**Files to Check:**
- `Sources/Core/Network/TorManager.swift` - Arti configuration
- `Sources/Core/Network/Peer.swift` - Connection attempt logic
- `Sources/Core/Network/NetworkManager.swift` - Peer connection batching

**Potential Solutions:**
- Rate limit connection attempts
- Increase SOCKS5 connection timeout
- Implement connection pooling with queuing
- Check Arti configuration for max concurrent connections

---

### 2. All Peers Die Simultaneously (High Priority)

**Symptoms:**
- All 8 connected peers timeout within same 30-second window
- Health monitor shows "4 connected, 0 alive"
- Pattern repeats every few minutes

**Evidence:**
```
13:43:45] Peer 140.174.189.17 ping timeout
13:43:47] Peer 140.174.189.3 handshake failed
13:43:50] Peer 205.209.104.118 ping timeout
13:43:53] Peer 74.50.74.102 ping timeout
Result: 4 connected, 0 alive
```

**Hypothesis:**
- Tor circuit degradation over time
- SOCKS5 proxy stops accepting new connections
- Arti internal state corruption

**Implementation Status:**
- ✅ Detection implemented (FIX #246)
- ✅ SOCKS5 health monitoring implemented
- ✅ Auto-restart Tor after 2 consecutive failures
- ❌ Not triggering (health check not being called consistently)

**Files to Check:**
- `Sources/Core/Network/TorManager.swift:536-565` - SOCKS5 health check
- `Sources/Core/Network/NetworkManager.swift:6620-6642` - Health monitor

---

### 3. Header Sync Timeouts Over Tor (Resolved)

**Symptoms:**
- Header sync timing out after 45-75 seconds
- Multiple retry attempts needed
- Eventually succeeds after 3-5 attempts

**Root Cause:**
- Tor latency + peer timeout = sync timeout
- Combined timeouts were too aggressive

**FIX Implemented:**
- ✅ FIX #444: Timeout throws error (not silent failure)
- ✅ FIX #274: Dynamic timeout based on headers needed
- ✅ FIX #406: Retry mechanism (3 attempts)

**Result:**
- Header sync now completes successfully after retries
- 88 headers synced in 19 seconds over Tor

---

### 4. Health Monitor Not Calling SOCKS5 Check (Debugging Needed)

**Symptoms:**
- Connection health monitor runs every 30 seconds ✅
- Prints "💓 Connection health: X connected, Y alive" ✅
- But never calls SOCKS5 health check ❌
- No debug output from `checkSOCKS5Health()`

**Expected Behavior:**
```
🔍 [HEALTH] Tor mode: enabled
🔍 [HEALTH] Tor enabled - calling SOCKS5 health check...
🔍 [SOCKS5] checkSOCKS5Health() called - mode: enabled, socksPort: 9250
🔍 [SOCKS5] Testing connection to 127.0.0.1:9250
```

**Actual Behavior:**
```
💓 Connection health: 4 connected, 0 alive
[Then immediate peer pings, no SOCKS5 output]
```

**Hypothesis:**
- Code path not being reached
- `TorManager.shared.mode` check failing silently
- Async/await context issue

**Debugging Added:**
- ✅ Added logging to show Tor mode value
- ✅ Added logging before SOCKS5 check call
- ✅ Added extensive logging inside `checkSOCKS5Health()`

**Next Step:**
- Rebuild app with new logging
- Run with Tor enabled
- Check zmac.log for debug output

---

## Test Plan for Tor Re-enablement

### Phase 1: Direct Mode Baseline (Current)
- [x] Disable Tor
- [ ] Test all core functionality
- [ ] Establish performance baseline
- [ ] Document direct mode behavior

### Phase 2: Tor Re-enablement (Future)
1. **Enable Tor** in settings
2. **Run test_direct_mode.sh** to compare
3. **Check logs** for SOCKS5 health check output
4. **Monitor peer connections** for stability
5. **Test header sync** with Tor enabled

### Phase 3: Tor Debugging (If Issues Persist)
1. **Add rate limiting** to connection attempts
2. **Increase SOCKS5 timeout** from 1s to 3s
3. **Check Arti config** for max connections
4. **Implement connection queue** with semaphore
5. **Add circuit isolation** for different operations

---

## Files Modified (Related to Tor)

1. **TorManager.swift**
   - Added SOCKS5 health monitoring
   - Added Tor restart logic
   - Added extensive debug logging

2. **NetworkManager.swift**
   - Added connection health monitoring
   - Added "all peers dead" detection
   - Added Tor health check integration
   - Added debug logging for health checks

3. **Peer.swift**
   - TCP keepalive improvements
   - Connection timeout handling
   - Handshake failure detection

4. **analyze_log.sh**
   - Added SOCKS5 error detection
   - Added Tor mode detection
   - Added handshake failure tracking
   - Added header sync loop detection

5. **test_direct_mode.sh** (NEW)
   - Comprehensive test suite for direct mode
   - Scoring system (0-10)
   - Tests all core functionality

---

## Key Metrics to Compare

| Metric | Direct Mode | Tor Mode | Target |
|--------|-------------|----------|--------|
| Startup time | ? | ? | < 5s (FAST) |
| Header sync time | ? | 19s | < 30s |
| Peer connections | ? | 8/8 | ≥ 5 |
| SOCKS5 errors | 0 | 27 | 0 |
| Ping timeouts | ? | Many | < 10% |
| Uptime stability | ? | Poor | > 95% |

---

## Related FIX Numbers

- FIX #169: Persistent .onion address
- FIX #246: Tor keepalive ping + auto-reconnection
- FIX #268: NWPathMonitor for network transitions
- FIX #267: iOS TCP keepalive for mobile connections
- FIX #258: iOS background peer recovery
- FIX #274: Dynamic header sync timeout
- FIX #406: Header sync retry mechanism
- FIX #419: Lock acquisition timeout for peer access
- FIX #444: Header sync timeout error throwing

---

## Commands for Testing

```bash
# Test direct mode
./test_direct_mode.sh

# Analyze logs
./analyze_log.sh zmac

# Check Tor status
grep "Tor mode" zmac.log

# Check SOCKS5 health
grep "SOCKS5" zmac.log | tail -20

# Check peer connections
grep "Connected to" zmac.log | tail -10

# Check health monitor
grep "\[HEALTH\]" zmac.log | tail -20
```

---

**End of Document**
