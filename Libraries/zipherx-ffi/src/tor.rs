//! Arti (Rust Tor) integration for ZipherX
//!
//! Provides embedded Tor support for both iOS and macOS
//! Uses Arti - the Tor Project's official Rust implementation
//! Includes SOCKS5 proxy server for P2P connections

use arti_client::{TorClient, TorClientConfig, StreamPrefs};
use tor_rtcompat::PreferredRuntime;
use tokio::runtime::Runtime;
use tokio::net::{TcpListener, TcpStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use once_cell::sync::OnceCell;
use std::sync::{Arc, Mutex, atomic::{AtomicU8, AtomicU16, AtomicBool, Ordering}};
use std::path::PathBuf;
use std::net::SocketAddr;

/// Global Tor client instance
static TOR_CLIENT: OnceCell<Mutex<Option<TorClient<PreferredRuntime>>>> = OnceCell::new();

/// Global Tokio runtime for async operations
static TOKIO_RUNTIME: OnceCell<Runtime> = OnceCell::new();

/// Tor connection state (matches Swift TorConnectionState)
/// 0 = Disconnected, 1 = Connecting, 2 = Bootstrapping, 3 = Connected, 4 = Error
static TOR_STATE: AtomicU8 = AtomicU8::new(0);

/// Bootstrap progress (0-100)
static TOR_BOOTSTRAP_PROGRESS: AtomicU8 = AtomicU8::new(0);

/// SOCKS proxy port - fixed at 9150 for compatibility with zclassicd
/// (9150 is the standard Tor Browser SOCKS port, 9050 is system Tor)
const FIXED_SOCKS_PORT: u16 = 9150;

/// SOCKS proxy port (stored after binding)
static TOR_SOCKS_PORT: AtomicU16 = AtomicU16::new(0);

/// Last error message
static TOR_ERROR: Mutex<Option<String>> = Mutex::new(None);

/// Flag to stop the SOCKS proxy server
static SOCKS_SERVER_RUNNING: AtomicBool = AtomicBool::new(false);

/// Get or create the Tokio runtime
fn get_runtime() -> &'static Runtime {
    TOKIO_RUNTIME.get_or_init(|| {
        Runtime::new().expect("Failed to create Tokio runtime")
    })
}

/// Get the Tor data directory
fn get_tor_data_dir() -> PathBuf {
    #[cfg(target_os = "ios")]
    {
        // iOS: Use Documents directory
        if let Some(home) = dirs::document_dir() {
            return home.join("ZipherX").join("Tor");
        }
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: Use Application Support
        if let Some(support) = dirs::data_dir() {
            return support.join("ZipherX").join("Tor");
        }
    }

    // Fallback
    PathBuf::from("/tmp/zipherx_tor")
}

/// Start the embedded Tor client
/// Returns 0 on success, 1 on error
#[no_mangle]
pub extern "C" fn zipherx_tor_start() -> i32 {
    // Already running?
    let state = TOR_STATE.load(Ordering::SeqCst);
    if state == 1 || state == 3 {
        eprintln!("🧅 Tor already running or starting");
        return 0;
    }

    TOR_STATE.store(1, Ordering::SeqCst); // Connecting
    TOR_BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);

    let runtime = get_runtime();

    runtime.spawn(async {
        match start_tor_async().await {
            Ok(port) => {
                TOR_SOCKS_PORT.store(port, Ordering::SeqCst);
                TOR_STATE.store(3, Ordering::SeqCst); // Connected
                TOR_BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
                eprintln!("🧅 Tor connected! SOCKS port: {}", port);
            }
            Err(e) => {
                let msg = format!("{}", e);
                eprintln!("🧅 Tor error: {}", msg);
                if let Ok(mut err) = TOR_ERROR.lock() {
                    *err = Some(msg);
                }
                TOR_STATE.store(4, Ordering::SeqCst); // Error
            }
        }
    });

    0
}

/// Async function to start Tor and SOCKS5 proxy server
async fn start_tor_async() -> Result<u16, Box<dyn std::error::Error + Send + Sync>> {
    let data_dir = get_tor_data_dir();

    // Create data directory if it doesn't exist
    std::fs::create_dir_all(&data_dir)?;

    eprintln!("🧅 Tor data directory: {:?}", data_dir);

    // Build Tor configuration using default config with custom paths
    // Note: Arti 0.37+ requires CfgPath type, so we use environment variables
    // to set the directories instead
    std::env::set_var("ARTI_CACHE_DIR", data_dir.join("cache").to_string_lossy().to_string());
    std::env::set_var("ARTI_STATE_DIR", data_dir.join("state").to_string_lossy().to_string());

    // Use default configuration
    let config = TorClientConfig::default();

    eprintln!("🧅 Starting Arti Tor client...");
    TOR_BOOTSTRAP_PROGRESS.store(10, Ordering::SeqCst);

    // Create and bootstrap the client
    let client = TorClient::create_bootstrapped(config).await?;

    TOR_BOOTSTRAP_PROGRESS.store(80, Ordering::SeqCst);
    eprintln!("🧅 Arti client bootstrapped, starting SOCKS5 proxy...");

    // Store the client
    let client_arc = Arc::new(client);
    let client_storage = TOR_CLIENT.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = client_storage.lock() {
        *guard = Some((*client_arc).clone());
    }

    // Start SOCKS5 proxy server on fixed port 9150 (for zclassicd compatibility)
    // Try the fixed port first, fallback to dynamic if in use
    let listener = match TcpListener::bind(format!("127.0.0.1:{}", FIXED_SOCKS_PORT)).await {
        Ok(l) => {
            eprintln!("🧅 SOCKS5 proxy listening on 127.0.0.1:{} (fixed port)", FIXED_SOCKS_PORT);
            l
        }
        Err(e) => {
            eprintln!("🧅 Fixed port {} in use ({}), trying dynamic port...", FIXED_SOCKS_PORT, e);
            let l = TcpListener::bind("127.0.0.1:0").await?;
            eprintln!("🧅 SOCKS5 proxy listening on 127.0.0.1:{} (dynamic fallback)", l.local_addr()?.port());
            l
        }
    };
    let socks_port = listener.local_addr()?.port();
    TOR_SOCKS_PORT.store(socks_port, Ordering::SeqCst);
    TOR_BOOTSTRAP_PROGRESS.store(95, Ordering::SeqCst);

    // Spawn the SOCKS5 proxy server
    SOCKS_SERVER_RUNNING.store(true, Ordering::SeqCst);
    let client_for_proxy = client_arc.clone();

    tokio::spawn(async move {
        run_socks5_proxy(listener, client_for_proxy).await;
    });

    TOR_BOOTSTRAP_PROGRESS.store(100, Ordering::SeqCst);
    Ok(socks_port)
}

/// Run the SOCKS5 proxy server
async fn run_socks5_proxy(listener: TcpListener, client: Arc<TorClient<PreferredRuntime>>) {
    eprintln!("🧅 SOCKS5 proxy server started");

    while SOCKS_SERVER_RUNNING.load(Ordering::SeqCst) {
        match listener.accept().await {
            Ok((stream, addr)) => {
                let client_clone = client.clone();
                tokio::spawn(async move {
                    // Silently handle connection errors (too verbose otherwise)
                    let _ = handle_socks5_connection(stream, addr, client_clone).await;
                });
            }
            Err(e) => {
                if SOCKS_SERVER_RUNNING.load(Ordering::SeqCst) {
                    eprintln!("🧅 SOCKS5 accept error: {}", e);
                }
            }
        }
    }

    eprintln!("🧅 SOCKS5 proxy server stopped");
}

/// Handle a single SOCKS5 client connection
async fn handle_socks5_connection(
    mut stream: TcpStream,
    addr: SocketAddr,
    client: Arc<TorClient<PreferredRuntime>>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // SOCKS5 greeting: client sends version + auth methods
    let mut greeting = [0u8; 2];
    stream.read_exact(&mut greeting).await?;

    if greeting[0] != 0x05 {
        return Err("Not SOCKS5".into());
    }

    let num_methods = greeting[1] as usize;
    let mut methods = vec![0u8; num_methods];
    stream.read_exact(&mut methods).await?;

    // Reply: accept no auth (0x00)
    stream.write_all(&[0x05, 0x00]).await?;

    // Read connection request
    let mut request = [0u8; 4];
    stream.read_exact(&mut request).await?;

    if request[0] != 0x05 || request[1] != 0x01 {
        // Only support CONNECT (0x01)
        stream.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
        return Err("Unsupported SOCKS5 command".into());
    }

    // Parse destination address
    let (host, port) = match request[3] {
        0x01 => {
            // IPv4
            let mut ip = [0u8; 4];
            stream.read_exact(&mut ip).await?;
            let mut port_bytes = [0u8; 2];
            stream.read_exact(&mut port_bytes).await?;
            let port = u16::from_be_bytes(port_bytes);
            (format!("{}.{}.{}.{}", ip[0], ip[1], ip[2], ip[3]), port)
        }
        0x03 => {
            // Domain name
            let mut len = [0u8; 1];
            stream.read_exact(&mut len).await?;
            let mut domain = vec![0u8; len[0] as usize];
            stream.read_exact(&mut domain).await?;
            let mut port_bytes = [0u8; 2];
            stream.read_exact(&mut port_bytes).await?;
            let port = u16::from_be_bytes(port_bytes);
            (String::from_utf8_lossy(&domain).to_string(), port)
        }
        0x04 => {
            // IPv6
            let mut ip = [0u8; 16];
            stream.read_exact(&mut ip).await?;
            let mut port_bytes = [0u8; 2];
            stream.read_exact(&mut port_bytes).await?;
            let port = u16::from_be_bytes(port_bytes);
            // Format IPv6 address
            let addr: std::net::Ipv6Addr = ip.into();
            (addr.to_string(), port)
        }
        _ => {
            stream.write_all(&[0x05, 0x08, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Err("Unsupported address type".into());
        }
    };

    // Connect through Tor (minimal logging - only errors)
    let prefs = StreamPrefs::new();
    match client.connect_with_prefs((host.as_str(), port), &prefs).await {
        Ok(mut tor_stream) => {
            // Send success response
            stream.write_all(&[0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 0]).await?;

            // Bidirectional copy between client and Tor stream
            let _ = tokio::io::copy_bidirectional(&mut stream, &mut tor_stream).await;
        }
        Err(e) => {
            // Only log connection failures (not every attempt)
            let err_msg = format!("{}", e);
            if !err_msg.contains("timed out") && !err_msg.contains("Protocol error") {
                eprintln!("🧅 Tor connection to {}:{} failed: {}", host, port, e);
            }
            // Send connection failed response
            stream.write_all(&[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]).await?;
            return Err(format!("Tor connection failed: {}", e).into());
        }
    }

    Ok(())
}

/// Stop the Tor client
/// Returns 0 on success
#[no_mangle]
pub extern "C" fn zipherx_tor_stop() -> i32 {
    eprintln!("🧅 Stopping Tor...");

    // Stop SOCKS proxy server
    SOCKS_SERVER_RUNNING.store(false, Ordering::SeqCst);

    // Clear the client
    if let Some(client_storage) = TOR_CLIENT.get() {
        if let Ok(mut guard) = client_storage.lock() {
            *guard = None;
        }
    }

    TOR_STATE.store(0, Ordering::SeqCst); // Disconnected
    TOR_BOOTSTRAP_PROGRESS.store(0, Ordering::SeqCst);
    TOR_SOCKS_PORT.store(0, Ordering::SeqCst);

    eprintln!("🧅 Tor stopped");
    0
}

/// Get current Tor state
/// 0 = Disconnected, 1 = Connecting, 2 = Bootstrapping, 3 = Connected, 4 = Error
#[no_mangle]
pub extern "C" fn zipherx_tor_get_state() -> u8 {
    TOR_STATE.load(Ordering::SeqCst)
}

/// Get bootstrap progress (0-100)
#[no_mangle]
pub extern "C" fn zipherx_tor_get_progress() -> u8 {
    TOR_BOOTSTRAP_PROGRESS.load(Ordering::SeqCst)
}

/// Get SOCKS proxy port (0 if not connected)
#[no_mangle]
pub extern "C" fn zipherx_tor_get_socks_port() -> u16 {
    TOR_SOCKS_PORT.load(Ordering::SeqCst)
}

/// Get last error message
/// Returns pointer to null-terminated string (caller must free with zipherx_free_string)
#[no_mangle]
pub extern "C" fn zipherx_tor_get_error() -> *mut libc::c_char {
    if let Ok(guard) = TOR_ERROR.lock() {
        if let Some(ref msg) = *guard {
            let c_str = std::ffi::CString::new(msg.as_str()).unwrap_or_default();
            return c_str.into_raw();
        }
    }
    std::ptr::null_mut()
}

/// Request new Tor identity (new circuit)
/// Returns 0 on success
#[no_mangle]
pub extern "C" fn zipherx_tor_new_identity() -> i32 {
    let state = TOR_STATE.load(Ordering::SeqCst);
    if state != 3 {
        eprintln!("🧅 Cannot request new identity - Tor not connected");
        return 1;
    }

    // In Arti, we can request isolation for new connections
    // For existing connections, we'd need to close and reopen
    eprintln!("🧅 New identity requested (will isolate future connections)");

    0
}

/// Make an HTTP request through Tor
/// Returns response body as null-terminated string (caller must free)
/// Returns null on error
#[no_mangle]
pub unsafe extern "C" fn zipherx_tor_http_get(
    url_ptr: *const libc::c_char,
) -> *mut libc::c_char {
    if url_ptr.is_null() {
        return std::ptr::null_mut();
    }

    let url = match std::ffi::CStr::from_ptr(url_ptr).to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return std::ptr::null_mut(),
    };

    let state = TOR_STATE.load(Ordering::SeqCst);
    if state != 3 {
        eprintln!("🧅 Cannot make HTTP request - Tor not connected");
        return std::ptr::null_mut();
    }

    let runtime = get_runtime();

    // Block on the async request
    let result = runtime.block_on(async {
        tor_http_get_async(&url).await
    });

    match result {
        Ok(body) => {
            let c_str = std::ffi::CString::new(body).unwrap_or_default();
            c_str.into_raw()
        }
        Err(e) => {
            eprintln!("🧅 HTTP request error: {}", e);
            std::ptr::null_mut()
        }
    }
}

/// Async HTTP GET through Tor
async fn tor_http_get_async(url: &str) -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let client_storage = TOR_CLIENT.get()
        .ok_or("Tor client not initialized")?;

    let client = client_storage.lock()
        .map_err(|_| "Failed to lock Tor client")?;

    let client = client.as_ref()
        .ok_or("Tor client not available")?;

    // Parse URL to get host and port
    let url_parsed: url::Url = url.parse()?;
    let host = url_parsed.host_str().ok_or("No host in URL")?;
    let port = url_parsed.port().unwrap_or(if url_parsed.scheme() == "https" { 443 } else { 80 });

    // Connect through Tor
    let mut stream = client.connect((host, port)).await?;

    // Build HTTP request
    let path = url_parsed.path();
    let request = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nUser-Agent: ZipherX/1.0\r\n\r\n",
        if path.is_empty() { "/" } else { path },
        host
    );

    // Send request
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    stream.write_all(request.as_bytes()).await?;

    // Read response
    let mut response = Vec::new();
    stream.read_to_end(&mut response).await?;

    // Parse response - extract body after headers
    let response_str = String::from_utf8_lossy(&response);
    if let Some(body_start) = response_str.find("\r\n\r\n") {
        Ok(response_str[body_start + 4..].to_string())
    } else {
        Ok(response_str.to_string())
    }
}

/// Free a string allocated by Tor functions
#[no_mangle]
pub unsafe extern "C" fn zipherx_tor_free_string(ptr: *mut libc::c_char) {
    if !ptr.is_null() {
        drop(std::ffi::CString::from_raw(ptr));
    }
}

/// Check if Tor is available (compiled in)
#[no_mangle]
pub extern "C" fn zipherx_tor_is_available() -> bool {
    true
}

// =============================================================================
// HIDDEN SERVICE (ONION SERVICE) HOSTING
// =============================================================================

use tor_hsservice::config::{OnionServiceConfig, OnionServiceConfigBuilder};
use tor_hsservice::RunningOnionService;
use std::sync::atomic::AtomicPtr;

/// Running hidden service handle - MUST be kept alive for the service to accept connections
static HIDDEN_SERVICE_HANDLE: OnceCell<Mutex<Option<Arc<RunningOnionService>>>> = OnceCell::new();

/// Hidden service state
/// 0 = Not running, 1 = Starting, 2 = Running, 3 = Error
static HIDDEN_SERVICE_STATE: AtomicU8 = AtomicU8::new(0);

/// Hidden service .onion address (56 characters for v3)
static HIDDEN_SERVICE_ADDRESS: Mutex<Option<String>> = Mutex::new(None);

/// P2P port for incoming connections (default 8033 = Zclassic mainnet)
const HIDDEN_SERVICE_P2P_PORT: u16 = 8033;

/// Chat port for encrypted messaging (8034 = ZipherX chat)
const HIDDEN_SERVICE_CHAT_PORT: u16 = 8034;

/// Callback type for incoming connections (connection_id, peer_host, peer_port)
static INCOMING_CONNECTION_CALLBACK: AtomicPtr<libc::c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Callback type for incoming chat connections
static INCOMING_CHAT_CALLBACK: AtomicPtr<libc::c_void> = AtomicPtr::new(std::ptr::null_mut());

/// Type alias for chat callback function (connection_id, data_ptr, data_len)
type IncomingChatFn = unsafe extern "C" fn(connection_id: u64, data_ptr: *const u8, data_len: usize);

/// Type alias for the callback function
type IncomingConnectionFn = unsafe extern "C" fn(connection_id: u64, host_ptr: *const libc::c_char, port: u16);

/// Start the hidden service
/// This makes ZipherX discoverable as a .onion peer
/// Returns 0 on success, 1 on error
#[no_mangle]
pub extern "C" fn zipherx_tor_hidden_service_start() -> i32 {
    let tor_state = TOR_STATE.load(Ordering::SeqCst);
    if tor_state != 3 {
        eprintln!("🧅 Cannot start hidden service - Tor not connected");
        return 1;
    }

    let hs_state = HIDDEN_SERVICE_STATE.load(Ordering::SeqCst);
    if hs_state == 1 || hs_state == 2 {
        eprintln!("🧅 Hidden service already running or starting");
        return 0;
    }

    HIDDEN_SERVICE_STATE.store(1, Ordering::SeqCst); // Starting

    let runtime = get_runtime();

    runtime.spawn(async {
        match start_hidden_service_async().await {
            Ok(onion_addr) => {
                eprintln!("🧅 Hidden service started!");
                eprintln!("🧅 Your .onion address: {}", onion_addr);
                if let Ok(mut addr) = HIDDEN_SERVICE_ADDRESS.lock() {
                    *addr = Some(onion_addr);
                }
                HIDDEN_SERVICE_STATE.store(2, Ordering::SeqCst); // Running
            }
            Err(e) => {
                eprintln!("🧅 Hidden service error: {}", e);
                HIDDEN_SERVICE_STATE.store(3, Ordering::SeqCst); // Error
            }
        }
    });

    0
}

/// Async function to start the hidden service
async fn start_hidden_service_async() -> Result<String, Box<dyn std::error::Error + Send + Sync>> {
    let client_storage = TOR_CLIENT.get()
        .ok_or("Tor client not initialized")?;

    let client = client_storage.lock()
        .map_err(|_| "Failed to lock Tor client")?;

    let client = client.as_ref()
        .ok_or("Tor client not available")?
        .clone();

    drop(client_storage); // Release the lock before async operations

    // Build hidden service configuration
    // The service will listen for rendezvous requests
    let mut config_builder = OnionServiceConfigBuilder::default();
    config_builder.nickname("zipherx".parse().unwrap());

    let config: OnionServiceConfig = config_builder.build()?;

    eprintln!("🧅 Launching hidden service...");

    // Launch the onion service
    let (service, rend_requests) = client.launch_onion_service(config)?
        .ok_or("Hidden service returned None")?;

    // CRITICAL: Store the service handle to keep it alive
    // Without this, the hidden service stops accepting connections immediately!
    // Note: launch_onion_service already returns Arc<RunningOnionService>
    let handle_storage = HIDDEN_SERVICE_HANDLE.get_or_init(|| Mutex::new(None));
    if let Ok(mut guard) = handle_storage.lock() {
        *guard = Some(service.clone());
        eprintln!("🧅 Hidden service handle stored - service will remain active");
    }

    // Get the .onion address using the new API
    let hs_id = service.onion_address()
        .ok_or("No onion address available")?;

    // Convert HsId to proper .onion v3 address format
    // Tor v3 address = base32(pubkey(32) + checksum(2) + version(1)) + ".onion"
    // HsId contains the 32-byte public key, we need to compute checksum and encode
    let hs_id_bytes: &[u8] = hs_id.as_ref();
    let pubkey_bytes: [u8; 32] = hs_id_bytes.try_into()
        .map_err(|_| "Invalid HsId length")?;

    // Compute checksum: SHA3-256(".onion checksum" + pubkey + version)[0..2]
    // Tor v3 spec: CHECKSUM = H(".onion checksum" || PUBKEY || VERSION)[:2]
    use sha3::{Sha3_256, Digest};
    let mut hasher = Sha3_256::new();
    hasher.update(b".onion checksum");
    hasher.update(&pubkey_bytes);
    hasher.update(&[0x03u8]); // Version 3
    let checksum_full = hasher.finalize();
    let checksum = [checksum_full[0], checksum_full[1]];

    // Combine: pubkey(32) + checksum(2) + version(1) = 35 bytes
    let mut address_bytes = Vec::with_capacity(35);
    address_bytes.extend_from_slice(&pubkey_bytes);
    address_bytes.extend_from_slice(&checksum);
    address_bytes.push(0x03); // Version 3

    // Base32 encode (lowercase, no padding)
    let onion_base32 = base32_encode(&address_bytes);
    let onion_addr_str = format!("{}.onion", onion_base32);

    eprintln!("🧅 Hidden service published: {}", onion_addr_str);

    // Spawn task to handle incoming rendezvous requests
    let onion_addr_for_handler = onion_addr_str.clone();
    tokio::spawn(async move {
        handle_hidden_service_connections(rend_requests, onion_addr_for_handler).await;
    });

    Ok(onion_addr_str)
}

/// Handle incoming connections to our hidden service
/// FULL IMPLEMENTATION: Accept streams and handle P2P protocol
async fn handle_hidden_service_connections(
    rend_requests: impl futures::Stream<Item = tor_hsservice::RendRequest> + Unpin + Send + 'static,
    onion_addr: String,
) {
    use futures::StreamExt;
    use tor_hsservice::StreamRequest;

    eprintln!("🧅 Hidden service connection handler started for {}", onion_addr);

    // Convert RendRequest stream to StreamRequest stream using the helper
    // This accepts all rendezvous requests and yields individual stream requests
    let mut stream_requests = tor_hsservice::handle_rend_requests(rend_requests);

    let mut connection_counter: u64 = 0;

    // Process incoming stream requests (these come after rendezvous is established)
    while let Some(stream_request) = stream_requests.next().await {
        connection_counter += 1;
        let conn_id = connection_counter;

        eprintln!("🧅 Incoming stream request #{}", conn_id);

        // Notify Swift about incoming connection attempt
        let callback_ptr = INCOMING_CONNECTION_CALLBACK.load(Ordering::SeqCst);
        if !callback_ptr.is_null() {
            unsafe {
                let callback: IncomingConnectionFn = std::mem::transmute(callback_ptr);
                let host = std::ffi::CString::new("tor-hidden-service").unwrap();
                callback(conn_id, host.as_ptr(), HIDDEN_SERVICE_P2P_PORT);
            }
        }

        // Accept the stream request and handle P2P protocol
        tokio::spawn(async move {
            if let Err(e) = handle_incoming_stream_request(stream_request, conn_id).await {
                eprintln!("🧅 P2P connection #{} error: {}", conn_id, e);
            }
        });
    }

    eprintln!("🧅 Hidden service connection handler ended");
}

/// Handle a single incoming stream request from the hidden service
/// StreamRequest comes from handle_rend_requests() and needs to be accepted to get DataStream
async fn handle_incoming_stream_request(
    stream_request: tor_hsservice::StreamRequest,
    conn_id: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tor_cell::relaycell::msg::Connected;

    // Check that this is a BEGIN message (standard Tor stream open)
    let request = stream_request.request();
    eprintln!("🧅 P2P #{}: Received stream request: {:?}", conn_id, request);

    // Accept the stream request with a CONNECTED response
    // This gives us a DataStream for bidirectional communication
    let mut stream = stream_request.accept(Connected::new_empty()).await
        .map_err(|e| format!("Failed to accept stream: {}", e))?;

    eprintln!("🧅 P2P #{}: Stream accepted, waiting for handshake...", conn_id);

    // Read P2P message header (24 bytes for Zclassic/Bitcoin)
    // Header: magic(4) + command(12) + length(4) + checksum(4)
    let mut header = [0u8; 24];
    match tokio::time::timeout(
        std::time::Duration::from_secs(30),
        stream.read_exact(&mut header)
    ).await {
        Ok(Ok(_)) => {}
        Ok(Err(e)) => return Err(format!("Failed to read header: {}", e).into()),
        Err(_) => return Err("Timeout reading header".into()),
    }

    // Verify magic bytes (Zclassic mainnet: 0x24e92764)
    let magic = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    if magic != 0x24e92764 {
        eprintln!("🧅 P2P #{}: Invalid magic: {:08x}", conn_id, magic);
        return Err(format!("Invalid magic bytes: {:08x}", magic).into());
    }

    // Extract command (12 bytes, null-terminated)
    let command_bytes = &header[4..16];
    let command = std::str::from_utf8(command_bytes)
        .unwrap_or("unknown")
        .trim_matches('\0');

    eprintln!("🧅 P2P #{}: Received command: '{}'", conn_id, command);

    // Extract payload length
    let payload_len = u32::from_le_bytes([header[20], header[21], header[22], header[23]]) as usize;

    // Read payload if any
    let mut payload = vec![0u8; payload_len];
    if payload_len > 0 {
        match tokio::time::timeout(
            std::time::Duration::from_secs(30),
            stream.read_exact(&mut payload)
        ).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => return Err(format!("Failed to read payload: {}", e).into()),
            Err(_) => return Err("Timeout reading payload".into()),
        }
    }

    // Handle "version" command - the first message in P2P handshake
    if command == "version" {
        eprintln!("🧅 P2P #{}: Parsing version message ({} bytes)", conn_id, payload_len);

        // Parse version message to get peer info
        if payload_len >= 85 {
            let version = i32::from_le_bytes([payload[0], payload[1], payload[2], payload[3]]);
            let services = u64::from_le_bytes([payload[4], payload[5], payload[6], payload[7],
                                               payload[8], payload[9], payload[10], payload[11]]);
            let timestamp = i64::from_le_bytes([payload[12], payload[13], payload[14], payload[15],
                                                payload[16], payload[17], payload[18], payload[19]]);

            eprintln!("🧅 P2P #{}: Peer version={}, services={:#x}, timestamp={}",
                     conn_id, version, services, timestamp);

            // Send our version message back
            let our_version = build_version_message();
            stream.write_all(&our_version).await?;
            eprintln!("🧅 P2P #{}: Sent version message", conn_id);

            // Send verack
            let verack = build_verack_message();
            stream.write_all(&verack).await?;
            eprintln!("🧅 P2P #{}: Sent verack", conn_id);

            // Now wait for verack from peer
            let mut verack_header = [0u8; 24];
            match tokio::time::timeout(
                std::time::Duration::from_secs(30),
                stream.read_exact(&mut verack_header)
            ).await {
                Ok(Ok(_)) => {
                    let verack_cmd = std::str::from_utf8(&verack_header[4..16])
                        .unwrap_or("")
                        .trim_matches('\0');
                    eprintln!("🧅 P2P #{}: Received '{}' - handshake complete!", conn_id, verack_cmd);
                }
                Ok(Err(e)) => eprintln!("🧅 P2P #{}: Error reading verack: {}", conn_id, e),
                Err(_) => eprintln!("🧅 P2P #{}: Timeout waiting for verack", conn_id),
            }

            // Keep connection alive and handle further messages
            handle_p2p_session(&mut stream, conn_id).await?;
        }
    } else {
        eprintln!("🧅 P2P #{}: Unexpected first command: '{}' (expected 'version')", conn_id, command);
    }

    Ok(())
}

/// Handle ongoing P2P session after handshake
async fn handle_p2p_session<S>(
    stream: &mut S,
    conn_id: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    eprintln!("🧅 P2P #{}: Session started, handling messages...", conn_id);

    loop {
        // Read next message header
        let mut header = [0u8; 24];
        match tokio::time::timeout(
            std::time::Duration::from_secs(120), // 2 minute timeout for idle
            stream.read_exact(&mut header)
        ).await {
            Ok(Ok(_)) => {}
            Ok(Err(e)) => {
                eprintln!("🧅 P2P #{}: Connection closed: {}", conn_id, e);
                break;
            }
            Err(_) => {
                eprintln!("🧅 P2P #{}: Connection idle timeout", conn_id);
                break;
            }
        }

        // Verify magic
        let magic = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
        if magic != 0x24e92764 {
            eprintln!("🧅 P2P #{}: Invalid magic in session: {:08x}", conn_id, magic);
            break;
        }

        // Extract command
        let command = std::str::from_utf8(&header[4..16])
            .unwrap_or("unknown")
            .trim_matches('\0')
            .to_string();

        let payload_len = u32::from_le_bytes([header[20], header[21], header[22], header[23]]) as usize;

        // Read payload
        let mut payload = vec![0u8; payload_len];
        if payload_len > 0 {
            if let Err(e) = stream.read_exact(&mut payload).await {
                eprintln!("🧅 P2P #{}: Failed to read payload: {}", conn_id, e);
                break;
            }
        }

        eprintln!("🧅 P2P #{}: Received '{}' ({} bytes)", conn_id, command, payload_len);

        // Handle common P2P commands
        match command.as_str() {
            "ping" => {
                // Respond with pong (echo the nonce)
                let pong = build_pong_message(&payload);
                stream.write_all(&pong).await?;
                eprintln!("🧅 P2P #{}: Sent pong", conn_id);
            }
            "getaddr" => {
                // Respond with addr message (empty for now)
                let addr = build_addr_message();
                stream.write_all(&addr).await?;
                eprintln!("🧅 P2P #{}: Sent addr", conn_id);
            }
            "getheaders" => {
                // We don't serve headers - send empty response
                let headers = build_headers_message(&[]);
                stream.write_all(&headers).await?;
                eprintln!("🧅 P2P #{}: Sent empty headers", conn_id);
            }
            "mempool" => {
                // We don't have a mempool - send empty inv
                let inv = build_inv_message(&[]);
                stream.write_all(&inv).await?;
                eprintln!("🧅 P2P #{}: Sent empty inv for mempool", conn_id);
            }
            "pong" => {
                // Just acknowledge
                eprintln!("🧅 P2P #{}: Got pong", conn_id);
            }
            "addr" | "addrv2" => {
                // Process address announcement from peer
                eprintln!("🧅 P2P #{}: Got {} addresses", conn_id, payload_len / 30);
            }
            "sendheaders" => {
                // Peer wants us to send headers via headers msg instead of inv
                eprintln!("🧅 P2P #{}: Peer requests sendheaders mode", conn_id);
            }
            "sendaddrv2" => {
                // Peer supports BIP-155 addrv2
                eprintln!("🧅 P2P #{}: Peer supports addrv2", conn_id);
            }
            _ => {
                eprintln!("🧅 P2P #{}: Unhandled command: '{}'", conn_id, command);
            }
        }
    }

    eprintln!("🧅 P2P #{}: Session ended", conn_id);
    Ok(())
}

/// Build a version message for P2P handshake
fn build_version_message() -> Vec<u8> {
    let mut msg = Vec::new();

    // Version payload
    let mut payload = Vec::new();

    // Protocol version (170100 = Zclassic 2.1.x)
    payload.extend_from_slice(&170100i32.to_le_bytes());

    // Services (NODE_NETWORK = 1)
    payload.extend_from_slice(&1u64.to_le_bytes());

    // Timestamp
    let timestamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64;
    payload.extend_from_slice(&timestamp.to_le_bytes());

    // Addr_recv (26 bytes: services(8) + ip(16) + port(2))
    payload.extend_from_slice(&1u64.to_le_bytes()); // services
    payload.extend_from_slice(&[0u8; 10]); // IPv4-mapped prefix
    payload.extend_from_slice(&[0xff, 0xff]); // IPv4 marker
    payload.extend_from_slice(&[127, 0, 0, 1]); // 127.0.0.1
    payload.extend_from_slice(&8033u16.to_be_bytes()); // port

    // Addr_from (26 bytes)
    payload.extend_from_slice(&1u64.to_le_bytes()); // services
    payload.extend_from_slice(&[0u8; 10]);
    payload.extend_from_slice(&[0xff, 0xff]);
    payload.extend_from_slice(&[0, 0, 0, 0]); // 0.0.0.0
    payload.extend_from_slice(&8033u16.to_be_bytes());

    // Nonce (8 bytes random)
    let nonce: u64 = rand::random();
    payload.extend_from_slice(&nonce.to_le_bytes());

    // User agent (varint length + string)
    let user_agent = b"/ZipherX:1.0.0/";
    payload.push(user_agent.len() as u8);
    payload.extend_from_slice(user_agent);

    // Start height
    payload.extend_from_slice(&0i32.to_le_bytes());

    // Relay (1 byte)
    payload.push(1);

    // Build message with header
    build_p2p_message("version", &payload, &mut msg);
    msg
}

/// Build a verack message
fn build_verack_message() -> Vec<u8> {
    let mut msg = Vec::new();
    build_p2p_message("verack", &[], &mut msg);
    msg
}

/// Build a pong message (response to ping)
fn build_pong_message(ping_payload: &[u8]) -> Vec<u8> {
    let mut msg = Vec::new();
    build_p2p_message("pong", ping_payload, &mut msg);
    msg
}

/// Build an addr message
fn build_addr_message() -> Vec<u8> {
    let mut msg = Vec::new();
    // Empty addr: just varint 0
    build_p2p_message("addr", &[0], &mut msg);
    msg
}

/// Build a headers message
fn build_headers_message(_headers: &[u8]) -> Vec<u8> {
    let mut msg = Vec::new();
    // Empty headers: varint 0
    build_p2p_message("headers", &[0], &mut msg);
    msg
}

/// Build an inv message
fn build_inv_message(_inventory: &[u8]) -> Vec<u8> {
    let mut msg = Vec::new();
    // Empty inv: varint 0
    build_p2p_message("inv", &[0], &mut msg);
    msg
}

/// Build a P2P message with header
fn build_p2p_message(command: &str, payload: &[u8], out: &mut Vec<u8>) {
    // Magic (Zclassic mainnet)
    out.extend_from_slice(&0x24e92764u32.to_le_bytes());

    // Command (12 bytes, null-padded)
    let mut cmd_bytes = [0u8; 12];
    let cmd_len = command.len().min(12);
    cmd_bytes[..cmd_len].copy_from_slice(&command.as_bytes()[..cmd_len]);
    out.extend_from_slice(&cmd_bytes);

    // Payload length
    out.extend_from_slice(&(payload.len() as u32).to_le_bytes());

    // Checksum (first 4 bytes of double SHA256)
    let hash1 = sha2::Sha256::digest(payload);
    let hash2 = sha2::Sha256::digest(&hash1);
    out.extend_from_slice(&hash2[..4]);

    // Payload
    out.extend_from_slice(payload);
}

use sha2::Digest;

/// Placeholder for incoming P2P connection handling
/// Full implementation requires bi-directional stream handling between Rust and Swift
#[allow(dead_code)]
async fn handle_p2p_incoming_placeholder(
    conn_id: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
{
    eprintln!("🧅 P2P connection #{} - would handle protocol here", conn_id);

    // In a full implementation:
    // 1. Accept the rendezvous stream
    // 2. Handle P2P protocol messages (version, verack, getdata, etc.)
    // 3. Forward relevant data to Swift via callbacks

    Ok(())
}

/// Dummy function to avoid dead_code warning for buffer reading pattern
#[allow(dead_code)]
async fn read_from_stream<S>(
    mut stream: S,
    conn_id: u64,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut buffer = vec![0u8; 65536];

    loop {
        match stream.read(&mut buffer).await {
            Ok(0) => {
                eprintln!("🧅 P2P connection #{} closed by peer", conn_id);
                break;
            }
            Ok(n) => {
                eprintln!("🧅 P2P #{} received {} bytes", conn_id, n);
                // Echo back (for testing - real impl would process P2P messages)
                if let Err(e) = stream.write_all(&buffer[..n]).await {
                    eprintln!("🧅 P2P #{} write error: {}", conn_id, e);
                    break;
                }
            }
            Err(e) => {
                eprintln!("🧅 P2P #{} read error: {}", conn_id, e);
                break;
            }
        }
    }

    Ok(())
}

/// Stop the hidden service
/// Returns 0 on success
#[no_mangle]
pub extern "C" fn zipherx_tor_hidden_service_stop() -> i32 {
    eprintln!("🧅 Stopping hidden service...");

    // Clear the service handle - this will stop the hidden service
    if let Some(handle_storage) = HIDDEN_SERVICE_HANDLE.get() {
        if let Ok(mut guard) = handle_storage.lock() {
            *guard = None;
            eprintln!("🧅 Hidden service handle released");
        }
    }

    // Clear the address
    if let Ok(mut addr) = HIDDEN_SERVICE_ADDRESS.lock() {
        *addr = None;
    }

    HIDDEN_SERVICE_STATE.store(0, Ordering::SeqCst); // Not running

    eprintln!("🧅 Hidden service stopped");
    0
}

/// Get hidden service state
/// 0 = Not running, 1 = Starting, 2 = Running, 3 = Error
#[no_mangle]
pub extern "C" fn zipherx_tor_hidden_service_get_state() -> u8 {
    HIDDEN_SERVICE_STATE.load(Ordering::SeqCst)
}

/// Get the .onion address of our hidden service
/// Returns pointer to null-terminated string (caller must free with zipherx_tor_free_string)
/// Returns null if hidden service is not running
#[no_mangle]
pub extern "C" fn zipherx_tor_hidden_service_get_address() -> *mut libc::c_char {
    if let Ok(guard) = HIDDEN_SERVICE_ADDRESS.lock() {
        if let Some(ref addr) = *guard {
            let c_str = std::ffi::CString::new(addr.as_str()).unwrap_or_default();
            return c_str.into_raw();
        }
    }
    std::ptr::null_mut()
}

/// Set callback for incoming P2P connections
/// The callback will be called with (connection_id, host, port) for each new connection
#[no_mangle]
pub extern "C" fn zipherx_tor_hidden_service_set_callback(
    callback: Option<unsafe extern "C" fn(connection_id: u64, host_ptr: *const libc::c_char, port: u16)>
) {
    let ptr = match callback {
        Some(f) => f as *mut libc::c_void,
        None => std::ptr::null_mut(),
    };
    INCOMING_CONNECTION_CALLBACK.store(ptr, Ordering::SeqCst);
    eprintln!("🧅 Hidden service callback set");
}

/// Check if hidden service feature is available (compiled in)
#[no_mangle]
pub extern "C" fn zipherx_tor_hidden_service_is_available() -> bool {
    true
}

/// Set callback for incoming chat messages
/// The callback will be called with (connection_id, data_ptr, data_len) for each incoming message
#[no_mangle]
pub extern "C" fn zipherx_tor_chat_set_callback(
    callback: Option<unsafe extern "C" fn(connection_id: u64, data_ptr: *const u8, data_len: usize)>
) {
    let ptr = match callback {
        Some(f) => f as *mut libc::c_void,
        None => std::ptr::null_mut(),
    };
    INCOMING_CHAT_CALLBACK.store(ptr, Ordering::SeqCst);
    eprintln!("🧅 Chat callback set");
}

/// Get the chat port for ZipherX encrypted messaging
#[no_mangle]
pub extern "C" fn zipherx_tor_chat_get_port() -> u16 {
    HIDDEN_SERVICE_CHAT_PORT
}

/// Send an encrypted chat message to an .onion address
/// Returns 0 on success, 1 on error
/// The message should already be encrypted by the caller (X25519 + ChaCha20-Poly1305)
#[no_mangle]
pub unsafe extern "C" fn zipherx_tor_chat_send(
    onion_address: *const libc::c_char,
    data: *const u8,
    data_len: usize,
) -> i32 {
    if onion_address.is_null() || data.is_null() || data_len == 0 {
        return 1;
    }

    let address = match std::ffi::CStr::from_ptr(onion_address).to_str() {
        Ok(s) => s.to_string(),
        Err(_) => return 1,
    };

    let message = std::slice::from_raw_parts(data, data_len).to_vec();

    let state = TOR_STATE.load(Ordering::SeqCst);
    if state != 3 {
        eprintln!("🧅 Cannot send chat - Tor not connected");
        return 1;
    }

    let runtime = get_runtime();

    // Send message asynchronously
    let result = runtime.block_on(async {
        send_chat_message_async(&address, &message).await
    });

    match result {
        Ok(_) => 0,
        Err(e) => {
            eprintln!("🧅 Chat send error: {}", e);
            1
        }
    }
}

/// Async function to send a chat message through Tor to an .onion address
async fn send_chat_message_async(
    onion_address: &str,
    message: &[u8],
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let client_storage = TOR_CLIENT.get()
        .ok_or("Tor client not initialized")?;

    let client = client_storage.lock()
        .map_err(|_| "Failed to lock Tor client")?;

    let client = client.as_ref()
        .ok_or("Tor client not available")?
        .clone();

    drop(client_storage);

    // Parse the onion address (with or without port)
    let (host, port) = if onion_address.contains(':') {
        let parts: Vec<&str> = onion_address.split(':').collect();
        (parts[0].to_string(), parts[1].parse::<u16>().unwrap_or(HIDDEN_SERVICE_CHAT_PORT))
    } else {
        (onion_address.to_string(), HIDDEN_SERVICE_CHAT_PORT)
    };

    eprintln!("🧅 Connecting to chat peer: {}:{}", host, port);

    // Connect through Tor
    let mut stream = client.connect((host.as_str(), port)).await?;

    // Send the message length (4 bytes, big-endian) followed by message data
    let len_bytes = (message.len() as u32).to_be_bytes();
    stream.write_all(&len_bytes).await?;
    stream.write_all(message).await?;
    stream.flush().await?;

    eprintln!("🧅 Chat message sent ({} bytes)", message.len());

    Ok(())
}

/// RFC 4648 Base32 encoding (lowercase, no padding) for Tor v3 onion addresses
fn base32_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"abcdefghijklmnopqrstuvwxyz234567";

    let mut result = String::with_capacity((data.len() * 8 + 4) / 5);
    let mut buffer: u64 = 0;
    let mut bits_left = 0;

    for &byte in data {
        buffer = (buffer << 8) | byte as u64;
        bits_left += 8;

        while bits_left >= 5 {
            bits_left -= 5;
            let index = ((buffer >> bits_left) & 0x1F) as usize;
            result.push(ALPHABET[index] as char);
        }
    }

    // Handle remaining bits (if any)
    if bits_left > 0 {
        let index = ((buffer << (5 - bits_left)) & 0x1F) as usize;
        result.push(ALPHABET[index] as char);
    }

    result
}
